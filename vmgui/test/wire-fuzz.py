#!/usr/bin/python3 -I
"""A misbehaving vmgui wire guest for vmgui-wire-e2e.sh (lab only).

    wire-fuzz.py <case> <host cid> <port>

Cases: bad-hello (garbage first message), damage-outside (a damage rectangle
past the window's edge), oversized (CREATE 5000x10). Each should make vmgui-wire
drop this connection; the script waits for the close.
"""
import socket
import struct
import sys

HDR = struct.Struct("<HHII")


def msg(typ, win, payload=b""):
    return HDR.pack(typ, 0, win, len(payload)) + payload


def main():
    case, cid, port = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    hello = msg(1, 0, struct.pack("<II", 0x57474D56, 1))
    if case == "bad-hello":
        data = msg(2, 0, struct.pack("<II", 1, 1))
    elif case == "damage-outside":
        data = hello + msg(2, 9, struct.pack("<II", 100, 100)) + \
            msg(6, 9, struct.pack("<IIII", 90, 0, 20, 1) + b"\0" * 80)
    elif case == "oversized":
        data = hello + msg(2, 9, struct.pack("<II", 5000, 10))
    else:
        sys.exit(f"unknown case {case}")
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect((cid, port))
    s.sendall(data)
    try:
        while s.recv(4096):      # host events until vmgui-wire closes on us
            pass
    except (ConnectionResetError, TimeoutError):
        pass
    print(f"{case}: closed by the host")


if __name__ == "__main__":
    main()
