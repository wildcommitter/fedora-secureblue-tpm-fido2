#!/usr/bin/python3 -I
"""Lab probe: act as the guest end of persistent TAPs (what QEMU does).

  tapprobe.py send <tap> <src-mac> <dst-mac> <tag>     one Ethernet frame into <tap>
  tapprobe.py recv <tap> <tag> <seconds>               exit 0 if a frame with <tag> arrives
  tapprobe.py arp <tap> <mac> <sip> <tip> <seconds>    ARP who-has <tip>; exit 0 on a reply
  tapprobe.py ping <tap> <smac> <dmac> <sip> <dip> <seconds>
                                                       ICMP echo; exit 0 on an echo reply
  tapprobe.py tcp <tap> <smac> <dmac> <sip> <dip> <dport> <seconds>
                                                       TCP SYN; exit 0 on a SYN-ACK

The frame is EtherType 0x88b5 (local experimental) with the tag as payload, so nothing
else on the wire matches it. recv attaches first and prints every frame it sees.
"""
import fcntl
import os
import select
import struct
import sys
import time

TUNSETIFF, IFF_TAP, IFF_NO_PI = 0x400454CA, 0x0002, 0x1000


def attach(tap):
    fd = os.open("/dev/net/tun", os.O_RDWR)
    fcntl.ioctl(fd, TUNSETIFF, struct.pack("16sH", tap.encode(), IFF_TAP | IFF_NO_PI))
    return fd


def mac(s):
    return bytes(int(x, 16) for x in s.split(":"))


def ip4(s):
    return bytes(int(x) for x in s.split("."))


def csum(b):
    s = sum(int.from_bytes(b[i:i + 2], "big") for i in range(0, len(b), 2))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s & 0xFFFF).to_bytes(2, "big")


def wait(fd, secs, match):
    end = time.monotonic() + float(secs)
    while (left := end - time.monotonic()) > 0:
        if select.select([fd], [], [], left)[0]:
            f = os.read(fd, 65536)
            print(f"frame {f[6:12].hex(':')} -> {f[0:6].hex(':')} type {f[12:14].hex()}", flush=True)
            if match(f):
                return 0
    return 1


def main(a):
    if a[0] == "arp":
        fd = attach(a[1])
        arp = (b"\x00\x01\x08\x00\x06\x04\x00\x01" + mac(a[2]) + ip4(a[3]) + b"\0" * 6 + ip4(a[4]))
        os.write(fd, b"\xff" * 6 + mac(a[2]) + b"\x08\x06" + arp.ljust(46, b"\0"))
        return wait(fd, a[5], lambda f: f[12:14] == b"\x08\x06" and f[20:22] == b"\x00\x02"
                    and f[28:32] == ip4(a[4]))
    if a[0] == "ping":
        fd = attach(a[1])
        icmp = b"\x08\x00\x00\x00\x12\x34\x00\x01" + b"vmswitch"
        icmp = icmp[:2] + csum(icmp) + icmp[4:]
        hdr = (b"\x45\x00" + (20 + len(icmp)).to_bytes(2, "big") + b"\x00\x01\x40\x00\x40\x01"
               + b"\0\0" + ip4(a[4]) + ip4(a[5]))
        hdr = hdr[:10] + csum(hdr) + hdr[12:]
        os.write(fd, mac(a[3]) + mac(a[2]) + b"\x08\x00" + hdr + icmp)
        return wait(fd, a[6], lambda f: f[12:14] == b"\x08\x00" and f[23] == 1 and f[34] == 0)
    if a[0] == "tcp":
        fd = attach(a[1])
        sport, dport = 40000, int(a[6])
        tcp = (sport.to_bytes(2, "big") + dport.to_bytes(2, "big") + b"\x00\x00\x10\x00" + b"\0" * 4
               + b"\x50\x02\xff\xff" + b"\0\0\0\0")
        pseudo = ip4(a[4]) + ip4(a[5]) + b"\x00\x06" + len(tcp).to_bytes(2, "big")
        tcp = tcp[:16] + csum(pseudo + tcp) + tcp[18:]
        hdr = (b"\x45\x00" + (20 + len(tcp)).to_bytes(2, "big") + b"\x00\x01\x40\x00\x40\x06"
               + b"\0\0" + ip4(a[4]) + ip4(a[5]))
        hdr = hdr[:10] + csum(hdr) + hdr[12:]
        os.write(fd, mac(a[3]) + mac(a[2]) + b"\x08\x00" + hdr + tcp)
        # SYN-ACK from <dip>:<dport> to our port. Like a guest, answer the host's ARP
        # for <sip> meanwhile: it sends the SYN-ACK only once it knows our MAC.
        def match(f):
            if f[12:14] == b"\x08\x06" and f[20:22] == b"\x00\x01" and f[38:42] == ip4(a[4]):
                rep = b"\x00\x01\x08\x00\x06\x04\x00\x02" + mac(a[2]) + ip4(a[4]) + f[22:28] + f[28:32]
                os.write(fd, f[6:12] + mac(a[2]) + b"\x08\x06" + rep.ljust(46, b"\0"))
                return False
            return (f[12:14] == b"\x08\x00" and f[23] == 6 and f[26:30] == ip4(a[5])
                    and f[34:36] == dport.to_bytes(2, "big") and f[36:38] == sport.to_bytes(2, "big")
                    and f[47] & 0x12 == 0x12)
        return wait(fd, a[7], match)
    if a[0] == "send":
        fd = attach(a[1])
        frame = mac(a[3]) + mac(a[2]) + b"\x88\xb5" + a[4].encode().ljust(46, b"\0")
        os.write(fd, frame)
        return 0
    if a[0] == "recv":
        fd = attach(a[1])
        print("ready", flush=True)
        end = time.monotonic() + float(a[3])
        while (left := end - time.monotonic()) > 0:
            if select.select([fd], [], [], left)[0]:
                f = os.read(fd, 65536)
                print(f"frame {f[6:12].hex(':')} -> {f[0:6].hex(':')} type {f[12:14].hex()}", flush=True)
                if a[2].encode() in f:
                    return 0
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
