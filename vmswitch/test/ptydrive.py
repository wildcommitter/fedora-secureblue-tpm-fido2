#!/usr/bin/python3 -I
"""Lab driver: run a command in a 120x32 pty, type the given keys with pauses, save the
raw screen output.  ptydrive.py <out> <keys> -- <cmd...>

Keys: a string with escapes \\e (Esc), \\n, and {down}/{up}/{pause}.
"""
import os
import pty
import select
import struct
import sys
import termios
import fcntl
import time

out, keys = sys.argv[1], sys.argv[2]
cmd = sys.argv[sys.argv.index("--") + 1:]
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM="xterm-256color", LINES="32", COLUMNS="120")
    os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 120, 0, 0))
buf = bytearray()


def pump(t):
    end = time.monotonic() + t
    while (left := end - time.monotonic()) > 0:
        if select.select([fd], [], [], left)[0]:
            try:
                buf.extend(os.read(fd, 65536))
            except OSError:
                return


pump(1.0)
# One write per key: an escape sequence split over writes reads as a lone Esc.
# Arrows in application cursor mode (\eOB), which curses keypad mode switches on.
TOKENS = {"{down}": "\x1bOB", "{up}": "\x1bOA", "\\n": "\n", "\\e": "\x1b"}
for part in keys.split("{pause}"):
    i = 0
    while i < len(part):
        tok = next((t for t in TOKENS if part.startswith(t, i)), part[i])
        os.write(fd, TOKENS.get(tok, tok).encode())
        i += len(tok)
        pump(0.15)
    pump(1.0)
_, status = os.waitpid(pid, 0) if select.select([fd], [], [], 3) else (0, 0)
open(out, "wb").write(buf)
sys.exit(os.waitstatus_to_exitcode(status))
