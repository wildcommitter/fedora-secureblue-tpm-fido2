#!/usr/bin/env python3
"""Run a command on a pseudo-terminal and type a PIN at its PIN prompt.

  pty-pin.py <pin> <command> [args...]

For tools that read a PIN only from a terminal (pamu2fcfg -N). Everything
the command prints, PIN prompt included, goes to stdout; exits with its status.
"""
import os
import pty
import sys

pin, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)

out, sent = b"", False
while True:
    try:
        data = os.read(fd, 1024)
    except OSError:  # EIO once the child closes the terminal
        break
    if not data:
        break
    out += data
    if not sent and b"PIN" in out:
        os.write(fd, pin.encode() + b"\n")
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
sys.exit(os.waitstatus_to_exitcode(status))
