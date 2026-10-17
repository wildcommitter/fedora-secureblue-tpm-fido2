#!/usr/bin/env bash
# Runs INSIDE the CachyOS live environment (QEMU guest only). Installs a
# minimal Arch/CachyOS base system onto /dev/vda with a LUKS2 root, mirroring
# the real host's mkinitcpio/systemd/cryptsetup pipeline, so the
# hardened-boot project can be tested against it without touching real
# hardware. Prints HARDENED_BOOT_LAB_INSTALL_OK or _FAILED as the last line.
set -uo pipefail
exec > >(tee -a /srv/hb/labvm/install.log) 2>&1

fail() { echo "INSTALL ERROR: $*"; echo "HARDENED_BOOT_LAB_INSTALL_FAILED"; exit 1; }
trap 'fail "unexpected error at line $LINENO"' ERR

echo "=== network check ==="
for i in $(seq 1 20); do
    curl -fsS --max-time 3 https://geo.mirror.pkgbuild.com >/dev/null 2>&1 && { echo "network OK"; break; }
    sleep 3
    [ "$i" -eq 20 ] && fail "no network after 60s"
done

echo "=== partitioning /dev/vda ==="
sgdisk --zap-all /dev/vda
sgdisk -n1:0:+512M -t1:ef00 -c1:ESP /dev/vda
sgdisk -n2:0:0     -t2:8309 -c2:cryptroot /dev/vda
partprobe /dev/vda
sleep 2

echo "=== LUKS2 format (lab-only test password) ==="
LAB_PW="labtest123"
printf '%s' "$LAB_PW" | cryptsetup luksFormat --type luks2 /dev/vda2 -
LUKS_UUID=$(cryptsetup luksUUID /dev/vda2)
echo "guest LUKS UUID: $LUKS_UUID"
printf '%s' "$LAB_PW" | cryptsetup open /dev/vda2 "luks-${LUKS_UUID}" -

echo "=== filesystems ==="
mkfs.fat -F32 -n ESP /dev/vda1
mkfs.ext4 -L root "/dev/mapper/luks-${LUKS_UUID}"

mount "/dev/mapper/luks-${LUKS_UUID}" /mnt
mkdir -p /mnt/boot
mount /dev/vda1 /mnt/boot

echo "=== pacstrap ==="
pacstrap -K /mnt base linux linux-firmware mkinitcpio cryptsetup \
    tpm2-tools libfido2 openssl sudo efibootmgr vim

echo "=== fstab ==="
genfstab -U /mnt >> /mnt/etc/fstab

echo "=== copying hardened-boot project into guest (excluding labvm/ scratch) ==="
mkdir -p /mnt/root/hardened-boot
(cd /srv/hb && tar cf - --exclude=./labvm .) | tar xf - -C /mnt/root/hardened-boot
sed -i \
    -e "s/^LUKS_UUID=.*/LUKS_UUID=${LUKS_UUID}/" \
    -e "s#^LUKS_DEVICE=.*#LUKS_DEVICE=/dev/disk/by-uuid/${LUKS_UUID}#" \
    /mnt/root/hardened-boot/config/hardened-boot.conf
echo "patched guest config:"
grep -E '^LUKS_' /mnt/root/hardened-boot/config/hardened-boot.conf

echo "=== chroot configuration ==="
arch-chroot /mnt /bin/bash -eu <<CHROOT
echo "root:${LAB_PW}" | chpasswd

sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode kms modconf block keyboard sd-vconsole sd-encrypt filesystems)/' /etc/mkinitcpio.conf
grep '^HOOKS=' /etc/mkinitcpio.conf

mkinitcpio -P

bootctl install

mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf <<LOADER
default arch.conf
timeout 3
console-mode max
LOADER

KVER=\$(ls /usr/lib/modules | head -1)
cat > /boot/loader/entries/arch.conf <<ENTRY
title   Hardened Boot Lab
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options rd.luks.uuid=${LUKS_UUID} root=/dev/mapper/luks-${LUKS_UUID} rw console=ttyS0,115200n8 console=tty0
ENTRY

systemctl enable systemd-networkd systemd-resolved 2>/dev/null || true
CHROOT

umount -R /mnt
cryptsetup close "luks-${LUKS_UUID}"

echo "guest LUKS UUID: ${LUKS_UUID}" > /srv/hb/labvm/guest-uuid.txt
echo "lab root/luks password: ${LAB_PW}" >> /srv/hb/labvm/guest-uuid.txt

echo "HARDENED_BOOT_LAB_INSTALL_OK"
