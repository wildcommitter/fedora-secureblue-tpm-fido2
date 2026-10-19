#!/usr/bin/env python3
"""Desktop smoke test on the sealed image under KVM: Secure Boot, swtpm, virtio
GPU with two outputs, and scroll on the DRM backend as a real user.

The lab disk is unlocked with the recovery passphrase. Lab-only changes, made in
the guest at run time and never in the image: a user, SDDM autologin, a debug
session file and a cursor-theme drop-in.

Phase A, the real session (scroll.desktop through our SDDM SessionCommand):
  * scroll -c /etc/scroll/config; a planted ~/.profile (marker + LD_PRELOAD)
    isn't sourced and LD_PRELOAD doesn't reach the compositor.

Phase B, the same compositor with -d and WLR_RENDERER=gles2 (lab session), going
through the fork's FORK.md "VM smoke test" checklist:
  1. sandbox log lines; Seccomp 2, NoNewPrivs 1
  2. gles2 on the virtual GPU, render node open, no EACCES from EGL/GBM
  3. output hotplug (connector forced on/off): wl_output globals 1 -> 2 -> 1
  4. USB keyboard hotplug (device_add usb-kbd): evdev fd opened/closed; typing works
  5. cursor theme set and resized across reloads, no load errors
  6. fonts: title bar screenshot (artifacts/), no pango/font errors
  7. exec: foot by binding, swayidle -> scroll-lock -> locker, wayvnc by exec_privileged
  8. reload by binding
  9. children (foot) Seccomp 0
 10. no Landlock denials in the kernel log or audit
plus: grim and a locker run directly are denied (plain clients), and the
headless unit's wayvnc answers a full RFB handshake on the Unix socket.

  test/bootc/desktop-smoke.py [--work test/bootc/work]
"""
import argparse
import base64
import importlib.util
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import e2e  # noqa: E402
from e2e import Fail, log  # noqa: E402

_spec = importlib.util.spec_from_file_location("bootc_e2e", os.path.join(HERE, "e2e.py"))
bootc_e2e = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bootc_e2e)   # guest prompts and Secure Boot knobs

USER, PASS = "tester", "Acct-Pass-1"
SLOG = f"/home/{USER}/.local/share/sddm/wayland-session.log"

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

# Plain Wayland client: prints the interfaces of all globals (wire protocol, stdlib).
GLOBALS = r'''
import os, socket, struct
s = socket.socket(socket.AF_UNIX)
s.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"], os.environ["WAYLAND_DISPLAY"]))
s.sendall(struct.pack("<III", 1, (12 << 16) | 1, 2) + struct.pack("<III", 1, (12 << 16) | 0, 3))
buf, names, done = b"", [], False
while not done:
    d = s.recv(65536)
    if not d: break
    buf += d
    while len(buf) >= 8:
        obj, so = struct.unpack("<II", buf[:8]); size, op = so >> 16, so & 0xffff
        if len(buf) < size: break
        body, buf = buf[8:size], buf[size:]
        if obj == 2 and op == 0:
            n = struct.unpack("<I", body[4:8])[0]
            names.append(body[8:8 + n - 1].decode())
        elif obj == 3:
            done = True
print(" ".join(names))
'''

KEYS = {" ": "spc", "-": "minus", "/": "slash", ".": "dot", "\n": "ret", "_": "shift-minus"}


def guest_file(ser, path, text, mode="0644", owner="root"):
    """Write a file in the guest. Its directory is created with an explicit owner and
    mode: root's umask on secureblue is 027, which would hide lab dirs from sddm."""
    b64 = base64.b64encode(text.encode()).decode()
    umask = "077" if owner != "root" else "022"
    ser.check(f"d=$(dirname {path}); [ -d \"$d\" ] || (umask {umask}; mkdir -p \"$d\"; chown {owner}: \"$d\"); "
              f"echo {b64} | base64 -d > {path} && chmod {mode} {path} && chown {owner}: {path}")


def type_keys(lab, text):
    for ch in text:
        lab.monitor(f"sendkey {KEYS.get(ch, ch)}")


class Smoke:
    boot_only = False

    def __init__(self, lab):
        self.lab = lab
        self.results = []

    def ok(self, name, cond, detail=""):
        self.results.append((name, bool(cond)))
        log(f"{'PASS' if cond else 'FAIL'} {name}" + (f" -- {detail}" if detail and not cond else ""))

    def start_session(self, session):
        ser = self.ser
        guest_file(ser, "/etc/sddm.conf.d/zz-lab-autologin.conf",
                   f"[Autologin]\nUser={USER}\nSession={session}\n\n"
                   "[Wayland]\nSessionDir=/usr/share/wayland-sessions,/etc/scroll-lab/sessions\n")
        rc, out = ser.run(f"rm -f {SLOG}; systemctl reset-failed sddm; systemctl restart sddm")
        if rc != 0:
            log(ser.check("systemctl status sddm --no-pager | tail -15; "
                          "journalctl -b -u sddm --no-pager | tail -40"))
            raise Fail(f"sddm restart for {session} failed")
        for _ in range(60):
            pid = ser.value(f"pgrep -u {USER} -x scroll | head -1")
            if pid:
                time.sleep(4)
                return pid
            time.sleep(2)
        log(ser.check(f"journalctl -b -u sddm --no-pager | tail -30; tail -40 {SLOG} 2>&1"))
        raise Fail(f"scroll session {session} did not start under SDDM")

    def user_env(self, pid):
        disp = self.ser.value(f"cd {self.rt} && ls wayland-* | grep -v lock | head -1")
        return f"runuser -u {USER} -- env XDG_RUNTIME_DIR={self.rt} WAYLAND_DISPLAY={disp} SCROLL_PID={pid}"

    def outputs(self, as_user):
        names = self.ser.value(f"{as_user} python3 -I /tmp/globals.py")
        return names.split().count("wl_output"), names

    def fds(self, pid, pattern):
        return int(self.ser.value(f"ls -l /proc/{pid}/fd 2>/dev/null | grep -c '{pattern}' || true") or 0)

    def run(self):
        lab = self.lab
        ser = self.ser = lab.boot("desktop")
        ser.expect(e2e.PASS_PROMPT, 240, fail_on=e2e.TPM_PROMPT)
        ser.send(lab.env["LAB_RECOVERY"])
        lab.wait_shell(300)
        ok = self.ok
        if self.boot_only:
            ok("boot to a root shell", True)
            lab.poweroff()
            return

        ser.check(f"id {USER} >/dev/null 2>&1 || useradd -m {USER}; echo '{USER}:{PASS}' | chpasswd; "
                  f"install -d -o {USER} -g {USER} -m 0700 /home/{USER}; chown {USER}: /home/{USER}; "
                  "rm -rf /etc/scroll/config.d/zz-lab-* /etc/scroll-lab /etc/sddm.conf.d/zz-lab-*")
        self.rt = rt = f"/run/user/{ser.value(f'id -u {USER}')}"
        evil = "touch /tmp/profile-ran\nexport LD_PRELOAD=/nonexistent-evil.so\n"
        for f in (".profile", ".bash_profile"):
            guest_file(ser, f"/home/{USER}/{f}", evil, owner=USER)
        guest_file(ser, "/tmp/globals.py", GLOBALS)
        guest_file(ser, "/tmp/rfb.py", RFB)
        guest_file(ser, "/etc/scroll-lab/sessions/scroll-lab.desktop",
                   "[Desktop Entry]\nName=scroll (lab debug)\n"
                   "Exec=env WLR_RENDERER=gles2 scroll -d -c /etc/scroll/config\nType=Application\n")
        ser.check("rm -f /tmp/profile-ran")

        # ---- phase A: the real session
        pid = self.start_session("scroll.desktop")
        cmdline = ser.value(f"tr '\\0' ' ' < /proc/{pid}/cmdline")
        ok("A: SDDM session runs scroll -c /etc/scroll/config", "-c /etc/scroll/config" in cmdline, cmdline)
        ok("A: ~/.profile not sourced", ser.value("test -e /tmp/profile-ran && echo ran || echo no") == "no")
        ok("A: no LD_PRELOAD in the compositor", ser.value(
            f"tr '\\0' '\\n' < /proc/{pid}/environ | grep -c '^LD_PRELOAD=' || true") == "0")
        ok("A: DRM backend (compositor holds /dev/dri/card*)", self.fds(pid, "/dev/dri/card") > 0)

        # ---- phase B: same compositor with -d and gles2
        # lab only: a cursor theme to resize across reloads, and title bars, so the
        # compositor itself renders text (pango) for item 6
        guest_file(ser, "/etc/scroll/config.d/zz-lab-cursor.conf",
                   "seat * xcursor_theme Adwaita 24\ndefault_border normal 2\n")
        pid = self.start_session("scroll-lab.desktop")
        as_user = self.user_env(pid)
        # The compositor's log: wherever its stderr goes (a file, or the journal).
        guest_file(ser, "/tmp/slog",
                   f"#!/bin/sh\nt=$(readlink /proc/{pid}/fd/2)\n"
                   "case $t in /*) cat \"$t\" ;; "
                   f"*) journalctl -b _PID={pid} -o cat --no-pager ;; esac\n", mode="0755")
        log(f"compositor stderr: {ser.value(f'readlink /proc/{pid}/fd/2')}")
        st = ser.value(f"grep -E '^(NoNewPrivs|Seccomp):' /proc/{pid}/status | tr -s '\\t\\n' '  '")
        logs = ser.check(f"/tmp/slog | grep -E 'sandbox: (Landlock ABI [0-9]+ applied|seccomp filter applied)'")
        ok("1 sandbox applied (log), Seccomp 2, NoNewPrivs 1",
           re.search(r"Landlock ABI \d+ applied", logs) and "seccomp filter applied" in logs
           and re.search(r"NoNewPrivs: 1 .*Seccomp: 2", st), f"{st} / {logs[-300:]}")
        log(ser.check(f"/tmp/slog | grep -iE 'GLES2|EGL (vendor|version)|renderer|DRM device|render node' | head -10 || true"))
        eacces = ser.value(f"/tmp/slog | grep -ciE 'permission denied|EACCES' || true")
        ok("2 gles2 renderer, render node open, no EACCES",
           self.fds(pid, "/dev/dri/renderD") > 0 and eacces == "0"
           and ser.value(f"/tmp/slog | grep -ciE 'Failed to create (renderer|EGL)|Could not initialize EGL' || true") == "0",
           f"renderD fds={self.fds(pid, '/dev/dri/renderD')} eacces={eacces}")

        # 3. output hotplug via the second virtio-gpu connector. Forcing its status
        # sends no uevent, and wlroots rescans only on a drm change with HOTPLUG=1;
        # a synthetic uevent carries that as SYNTH_ARG_HOTPLUG, which a lab-only
        # udev rule turns into HOTPLUG=1 (what the kernel sends on a real hotplug).
        guest_file(ser, "/etc/udev/rules.d/99-lab-hotplug.rules",
                   'ACTION=="change", SUBSYSTEM=="drm", ENV{SYNTH_ARG_HOTPLUG}=="1", ENV{HOTPLUG}="1"\n')
        ser.check("udevadm control --reload")
        conn = ser.value("ls -d /sys/class/drm/card*-Virtual-2 2>/dev/null | head -1")
        card = conn.rsplit("-Virtual-2", 1)[0] if conn else ""
        hotplug = f"echo \"change $(cat /proc/sys/kernel/random/uuid) HOTPLUG=1\" > {card}/uevent"
        n0, _ = self.outputs(as_user)
        ser.check(f"echo on > {conn}/status && {hotplug}")
        time.sleep(4)
        n1, _ = self.outputs(as_user)
        log(f"screenshot {lab.screenshot('two-outputs')}")
        ser.check(f"echo off > {conn}/status && {hotplug}")
        time.sleep(4)
        n2, _ = self.outputs(as_user)
        denied = ser.value(f"/tmp/slog | grep -ciE '(/sys|/run/udev).*(denied|EACCES)|(denied|EACCES).*(/sys|/run/udev)' || true")
        ok("3 output hotplug: wl_output 1 -> 2 -> 1, no /sys or /run/udev denial",
           conn and (n0, n1, n2) == (1, 2, 1) and denied == "0", f"conn={conn} outputs={n0},{n1},{n2} denied={denied}")

        # 4. USB keyboard hotplug; 7. foot by binding; 9. its Seccomp
        ev0 = self.fds(pid, "/dev/input/event")
        lab.monitor("device_add usb-kbd,bus=xhci.0,id=labkbd")
        time.sleep(4)
        ev1 = self.fds(pid, "/dev/input/event")
        lab.monitor("sendkey meta_l-ret")      # $mod+Return -> exec $term (foot)
        foot = ""
        for _ in range(20):
            foot = ser.value(f"pgrep -u {USER} -n -x foot || true")
            if foot:
                break
            time.sleep(1)
        ok("7a exec by binding starts foot", foot != "")
        time.sleep(3)
        ser.check("rm -f /tmp/kbd-typed")
        type_keys(lab, "touch /tmp/kbd-typed\n")
        time.sleep(3)
        typed = ser.value("test -e /tmp/kbd-typed && stat -c %U /tmp/kbd-typed || echo none")
        log(f"screenshot {lab.screenshot('foot')}")
        lab.monitor("device_del labkbd")
        time.sleep(4)
        ev2 = self.fds(pid, "/dev/input/event")
        ok("4 USB keyboard hotplug: evdev fd added and removed; typing reaches foot",
           ev1 == ev0 + 1 and ev2 == ev0 and typed == USER, f"evdev fds {ev0},{ev1},{ev2} typed={typed}")
        if foot:
            seccomp = ser.value(f"grep -E '^Seccomp:' /proc/{foot}/status | tr -s '\\t' ' '")
            ok("9 children: foot has Seccomp 0", seccomp == "Seccomp: 0", seccomp)
        else:
            ok("9 children: foot has Seccomp 0", False, "no foot")
        ok("6 fonts: no pango/font errors (title bar in artifacts/*-foot.png)",
           ser.value(f"/tmp/slog | grep -ciE 'pango.*(error|fail)|font.*(not found|fail)' || true") == "0")

        # 5. cursor theme across reloads; 8. reload by binding ($mod+Shift+c)
        loads0 = int(ser.value(f"/tmp/slog | grep -c 'Loading config from' || true") or 0)
        guest_file(ser, "/etc/scroll/config.d/zz-lab-cursor.conf",
                   "seat * xcursor_theme Adwaita 32\ndefault_border normal 2\n")
        lab.monitor("sendkey meta_l-shift-c")
        time.sleep(4)
        loads1 = int(ser.value(f"/tmp/slog | grep -c 'Loading config from' || true") or 0)
        alive = ser.value(f"kill -0 {pid} && echo y || echo n")
        ok("8 reload by binding (config from /etc/scroll)", loads1 > loads0 and alive == "y",
           f"loads {loads0}->{loads1} alive={alive}")
        curerr = ser.value(f"/tmp/slog | grep -ciE 'xcursor|cursor theme' | head -1 || true")
        cur_bad = ser.value(f"/tmp/slog | grep -ciE '(cannot|failed to|unable to) load .*(xcursor|cursor)' || true")
        ok("5 cursor theme Adwaita 24 -> 32 across reload, no load error", cur_bad == "0",
           f"cursor lines={curerr} errors={cur_bad}")
        log(f"screenshot {lab.screenshot('after-reload')}")

        # plain clients are denied privileged protocols
        rc, out = ser.run(f"{as_user} grim /tmp/smoke-grim.png 2>&1 | tail -2")
        ok("grim (screencopy) denied to a plain client",
           ser.value("test -s /tmp/smoke-grim.png && echo shot || echo none") == "none", out)
        rc, out = ser.run(f"{as_user} timeout 15 hardened-unlock -f </dev/null 2>&1 | tail -3; "
                          f"test -e {rt}/scroll-locked.{pid}")
        ok("a locker run directly (plain client) can't lock", rc != 0, out)

        # 7b. swayidle -> scroll-lock -> lock_command (hardened-unlock -f)
        ser.check(f"{as_user} sh -c 'swayidle -w timeout 5 scroll-lock >/tmp/swayidle.log 2>&1 &'")
        locked = "n"
        for _ in range(30):
            locked = ser.value(f"test -e {rt}/scroll-locked.{pid} && pgrep -u {USER} -x hardened-unlock >/dev/null && echo y || echo n")
            if locked == "y":
                break
            time.sleep(1)
        ok("7b swayidle -> scroll-lock -> hardened-unlock locks the session", locked == "y")
        time.sleep(3)
        log(f"screenshot {lab.screenshot('locked')}")

        # 7c. wayvnc via exec_privileged in the headless unit, over the Unix socket
        ser.check(f"systemctl --user -M {USER}@ start scroll-headless.service", 120)
        sock = f"{rt}/wayvnc.sock"
        for _ in range(30):
            if ser.value(f"test -S {sock} && echo y || echo n") == "y":
                break
            time.sleep(1)
        rc, out = ser.run(f"runuser -u {USER} -- python3 -I /tmp/rfb.py {sock}", 60)
        ok("7c wayvnc (exec_privileged): RFB handshake + framebuffer on the Unix socket", "RFB-OK" in out, out)
        ok("no TCP listener for VNC", ser.value("ss -Hltn | grep -c ':590[0-9]' || true") == "0")
        hpid = ser.value(f"pgrep -u {USER} -f 'scroll -c /etc/scroll/headless.conf' | head -1")
        st = ser.value(f"grep -E '^(NoNewPrivs|Seccomp):' /proc/{hpid}/status | tr -s '\\t\\n' '  '")
        ok("headless unit: NoNewPrivs 1, Seccomp 2", re.search(r"NoNewPrivs: 1 .*Seccomp: 2", st), st)

        # 10. Landlock denials
        # "landlock: Up and running." is the kernel's boot banner, not a denial
        kern = ser.value("journalctl -k -b --no-pager -o cat | grep -i landlock "
                         "| grep -vc 'Up and running' || true")
        aud = ser.value("ausearch -m LANDLOCK_ACCESS,LANDLOCK_DOMAIN -ts boot 2>/dev/null | grep -c 'type=' || true")
        audit_on = ser.value("auditctl -s 2>/dev/null | sed -n 's/^enabled //p'")
        log(ser.check("journalctl -k -b --no-pager -o cat | grep -i landlock | tail -5 || true"))
        ok("10 no Landlock denials (kernel log, audit)", kern == "0" and aud in ("", "0"),
           f"kernel lines={kern} audit records={aud} audit enabled={audit_on}")
        log(f"audit enabled={audit_on!r} (Landlock audit records need it)")
        lab.poweroff()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=os.path.join(e2e.ROOT, "test/bootc/work"))
    ap.add_argument("--gpu", default="virtio-vga,max_outputs=2",
                    help="QEMU GPU device (std = -vga std, for comparison)")
    ap.add_argument("--boot-only", action="store_true", help="stop after the root shell")
    a = ap.parse_args()
    lab = e2e.Lab(a.work)
    bootc_e2e.CLI_FROM_IMAGE = True      # no tokenvault CLI disk needed here
    bootc_e2e.configure(lab)
    if a.gpu == "std":
        lab.vga = "std"
    else:
        lab.vga = "none"
        lab.extra_qemu += ["-device", a.gpu]
    Smoke.boot_only = a.boot_only
    orig = lab.boot
    lab.boot = lambda *x, **k: orig(*x, fido=False, **k)
    s, err = Smoke(lab), None
    try:
        s.run()
    except Fail as e:
        err = str(e)
        log(f"FAIL: {e}")
    finally:
        lab.kill()
    print("\n==== desktop smoke results ====")
    for n, r in s.results:
        print(f"  {'PASS' if r else 'FAIL'}  {n}")
    if err:
        print(f"  ERROR {err[:400]}")
    return 0 if s.results and all(r for _, r in s.results) and not err else 1


if __name__ == "__main__":
    sys.exit(main())
