#!/usr/bin/env bash
# Stage the llm payload (llm/README.md) into the new system, if the installer USB has a
# SCROLL-PAYLOAD partition (build-iso.sh --payload). install.sh calls it with the target's
# /var once bootc has installed; on first boot llm-firstboot.service runs
# `llm import --consume` on it: sha256s checked there, the model moved (same
# filesystem), the server started.
#
#   install-payload.sh <target /var>      # e.g. /mnt/state/os/default/var
#
# Without the partition it does nothing and exits 0. Copies only what SHA256SUMS lists.
set -euo pipefail

die() { echo "install-payload: $*" >&2; exit 1; }

var=${1:?usage: install-payload.sh <target /var>}
[[ -d "${var}" ]] || die "no ${var}"
dev=$(blkid -L SCROLL-PAYLOAD 2> /dev/null || true)
[[ -n "${dev}" ]] || exit 0

src=$(mktemp -d)
trap 'umount "${src}" 2> /dev/null || true; rmdir "${src}"' EXIT
# The live system mounts the whole USB disk (the ISO is found on it, not on partition 1),
# and that exclusive claim keeps the partition itself from being mounted. A read-only
# loop device over the disk at the partition's offset isn't blocked.
parent=$(lsblk -dno PKNAME "${dev}")
if [[ -n "${parent}" ]]; then
    part=/sys/class/block/$(basename "$(readlink -f "${dev}")")
    mount -o "ro,loop,offset=$(( $(< "${part}/start") * 512 )),sizelimit=$(( $(< "${part}/size") * 512 ))" \
        "/dev/${parent}" "${src}"
else
    mount -o ro "${dev}" "${src}"
fi
[[ -s "${src}/SHA256SUMS" ]] || die "${dev}: no SHA256SUMS"
mapfile -t names < <(sed -n 's/^[0-9a-f]\{64\}  \*\{0,1\}\([A-Za-z0-9._+-]*\)$/\1/p' "${src}/SHA256SUMS")
[[ ${#names[@]} -eq $(grep -c . "${src}/SHA256SUMS") ]] || die "${dev}: SHA256SUMS has lines that aren't <sha256>  <name>"

need=$(cd "${src}" && du -cb -- "${names[@]}" | tail -1 | cut -f1)
free=$(df -B1 --output=avail "${var}" | tail -1)
(( free > need + (8 << 30) )) || die "the target needs $((need >> 30)) GiB for the payload plus 8 GiB to spare; $((free >> 30)) GiB free"

dst=${var}/lib/llm/payload
echo "Copying the llm payload ($((need >> 20)) MiB) into the new system..."
mkdir -p "${dst}"
chmod 0700 "${var}/lib/llm" "${dst}"
for n in "${names[@]}" SHA256SUMS; do
    cp -- "${src}/${n}" "${dst}/${n}"
done
sync -f "${dst}"
# As install.sh does for the home directory: the live system's labels don't fit.
chcon -R system_u:object_r:var_lib_t:s0 "${var}/lib/llm"
echo "The model server starts on first boot (llm-firstboot.service)."
