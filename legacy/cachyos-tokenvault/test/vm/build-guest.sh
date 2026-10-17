#!/usr/bin/env bash
# Builds the e2e guest disk on the host (run as root): a CachyOS install that
# mirrors the real machine's boot chain -- GPT, FAT ESP at /boot, LUKS2 root
# with btrfs subvolume @, linux-cachyos, mkinitcpio HOOKS identical to the
# host (systemd, plymouth, sd-encrypt), Limine via limine-mkinitcpio.
#
#   sudo legacy/cachyos-tokenvault/test/vm/build-guest.sh <workdir>
#
# Lab-only secrets: LUKS recovery passphrase "$LAB_RECOVERY", root autologin
# on ttyS0. This legacy tree (legacy/cachyos-tokenvault) is copied to /root/tokenvault.
set -euo pipefail

W=$(readlink -f "${1:?workdir}")
PROJ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LAB_RECOVERY=${LAB_RECOVERY:-lab-recovery-passphrase}
DISK=$W/disk.raw
MNT=$(mktemp -d /var/tmp/tokenvault-guest.XXXXXX)   # alpm download user must reach it
PKGS=(base linux-cachyos mkinitcpio cryptsetup btrfs-progs dosfstools
      limine limine-mkinitcpio-hook efibootmgr plymouth cachyos-plymouth-theme
      tpm2-tools tpm2-tss libfido2 python python-fido2 python-cryptography
      util-linux sudo)

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
mkdir -p "$W"; chmod 755 "$MNT"

LOOP= MAPPED=
cleanup() {
    set +e
    for m in "$MNT/boot" "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys/firmware/efi/efivars" "$MNT/sys" "$MNT/run" "$MNT"; do
        mountpoint -q "$m" && umount -l "$m"
    done
    [[ -n $MAPPED ]] && cryptsetup close "$MAPPED"
    [[ -n $LOOP ]] && losetup -d "$LOOP"
}
trap cleanup EXIT

rm -f "$DISK"
truncate -s 12G "$DISK"
sfdisk -q "$DISK" <<'EOF'
label: gpt
size=1GiB, type=U, name=ESP
type=L, name=cryptroot
EOF
LOOP=$(losetup -f --show -P "$DISK")
udevadm settle
mkfs.fat -F32 -n ESP "${LOOP}p1" >/dev/null
printf %s "$LAB_RECOVERY" | cryptsetup luksFormat --batch-mode --type luks2 \
    --pbkdf argon2id --pbkdf-memory 262144 --iter-time 1000 "${LOOP}p2" -
UUID=$(cryptsetup luksUUID "${LOOP}p2")
MAPPED=luks-$UUID
printf %s "$LAB_RECOVERY" | cryptsetup open "${LOOP}p2" "$MAPPED" -
mkfs.btrfs -q "/dev/mapper/$MAPPED"
mount "/dev/mapper/$MAPPED" "$MNT"
btrfs -q subvolume create "$MNT/@"
umount "$MNT"
mount -o subvol=/@ "/dev/mapper/$MAPPED" "$MNT"
mkdir -p "$MNT/boot"
mount "${LOOP}p1" "$MNT/boot"

# pacstrap-equivalent (arch-install-scripts is not on the host)
mkdir -p "$MNT"/{dev,proc,sys,run,etc,var/lib/pacman,var/cache/pacman/pkg}
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
mount -t tmpfs tmpfs "$MNT/run"

# Configuration that must exist before the kernel's alpm hooks fire
cat > "$MNT/etc/mkinitcpio.conf" <<'EOF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode kms modconf block keyboard sd-vconsole plymouth sd-encrypt filesystems)
EOF
# Lab-only: the first image is built in a chroot on the host, where
# 'autodetect' sees the host's hardware, not the VM's.
mkdir -p "$MNT/etc/mkinitcpio.conf.d"
echo 'MODULES+=(virtio_blk virtio_pci tpm_crb)' > "$MNT/etc/mkinitcpio.conf.d/00-lab-vm.conf"
echo 'KEYMAP=us' > "$MNT/etc/vconsole.conf"
mkdir -p "$MNT/etc/default"
cat > "$MNT/etc/default/limine" <<EOF
ESP_PATH="/boot"
KERNEL_CMDLINE[default]+="quiet nowatchdog splash rw rootflags=subvol=/@ rd.luks.uuid=$UUID root=/dev/mapper/luks-$UUID console=tty0 console=ttyS0,115200n8"
BOOT_ORDER="*, *fallback"
EOF
echo tokenvault-lab > "$MNT/etc/hostname"
systemd-machine-id-setup --root="$MNT" >/dev/null

pacman --root "$MNT" --config /etc/pacman.conf --cachedir /var/cache/pacman/pkg \
    --gpgdir /etc/pacman.d/gnupg --noconfirm --needed -Sy "${PKGS[@]}" >"$W/pacman.log" 2>&1 \
    || { tail -30 "$W/pacman.log"; exit 1; }

genfs() {
    printf 'UUID=%s / btrfs subvol=/@,rw,noatime 0 0\n' "$(blkid -s UUID -o value "/dev/mapper/$MAPPED")"
    printf 'UUID=%s /boot vfat rw,fmask=0077,dmask=0077 0 2\n' "$(blkid -s UUID -o value "${LOOP}p1")"
}
genfs > "$MNT/etc/fstab"
mkdir -p "$MNT/etc/plymouth"
printf '[Daemon]\nTheme=cachyos\n' > "$MNT/etc/plymouth/plymouthd.conf"

# Lab conveniences: root autologin on the serial console, no root password
mkdir -p "$MNT/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$MNT/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root --keep-baud 115200,57600,38400,9600 - $TERM
EOF
chroot "$MNT" systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1
mkdir -p "$MNT/root/tokenvault"
tar -C "$PROJ" --exclude=./test/vm/work --exclude=.git -cf - . | tar -C "$MNT/root/tokenvault" -xf -

# Limine on the removable-media path (no efivars in a chroot), then entries
install -D -m 644 "$MNT/usr/share/limine/BOOTX64.EFI" "$MNT/boot/EFI/BOOT/BOOTX64.EFI"
chroot "$MNT" /usr/bin/limine-mkinitcpio >"$W/limine-mkinitcpio.log" 2>&1 \
    || { tail -30 "$W/limine-mkinitcpio.log"; exit 1; }
grep -q 'module_path' "$MNT/boot/limine.conf" || { echo "no limine entries" >&2; exit 1; }

cat > "$W/guest.env" <<EOF
GUEST_LUKS_UUID=$UUID
GUEST_TARGET_NAME=luks-$UUID
LAB_RECOVERY=$LAB_RECOVERY
EOF
cleanup
trap - EXIT
rmdir "$MNT"
chown --reference="$PROJ" "$W" "$DISK" "$W"/*.log "$W/guest.env"
echo "guest built: $DISK (LUKS UUID $UUID)"
