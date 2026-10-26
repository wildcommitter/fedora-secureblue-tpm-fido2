#!/usr/bin/env bash
# vmswitch USB logic e2e with stubs: usbguard and virsh are lab stubs that log their
# calls (test/stub/), sysfs is a fake tree. No real USB device, usbguard daemon or
# libvirt is touched: those run in the KVM e2e.
#
#   vmswitch/test/vmswitch-usb-e2e.sh
#
# Checks: list parses usbguard's format (hubs flagged); attach allows the device, then
# hot-plugs it with the right bus/device; a failed hot-plug blocks it again; detach
# unplugs and blocks; hubs and devices on another guest are refused.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VS=$(dirname "$HERE")/host/usr/libexec/vmswitch/vmswitch
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export STUB=$W PATH=$HERE/stub:$PATH VMSWITCH_STATE=$W/state/table.json VMSWITCH_SYSFS=$W/sys

cat > "$W/devices" <<'DEV'
1: allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" hash "jEP/6Wz=" parent-hash "rV9b=" via-port "usb1" with-interface 09:00:00 with-connect-type ""
5: block id 1209:7f1d serial "vfido-1" name "Virtual \"FIDO\" key" hash "aa=" parent-hash "jEP/6Wz=" via-port "1-2" with-interface { 03:00:00 03:01:01 } with-connect-type "hotplug"
6: allow id 046d:c52b serial "" name "USB Receiver" hash "bb=" parent-hash "jEP/6Wz=" via-port "1-3" with-interface { 03:01:01 03:01:02 } with-connect-type "hotplug"
DEV
for p in 1-2:1:7 1-3:1:9; do
    IFS=: read -r port bus dev <<< "$p"
    mkdir -p "$W/sys/bus/usb/devices/$port"
    echo "$bus" > "$W/sys/bus/usb/devices/$port/busnum"
    echo "$dev" > "$W/sys/bus/usb/devices/$port/devnum"
done

pass=0 fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
# vs: run vmswitch as "root" for the euid check (fakeroot-free: python sees our uid,
# so run it through unshare -r, a user namespace where we are uid 0).
vs() { unshare -r python3 -I "$VS" "$@"; }
calls() { grep -v "^usbguard list-devices$" "$W/calls" 2>/dev/null || true; : > "$W/calls"; }

out=$(vs usb list); calls > /dev/null
if [[ $(grep -c $'^1\tallow\t1d6b:0002\tusb1\thub\t' <<< "$out") == 1 \
   && $(grep -c $'^5\tblock\t1209:7f1d\t1-2\t-\tVirtual \\\\"FIDO\\\\" key$' <<< "$out") == 1 ]]; then
    ok "list parses usbguard's format, flags the hub"
else
    bad "list"; echo "$out"
fi

vs usb attach browser 5; c=$(calls)
if [[ $(sed -n 1p <<< "$c") == "usbguard allow-device 5" \
   && $(grep -c "attach-device browser .* --live" <<< "$c") == 1 \
   && $(grep -c "<vendor id='0x1209'/><product id='0x7f1d'/><address bus='1' device='7'/>" <<< "$c") == 1 ]]; then
    ok "attach: allow, then hot-plug bus 1 device 7"
else
    bad "attach"; echo "$c"
fi
[[ $(vs usb list | grep -c $'^5\tblock\t1209:7f1d\t1-2\tbrowser\t') == 1 ]] && ok "list shows the guest" || bad "list shows the guest"
calls > /dev/null

vs usb attach other 5 2> "$W/err" && bad "second guest got the device" \
    || { grep -q "is on browser" "$W/err" && ok "device on another guest refused" || bad "refusal message"; }
vs usb attach other 1 2> /dev/null && bad "hub attached" || ok "hub refused"
calls > /dev/null

vs usb detach browser 5; c=$(calls)
if [[ $(grep -c "detach-device browser .* --live" <<< "$c") == 1 && $(tail -1 <<< "$c") == "usbguard block-device 5" ]]; then
    ok "detach: unplug, then block"
else
    bad "detach"; echo "$c"
fi

touch "$W/virsh-fail"
vs usb attach browser 6 2> /dev/null && bad "failed hot-plug reported success" || true
c=$(calls)
if [[ $(head -1 <<< "$c") == "usbguard allow-device 6" && $(tail -1 <<< "$c") == "usbguard block-device 6" ]] \
   && [[ $(vs usb list | grep -c $'^6\t.*\t-\tUSB Receiver$') == 1 ]]; then
    ok "failed hot-plug blocks the device again, not recorded"
else
    bad "failed hot-plug"; echo "$c"
fi
echo "vmswitch-usb-e2e: $pass passed, $fail failed"
((fail == 0))
