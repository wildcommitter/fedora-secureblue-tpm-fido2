#!/usr/bin/env bash
# Boots the extracted CachyOS live kernel/initrd directly in QEMU (bypassing
# its GRUB menu so we control the cmdline), with the install-target disk,
# an emulated TPM2 (swtpm), and a 9p share of the hardened-boot project.
# Serial console and monitor are exposed as unix sockets for scripted control.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rm -f "$D/serial.sock" "$D/monitor.sock"

exec qemu-system-x86_64 \
  -name hb-lab \
  -machine q35,accel=kvm \
  -cpu host -smp 4 -m 6144 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$D/OVMF_VARS.fd" \
  -drive if=virtio,file="$D/disk.qcow2",format=qcow2,cache=writeback \
  -cdrom "$D/cachyos-live.iso" \
  -kernel "$D/vmlinuz" \
  -initrd "$D/initrd.img" \
  -append "archisobasedir=arch archisosearchuuid=2026-08-09-15-47-03-00 cow_spacesize=2G copytoram=auto console=ttyS0,115200n8 console=tty0" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -virtfs local,path="$(dirname "$D")",mount_tag=hbshare,security_model=mapped-xattr,id=hbshare \
  -chardev socket,id=chrtpm,path="$D/tpm2/swtpm-sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  -serial unix:"$D/serial.sock",server,nowait \
  -monitor unix:"$D/monitor.sock",server,nowait \
  -display none \
  -no-reboot
