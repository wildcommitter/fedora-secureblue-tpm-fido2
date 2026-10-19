#!/usr/bin/env python3
"""Duress canary e2e on the sealed-UKI image under KVM: the real hard reset.

The guest runs the production locker and helper. Everything happens inside
the VM; the host is never reset. Steps:

  1. Boot with the recovery passphrase (tokenvault isn't needed here). Check
     SELinux is enforcing, the helper socket's owner and mode, and that a user
     outside hardened-duress can't connect. Set the canary with
     `hardened-unlock duress set`. A malformed request doesn't reset and causes no AVC.
  2. Control: with systemd's status output on the console, a graceful
     `systemctl reboot` shows its shutdown sequence on the serial log.
  3. SDDM autologin (lab-only drop-in) starts scroll on the DRM backend, as
     the image's session does. Mod+Alt+L (QEMU sendkey) locks through
     `lock` -> lock_command. The canary is typed on the emulated keyboard.
     The guest must reset at once: "reboot: Restarting system", with none
     of the shutdown lines from step 2, then the firmware boots it again.
  4. On the next boot: the previous boot's journal has no shutdown sequence,
     no AVC mentions duress-reset, and the reset-attack (MOR) state is
     recorded.

  sudo test/bootc/lab-secureboot.sh <work> <dev keys> <dev db.key>
  sudo test/bootc/build-disk.sh <work> <dev image>
  test/bootc/duress-vm-e2e.py --work <work>
"""
import argparse
import os
import re
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import e2e  # noqa: E402
from e2e import Fail, log  # noqa: E402

e2e.SHELL_PROMPT = r"(-bash-[0-9.]+# |root@tokenvault-lab# )"
e2e.PASS_PROMPT = r"Please enter passphrase for disk [^\n]*\broot\b"

CANARY = "Heron-Canary-9"
USER, USER_PASS = "duser", "Duser-Pass-1"
SHUTDOWN = r"Stopping |Stopped |Reached target [^\n]*(Shutdown|Final Step|Reboot)|systemd-shutdown|Unmounting "
MOR = "/sys/firmware/efi/efivars/MemoryOverwriteRequestControl-e20939be-32d4-41be-a150-897f85d49829"
MOR_LOCK = "/sys/firmware/efi/efivars/MemoryOverwriteRequestControlLock-bb983ccf-151d-40e1-a07b-4a17be168292"


def configure(lab):
    lab.ovmf_code = "/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd"
    lab.vars_template = os.path.join(lab.work, "OVMF_VARS.sb.fd")
    lab.machine = "q35,accel=kvm,smm=on"
    lab.extra_qemu = ["-global", "driver=cfi.pflash01,property=secure,value=on", "-nic", "none"]


def recovery_boot(lab, ser):
    ser.expect(e2e.PASS_PROMPT, 300)
    ser.send(lab.env["LAB_RECOVERY"])
    lab.wait_shell(300)


def wait_value(ser, cmd, want, timeout):
    end = time.time() + timeout
    got = None
    while time.time() < end:
        got = ser.value(cmd)
        if got == want:
            return got
        time.sleep(2)
    raise Fail(f"{cmd!r}: got {got!r}, want {want!r}")


def mor_state(ser):
    out = {}
    for name, path in (("MOR", MOR), ("MORLock", MOR_LOCK)):
        out[name] = ser.value(f"test -e {path} && od -An -tx1 {path} | tr -s ' ' || echo absent")
    out["kernel RESET_ATTACK_MITIGATION"] = ser.value(
        "grep -h '^.*RESET_ATTACK_MITIGATION' /usr/lib/modules/$(uname -r)/config 2>/dev/null || echo unknown")
    out["init_on_free"] = ser.value("grep -o 'init_on_free=[0-9]' /proc/cmdline || echo absent")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    a = ap.parse_args()
    lab = e2e.Lab(a.work)
    configure(lab)
    results = []

    def step(name, ok, detail=""):
        results.append((name, ok))
        log(f"{'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}")
        if not ok:
            raise Fail(f"{name}: {detail}")

    try:
        # ---- boot 1: setup + graceful-reboot control
        ser = lab.boot("duress-setup", fido=False, no_reboot=False)
        recovery_boot(lab, ser)
        step("SELinux enforcing", ser.value("getenforce") == "Enforcing")
        step("helper socket active", ser.value("systemctl is-active hardened-unlock-duress.socket") == "active")
        ser.check(f"id {USER} >/dev/null 2>&1 || useradd -m {USER}; echo '{USER}:{USER_PASS}' | chpasswd; "
                  "id outsider >/dev/null 2>&1 || useradd -m outsider")
        out = ser.check(f"printf '%s\\n%s\\n' '{CANARY}' '{CANARY}' | hardened-unlock duress set --user {USER} 2>&1")
        log(out.strip()[-400:])
        step("canary file", ser.value("stat -c '%a %U %G' /etc/hardened-unlock/duress") == "640 root hardened-duress")
        step("socket mode", ser.value("stat -c '%a %U %G' /run/hardened-unlock/duress.sock") == "660 root hardened-duress")
        probe = ("python3 -Ic \"import socket,sys; s=socket.socket(socket.AF_UNIX); "
                 "s.connect('/run/hardened-unlock/duress.sock'); s.send(sys.argv[1].encode()); s.close(); print('sent')\"")
        step("outsider can't connect",
             ser.value(f"runuser -u outsider -- {probe} x 2>&1 | grep -c PermissionError") == "1")
        ser.check(f"runuser -u {USER} -- {probe} junk")
        time.sleep(2)
        step("malformed request: no reset, logged",
             ser.value("journalctl -b --no-pager -o cat -u hardened-unlock-duress.service | grep -c 'malformed request'") != "0")
        dom = ser.value("ps -eZ | awk '/duress-reset/{print $1}' | head -1")
        log(f"duress-reset runs as {dom}")
        uid = ser.value("ps -o user= -C duress-reset | head -1")
        caps = ser.value("grep CapEff /proc/$(pgrep -x duress-reset)/status | awk '{print $2}'")
        log(f"duress-reset user={uid} CapEff={caps} (CAP_SYS_BOOT only = 0000000000400000)")
        step("helper has only CAP_SYS_BOOT", caps == "0000000000400000", caps)
        step("no AVC so far", ser.value("ausearch -m AVC -ts boot 2>/dev/null | grep -c duress || true") in ("0", ""))
        # lab only: autologin into the image's scroll session
        ser.check("mkdir -p /etc/sddm.conf.d && printf '[Autologin]\\nUser=%s\\nSession=scroll.desktop\\n' "
                  f"{USER} > /etc/sddm.conf.d/zz-lab-autologin.conf")
        # control: systemd status on the console, then a graceful reboot
        ser.check("dmesg -n 7; kill -s RTMIN+20 1")
        mark = ser.mark()
        ser.send("systemctl reboot")
        ser.expect(r"reboot: Restarting system", 180)
        step("control: graceful reboot shows the shutdown sequence", ser.seen_since(mark, SHUTDOWN))

        # ---- boot 2: session, lock, canary -> hard reset
        recovery_boot(lab, ser)
        uid = ser.value(f"id -u {USER}")
        spid = ""
        end = time.time() + 120
        while time.time() < end and not spid:
            spid = ser.value(f"pgrep -u {USER} -x scroll || true")
            time.sleep(3)
        if not spid:
            log(ser.check(f"journalctl -b --no-pager -o cat -u sddm | tail -30; "
                          f"tail -30 /home/{USER}/.local/share/sddm/wayland-session.log 2>&1"))
        step("scroll session on DRM (SDDM autologin)", bool(spid), spid)
        time.sleep(5)
        lab.monitor("sendkey meta_l-alt-l")
        wait_value(ser, f"test -e /run/user/{uid}/scroll-locked.{spid} && echo locked || echo no", "locked", 30)
        step("Mod+Alt+L locked through lock_command",
             ser.value(f"pgrep -u {USER} -x hardened-unlock >/dev/null && echo yes || echo no") == "yes")
        log(f"screenshot {lab.screenshot('locked')}")
        ser.check("dmesg -n 7; kill -s RTMIN+20 1")
        time.sleep(3)
        mark = ser.mark()
        t0 = time.time()
        lab.sendkeys(CANARY + "\n")
        try:
            ser.expect(r"reboot: Restarting system", 30)
        except Fail:
            log(f"screenshot {lab.screenshot('after-canary')}")
            log(ser.check(
                "journalctl -b --no-pager -o short-monotonic -u hardened-unlock-duress.service | tail; "
                f"tail -40 /home/{USER}/.local/share/sddm/wayland-session.log 2>&1; "
                "ausearch -m AVC -ts recent 2>/dev/null | tail -20; "
                f"ps -eZ | grep -E 'hardened-unlock|scroll|duress'; id {USER}; "
                "ls -laZ /etc/hardened-unlock; "
                f"runuser -u {USER} -- head -c 4 /etc/hardened-unlock/duress; echo; "
                f"grep Groups /proc/$(pgrep -u {USER} -x hardened-unlock | head -1)/status; "
                f"journalctl -b --no-pager -o cat _UID=$(id -u {USER}) | grep -iE 'hardened-unlock|duress' | tail -20"))
            raise
        dt = time.time() - t0
        tail = ser.buf[mark:ser.pos] if hasattr(ser, "buf") else ""
        step("canary: immediate reset", True, f"{dt:.1f}s after the keys")
        step("canary: no shutdown sequence on the console", not ser.seen_since(mark, SHUTDOWN),
             re.findall(SHUTDOWN, tail)[:5].__str__())

        # ---- boot 3: back up, evidence
        recovery_boot(lab, ser)
        step("guest booted again after the reset", True)
        prev = ser.check("journalctl -b -1 --no-pager -o cat | tail -400")
        step("previous boot's journal: no shutdown sequence",
             not re.search(r"Reached target [^\n]*(Shutdown|Reboot)|System is rebooting|Stopping session", prev))
        avc = ser.value("ausearch -m AVC -ts yesterday 2>/dev/null | grep -c 'duress' || true")
        step("no AVC for the helper", avc in ("0", ""), avc)
        for k, v in mor_state(ser).items():
            log(f"reset-attack state: {k} = {v}")
        lab.poweroff()
    except Fail as e:
        log(f"FAIL: {e}")
        results.append(("(aborted) " + str(e).splitlines()[0][:100], False))
    finally:
        lab.kill()
    print("\n==== duress VM e2e results ====")
    for n, ok in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {n}")
    return 0 if results and all(ok for _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())
