#!/usr/bin/python3 -I
"""Lab probe: act as the guest end of persistent TAPs (what QEMU does).

  tapprobe.py send <tap> <src-mac> <dst-mac> <tag>     one Ethernet frame into <tap>
  tapprobe.py recv <tap> <tag> <seconds>               exit 0 if a frame with <tag> arrives

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


def main(a):
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
