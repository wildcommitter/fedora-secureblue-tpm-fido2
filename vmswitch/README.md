# vmswitch: the guests' network switch (TAP + nftables)

Guests get networks only through vmswitch. It uses no bridge, no daemon and no extra
package: just persistent TAP devices and one nftables table that the kernel runs.

## How it works

| Piece | What | Notes |
|---|---|---|
| NIC | A persistent TAP `vsXXXXXXXXXX` per guest NIC, owned by `qemu` | Name and MAC (`52:54:00:…`) derive from `guest/nic`. `addrgenmode none`, `arp off`: the host puts no address on it |
| Network | A named group of NICs | A NIC is on one network or on none |
| `netdev vmswitch`, ingress | Per TAP: `ether saddr <its MAC> dup to` every other TAP of its network, then **drop** | A hub: frames reach all peers, no MAC learning. A spoofed source MAC goes nowhere. The host stack never sees guest frames |
| `netdev vmswitch`, egress | Per TAP: accept only source MACs of its network's peers, **drop** the rest | `dup`ed frames pass the egress hook too (tested), so this also drops everything the host itself would send |

Every change rewrites the whole table in one `nft -f` transaction (checked with
`nft -c` first). A NIC moved to another network is cut from the old one in the same
transaction.

## Use

Root only (`run0`). State is in `/var/lib/vmswitch/table.json`.

```sh
vmswitch net add work                # networks
vmswitch nic add browser eth0        # a NIC for guest "browser" (on no network yet)
vmswitch plug browser eth0 work      # move it onto "work" (- = off all networks)
vmswitch xml browser eth0            # the <interface> for `virsh edit browser`
vmswitch show                        # the switching table, JSON
vmswitch apply                       # recreate TAPs and table (at boot)
```

## Tests

`test/vmswitch-e2e.sh` runs the switch in a container's own network namespace, with
`test/tapprobe.py` as the guest end of each TAP (it attaches to the TAP fd like QEMU).
The checks:
- same network delivers, another network or none doesn't
- plugging a NIC moves it
- a spoofed MAC is dropped
- no IPv6 is on the TAP, and the host sends nothing onto it
- `apply` is idempotent
- `nic del` removes the TAP and its chains

The host's network namespace is never touched. Result: 9 passed, 0 failed.

## Not done yet

| What | Plan |
|---|---|
| Uplink (internet for a guest) | Per NIC, routed: host `/30` on that TAP, nftables forward + masquerade. Static guest IP, no DHCP/DNS server (no extra software) |
| USB to guests | usbguard blocks new devices; attaching one allows it and hot-plugs it into the guest (libvirt `hostdev`); detaching blocks it again |
| TUI | A curses tree table: networks → NICs, USB devices → guest; keys to plug and attach |
| Image | Unit that runs `apply` at boot, `tmpfiles.d` for `/var/lib/vmswitch`, a KVM e2e with real guests |
