"""Minimal expect-like driver for a QEMU serial console exposed as a unix
socket (-serial unix:PATH,server,nowait). Stdlib only. Used to script the
otherwise-interactive install/enroll steps in the hardened-boot QEMU lab.

Keeps one persistent, growing buffer per Session so output that arrives
between calls (e.g. while a previous expect() was still deciding whether to
match) is never silently dropped.
"""
import re
import socket
import sys
import time


class Session:
    def __init__(self, path, connect_timeout=10):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(connect_timeout)
        self.sock.connect(path)
        self.buf = b""

    def _pump(self, poll):
        self.sock.settimeout(poll)
        try:
            chunk = self.sock.recv(65536)
        except socket.timeout:
            return False
        except OSError:
            return False
        if chunk:
            self.buf += chunk
            sys.stderr.buffer.write(chunk)
            sys.stderr.flush()
            return True
        return False

    def expect(self, pattern, timeout=60, poll=0.3, consume=True):
        """Block until `pattern` matches the accumulated buffer. On match,
        by default consumes everything up to and including the match so the
        next expect() starts fresh. Returns the buffer seen so far."""
        rex = re.compile(pattern.encode() if isinstance(pattern, str) else pattern)
        deadline = time.time() + timeout
        while True:
            m = rex.search(self.buf)
            if m:
                seen = self.buf[: m.end()]
                if consume:
                    self.buf = self.buf[m.end():]
                return seen
            if time.time() >= deadline:
                raise TimeoutError(
                    f"timeout after {timeout}s waiting for {pattern!r}; tail: {self.buf[-800:]!r}"
                )
            self._pump(poll)

    def send(self, text, newline=True):
        payload = (text + ("\n" if newline else "")).encode()
        self.sock.sendall(payload)

    def drain(self, seconds=1.0, poll=0.2):
        """Read whatever trickles in for a bit, without requiring a match."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            self._pump(poll)


def connect(path, timeout=10):
    return Session(path, connect_timeout=timeout)
