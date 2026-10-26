#!/usr/bin/env bash
# vmtui e2e: the curses UI in a pty, driving the real vmswitch (TAPs and nft in a
# container's own network namespace) with stub usbguard and virsh (test/stub/).
#
#   vmswitch/test/vmtui-e2e.sh
#
#   IMAGE=<rootfs>   image rootfs with nftables + iproute (default localhost/scroll-secure-rootfs)
#
# Checks: --dump shows the tree (networks, NICs, uplink, USB with the hub); keys plug a
# NIC into uplink through the picker, attach a USB device to the guest picked, add a
# network, and q exits cleanly.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VS=$(dirname "$HERE")
IMAGE=${IMAGE:-localhost/scroll-secure-rootfs:latest}
CT=${CT_NAME:-vmtui-e2e}

die() { echo "vmtui-e2e: $*" >&2; exit 1; }
for m in nft_dup_netdev nf_dup_netdev; do
    [[ -d /sys/module/$m ]] || sudo modprobe "$m" || die "needs the $m module"
done

podman rm -f "$CT" > /dev/null 2>&1 || true
trap 'podman rm -f -t0 "$CT" > /dev/null 2>&1' EXIT
podman run -d --init --name "$CT" --network none --cap-add NET_ADMIN --device /dev/net/tun \
    -e VMSWITCH_TAP_USER=root -e STUB=/stub -e PATH=/vstest/stub:/usr/bin:/usr/sbin \
    -e VMSWITCH_SYSFS=/stub/sys \
    -v "$VS/host/usr/libexec/vmswitch/vmswitch:/usr/libexec/vmswitch/vmswitch:ro,Z" \
    -v "$VS/host/usr/bin/vmtui:/usr/bin/vmtui:ro,Z" \
    -v "$HERE:/vstest:ro,Z" \
    --entrypoint sleep "$IMAGE" infinity > /dev/null
ct() { podman exec -i "$CT" "$@"; }
vs() { ct /usr/libexec/vmswitch/vmswitch "$@"; }

ct sh -euc 'mkdir -p /stub/sys/bus/usb/devices/1-2; echo 1 > /stub/sys/bus/usb/devices/1-2/busnum
            echo 7 > /stub/sys/bus/usb/devices/1-2/devnum; printf "browser\nwork\n" > /stub/guests
            cat > /stub/devices <<DEV
1: allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" hash "a=" parent-hash "b=" via-port "usb1" with-interface 09:00:00 with-connect-type ""
5: block id 1209:7f1d serial "vf" name "Virtual FIDO key" hash "c=" parent-hash "a=" via-port "1-2" with-interface { 03:00:00 } with-connect-type "hotplug"
DEV'
vs net add red; vs net add blue
vs nic add work eth0; vs plug work eth0 red
vs nic add browser eth0

pass=0 fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

d=$(ct vmtui --dump)
echo "$d"
if grep -q '^▾ red' <<< "$d" && grep -q '└─ work/eth0 *work *eth0' <<< "$d" \
   && grep -q '^▾ (no network)' <<< "$d" && grep -q '└─ browser/eth0' <<< "$d" \
   && grep -q '^▾ uplink (internet only)' <<< "$d" \
   && grep -q 'xHCI Host Controller.*hub (host)' <<< "$d" && grep -q 'Virtual FIDO key .*#5 1209:7f1d *1-2 *block' <<< "$d"; then
    ok "--dump shows networks, NICs, uplink and USB"
else
    bad "--dump"
fi

# Rows: red, work/eth0, blue, uplink, (no network), browser/eth0, USB, hub, FIDO.
# 5 down -> browser/eth0; p; picker [blue, red, uplink, -] starts on its current
# network (-): 1 up -> uplink.
# Then (no network) is gone: cursor 5 = USB; 2 down -> FIDO; a; picker [browser, work].
ct sh -c ': > /stub/calls'
if ct python3 -I /vstest/ptydrive.py /tmp/screen \
     '{down}{down}{down}{down}{down}p{pause}{up}\n{pause}{down}{down}a{pause}\n{pause}nlab\n{pause}q' \
     -- vmtui; then
    ok "q exits cleanly"
else
    bad "vmtui exit status"
fi
st=$(vs show)
[[ $(python3 -Ic 'import json,sys; print(json.load(sys.stdin)["nics"]["browser/eth0"]["net"])' <<< "$st") == uplink ]] \
    && ok "p + picker plugs browser/eth0 into uplink" || bad "plug through the picker"
calls=$(ct cat /stub/calls)
grep -q '^usbguard allow-device 5$' <<< "$calls" && grep -q 'attach-device browser .* --live' <<< "$calls" \
    && ok "a + picker attaches device 5 to browser" || { bad "attach through the picker"; echo "$calls"; }
python3 -Ic 'import json,sys; sys.exit("lab" not in json.load(sys.stdin)["nets"])' <<< "$st" \
    && ok "n adds network lab" || bad "n adds network"
echo "vmtui-e2e: $pass passed, $fail failed"
((fail == 0))
