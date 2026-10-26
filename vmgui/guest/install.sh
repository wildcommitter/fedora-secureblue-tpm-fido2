#!/usr/bin/env bash
# Install the vmgui guest addon in a Fedora VM (run inside the guest, as root):
#
#   ./install.sh [<user>]     # default user: the one who ran sudo/run0
#
# Installs waypipe, the addon files (vmgui-guest + its user unit, environment.d),
# enables the unit for every user and lingering for <user>, so the forwarder runs
# without a login on the guest. Apps then reach the host with `vmgui run` there,
# or from any shell in the guest's user session.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
die() { echo "install.sh: $*" >&2; exit 1; }

[[ $(id -u) -eq 0 ]] || die "run as root inside the guest"
[[ $(systemd-detect-virt --vm || true) != none ]] || die "this is not a VM; the addon belongs in the guest"
user=${1:-${SUDO_USER:-${RUN0_USER:-}}}
[[ -n $user ]] && id "$user" > /dev/null 2>&1 || die "usage: install.sh <guest user>"

command -v waypipe > /dev/null || dnf -y install waypipe
install -D -m 0755 "$HERE/usr/libexec/vmgui/vmgui-guest" /usr/libexec/vmgui/vmgui-guest
install -D -m 0644 "$HERE/usr/lib/systemd/user/vmgui-guest.service" /usr/lib/systemd/user/vmgui-guest.service
install -D -m 0644 "$HERE/usr/lib/environment.d/60-vmgui.conf" /usr/lib/environment.d/60-vmgui.conf
systemctl --global enable vmgui-guest.service
loginctl enable-linger "$user"
systemctl --user -M "$user@" daemon-reload 2> /dev/null || true
systemctl --user -M "$user@" restart vmgui-guest.service 2> /dev/null || true
echo "vmgui guest addon installed for $user."
