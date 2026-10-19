#!/usr/bin/env python3
"""Desktop smoke test on the sealed image under KVM (Secure Boot, swtpm, virtio GPU).

Boots the lab disk with the recovery passphrase, then, as a real user:

  * SDDM autologin (lab-only drop-in, written in the guest at run time) into the
    scroll session: our SessionCommand starts `scroll -c /etc/scroll/config` on the
    DRM backend; a planted ~/.profile (LD_PRELOAD + marker) must not take effect;
  * privileged protocols: grim (screencopy) and a locker run directly as plain
    clients are denied;
  * scroll-lock: SIGUSR1 -> lock_command (hardened-unlock -f) locks the session;
  * scroll-headless.service: wayvnc on /run/user/<uid>/wayvnc.sock, full RFB
    handshake with a framebuffer update, and the unit's NoNewPrivs/seccomp.

  test/bootc/desktop-smoke.py [--work test/bootc/work]
"""
import argparse
import base64
import os
import re
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e  # noqa: E402
from e2e import Fail, log  # noqa: E402
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "bootc_e2e", os.path.join(os.path.dirname(os.path.abspath(__file__)), "e2e.py"))
bootc_e2e = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bootc_e2e)   # sets the guest prompts and Secure Boot knobs

USER, PASS = "tester", "Acct-Pass-1"

# RFB 3.8 client: version, security None, ClientInit, one full FramebufferUpdate.
RFB = r'''
import socket, struct, sys
def rx(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: sys.exit("closed")
        b += c
    return b
s = socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sys.argv[1])
assert rx(s, 12) == b"RFB 003.008\n"; s.sendall(b"RFB 003.008\n")
n = rx(s, 1)[0]; assert 1 in rx(s, n), "no None security"
s.sendall(b"\x01"); assert rx(s, 4) == b"\0\0\0\0"; s.sendall(b"\x01")
w, h = struct.unpack(">HH", rx(s, 4)); rx(s, 16); rx(s, struct.unpack(">I", rx(s, 4))[0])
s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))
assert rx(s, 1) == b"\0", "no FramebufferUpdate"
print(f"RFB-OK {w}x{h}")
'''


def guest_file(ser, path, text, mode="0644", owner="root"):
    b64 = base64.b64encode(text.encode()).decode()
    ser.check(f"echo {b64} | base64 -d > {path} && chmod {mode} {path} && chown {owner}: {path}")


def smoke(lab):
    ser = lab.boot("desktop")
    ser.expect(e2e.PASS_PROMPT, 240, fail_on=e2e.TPM_PROMPT)
    ser.send(lab.env["LAB_RECOVERY"])
    lab.wait_shell(300)
    results = []

    def ok(name, cond, detail=""):
        results.append((name, bool(cond)))
        log(f"{'PASS' if cond else 'FAIL'} {name}" + (f": {detail}" if detail and not cond else ""))

    ser.check(f"id {USER} >/dev/null 2>&1 || useradd -m {USER}; echo '{USER}:{PASS}' | chpasswd")
    uid = ser.value(f"id -u {USER}")
    rt = f"/run/user/{uid}"
    evil = "touch /tmp/profile-ran\nexport LD_PRELOAD=/nonexistent-evil.so\n"
    for f in (".profile", ".bash_profile"):
        guest_file(ser, f"/home/{USER}/{f}", evil, owner=USER)
    ser.check("rm -f /tmp/profile-ran")
    # lab only: SDDM autologin into the scroll session
    guest_file(ser, "/etc/sddm.conf.d/zz-lab-autologin.conf",
               f"[Autologin]\nUser={USER}\nSession=scroll.desktop\n")
    ser.check("systemctl restart sddm")

    pid = ""
    for _ in range(60):
        pid = ser.value(f"pgrep -u {USER} -x scroll | head -1")
        if pid:
            break
        time.sleep(2)
    if not pid:
        log(ser.check(f"journalctl -b -u sddm --no-pager | tail -30; "
                      f"tail -40 /home/{USER}/.local/share/sddm/wayland-session.log 2>&1"))
        raise Fail("scroll session did not start under SDDM")
    time.sleep(5)
    log(f"screenshot {lab.screenshot('session')}")
    cmdline = ser.value(f"tr '\\0' ' ' < /proc/{pid}/cmdline")
    ok("session runs scroll -c /etc/scroll/config", "-c /etc/scroll/config" in cmdline, cmdline)
    ok("~/.profile not sourced", ser.value("test -e /tmp/profile-ran && echo ran || echo no") == "no")
    ok("no LD_PRELOAD in the compositor", ser.value(
        f"tr '\\0' '\\n' < /proc/{pid}/environ | grep -c '^LD_PRELOAD=' || true") == "0")
    drm = ser.value(f"ls -l /proc/{pid}/fd 2>/dev/null | grep -c '/dev/dri/card' || true")
    ok("DRM backend (compositor holds /dev/dri/card*)", drm not in ("", "0"), drm)
    log(ser.check(f"grep -iE 'renderer|backend|GLES|pixman|EGL' "
                  f"/home/{USER}/.local/share/sddm/wayland-session.log 2>/dev/null | head -8 || true"))

    disp = ser.value(f"cd {rt} && ls wayland-* | grep -v lock | head -1")
    env = f"XDG_RUNTIME_DIR={rt} WAYLAND_DISPLAY={disp} SCROLL_PID={pid}"
    as_user = f"runuser -u {USER} -- env {env}"
    rc, out = ser.run(f"{as_user} grim /tmp/smoke-grim.png 2>&1 | tail -2")
    ok("grim (screencopy) denied to a plain client",
       ser.value("test -s /tmp/smoke-grim.png && echo shot || echo none") == "none", out)
    rc, out = ser.run(f"{as_user} timeout 15 hardened-unlock -f </dev/null 2>&1 | tail -3; "
                      f"test -e {rt}/scroll-locked.{pid}")
    ok("a locker run directly can't lock", rc != 0, out)
    rc, out = ser.run(f"{as_user} scroll-lock </dev/null; echo lockrc=$?", 60)
    ok("scroll-lock locks the DRM session",
       "lockrc=0" in out and ser.value(f"test -e {rt}/scroll-locked.{pid} && echo y") == "y"
       and ser.value(f"pgrep -u {USER} -x hardened-unlock | head -1") != "", out)
    time.sleep(3)
    log(f"screenshot {lab.screenshot('locked')}")

    # headless session with wayvnc on the Unix socket
    ser.check(f"systemctl --user -M {USER}@ start scroll-headless.service", 120)
    sock = f"{rt}/wayvnc.sock"
    for _ in range(30):
        if ser.value(f"test -S {sock} && echo y || echo n") == "y":
            break
        time.sleep(1)
    guest_file(ser, "/tmp/rfb.py", RFB, owner=USER)
    rc, out = ser.run(f"runuser -u {USER} -- python3 -I /tmp/rfb.py {sock}", 60)
    ok("wayvnc over the Unix socket: RFB handshake + framebuffer", "RFB-OK" in out, out)
    ok("no TCP listener for VNC", ser.value("ss -Hltn | grep -c ':590[0-9]' || true") == "0")
    perms = ser.value(f"stat -c %a {rt}")
    ok("runtime dir is 0700", perms == "700", perms)
    hpid = ser.value(f"pgrep -u {USER} -f 'scroll -c /etc/scroll/headless.conf' | head -1")
    st = ser.value(f"grep -E '^(NoNewPrivs|Seccomp):' /proc/{hpid}/status | tr -s '\\t\\n' '  '")
    ok("headless unit: NoNewPrivs 1, seccomp filter", re.search(r"NoNewPrivs: 1 .*Seccomp: 2", st), st)
    lab.poweroff()
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=os.path.join(e2e.ROOT, "test/bootc/work"))
    a = ap.parse_args()
    lab = e2e.Lab(a.work)
    bootc_e2e.configure(lab)
    lab.extra_qemu_tail = []
    lab.vga = "virtio"
    orig = lab.boot
    lab.boot = lambda *x, **k: orig(*x, fido=False, **k)
    results, err = [], None
    try:
        results = smoke(lab)
    except Fail as e:
        err = str(e)
        log(f"FAIL: {e}")
    finally:
        lab.kill()
    print("\n==== desktop smoke results ====")
    for n, r in results:
        print(f"  {'PASS' if r else 'FAIL'}  {n}")
    if err:
        print(f"  ERROR {err[:300]}")
    return 0 if results and all(r for _, r in results) and not err else 1


if __name__ == "__main__":
    sys.exit(main())
