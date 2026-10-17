#!/usr/bin/env bash
# Builds the sealed-UKI e2e VM disk (run as root), mirroring image/uki/install.sh:
# GPT with a 2G ESP (mounted at /boot) and a LUKS2 root of GPT type
# root-x86-64 (8304) holding btrfs, then `bootc install to-filesystem
# --bootloader=systemd --composefs-backend` from the given image.
#
# Lab-only additions (never in the image): root autologin on ttyS0, and the
# DEV-key-signed serial-console UKI addon from lab-secureboot.sh on the ESP.
#
#   sudo test/bootc/build-disk.sh <workdir> <image in the invoking user's podman storage>
set -euo pipefail

W=$(readlink -f "${1:?workdir}")
IMAGE=${2:?image ref in the invoking users podman storage}
LAB_RECOVERY=${LAB_RECOVERY:-lab-recovery-passphrase}
DISK=$W/disk.raw
MNT=$(mktemp -d /var/tmp/tokenvault-uki.XXXXXX)
MAPPED=tvlab-root
ADDON=$W/lab-serial-console.addon.efi

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -f $W/OVMF_VARS.sb.fd ]] || { echo "run lab-secureboot.sh first" >&2; exit 1; }

LOOP=
cleanup() {
    set +e
    for m in "$MNT/boot" "$MNT"; do mountpoint -q "$m" && umount "$m"; done
    [[ -e /dev/mapper/$MAPPED ]] && cryptsetup close "$MAPPED"
    [[ -n $LOOP ]] && losetup -d "$LOOP"
    rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

rm -f "$DISK"
truncate -s 32G "$DISK"
sfdisk -q "$DISK" <<'EOF'
label: gpt
size=2GiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=esp
type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name=root-x86-64
EOF
LOOP=$(losetup -f --show -P "$DISK")
udevadm settle
printf %s "$LAB_RECOVERY" | cryptsetup luksFormat -q "${LOOP}p2" -
printf %s "$LAB_RECOVERY" | cryptsetup open "${LOOP}p2" "$MAPPED" -
mkfs.btrfs -q "/dev/mapper/$MAPPED"
mkfs.vfat -F 32 "${LOOP}p1" >/dev/null
UUID=$(cryptsetup luksUUID "${LOOP}p2")
ESP_PARTUUID=$(blkid -s PARTUUID -o value "${LOOP}p1")
mount -o compress=zstd:1 "/dev/mapper/$MAPPED" "$MNT"
mkdir "$MNT/boot"
mount "${LOOP}p1" "$MNT/boot"

# bootc's composefs backend cannot import from containers-storage (invalid
# splitstream), and install.sh installs from a registry anyway. The image is
# served from a throwaway loopback registry, pushed straight from the
# builder's (rootless) storage: a save/load round trip rewrites the manifest
# and bootc then rejects it ("Manifest integrity failed").
REG=127.0.0.1:5077
LAB_REF=$REG/tokenvault-lab:latest
OWNER=${SUDO_USER:?run via sudo from the user that built the image}
as_owner() { runuser -u "$OWNER" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$OWNER")" "$@"; }
as_owner podman rm -f tokenvault-lab-registry >/dev/null 2>&1 || true
as_owner podman run -d --rm --name tokenvault-lab-registry -p "$REG:5000" docker.io/library/registry:2 >/dev/null
trap 'as_owner podman rm -f tokenvault-lab-registry >/dev/null 2>&1; cleanup' EXIT
for _ in $(seq 1 50); do curl -fs "http://$REG/v2/" >/dev/null && break; sleep 0.2; done
as_owner podman push -q --tls-verify=false "$IMAGE" "docker://$LAB_REF"
podman pull -q --tls-verify=false "$LAB_REF" >/dev/null

# The image's own policy.json only admits its signed refs; the local dev
# image needs a permissive policy (and an insecure loopback registry) for
# this installer run only.
printf '{"default":[{"type":"insecureAcceptAnything"}]}\n' > "$W/install-policy.json"
printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "$REG" > "$W/install-registries.conf"
podman run --rm --privileged --pid=host --ipc=host --network=host \
    --security-opt label=type:unconfined_t \
    -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v "$MNT:/target" \
    -v "$W/install-policy.json:/etc/containers/policy.json:ro" \
    -v "$W/install-registries.conf:/etc/containers/registries.conf.d/99-lab.conf:ro" \
    "$LAB_REF" bootc install to-filesystem \
        --source-imgref "registry:$LAB_REF" --target-imgref "$IMAGE" \
        --bootloader=systemd --composefs-backend --skip-finalize \
        /target 2>&1 | tail -40
as_owner podman rm -f tokenvault-lab-registry >/dev/null 2>&1 || true

# As install.sh: systemd-boot menu timeout and the ESP mount on the target.
sed -i 's/#timeout 3/timeout 3/' "$MNT/boot/loader/loader.conf"
shopt -s nullglob
etc_dirs=("$MNT"/state/deploy/*/etc)
[[ ${#etc_dirs[@]} -eq 1 && -d ${etc_dirs[0]:-} ]] \
    || { echo "expected one deployment, found: ${etc_dirs[*]:-none}" >&2; exit 1; }
etc_dir=${etc_dirs[0]}
escaped_esp=$(systemd-escape -p "/dev/disk/by-partuuid/$ESP_PARTUUID")
cat > "$etc_dir/systemd/system/boot.mount" <<EOF
[Unit]
Description=EFI System Partition
Requires=systemd-fsck@${escaped_esp}.service
After=systemd-fsck@${escaped_esp}.service
After=blockdev@${escaped_esp}.target

[Mount]
What=/dev/disk/by-partuuid/$ESP_PARTUUID
Where=/boot
Type=vfat
Options=fmask=0177,dmask=0077,rw,nodev,nosuid,noexec

[Install]
WantedBy=local-fs.target
EOF
mkdir -p "$etc_dir/systemd/system/local-fs.target.wants"
ln -sf /etc/systemd/system/boot.mount "$etc_dir/systemd/system/local-fs.target.wants/boot.mount"

# ---- lab only ----
mkdir -p "$etc_dir/systemd/system/serial-getty@ttyS0.service.d" "$etc_dir/systemd/system/getty.target.wants"
cat > "$etc_dir/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 - $TERM
EOF
ln -sf /usr/lib/systemd/system/serial-getty@.service "$etc_dir/systemd/system/getty.target.wants/serial-getty@ttyS0.service"
if [[ -f $ADDON ]]; then
    install -D -m 0600 "$ADDON" "$MNT/boot/loader/addons/lab-serial-console.addon.efi"
fi

cat > "$W/guest.env" <<EOF
GUEST_LUKS_UUID=$UUID
GUEST_TARGET_NAME=root
LAB_RECOVERY=$LAB_RECOVERY
EOF
cleanup
trap - EXIT
rm -f "$W/install-registries.conf"
chown --reference="$(dirname "$W")" "$W" "$DISK" "$W/guest.env"
echo "sealed-UKI disk built: $DISK (LUKS UUID $UUID, ESP PARTUUID $ESP_PARTUUID)"
