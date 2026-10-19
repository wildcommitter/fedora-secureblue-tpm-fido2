#!/usr/bin/env python3
"""Shared KVM harness for the tokenvault e2e (test/bootc/e2e.py).

  * Lab: a QEMU guest with OVMF, an emulated TPM2 (swtpm, TPM-CRB) and the
    virtual FIDO2 key (test/vfido) on a dummy_hcd USB gadget, passed in with
    QEMU usb-host -- the host's TPM and real key are never touched;
  * Serial: the serial console for prompts and commands; the QEMU monitor
    for keystrokes and screendumps;
  * scenarios shared by the harnesses (wrong PINs, no touch, no key,
    foreign TPM). The caller sets the prompt regexes for its guest.

Artifacts (serial logs, vfido log, screenshots) land in <work>/artifacts/.
"""
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OVMF_CODE = "/usr/share/edk2/x64/OVMF_CODE.4m.fd"
OVMF_VARS = "/usr/share/edk2/x64/OVMF_VARS.4m.fd"
VID, PID = "0x1209", "0x7f1d"

TPM2_PIN = "tpm2 pin: Gr33n-Lantern!"
FIDO2_PIN = "fido2-pin 7781"
SHELL_PROMPT = r"root@tokenvault-lab[^\n]*# "
TPM_PROMPT = r"Please enter TPM2 PIN"
FIDO_PROMPT = r"Please enter security token PIN"
PASS_PROMPT = r"Please enter passphrase for disk [^\n]*luks-"


class Fail(Exception):
    pass


def log(msg):
    print(f"[e2e {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sh(*cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kw).stdout


class Serial:
    """Persistent reader of the QEMU serial socket with expect()."""

    def __init__(self, path, logpath):
        for _ in range(100):
            try:
                self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.s.connect(path)
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise Fail(f"cannot connect to serial {path}")
        self.buf = ""
        self.pos = 0
        self.lock = threading.Lock()
        self.logf = open(logpath, "a", buffering=1, errors="replace")
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while True:
            try:
                d = self.s.recv(65536)
            except OSError:
                return
            if not d:
                return
            t = d.decode("utf-8", "replace").replace("\r", "")
            # drop shell-integration OSC sequences (ESC ] 3008 ... ST) and CSI
            t = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", t)
            t = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", t)
            with self.lock:
                self.buf += t
            self.logf.write(t)

    def expect(self, pattern, timeout=120, fail_on=None):
        """Wait for regex after the last match; returns the match."""
        rx = re.compile(pattern)
        frx = re.compile(fail_on) if fail_on else None
        end = time.time() + timeout
        while time.time() < end:
            with self.lock:
                hay = self.buf[self.pos:]
            m = rx.search(hay)
            if m:
                self.pos += m.end()
                return m
            if frx and frx.search(hay):
                raise Fail(f"saw {fail_on!r} while waiting for {pattern!r}; tail:\n{hay[-1500:]}")
            time.sleep(0.2)
        with self.lock:
            tail = self.buf[-2000:]
        raise Fail(f"timeout ({timeout}s) waiting for {pattern!r}; serial tail:\n{tail}")

    def seen_since(self, mark, pattern):
        with self.lock:
            return re.search(pattern, self.buf[mark:]) is not None

    def mark(self):
        with self.lock:
            return len(self.buf)

    def send(self, line):
        self.s.sendall(line.encode() + b"\r")

    def run(self, cmd, timeout=300):
        """Run a shell command in the guest; returns (rc, output)."""
        tag = f"__E2E_{int(time.time() * 1000)}__"
        self.send(f"{cmd}; echo {tag}=$?")
        m = self.expect(re.escape(tag) + r"=(\d+)", timeout)
        with self.lock:
            out = self.buf[max(0, self.pos - m.end() - 20000):self.pos]
        out = out.rsplit(tag, 2)
        body = out[-2] if len(out) >= 2 else ""
        return int(m.group(1)), body

    def value(self, cmd, timeout=300):
        """Output of a guest command, robust against console noise: wrapped
        in markers that the echoed command line itself cannot match."""
        self.send(f"printf '%s%s\\n' '__V' \"AL<$({cmd})>__\"")
        return self.expect(r"__VAL<([^>\n]*)>__", timeout).group(1).strip()

    def check(self, cmd, timeout=300):
        rc, out = self.run(cmd, timeout)
        if rc != 0:
            raise Fail(f"guest command failed rc={rc}: {cmd}\n{out[-3000:]}")
        return out


class Lab:
    def __init__(self, work):
        self.work = os.path.abspath(work)
        self.art = os.path.join(self.work, "artifacts")
        os.makedirs(self.art, exist_ok=True)
        self.env = dict(l.strip().split("=", 1) for l in open(os.path.join(self.work, "guest.env")) if "=" in l)
        # Firmware/machine knobs; the sealed-UKI harness switches these to
        # Secure Boot (SMM, secboot code, custom-mode vars).
        self.ovmf_code = OVMF_CODE
        self.vars_template = OVMF_VARS
        self.machine = "q35,accel=kvm"
        self.extra_qemu = []
        self.extra_qemu_tail = []   # appended last (e.g. extra drives after the boot disk)
        self.vga = "std"            # QEMU -vga (desktop-smoke uses virtio)
        self.vars = os.path.join(self.work, "OVMF_VARS.fd")
        self.tpm_dir = os.path.join(self.work, "tpm-machine")
        self.vf_state = os.path.join(self.work, "vfido-state.json")
        self.vf_ctl = os.path.join(self.work, "vfido-ctl")
        self.vf_log = os.path.join(self.art, "vfido.log")
        self.qemu = self.swtpm = self.vfido = None
        self.boot_no = 0

    # ---- virtual FIDO2 key -------------------------------------------------
    def fido_up(self):
        out = sh("sudo", os.path.join(ROOT, "test/vfido/gadget.sh"), "up")
        hidg = re.search(r"hidg=(\S+)", out).group(1)
        os.makedirs(self.vf_ctl, exist_ok=True)
        self.presence("auto")
        self.vfido = subprocess.Popen(
            [sys.executable, "-I", os.path.join(ROOT, "test/vfido/vfido.py"),
             "--hidg", hidg, "--state", self.vf_state, "--ctl", self.vf_ctl],
            stdout=open(self.vf_log, "a"), stderr=subprocess.STDOUT)
        time.sleep(0.5)

    def fido_down(self):
        if self.vfido:
            self.vfido.terminate()
            self.vfido.wait()
            self.vfido = None
        subprocess.run(["sudo", os.path.join(ROOT, "test/vfido/gadget.sh"), "down"], check=False)

    def presence(self, mode):
        with open(os.path.join(self.vf_ctl, "presence"), "w") as f:
            f.write(mode)

    def vfido_events(self, start):
        with open(self.vf_log) as f:
            f.seek(start)
            return f.read()

    def vfido_mark(self):
        return os.path.getsize(self.vf_log) if os.path.exists(self.vf_log) else 0

    # ---- VM ----------------------------------------------------------------
    def boot(self, name, fido=True, tpm_dir=None, no_reboot=True):
        """no_reboot=False keeps QEMU running across a guest reset (the
        duress e2e watches the reset and the next boot on one serial log)."""
        self.boot_no += 1
        if not os.path.exists(self.vars):
            shutil.copy(self.vars_template, self.vars)
        tpm_dir = tpm_dir or self.tpm_dir
        os.makedirs(tpm_dir, exist_ok=True)
        sock = os.path.join(tpm_dir, "swtpm.sock")
        if os.path.exists(sock):
            os.unlink(sock)
        self.swtpm = subprocess.Popen(
            ["swtpm", "socket", "--tpm2", "--tpmstate", f"dir={tpm_dir}",
             "--ctrl", f"type=unixio,path={sock}", "--terminate",
             "--log", f"file={os.path.join(tpm_dir, 'swtpm.log')},level=1"])
        for _ in range(50):
            if os.path.exists(sock):
                break
            time.sleep(0.1)
        self.mon_path = os.path.join(self.work, "monitor.sock")
        ser_path = os.path.join(self.work, "serial.sock")
        for p in (self.mon_path, ser_path):
            if os.path.exists(p):
                os.unlink(p)
        cmd = ["qemu-system-x86_64", "-name", "tokenvault-e2e",
               "-machine", self.machine, "-cpu", "host", "-smp", "4", "-m", "4096",
               *self.extra_qemu,
               "-drive", f"if=pflash,format=raw,readonly=on,file={self.ovmf_code}",
               "-drive", f"if=pflash,format=raw,file={self.vars}",
               "-drive", f"if=virtio,format=raw,cache=writeback,file={os.path.join(self.work, 'disk.raw')}",
               "-chardev", f"socket,id=chrtpm,path={sock}",
               "-tpmdev", "emulator,id=tpm0,chardev=chrtpm", "-device", "tpm-crb,tpmdev=tpm0",
               "-device", "qemu-xhci,id=xhci",
               "-vga", self.vga, "-display", "none",
               "-serial", f"unix:{ser_path},server=on,wait=off",
               "-monitor", f"unix:{self.mon_path},server=on,wait=off"]
        if no_reboot:
            cmd.append("-no-reboot")
        if fido:
            cmd += ["-device", f"usb-host,bus=xhci.0,vendorid={VID},productid={PID}"]
        cmd += self.extra_qemu_tail
        log(f"boot #{self.boot_no} [{name}] fido={'yes' if fido else 'no'} tpm={os.path.basename(tpm_dir)}")
        self.qemu = subprocess.Popen(cmd, stdout=open(os.path.join(self.art, "qemu.log"), "a"),
                                     stderr=subprocess.STDOUT)
        self.ser = Serial(ser_path, os.path.join(self.art, f"serial-{self.boot_no:02d}-{name}.log"))
        return self.ser

    def monitor(self, command):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.mon_path)
        s.recv(4096)
        s.sendall(command.encode() + b"\n")
        time.sleep(0.3)
        s.close()

    def sendkeys(self, text):
        keymap = {" ": "spc", "-": "minus", "!": "shift-1", ":": "shift-semicolon",
                  ".": "dot", "\n": "ret", "_": "shift-minus", "@": "shift-2"}
        for ch in text:
            if ch in keymap:
                k = keymap[ch]
            elif ch.isupper():
                k = "shift-" + ch.lower()
            else:
                k = ch
            self.monitor(f"sendkey {k}")

    def screenshot(self, name):
        path = os.path.join(self.art, f"{self.boot_no:02d}-{name}.png")
        self.monitor(f"screendump {path} -f png")
        return path

    def wait_shell(self, timeout=180):
        self.ser.expect(SHELL_PROMPT, timeout)
        self.ser.send("stty cols 250; export SYSTEMD_PAGER= SYSTEMD_COLORS=0 TERM=dumb; PS1='root@tokenvault-lab# '")
        self.ser.expect(SHELL_PROMPT, 10)

    def poweroff(self):
        try:
            self.ser.send("systemctl poweroff")
        except OSError:
            pass
        try:
            self.qemu.wait(90)
        except subprocess.TimeoutExpired:
            self.monitor("quit")
            self.qemu.wait(10)
        self.swtpm.wait(10) if self.swtpm.poll() is None else None
        self.qemu = None

    def kill(self):
        for p in (self.qemu, self.swtpm):
            if p and p.poll() is None:
                p.send_signal(signal.SIGTERM)
                try:
                    p.wait(10)
                except subprocess.TimeoutExpired:
                    p.kill()


# ---------------------------------------------------------------- scenarios

def unlock_with_tokens(lab, ser, tpm_pin=TPM2_PIN):
    ser.expect(TPM_PROMPT, 180, fail_on=PASS_PROMPT)
    ser.send(tpm_pin)
    ser.expect(FIDO_PROMPT, 120, fail_on=PASS_PROMPT)
    ser.send(FIDO2_PIN)


def assert_clean_after_boot(ser, mark):
    if ser.seen_since(mark, PASS_PROMPT):
        raise Fail("target passphrase prompt appeared although the vault should have unlocked it")
    out = ser.check("ls /dev/mapper; findmnt -rn /run/tokenvault/esp || echo NO-ESP-MOUNT")
    if "tokenvault" in out:
        raise Fail(f"vault mapping still present after switch-root:\n{out}")
    if "NO-ESP-MOUNT" not in out:
        raise Fail("ESP still mounted at /run/tokenvault/esp")
    j = ser.check("journalctl -b -o cat --no-pager | grep -E 'tokenvault|Unlocked volume|keyfile|key file' | tail -40")
    return j


def touches(lab, vmark):
    return vfido_count(lab.vfido_events(vmark), "up=granted")


def vfido_count(text, what):
    return len(re.findall(r"EVENT " + what, text))


def sc_wrong_tpm_pin(lab):
    """A wrong TPM2 PIN is re-asked; the right one then unlocks."""
    ser = lab.boot("wrong-tpm-pin")
    mark = ser.mark()
    ser.expect(TPM_PROMPT, 180, fail_on=PASS_PROMPT)
    ser.send("definitely-not-the-pin")
    ser.expect(TPM_PROMPT, 60, fail_on=PASS_PROMPT)
    ser.send(TPM2_PIN)
    ser.expect(FIDO_PROMPT, 120, fail_on=PASS_PROMPT)
    ser.send(FIDO2_PIN)
    lab.wait_shell()
    assert_clean_after_boot(ser, mark)
    lab.poweroff()


def sc_wrong_fido_pin(lab):
    """A wrong FIDO2 PIN is re-asked (key counts the retry); right one unlocks."""
    vmark = lab.vfido_mark()
    ser = lab.boot("wrong-fido-pin")
    mark = ser.mark()
    ser.expect(TPM_PROMPT, 180, fail_on=PASS_PROMPT)
    ser.send(TPM2_PIN)
    ser.expect(FIDO_PROMPT, 120, fail_on=PASS_PROMPT)
    ser.send("0000-wrong")
    ser.expect(FIDO_PROMPT, 60, fail_on=PASS_PROMPT)
    ser.send(FIDO2_PIN)
    lab.wait_shell()
    assert_clean_after_boot(ser, mark)
    if "pin=wrong" not in lab.vfido_events(vmark):
        raise Fail("key never saw the wrong PIN")
    lab.poweroff()


def expect_fallback(lab, ser, why):
    ser.expect(PASS_PROMPT, 300)
    log(f"fallback to recovery passphrase ({why})")
    ser.send(lab.env["LAB_RECOVERY"])
    lab.wait_shell()
    out = ser.check("ls /dev/mapper; findmnt -rn /run/tokenvault/esp || echo NO-ESP-MOUNT")
    if "tokenvault" in out or "NO-ESP-MOUNT" not in out:
        raise Fail(f"vault not cleaned up after fallback:\n{out}")


def sc_no_touch(lab):
    """PINs right but nobody touches the key -> vault stays shut -> recovery passphrase."""
    lab.presence("deny")
    try:
        vmark = lab.vfido_mark()
        ser = lab.boot("no-touch")
        unlock_with_tokens(lab, ser)
        expect_fallback(lab, ser, "touch denied")
        if touches(lab, vmark) != 0:
            raise Fail("a touch was granted although presence=deny")
        lab.poweroff()
    finally:
        lab.presence("auto")


def sc_no_key(lab):
    """FIDO2 key not plugged in -> TPM2 PIN alone is not enough -> recovery."""
    ser = lab.boot("no-key", fido=False)
    ser.expect(TPM_PROMPT, 180, fail_on=PASS_PROMPT)
    ser.send(TPM2_PIN)
    expect_fallback(lab, ser, "no FIDO2 key")
    lab.poweroff()


def sc_foreign_tpm(lab):
    """Disk + key moved to another machine (different TPM) -> recovery."""
    other = os.path.join(lab.work, "tpm-other-machine")
    shutil.rmtree(other, ignore_errors=True)
    ser = lab.boot("foreign-tpm", tpm_dir=other)
    m = ser.expect(f"({TPM_PROMPT}|{PASS_PROMPT})", 300)
    if m.group(0).startswith("Please enter TPM2"):
        ser.send(TPM2_PIN)
    else:
        ser.pos -= len(m.group(0))
    expect_fallback(lab, ser, "foreign TPM")
    lab.poweroff()
