#!/usr/bin/env python3
"""tokenvault e2e on the sealed-UKI secureblue image under KVM.

  * OVMF Secure Boot in custom mode with the DEV PK/KEK/db only
    (lab-secureboot.sh), SMM on: our signed systemd-boot + UKI must verify;
  * swtpm (TPM-CRB) measured by OVMF + systemd-stub, so PCR 7 and the
    signed PCR 11 policy are real;
  * virtual CTAP2 key (test/vfido) via USB passthrough;
  * disk from build-disk.sh (install.sh layout, composefs, systemd-boot).

The sealed cmdline has "quiet rhgb", so plymouth runs on every boot; the lab
addon adds a serial console, where plymouth also prompts and reads input.

  test/bootc/e2e.py [--work test/bootc/work] [scenario ...]
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
# gpt-auto names the root volume "root"
e2e.PASS_PROMPT = r"Please enter passphrase for disk [^\n]*\broot\b"
ROOT = e2e.ROOT
# The CLI is handed to the guest as a read-only raw tar disk (/dev/vdb),
# rebuilt from the project before every boot, so it can be iterated without
# rebuilding the sealed image (the hardened kernel has no 9p). The initrd
# side always comes from the image.
TV = "bash /root/tv/usr/bin/tokenvault"
CLI_FILES = ("usr/bin/tokenvault", "usr/libexec/tokenvault/askpass.py",
             "usr/libexec/tokenvault/fido2-pin.py", "usr/libexec/tokenvault/check-uki",
             "usr/lib/tmpfiles.d/tokenvault.conf",
             "usr/share/selinux/packages/tokenvault/tokenvault.cil")
_pushed = {}


def build_cli_disk(lab):
    import tarfile
    path = os.path.join(lab.work, "tokenvault-cli.tar")
    with tarfile.open(path, "w") as t:
        for rel in CLI_FILES:
            t.add(os.path.join(ROOT, "image/files-luks", rel), arcname=rel)
    size = os.path.getsize(path)
    with open(path, "ab") as f:            # whole 1 MiB for a sane block device
        f.write(b"\0" * ((-size) % (1 << 20)))
    return path


CLI_FROM_IMAGE = False


def push_cli(lab, ser):
    if CLI_FROM_IMAGE or _pushed.get(lab.boot_no):
        return
    ser.check("rm -rf /root/tv && mkdir /root/tv && tar -xf /dev/vdb -C /root/tv "
              "&& test -f /root/tv/usr/libexec/tokenvault/askpass.py")
    _pushed[lab.boot_no] = True


def tv(ser, args, timeout=600):
    push_cli(ser.lab, ser)
    return ser.check(f"{'tokenvault' if CLI_FROM_IMAGE else TV} {args}", timeout)



def configure(lab):
    orig_boot = lab.boot

    def boot(*a, **kw):
        if not CLI_FROM_IMAGE:
            cli = build_cli_disk(lab)
            lab.extra_qemu_tail = ["-drive", f"if=virtio,format=raw,readonly=on,file={cli}"]
        ser = orig_boot(*a, **kw)
        ser.lab = lab
        return ser
    lab.boot = boot
    lab.ovmf_code = "/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd"
    lab.vars_template = os.path.join(lab.work, "OVMF_VARS.sb.fd")
    lab.machine = "q35,accel=kvm,smm=on"
    lab.extra_qemu = ["-global", "driver=cfi.pflash01,property=secure,value=on", "-nic", "none"]


def sc_setup(lab):
    """Recovery boot under Secure Boot, then `tokenvault enroll` in the guest."""
    ser = lab.boot("setup")
    ser.expect(e2e.PASS_PROMPT, 240, fail_on=e2e.TPM_PROMPT)
    log(f"screenshot {lab.screenshot('recovery-prompt')}")
    ser.send(lab.env["LAB_RECOVERY"])
    lab.wait_shell(300)
    out = ser.check("mokutil --sb-state 2>/dev/null || bootctl status 2>/dev/null | grep -i 'secure boot'")
    if "enabled" not in out.lower():
        raise Fail(f"guest is not running under Secure Boot:\n{out}")
    out = ser.check("bootctl status 2>/dev/null | grep -iE 'measured uki|tpm2 support' ; "
                    "ls /run/systemd/tpm2-pcr-signature.json /.extra 2>&1 | head")
    log(out)
    if CLI_FROM_IMAGE:
        import hashlib
        for rel in CLI_FILES:
            want = hashlib.sha256(open(os.path.join(ROOT, "image/files-luks", rel), "rb").read()).hexdigest()
            got = ser.value(f"sha256sum /{rel} | cut -d' ' -f1")
            if got != want:
                raise Fail(f"/{rel} in the image differs from image/files-luks/{rel}")
        log("image ships the current tokenvault CLI (sha256 match)")
    conf = {
        "TPM2_PIN": e2e.TPM2_PIN, "FIDO2_PIN": e2e.FIDO2_PIN,
        "TARGET_PASSPHRASE": lab.env["LAB_RECOVERY"],
    }
    ser.check("install -d -m 700 /etc/tokenvault && install -m 600 "
              "/usr/share/tokenvault/tokenvault.conf.example /etc/tokenvault/tokenvault.conf")
    for k, v in conf.items():
        ser.check(f"sed -i '/^{k}=/d' /etc/tokenvault/tokenvault.conf && "
                  f"printf '%s\\n' '{k}=\"{v}\"' >> /etc/tokenvault/tokenvault.conf")
    vmark = lab.vfido_mark()
    out = tv(ser, "enroll 2>&1 | grep -v WARNING")
    log("enroll output:\n" + out[-2500:])
    if "enrolled: vault keyslot" not in out:
        raise Fail("enroll did not finish")
    ev = lab.vfido_events(vmark)
    # the PIN is set once, unless the (persistent) virtual key already has it
    pin_ok = e2e.vfido_count(ev, "pin=set") == 1 or (
        e2e.vfido_count(ev, "pin=set") == 0 and "key already has the configured PIN" in out)
    if not pin_ok or e2e.vfido_count(ev, "up=granted") < 2:
        raise Fail(f"unexpected key activity during enroll:\n{ev}")
    log("status:\n" + tv(ser, "status"))
    lab.poweroff()


def sc_happy(lab):
    """TPM2 PIN + FIDO2 PIN + one touch -> gpt-auto root opens from the cache."""
    vmark = lab.vfido_mark()
    ser = lab.boot("happy")
    mark = ser.mark()
    ser.expect(e2e.TPM_PROMPT, 240, fail_on=e2e.PASS_PROMPT)
    log(f"screenshot {lab.screenshot('tpm2-pin-prompt')}")
    ser.send(e2e.TPM2_PIN)
    ser.expect(e2e.FIDO_PROMPT, 120, fail_on=e2e.PASS_PROMPT)
    log(f"screenshot {lab.screenshot('fido2-pin-prompt')}")
    ser.send(e2e.FIDO2_PIN)
    lab.wait_shell(300)
    e2e.assert_clean_after_boot(ser, mark)
    n = e2e.touches(lab, vmark)
    if n != 1:
        raise Fail(f"expected exactly 1 touch during unlock, got {n}")
    n = ser.value("keyctl show @u 2>/dev/null | grep -c cryptsetup")
    if n != "0":
        raise Fail(f"vault passphrase still cached in root's user keyring after boot ({n})")
    lab.poweroff()


def sc_sealed(lab):
    """After a token boot the TPM2 layer must refuse to unseal from userspace
    (PCR 11 moved past the signed enter-initrd phase); units ran in order."""
    ser = lab.boot("sealed")
    e2e.unlock_with_tokens(lab, ser)
    lab.wait_shell(300)
    j = ser.check("journalctl -b -o short-monotonic --no-pager -u 'tokenvault-*' "
                  "-u systemd-cryptsetup@root.service -u systemd-pcrphase-initrd.service | tail -40")
    log("initrd journal:\n" + j)
    for need in ("tokenvault: unlock TPM2 layer", "tokenvault: unlock FIDO2 layer",
                 "tokenvault: hand the vault passphrase", "tokenvault: close vault"):
        if need not in j:
            raise Fail(f"journal lacks {need!r}")
    out = tv(ser, "verify 2>&1 | tail -8", 300)
    log("verify:\n" + out)
    if "refuses to unseal after boot" not in out or "tokenvault: OK" not in out:
        raise Fail("verify did not confirm the sealed TPM2 layer")
    lab.poweroff()


ROOT_DEV = "$(cryptsetup status root | awk '$1==\"device:\"{print $2}')"


def vault_tokens(ser):
    """Number of tokenvault keyslot records in the root volume's LUKS header."""
    return ser.value(f"cryptsetup luksDump {ROOT_DEV} | grep -cE '^  [0-9]+: tokenvault$'")


def sc_remove(lab):
    """remove: vault keyslot killed, vault deleted -> plain passphrase boot."""
    ser = lab.boot("remove")
    e2e.unlock_with_tokens(lab, ser)
    lab.wait_shell(300)
    # The keyslot record must come from the LUKS header alone.
    ser.check("rm -f /etc/tokenvault/state")
    tv(ser, "remove 2>&1 | tail -3", 300)
    n = ser.value(f"cryptsetup luksDump {ROOT_DEV} | grep -cE '^  [0-9]+: luks2'")
    if n != "1":
        raise Fail(f"expected only the recovery keyslot left, found {n}")
    if vault_tokens(ser) != "0":
        raise Fail("a tokenvault record is still in the LUKS header after remove")
    lab.poweroff()
    ser = lab.boot("after-remove")
    ser.expect(e2e.PASS_PROMPT, 240, fail_on=e2e.TPM_PROMPT)
    ser.send(lab.env["LAB_RECOVERY"])
    lab.wait_shell(300)
    lab.poweroff()


def sc_rotate(lab):
    """Re-enroll in the guest; the old keyslot is retired; tokens still boot."""
    ser = lab.boot("rotate")
    e2e.unlock_with_tokens(lab, ser)
    lab.wait_shell(300)
    out = tv(ser, "enroll 2>&1 | grep -E 'keyslot|error'")
    log(out)
    if "killing previous vault keyslot" not in out:
        raise Fail("rotation did not retire the previous keyslot")
    if vault_tokens(ser) != "1":
        raise Fail("expected exactly one tokenvault record in the LUKS header after rotation")
    lab.poweroff()
    sc_happy(lab)


def unlock_any(lab, ser):
    """Tokens if enrolled, else the recovery passphrase."""
    m = ser.expect(f"({e2e.TPM_PROMPT}|{e2e.PASS_PROMPT})", 240)
    if m.group(0).startswith("Please enter TPM2"):
        ser.send(e2e.TPM2_PIN)
        ser.expect(e2e.FIDO_PROMPT, 120, fail_on=e2e.PASS_PROMPT)
        ser.send(e2e.FIDO2_PIN)
    else:
        ser.send(lab.env["LAB_RECOVERY"])
    lab.wait_shell(300)


def sc_selinux(lab):
    """tokenvault_conf_t: with the old etc_t label a confined daemon domain
    (NetworkManager_t) can read the PIN file; after tmpfiles relabels it, the
    same domain is denied while it can still read etc_t, and the unconfined
    admin CLI keeps working and repairs stray labels itself."""
    ser = lab.boot("selinux")
    unlock_any(lab, ser)
    if ser.value("getenforce") != "Enforcing":
        raise Fail("guest SELinux is not enforcing")
    if CLI_FROM_IMAGE:
        if ser.value("semodule -l | grep -cx tokenvault") != "1":
            raise Fail("image lacks the tokenvault SELinux module")
        tmpfiles, cli = "/usr/lib/tmpfiles.d/tokenvault.conf", "tokenvault"
    else:
        push_cli(lab, ser)
        ser.check("semodule -i /root/tv/usr/share/selinux/packages/tokenvault/tokenvault.cil", 600)
        tmpfiles, cli = "/root/tv/usr/lib/tmpfiles.d/tokenvault.conf", TV
    conf = "/etc/tokenvault/tokenvault.conf"
    ctx = lambda p: ser.value(f"stat -c %C {p} | cut -d: -f3")  # noqa: E731
    # A confined daemon domain, entered for real: init_t -> NetworkManager_t
    # through NetworkManager's entrypoint type on a copy of cat.
    ser.check("cp /usr/bin/cat /root/nmcat && chcon -t NetworkManager_exec_t /root/nmcat")
    nmcat = "systemd-run --wait --collect --pipe -q /root/nmcat"
    ser.check(f"test -f {conf} && chcon -R -t etc_t /etc/tokenvault")      # pre-module state
    if ser.value(f"{nmcat} {conf} >/dev/null 2>&1 && echo readable || echo denied") != "readable":
        raise Fail("baseline: NetworkManager_t could not read the etc_t-labelled PIN file")
    log("baseline: with etc_t, NetworkManager_t CAN read the PIN file")
    ser.check(f"systemd-run --wait --collect -q /usr/bin/systemd-tmpfiles --create {tmpfiles}")
    for p in ("/etc/tokenvault", conf):
        if ctx(p) != "tokenvault_conf_t":
            raise Fail(f"{p} is {ctx(p)} after systemd-tmpfiles, not tokenvault_conf_t")
    if ser.value("stat -c %a /etc/tokenvault") != "700":
        raise Fail("/etc/tokenvault is not 0700")
    # control: same owner/mode as the PIN file, plain etc_t
    ser.check("printf probe > /etc/tokenvault-probe && chmod 600 /etc/tokenvault-probe "
              "&& chcon -t etc_t /etc/tokenvault-probe")
    if ser.value(f"{nmcat} /etc/tokenvault-probe >/dev/null 2>&1 && echo readable || echo denied") != "readable":
        raise Fail("NetworkManager_t cannot read an etc_t 0600 file (test domain broken)")
    ser.check("rm -f /etc/tokenvault-probe")
    if ser.value(f"{nmcat} {conf} >/dev/null 2>&1 && echo readable || echo denied") != "denied":
        raise Fail("NetworkManager_t can still read the PIN file")
    avc = ser.value("{ ausearch -m AVC -ts boot 2>/dev/null; journalctl -k -b --no-pager -o cat; } "
                    "| grep -c 'denied.*tokenvault_conf_t'")
    log(f"with tokenvault_conf_t: NetworkManager_t denied ({avc} AVC record(s)); an etc_t 0600 control file stays readable")
    ser.check(f"chcon -t etc_t {conf}")
    out = ser.check(f"{cli} status 2>&1 | head -4")
    if "relabelled" not in out or ctx(conf) != "tokenvault_conf_t":
        raise Fail(f"CLI did not repair the stray label:\n{out}")
    ser.check("rm -f /root/nmcat")
    lab.poweroff()


SCENARIOS = [
    ("setup", sc_setup), ("happy", sc_happy), ("sealed", sc_sealed), ("selinux", sc_selinux),
    ("wrong-tpm-pin", e2e.sc_wrong_tpm_pin), ("wrong-fido-pin", e2e.sc_wrong_fido_pin),
    ("no-touch", e2e.sc_no_touch), ("no-key", e2e.sc_no_key),
    ("foreign-tpm", e2e.sc_foreign_tpm), ("rotate", sc_rotate), ("remove", sc_remove),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=os.path.join(ROOT, "test/bootc/work"))
    ap.add_argument("--cli-from-image", action="store_true",
                    help="use the tokenvault shipped in the image (no lab CLI disk)")
    ap.add_argument("scenarios", nargs="*", default=["all"])
    a = ap.parse_args()
    global CLI_FROM_IMAGE
    CLI_FROM_IMAGE = a.cli_from_image
    names = [n for n, _ in SCENARIOS] if a.scenarios == ["all"] else a.scenarios
    lab = e2e.Lab(a.work)
    configure(lab)
    lab.fido_up()
    results = []
    try:
        for name in names:
            fn = dict(SCENARIOS)[name]
            t0 = time.time()
            try:
                fn(lab)
                results.append((name, "PASS", time.time() - t0))
                log(f"PASS {name}")
            except Fail as e:
                results.append((name, "FAIL", time.time() - t0))
                log(f"FAIL {name}: {e}")
                break
    finally:
        lab.kill()
        lab.fido_down()
    print("\n==== tokenvault sealed-UKI e2e results ====")
    for n, r, t in results:
        print(f"  {r}  {n:16s} {t:6.0f}s")
    ok = len(results) == len(names) and all(r == "PASS" for _, r, _ in results)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
