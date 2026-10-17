#!/usr/bin/env bash
# Creates/removes a USB HID gadget with the FIDO report descriptor on a
# dummy_hcd virtual UDC, so vfido.py appears to the host (and, via QEMU
# usb-host passthrough, to a VM) as a real USB FIDO2 security key.
#
#   sudo gadget.sh up      -> prints "hidg=/dev/hidgN usb=BUS:DEV"
#   sudo gadget.sh down
set -euo pipefail

VID=0x1209 PID=0x7f1d   # pid.codes test range
G=/sys/kernel/config/usb_gadget/vfido

usb_node() {
    local d
    for d in /sys/bus/usb/devices/*; do
        [[ "$(cat "$d/idVendor" 2>/dev/null)" == "${VID#0x}" &&
           "$(cat "$d/idProduct" 2>/dev/null)" == "${PID#0x}" ]] || continue
        printf '%s:%s\n' "$(cat "$d/busnum")" "$(cat "$d/devnum")"
        return 0
    done
    return 1
}

up() {
    modprobe dummy_hcd
    modprobe libcomposite
    mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
    [[ -d $G ]] && down
    mkdir -p "$G"
    echo $VID > "$G/idVendor"
    echo $PID > "$G/idProduct"
    echo 0x0200 > "$G/bcdUSB"
    echo 0x0100 > "$G/bcdDevice"
    mkdir -p "$G/strings/0x409"
    echo "tokenvault-test" > "$G/strings/0x409/manufacturer"
    echo "Virtual FIDO2 Key" > "$G/strings/0x409/product"
    echo "VFIDO0001" > "$G/strings/0x409/serialnumber"
    mkdir -p "$G/configs/c.1/strings/0x409"
    echo "FIDO" > "$G/configs/c.1/strings/0x409/configuration"
    echo 100 > "$G/configs/c.1/MaxPower"
    mkdir -p "$G/functions/hid.fido"
    echo 0 > "$G/functions/hid.fido/protocol"
    echo 0 > "$G/functions/hid.fido/subclass"
    echo 64 > "$G/functions/hid.fido/report_length"
    # Usage page 0xF1D0 (FIDO), usage 0x01 (CTAPHID), 64-byte in/out reports
    printf '\x06\xd0\xf1\x09\x01\xa1\x01\x09\x20\x15\x00\x26\xff\x00\x75\x08\x95\x40\x81\x02\x09\x21\x15\x00\x26\xff\x00\x75\x08\x95\x40\x91\x02\xc0' \
        > "$G/functions/hid.fido/report_desc"
    ln -s "$G/functions/hid.fido" "$G/configs/c.1/"
    ls /sys/class/udc | grep -m1 dummy_udc > "$G/UDC"

    local dev minor i node
    dev=$(cat "$G/functions/hid.fido/dev")          # MAJOR:MINOR of /dev/hidgN
    minor=${dev#*:}
    for i in $(seq 1 40); do
        node=$(usb_node) && [[ -e /dev/hidg$minor ]] && break
        sleep 0.25
    done
    [[ -n "${node:-}" ]] || { echo "gadget did not enumerate" >&2; exit 1; }
    chmod 666 "/dev/hidg$minor"
    # QEMU (unprivileged) opens the usbfs node for usb-host passthrough
    chmod 666 "/dev/bus/usb/$(printf %03d "${node%:*}")/$(printf %03d "${node#*:}")"
    echo "hidg=/dev/hidg$minor usb=$node"
}

down() {
    [[ -d $G ]] || return 0
    echo "" > "$G/UDC" 2>/dev/null || true
    rm -f "$G/configs/c.1/hid.fido"
    rmdir "$G/configs/c.1/strings/0x409" "$G/configs/c.1" \
          "$G/functions/hid.fido" "$G/strings/0x409" "$G" 2>/dev/null || true
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    node) usb_node ;;
    *) echo "usage: $0 up|down|node" >&2; exit 2 ;;
esac
