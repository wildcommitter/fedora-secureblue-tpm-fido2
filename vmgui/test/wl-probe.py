#!/usr/bin/python3 -I
"""Wayland probe for vmgui-e2e.sh (lab only).

    wl-probe.py globals             # print the globals this client sees, one per line
    wl-probe.py secctx <engine>     # try to commit a security context with <engine>;
                                    # prints "committed" or "refused: <message>"
    wl-probe.py hold-pointer        # plug in one virtual pointer and keep it until
                                    # killed (needs privileged_clients), so the seat
                                    # keeps its pointer capability between wlrctl calls

Connects to $WAYLAND_DISPLAY as an ordinary (unprivileged) client.
"""
import os
import socket
import struct
import sys


def wl_str(s):
    b = s.encode() + b"\0"
    return struct.pack("=I", len(b)) + b + b"\0" * (-len(b) % 4)


class Wayland:
    def __init__(self):
        path = os.environ["WAYLAND_DISPLAY"]
        if not path.startswith("/"):
            path = os.path.join(os.environ["XDG_RUNTIME_DIR"], path)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buf = b""
        self.globals = {}

    def send(self, obj, opcode, payload=b"", fds=()):
        msg = struct.pack("=II", obj, ((8 + len(payload)) << 16) | opcode) + payload
        if fds:
            socket.send_fds(self.sock, [msg], list(fds))
        else:
            self.sock.sendall(msg)

    def event(self):
        while True:
            if len(self.buf) >= 8:
                obj, word = struct.unpack_from("=II", self.buf)
                size = word >> 16
                if len(self.buf) >= size:
                    body, self.buf = self.buf[8:size], self.buf[size:]
                    return obj, word & 0xFFFF, body
            data = self.sock.recv(4096)
            if not data:
                raise EOFError
            self.buf += data

    def roundtrip(self, callback_id):
        """Returns None, or the wl_display.error message."""
        self.send(1, 0, struct.pack("=I", callback_id))
        while True:
            try:
                obj, op, body = self.event()
            except EOFError:
                return "disconnected"
            if obj == callback_id and op == 0:
                return None
            if obj == 1 and op == 0:
                n = struct.unpack_from("=I", body, 8)[0]
                return body[12:12 + n - 1].decode(errors="replace")
            if obj == 2 and op == 0:
                name, n = struct.unpack_from("=II", body)
                self.globals[body[8:8 + n - 1].decode()] = name


def main():
    wl = Wayland()
    wl.send(1, 1, struct.pack("=I", 2))
    wl.roundtrip(3)
    if sys.argv[1:] == ["globals"]:
        print("\n".join(sorted(wl.globals)))
        return
    if sys.argv[1:] == ["hold-pointer"]:
        iface = "zwlr_virtual_pointer_manager_v1"
        if iface not in wl.globals:
            sys.exit(f"no {iface}")
        wl.send(2, 0, struct.pack("=I", wl.globals[iface]) + wl_str(iface) + struct.pack("=II", 1, 4))
        wl.send(4, 0, struct.pack("=II", 0, 5))   # create_virtual_pointer(seat: default) -> 5
        err = wl.roundtrip(6)
        if err:
            sys.exit(f"refused: {err}")
        print("holding", flush=True)
        while True:
            wl.event()
    if len(sys.argv) != 3 or sys.argv[1] != "secctx":
        sys.exit(__doc__)
    iface = "wp_security_context_manager_v1"
    if iface not in wl.globals:
        print(f"refused: no {iface}")
        return
    wl.send(2, 0, struct.pack("=I", wl.globals[iface]) + wl_str(iface) + struct.pack("=II", 1, 4))
    lsock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    path = os.path.join(os.environ["XDG_RUNTIME_DIR"], f"probe-{os.getpid()}")
    lsock.bind(path)
    lsock.listen(1)
    r, w = os.pipe()
    wl.send(4, 1, struct.pack("=I", 5), fds=(lsock.fileno(), r))
    wl.send(5, 1, wl_str(sys.argv[2]))
    wl.send(5, 2, wl_str("probe"))
    wl.send(5, 4)
    err = wl.roundtrip(6)
    os.unlink(path)
    print(f"refused: {err}" if err else "committed")


if __name__ == "__main__":
    main()
