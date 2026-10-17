#!/usr/bin/env python3
"""Run a command and answer its systemd ask-password prompts from env vars.

  askpass.py [--map 'REGEX=ENVVAR']... -- COMMAND [ARGS...]

Only prompts raised by COMMAND or its descendants are answered (systemd's
password-agent protocol, /run/systemd/ask-password). The first --map whose
REGEX matches the prompt message supplies the answer, read from ENVVAR so
secrets never appear in argv. Each mapping answers at most once: a repeat
means the PIN was wrong, and re-sending it would only burn the token's
retry/lockout counter, so the prompt is cancelled instead. Unmatched prompts
are cancelled too. Exit status is COMMAND's.
"""
import configparser
import glob
import os
import re
import socket
import subprocess
import sys
import time

ASK_DIR = "/run/systemd/ask-password"


def descendants(root):
    kids, out = {}, {root}
    for st in glob.glob("/proc/[0-9]*/stat"):
        try:
            with open(st) as f:
                fields = f.read().rsplit(")", 1)[1].split()
            kids.setdefault(int(fields[1]), []).append(int(st.split("/")[2]))
        except (OSError, IndexError, ValueError):
            continue
    todo = [root]
    while todo:
        for c in kids.get(todo.pop(), []):
            if c not in out:
                out.add(c)
                todo.append(c)
    return out


def reply(sock_path, answer):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        s.sendto(b"+" + answer.encode() if answer is not None else b"-", sock_path)
    finally:
        s.close()


def main():
    args = sys.argv[1:]
    maps = []
    while args and args[0] == "--map":
        rx, var = args[1].rsplit("=", 1)
        maps.append([re.compile(rx), var, 0])
        args = args[2:]
    if not args or args[0] != "--" or len(args) < 2:
        sys.exit(__doc__)
    # stdin must not be a TTY: systemd tools then prompt on the terminal
    # directly instead of through the ask-password agent protocol.
    proc = subprocess.Popen(args[1:], stdin=subprocess.DEVNULL)
    seen = set()
    while proc.poll() is None:
        mine = None
        for ask in glob.glob(os.path.join(ASK_DIR, "ask.*")):
            if ask in seen:
                continue
            cp = configparser.ConfigParser(interpolation=None)
            try:
                cp.read(ask)
                a = cp["Ask"]
                pid, sock, msg = int(a["PID"]), a["Socket"], a.get("Message", "")
            except (KeyError, ValueError, configparser.Error):
                continue
            if mine is None:
                mine = descendants(proc.pid)
            if pid not in mine:
                continue
            seen.add(ask)
            for m in maps:
                if m[0].search(msg):
                    if m[2] >= 1:
                        print(f"askpass: repeated prompt {msg!r}, cancelling (wrong {m[1]}?)",
                              file=sys.stderr)
                        reply(sock, None)
                    else:
                        m[2] += 1
                        print(f"askpass: answered {msg!r} from {m[1]}", file=sys.stderr)
                        reply(sock, os.environ.get(m[1], ""))
                    break
            else:
                print(f"askpass: no answer for prompt {msg!r}, cancelling", file=sys.stderr)
                reply(sock, None)
        time.sleep(0.1)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
