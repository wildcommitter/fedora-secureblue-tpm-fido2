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

### Uplink (internet for a guest)

`uplink` is a built-in network that is routed instead of switched. Each NIC on it gets
its own /30: the host is `10.88.N.1` and the guest `10.88.N.2`. Because no DHCP or DNS
server runs, the guest uses a static address and a public resolver. `vmswitch xml`
prints its address.

| Table | Rule |
|---|---|
| `netdev vmswitch` | Ingress takes only ARP and IPv4 from the NIC's MAC **and** its address; egress passes only the host's ARP and traffic to the guest's address |
| `inet vmswitch` input | `iifname "vs*" drop`: guests reach no host service (ARP still works) |
| `inet vmswitch` forward, **policy drop** | Uplink → anything but another TAP and not private, link-local, CGNAT, multicast or reserved ranges (so not the LAN); replies back (`ct state established,related`). Nothing else is forwarded |
| `inet vmswitch` postrouting | masquerade out of the host's route |

The `inet` table exists only while a NIC is on `uplink`, and vmswitch then turns on
`net.ipv4.ip_forward`. Its forward policy is drop, so in that time the host forwards
**only** uplink flows. That breaks rootful container bridge networks; this image has
none. Uplink guests are isolated from each other too. No IPv6.

### USB to guests (usbguard)

usbguard's policy decides what the host uses. A device the policy doesn't allow stays
blocked, with no host driver bound.

| Step | `vmswitch usb attach <guest> <id>` | `vmswitch usb detach <guest> <id>` |
|---|---|---|
| 1 | `usbguard allow-device <id>`: for this plug-in only, not written to the policy | `virsh detach-device --live` |
| 2 | `virsh attach-device --live`: a `hostdev` by vendor, product **and** bus/device, so only that one device | `usbguard block-device <id>`, even if the guest is gone |
| On failure | blocked again, nothing recorded | |

- Hubs never leave the host. A device on one guest must be detached before another
  guest can take it.
- Between steps 1 and 2 a host driver can bind for a moment. QEMU detaches it when it
  claims the device. A device you never want the host to drive should not be plugged in
  while it is blocked for a guest that isn't running.
- `vmswitch usb list` shows usbguard's id, its target, vendor:product, port, the guest
  (or `hub`, `-`) and the name.

Every change rewrites the whole table in one `nft -f` transaction (checked with
`nft -c` first). A NIC moved to another network is cut from the old one in the same
transaction.

## Use

Root only (`run0`). State is in `/var/lib/vmswitch/table.json`.

```sh
vmswitch net add work                # networks
vmswitch nic add browser eth0        # a NIC for guest "browser" (on no network yet)
vmswitch plug browser eth0 work      # move it onto "work" (- = off all networks)
vmswitch plug browser eth0 uplink    # or: routed to the internet only
vmswitch xml browser eth0            # the <interface> for `virsh edit browser`
vmswitch show                        # the switching table, JSON
vmswitch apply                       # recreate TAPs and table (at boot)
vmswitch usb list                    # USB devices, usbguard id, which guest has them
vmswitch usb attach browser 5        # device 5 into the running guest
vmswitch usb detach browser 5        # back out, blocked again
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
- uplink, with a `dummy` WAN holding the default route and a lab egress counter on it:
  - the host answers ARP but not a ping
  - an internet ping leaves masqueraded
  - the LAN and a spoofed source don't leave
  - the uplink NIC is off the switched networks
  - unplugging removes the routing table and the host address

The host's network namespace is never touched. Result: 15 passed, 0 failed. `/proc/sys`
is read-only in a container, so turning on `ip_forward` is left to the KVM e2e.

`test/vmswitch-usb-e2e.sh` tests the USB logic with stubs. `usbguard` and `virsh` are
lab stubs in `test/stub/` that log their calls, and sysfs is a fake tree. It runs as
uid 0 in a user namespace (`unshare -r`). The checks:
- `list` parses usbguard's format and flags hubs
- attach allows the device, then hot-plugs it with its bus/device
- detach unplugs it, then blocks it
- a failed hot-plug blocks the device again and records nothing
- hubs, and a device already on another guest, are refused

Result: 7 passed, 0 failed. The real usbguard daemon and libvirt are for the KVM e2e
(usbguard writes the host's sysfs, so never in a container).

## Not done yet

| What | Plan |
|---|---|
| usbguard in the image | Enabled, with a first-boot policy generated from the devices present then (so the keyboard and the FIDO2 key work) |
| TUI | A curses tree table: networks → NICs, USB devices → guest; keys to plug and attach |
| Image | Unit that runs `apply` at boot, `tmpfiles.d` for `/var/lib/vmswitch`, a KVM e2e with real guests |
