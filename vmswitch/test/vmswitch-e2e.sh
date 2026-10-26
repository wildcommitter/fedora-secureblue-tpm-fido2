#!/usr/bin/env bash
# vmswitch e2e: the switch in a container's own network namespace, with persistent
# TAPs and tapprobe.py as the guest ends (what QEMU does with the TAP fd). Lab only:
# the host's network namespace is never touched.
#
#   vmswitch/test/vmswitch-e2e.sh      (loads nft_dup_netdev with sudo if needed)
#
#   IMAGE=<rootfs>   image rootfs with nftables + iproute (default localhost/scroll-secure-rootfs)
#
# Checks: a frame reaches a NIC on the same network and not one on another; a NIC on
# no network is cut off; plugging moves it; a spoofed source MAC is dropped; the host
# sends nothing onto a TAP (no IPv6 RS/ND, egress drop); the table survives apply;
# deleting a NIC removes its TAP and chains. Uplink (a dummy "wan" with the default
# route stands in for the host's network): the host answers ARP but not pings, a ping
# to the internet leaves wan masqueraded, the LAN and a spoofed source don't leave,
# unplugging removes the routing table. /proc/sys is read-only in a container, so
# forwarding starts on here; vmswitch switching it on is for the KVM e2e.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VS=$(dirname "$HERE")
IMAGE=${IMAGE:-localhost/scroll-secure-rootfs:latest}
CT=${CT_NAME:-vmswitch-e2e}

die() { echo "vmswitch-e2e: $*" >&2; exit 1; }

for m in nft_dup_netdev nf_dup_netdev; do
    [[ -d /sys/module/$m ]] || sudo modprobe "$m" || die "needs the $m module"
done

podman rm -f "$CT" > /dev/null 2>&1 || true
trap 'podman rm -f "$CT" > /dev/null 2>&1' EXIT
# Own network namespace (podman default); NET_ADMIN only inside it.
podman run -d --init --name "$CT" --network none --cap-add NET_ADMIN --device /dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    -e VMSWITCH_STATE=/var/lib/vmswitch/table.json -e VMSWITCH_TAP_USER=root \
    -v "$VS/host/usr/libexec/vmswitch/vmswitch:/usr/libexec/vmswitch/vmswitch:ro,Z" \
    -v "$HERE/tapprobe.py:/vstest/tapprobe.py:ro,Z" \
    --entrypoint sleep "$IMAGE" infinity > /dev/null
ct() { podman exec -i "$CT" "$@"; }
vs() { ct /usr/libexec/vmswitch/vmswitch "$@"; }
probe() { ct python3 -I /vstest/tapprobe.py "$@"; }

pass=0 fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
tap() { vs show | python3 -Ic "import json,sys; print(json.load(sys.stdin)['nics']['$1']['$2'])"; }

vs net add red
vs net add blue
for n in a b c; do vs nic add "g$n" eth0; done
vs plug ga eth0 red
vs plug gb eth0 red
vs plug gc eth0 blue
A=$(tap ga/eth0 tap) B=$(tap gb/eth0 tap) C=$(tap gc/eth0 tap)
MA=$(tap ga/eth0 mac)

# delivered <from-tap> <src-mac> <to-tap> <tag>: 0 if the frame arrives at <to-tap>
delivered() {
    local out
    ct sh -c "python3 -I /vstest/tapprobe.py recv $3 $4 2 > /tmp/recv.$4 2>&1 & sleep 0.5;
              python3 -I /vstest/tapprobe.py send $1 $2 ff:ff:ff:ff:ff:ff $4; wait \$!"
}

delivered "$A" "$MA" "$B" t1 && ok "same network: ga -> gb" || bad "same network: ga -> gb"
delivered "$A" "$MA" "$C" t2 && bad "other network: ga reached gc" || ok "other network: ga can't reach gc"
vs plug gc eth0 -
delivered "$A" "$MA" "$C" t3 && bad "no network: gc reached" || ok "no network: gc cut off"
vs plug gc eth0 red
delivered "$A" "$MA" "$C" t4 && ok "plug moves gc onto red" || bad "plug moves gc onto red"
delivered "$A" 52:54:00:de:ad:00 "$B" t5 && bad "spoofed source MAC delivered" || ok "spoofed source MAC dropped"

# The host itself must put nothing on a guest's wire: no IPv6 link-local, and the
# egress hook drops what the host would send (a ping to the broadcast address here).
if [[ $(ct ip -6 addr show dev "$B" | grep -c inet6 || true) == 0 ]]; then
    ok "no IPv6 on the TAP"
else
    bad "IPv6 on the TAP"
fi
ct ip addr add 10.99.0.1/24 dev "$B"
ct sh -c "python3 -I /vstest/tapprobe.py recv $B none 3 > /tmp/recv.host 2>&1 & sleep 0.5;
          ping -c 2 -W 1 -b 10.99.0.255 > /dev/null 2>&1; arping -c 1 -I $B 10.99.0.2 > /dev/null 2>&1; wait" || true
if ct grep -c '^frame' /tmp/recv.host > /dev/null; then
    bad "host frames reached the guest end"; ct cat /tmp/recv.host
else
    ok "host sends nothing onto the TAP (egress drop)"
fi
ct ip addr del 10.99.0.1/24 dev "$B"

vs apply
delivered "$A" "$MA" "$B" t6 && ok "apply keeps the table" || bad "apply keeps the table"
vs nic del gc eth0
if ! ct test -e "/sys/class/net/$C" && ! ct nft list table netdev vmswitch | grep -c "$C" > /dev/null; then
    ok "nic del removes the TAP and its chains"
else
    bad "nic del removes the TAP and its chains"
fi
# ---- uplink
ct sh -euc 'ip link add wan type dummy; ip addr add 192.0.2.2/24 dev wan; ip link set wan up
            ip route add default via 192.0.2.1 dev wan
            nft -f - <<EOT
table netdev labwan {
  chain out { type filter hook egress device "wan" priority filter; policy accept;
    ip saddr 192.0.2.2 icmp type echo-request counter
    ip saddr 10.88.0.0/16 counter
  }
}
EOT'
masq() { ct nft list chain netdev labwan out | sed -n "s|.*ip saddr $1 .*counter packets \([0-9]*\).*|\1|p"; }
vs plug ga eth0 uplink
GA=10.88.0.2 HOST=10.88.0.1
if probe arp "$A" "$MA" "$GA" "$HOST" 2 > /dev/null; then ok "uplink: host answers ARP"; else bad "uplink: host answers ARP"; fi
HM=$(ct cat "/sys/class/net/$A/address")
probe ping "$A" "$MA" "$HM" "$GA" 198.51.100.7 1 > /dev/null || true
[[ $(masq 192.0.2.2) == 1 && $(masq 10.88.0.0/16) == 0 ]] && ok "uplink: internet ping leaves wan masqueraded" \
    || bad "uplink: internet ping leaves wan masqueraded (masq=$(masq 192.0.2.2) raw=$(masq 10.88.0.0/16))"
probe ping "$A" "$MA" "$HM" "$GA" 192.168.1.5 1 > /dev/null || true
probe ping "$A" "$MA" "$HM" 10.88.0.66 198.51.100.7 1 > /dev/null || true
[[ $(masq 192.0.2.2) == 1 && $(masq 10.88.0.0/16) == 0 ]] && ok "uplink: LAN and spoofed source don't leave" \
    || bad "uplink: LAN and spoofed source don't leave"
probe ping "$A" "$MA" "$HM" "$GA" "$HOST" 1 > /dev/null && bad "uplink: host answered a ping" \
    || ok "uplink: host services closed (no ping reply)"
delivered "$A" "$MA" "$B" t7 && bad "uplink NIC still switched to gb" || ok "uplink NIC is off the switched networks"
vs plug ga eth0 -
if ! ct nft list table inet vmswitch > /dev/null 2>&1 && [[ -z $(ct ip -4 addr show dev "$A") ]]; then
    ok "unplug: routing table and host address gone"
else
    bad "unplug: routing table and host address gone"
fi
echo "vmswitch-e2e: $pass passed, $fail failed"
((fail == 0))
