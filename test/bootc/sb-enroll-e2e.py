#!/usr/bin/env python3
"""e2e for image/uki/secure-boot-keys.sh under KVM: enroll our own Secure Boot
keys from bash into firmware that starts in Setup Mode, then boot enforced.

  * OVMF with Secure Boot support (SMM) and EMPTY vars: Setup Mode, as after
    "clear Secure Boot keys" in a real firmware setup;
  * a virtio NIC, whose iPXE EFI option ROM the firmware runs and measures
    into PCR 2 (stands in for a GPU's GOP);
  * swtpm, so there is a real TPM event log;
  * the disk from build-disk.sh (signed with the DEV keys built into the image).

Checks: create works in the guest; enroll refuses keys that don't sign the ESP;
dry run lists the option ROM; enroll writes db (cert + ROM hash), KEK, PK and
leaves Setup Mode; the next boot runs under enforced Secure Boot with the
firmware verifying our signed systemd-boot and UKI.

  test/bootc/sb-enroll-e2e.py [--work test/bootc/work]
"""
import argparse
import os
import re
import sys
import tarfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import e2e  # noqa: E402
from e2e import Fail, log  # noqa: E402

e2e.SHELL_PROMPT = r"(-bash-[0-9.]+# |root@tokenvault-lab# )"
e2e.PASS_PROMPT = r"Please enter passphrase for disk [^\n]*\broot\b"
ROOT = e2e.ROOT
SCRIPT = "image/uki/secure-boot-keys.sh"
SBK = "bash /root/sbk/secure-boot-keys.sh"


def script_disk(lab):
    path = os.path.join(lab.work, "sbk.tar")
    with tarfile.open(path, "w") as t:
        t.add(os.path.join(ROOT, SCRIPT), arcname="secure-boot-keys.sh")
    size = os.path.getsize(path)
    with open(path, "ab") as f:
        f.write(b"\0" * ((-size) % (1 << 20)))
    return path


def boot_recovery(lab, name):
    lab.extra_qemu_tail = ["-drive", f"if=virtio,format=raw,readonly=on,file={script_disk(lab)}"]
    ser = lab.boot(name, fido=False)
    ser.expect(e2e.PASS_PROMPT, 240)
    ser.send(lab.env["LAB_RECOVERY"])
    lab.wait_shell(300)
    ser.check("rm -rf /root/sbk && mkdir /root/sbk && tar -xf /dev/vdb -C /root/sbk")
    return ser


def run(work):
    lab = e2e.Lab(work)
    lab.ovmf_code = "/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd"
    lab.vars_template = "/usr/share/edk2/x64/OVMF_VARS.4m.fd"     # empty: Setup Mode
    lab.vars = os.path.join(lab.work, "OVMF_VARS.setupmode.fd")
    if os.path.exists(lab.vars):
        os.unlink(lab.vars)
    lab.machine = "q35,accel=kvm,smm=on"
    lab.extra_qemu = ["-global", "driver=cfi.pflash01,property=secure,value=on",
                      "-nic", "user,model=virtio-net-pci"]
    lab.tpm_dir = os.path.join(lab.work, "tpm-sbenroll")
    try:
        # ---- boot 1: Setup Mode, Secure Boot off ----
        ser = boot_recovery(lab, "setup-mode")
        st = ser.check(f"{SBK} status --esp /boot")
        log("status before:\n" + st)
        if "SetupMode=1" not in st or "SecureBoot=0" not in st:
            raise Fail("firmware is not in Setup Mode with Secure Boot off")

        ser.check("rm -rf /root/k2 /root/secure-boot-backup-*")   # leftovers on the shared lab disk
        out = ser.check(f"{SBK} create --keys /root/k2/keys --secrets /root/k2/secrets", 300)
        for f in ("PK/PK.auth", "KEK/KEK.esl", "db/db.esl", "db/db.der", "PCR/PCR.pem", "GUID"):
            ser.check(f"test -s /root/k2/keys/{f}")
        ser.check("test $(stat -c %a /root/k2/secrets) = 700 && test -s /root/k2/secrets/db.key")
        ser.check("sbverify --list /root/k2/keys/PK/PK.pem >/dev/null 2>&1 || openssl x509 -noout -in /root/k2/keys/PK/PK.pem")
        log("create: fresh hierarchy written (public + 0700 secrets)")

        rc, out = ser.run(f"{SBK} enroll --keys /root/k2/keys --esp /boot --dry-run 2>&1 | tail -4")
        rc = int(ser.value(f"{SBK} enroll --keys /root/k2/keys --esp /boot --dry-run >/dev/null 2>&1; echo $?"))
        if rc == 0 or "not signed by this db key" not in out:
            raise Fail(f"enroll accepted keys that don't sign the ESP (rc={rc}):\n{out}")
        log("guard: enroll refuses keys that don't sign the ESP binaries")

        rc = int(ser.value(f"EVENTLOG=/nonexistent {SBK} enroll --esp /boot --dry-run >/dev/null 2>&1; echo $?"))
        if rc == 0:
            raise Fail("enroll went ahead without a TPM event log (would drop the option ROM hashes)")
        log("guard: enroll stops when the TPM event log can't be read")

        out = ser.check(f"{SBK} enroll --esp /boot --dry-run 2>&1")
        log("dry run:\n" + out[-1500:])
        m = re.search(r"option ROMs measured by the firmware: (\d+)", out)
        if not m or int(m.group(1)) < 1:
            raise Fail("dry run found no option ROM (the virtio NIC's iPXE ROM should be in PCR 2)")
        if "UNSIGNED" in out:
            raise Fail("ESP has binaries not signed by the image's db key")
        roms = re.findall(r"sha256 ([0-9a-f]{64})", out)

        out = ser.check(f"{SBK} enroll --esp /boot 2>&1", 300)
        log("enroll:\n" + out[-1500:])
        if "Enrolled: PK, KEK, db" not in out:
            raise Fail("enroll did not finish")
        st = ser.check(f"{SBK} status --esp /boot")
        log("status after:\n" + st)
        for need in ("SetupMode=0", "PK: holds our cert", "KEK: holds our cert", "db: holds our cert"):
            if need not in st:
                raise Fail(f"status lacks {need!r}")
        ser.check("ls /root/secure-boot-backup-*/ >/dev/null")
        lab.poweroff()

        # ---- boot 2: firmware must now verify our signed chain ----
        ser = boot_recovery(lab, "enforced")
        out = ser.check("mokutil --sb-state 2>&1; bootctl status 2>/dev/null | grep -iE 'secure boot|setup mode'")
        log("after reboot:\n" + out)
        if "SecureBoot enabled" not in out:
            raise Fail("Secure Boot is not enabled after enrollment")
        st = ser.check(f"{SBK} status --esp /boot")
        if "SecureBoot=1 SetupMode=0" not in st:
            raise Fail(f"unexpected state:\n{st}")
        db = ser.value("od -An -v -tx1 /sys/firmware/efi/efivars/db-d719b2cb-3d3a-4596-a3bc-dad00e67656f | tr -d ' \\n'")
        missing = [h for h in roms if h not in db]
        if missing:
            raise Fail(f"option ROM hash(es) missing from db: {missing}")
        log(f"booted under enforced Secure Boot with our keys; db holds the cert + {len(roms)} option ROM hash(es)")
        lab.poweroff()
    finally:
        lab.kill()
    print("\n==== secure-boot-keys e2e: PASS ====")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=os.path.join(ROOT, "test/bootc/work"))
    a = ap.parse_args()
    try:
        return run(a.work)
    except Fail as e:
        log(f"FAIL: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
