#!/usr/bin/env python3
"""Installer payload e2e under KVM: build-iso.sh --payload's USB image, booted as a USB
stick, stages the llm payload into a target /var (llm/README.md, step 4).

  1. The live system (Fedora CoreOS, from the image) finds the SCROLL-PAYLOAD partition
     and has install-payload.sh; install.sh calls it.
  2. A target too small for the payload plus 8 GiB: install-payload.sh refuses, copies
     nothing.
  3. A target large enough: exactly SHA256SUMS' files, sha256s intact, 0700, var_lib_t.
  4. The same image without the partition (the plain ISO's layout): a no-op, rc 0.

The other half, llm-firstboot.service importing the staged payload on the installed
system, is in llm-vm-e2e.py. A whole install.sh run (registry pull, cosign, LUKS) isn't
covered here.

A copy of the image gets console=ttyS0 (a lab aid; the built image is unchanged). Stock
OVMF, no TPM.

  llm/payload.sh small.gguf <dir>
  image/iso/build-iso.sh --payload <dir> localhost/x:uki <out>
  test/bootc/installer-payload-e2e.py --work <w> --img <out>/scroll-secure-installer-*-payload.img
"""
import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "test"))
import e2e  # noqa: E402
from e2e import Fail, log  # noqa: E402

OVMF_CODE = "/usr/share/edk2/x64/OVMF_CODE.4m.fd"
OVMF_VARS = "/usr/share/edk2/x64/OVMF_VARS.4m.fd"
INSTALLER = "quay.io/coreos/coreos-installer:release"
PROMPT = r"root@payload-lab# "
VAR = "/mnt/state/os/default/var"


def lab_copy(img, work):
    """The image plus console=ttyS0, and a copy without partition 3."""
    usb = os.path.join(work, "usb.img")
    subprocess.run(["cp", "--reflink=auto", img, usb], check=True)
    subprocess.run(["podman", "run", "--rm", "-v", f"{work}:/data:Z", "-w", "/data", INSTALLER,
                    "iso", "kargs", "modify", "-a", "console=ttyS0,115200n8", "usb.img"],
                   check=True, capture_output=True)
    bare = os.path.join(work, "usb-bare.img")
    subprocess.run(["cp", "--reflink=auto", usb, bare], check=True)
    subprocess.run(["sfdisk", "-q", "--delete", bare, "3"], check=True)
    return usb, bare


def boot(work, usb, name, disks):
    vars_ = os.path.join(work, "OVMF_VARS.fd")
    shutil.copy(OVMF_VARS, vars_)
    ser_path = os.path.join(work, "serial.sock")
    if os.path.exists(ser_path):
        os.unlink(ser_path)
    cmd = ["qemu-system-x86_64", "-name", "payload-e2e", "-machine", "q35,accel=kvm",
           "-cpu", "host", "-smp", "4", "-m", "4096", "-no-reboot",
           "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
           "-drive", f"if=pflash,format=raw,file={vars_}",
           "-device", "qemu-xhci,id=xhci",
           "-drive", f"if=none,id=usb,format=raw,snapshot=on,file={usb}",
           "-device", "usb-storage,bus=xhci.0,drive=usb,removable=on,bootindex=0",
           "-display", "none", "-serial", f"unix:{ser_path},server=on,wait=off"]
    for d in disks:
        cmd += ["-drive", f"if=virtio,format=raw,file={d}"]
    art = os.path.join(work, "artifacts")
    os.makedirs(art, exist_ok=True)
    log(f"boot [{name}]")
    q = subprocess.Popen(cmd, stdout=open(os.path.join(art, "qemu.log"), "a"), stderr=subprocess.STDOUT)
    ser = e2e.Serial(ser_path, os.path.join(art, f"serial-{name}.log"))
    # Ignition's autologin for core (passwordless sudo on the live system, in RAM).
    ser.expect(r"core@localhost\S*\$ ", 600)
    ser.send("sudo -i")
    ser.expect(r"root@localhost\S*# ", 30)
    ser.send(f"stty cols 250; export SYSTEMD_PAGER= SYSTEMD_COLORS=0 TERM=dumb; PS1='{PROMPT}'")
    ser.expect(PROMPT, 10)
    return q, ser


def target(ser, dev):
    """install.sh's layout, enough for install-payload.sh: btrfs, the deployment's /var."""
    ser.check(f"umount /mnt 2>/dev/null; mkfs.btrfs -q -f {dev} && mount {dev} /mnt && mkdir -p {VAR}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--img", required=True)
    a = ap.parse_args()
    work = os.path.abspath(a.work)
    os.makedirs(work, exist_ok=True)
    usb, bare = lab_copy(os.path.abspath(a.img), work)
    small, large = os.path.join(work, "small.raw"), os.path.join(work, "large.raw")
    for p, size in ((small, 6 << 30), (large, 24 << 30)):
        with open(p, "wb") as f:
            f.truncate(size)
    results = []

    def step(name, ok, detail=""):
        results.append((name, ok))
        log(f"{'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}")

    q = None
    try:
        q, ser = boot(work, usb, "payload", [small, large])
        # ---- 1. the live system
        dev = ser.value("blkid -L SCROLL-PAYLOAD")
        step("live system sees SCROLL-PAYLOAD", dev.startswith("/dev/sd"), dev)
        step("install-payload.sh in the live system",
             ser.value("test -x /var/lib/scroll-secure/install-payload.sh && echo y") == "y")
        step("install.sh calls it",
             ser.value("grep -c 'install-payload.sh \"${var_dir}\"' /var/lib/scroll-secure/uki/install.sh") == "1")
        part = dev.rsplit("/", 1)[1]
        sums = ser.value(f"mount -o ro,loop,offset=$(( $(cat /sys/class/block/{part}/start) * 512 )) /dev/$(lsblk -dno PKNAME {dev}) /media"
                         " && sort /media/SHA256SUMS | md5sum | cut -c1-32; umount /media")
        step("payload readable", len(sums) == 32, sums)
        # ---- 2. too small
        target(ser, "/dev/vda")
        rc, out = ser.run(f"/var/lib/scroll-secure/install-payload.sh {VAR}")
        step("small target refused", rc != 0 and "8 GiB to spare" in out, out.strip()[-160:])
        step("small target: nothing copied",
             ser.value(f"find {VAR} -type f | wc -l") == "0")
        # ---- 3. large enough
        target(ser, "/dev/vdb")
        rc, out = ser.run(f"/var/lib/scroll-secure/install-payload.sh {VAR}", 900)
        step("large target staged", rc == 0, out.strip()[-160:])
        p = f"{VAR}/lib/llm/payload"
        step("SHA256SUMS' files intact",
             ser.value(f"cd {p} && sha256sum --quiet -c SHA256SUMS && sort SHA256SUMS | md5sum | cut -c1-32") == sums)
        step("only the listed files",
             ser.value(f"ls {p} | wc -l") == ser.value(f"echo $(( $(wc -l < {p}/SHA256SUMS) + 1 ))"))
        step("0700 root, var_lib_t",
             ser.value(f"stat -c '%a %U %C' {VAR}/lib/llm {p} | sort -u")
             == "700 root system_u:object_r:var_lib_t:s0")
        q.terminate()
        q.wait(30)
        # ---- 4. no payload partition
        q, ser = boot(work, bare, "bare", [small])
        target(ser, "/dev/vda")
        rc, out = ser.run(f"/var/lib/scroll-secure/install-payload.sh {VAR}")
        step("no partition: no-op, rc 0", rc == 0 and ser.value(f"ls -A {VAR} | wc -l") == "0", out.strip()[-120:])
    except Fail as e:
        log(f"FAIL: {e}")
        results.append(("run", False))
    finally:
        if q and q.poll() is None:
            q.terminate()
            q.wait(30)
        for p in (small, large, usb, bare):
            if os.path.exists(p):
                os.unlink(p)
    print("==== installer payload e2e results ====")
    for name, ok in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}")
    sys.exit(0 if results and all(ok for _, ok in results) else 1)


if __name__ == "__main__":
    main()
