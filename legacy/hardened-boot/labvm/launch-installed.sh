#!/usr/bin/env bash
# Boots the installed VM disk directly (no live ISO/cdrom). Pass --fido2 to
# additionally pass through the real physical ExcelSecu FIDO2 key
# (1ea8:fc26) via USB host passthrough — only needed for enroll/unlock
# testing, not for the baseline password-only boot check.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXTRA=()
if [[ "${1:-}" == "--fido2" ]]; then
    EXTRA+=(-device qemu-xhci,id=xhci0)
    EXTRA+=(-device usb-host,bus=xhci0.0,vendorid=0x1ea8,productid=0xfc26)
fi

rm -f "$D/serial.sock" "$D/monitor.sock"

exec qemu-system-x86_64 \
  -name hb-lab \
  -machine q35,accel=kvm \
  -cpu host -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$D/OVMF_VARS.fd" \
  -drive if=virtio,file="$D/disk.qcow2",format=qcow2,cache=writeback,bootindex=1 \
  -virtfs local,path="$(dirname "$D")",mount_tag=hbshare,security_model=mapped-xattr,id=hbshare \
  -chardev socket,id=chrtpm,path="$D/tpm2/swtpm-sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  "${EXTRA[@]}" \
  -serial unix:"$D/serial.sock",server,nowait \
  -monitor unix:"$D/monitor.sock",server,nowait \
  -display none \
  -no-reboot
