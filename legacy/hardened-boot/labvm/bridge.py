"""Persistent bridge to the QEMU serial unix socket: keeps one connection
open indefinitely, continuously appending everything the guest prints to a
log file (so nothing is lost between separate tool calls / turns), and
sends whatever lines appear on a FIFO to the guest. Run this once in the
background per VM boot; interact with it via the FIFO and by tailing the
log file from any later, independent command.
"""
import os
import socket
import sys
import threading
import time

SOCK_PATH = sys.argv[1]
LOG_PATH = sys.argv[2]
FIFO_PATH = sys.argv[3]

if os.path.exists(FIFO_PATH):
    os.remove(FIFO_PATH)
os.mkfifo(FIFO_PATH)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(10)
sock.connect(SOCK_PATH)

log = open(LOG_PATH, "ab", buffering=0)


def reader():
    sock.settimeout(0.5)
    while True:
        try:
            chunk = sock.recv(65536)
            if chunk:
                log.write(chunk)
        except socket.timeout:
            continue
        except OSError:
            break


t = threading.Thread(target=reader, daemon=True)
t.start()

while True:
    fifo_fd = os.open(FIFO_PATH, os.O_RDONLY)
    with os.fdopen(fifo_fd, "r") as fifo:
        for line in fifo:
            line = line.rstrip("\n")
            sock.sendall((line + "\n").encode())
