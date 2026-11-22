#!/bin/bash
# Install vmgui-agent in a macOS VM (run as the user, from the unpacked
# vmgui-agent-macos-<arch> folder):
#
#   ./install.sh <cid> [fps]
#
# <cid> is the VM's vsock CID from `vmgui list` on the host. Installs a
# LaunchAgent, which runs the agent in the user's GUI session. Then allow
# vmgui-agent in System Settings > Privacy & Security under Screen Recording
# (capture) and Accessibility (input).
set -euo pipefail

die() { echo "install.sh: $*" >&2; exit 1; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cid=${1:-}
fps=${2:-15}
[[ $cid =~ ^[0-9]{1,7}$ ]] && ((cid >= 3 && cid <= 1000000)) || die "usage: install.sh <cid 3..1000000> [fps]"
[[ $fps =~ ^[0-9]{1,2}$ ]] && ((fps >= 1 && fps <= 60)) || die "fps must be 1..60"
[[ $(uname -s) == Darwin ]] || die "this is not macOS"

bin="$HOME/Library/Application Support/vmgui/vmgui-agent"
plist="$HOME/Library/LaunchAgents/org.scroll-secure.vmgui-agent.plist"
install -d "$(dirname "$bin")" "$(dirname "$plist")"
install -m 0755 "$HERE/vmgui-agent" "$bin"
sed -e "s|@BIN@|$bin|" -e "s|@CID@|$cid|" -e "s|@FPS@|$fps|" "$HERE/org.scroll-secure.vmgui-agent.plist" > "$plist"
launchctl bootout "gui/$(id -u)" "$plist" 2> /dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "vmgui-agent installed (CID $cid). Allow it under Screen Recording and Accessibility."
