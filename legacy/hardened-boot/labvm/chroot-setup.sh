#!/bin/bash
set -eu
echo "root:labtest123" | chpasswd
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode kms modconf block keyboard sd-vconsole sd-encrypt filesystems)/' /etc/mkinitcpio.conf
grep '^HOOKS=' /etc/mkinitcpio.conf
mkinitcpio -P
bootctl install
mkdir -p /boot/loader/entries
printf 'default arch.conf\ntimeout 3\nconsole-mode max\n' > /boot/loader/loader.conf
cat > /boot/loader/entries/arch.conf <<ENTRY
title   Hardened Boot Lab
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options rd.luks.uuid=189a2814-10e9-4b8e-a130-3ad421930792 root=/dev/mapper/luks-189a2814-10e9-4b8e-a130-3ad421930792 rw console=ttyS0,115200n8
ENTRY
cat /boot/loader/entries/arch.conf
echo CHROOT_STEPS_DONE
