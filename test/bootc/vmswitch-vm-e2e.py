#!/usr/bin/env python3
"""vmswitch e2e on the sealed-UKI image under KVM: usbguard, nested guests, uplink.

Everything happens inside the lab VM; the host's USB, network and usbguard are never
touched. The lab VM gets a restricted slirp NIC (no way out of QEMU) as its "WAN".

  1. Boot with the vfido gadget down. usbguard-firstboot wrote a policy before
     usbguard started, and it doesn't list the key. Then the gadget comes up: usbguard
     blocks the key. ip_forward is off.
  2. setup-guests.sh (from a tar disk): an initrd from the lab VM's own binaries and
     modules, guests ga + gb on network "shared", gc on uplink (libvirt, direct
     kernel boot, the vmswitch <interface>). ga and gb ping each other. gc's ping to
     an internet address leaves the WAN masqueraded; gc reaches neither ga's network
     nor the host (10.88.0.1). ip_forward is on.
  3. vmswitch usb attach gb <key>: usbguard allows it, gb sees 1209:7f1d. detach: gb
     loses it, usbguard blocks it again.
  4. Reboot: vmswitch.service rebuilt the TAPs and the table, usbguard's policy is
     the first boot's, ip_forward is on. No AVC for qemu, vmswitch or usbguard.

  sudo test/bootc/lab-secureboot.sh <work> <dev keys> <dev db.key>
  sudo test/bootc/build-disk.sh <work> <dev image>
  test/bootc/vmswitch-vm-e2e.py --work <work>
"""
import argparse
import fcntl
import os
import re
import sys
import tarfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "test"))
import e2e  # noqa: E402
from e2e import Fail, log  # noqa: E402

e2e.SHELL_PROMPT = r"(-bash-[0-9.]+# |root@tokenvault-lab# )"
e2e.PASS_PROMPT = r"Please enter passphrase for disk [^\n]*\broot\b"
KEY = "1209:7f1d"
SER = "/var/log/libvirt/qemu/{}.serial"


def configure(lab):
    lab.ovmf_code = "/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd"
    lab.vars_template = os.path.join(lab.work, "OVMF_VARS.sb.fd")
    lab.machine = "q35,accel=kvm,smm=on"
    lab.extra_qemu = ["-global", "driver=cfi.pflash01,property=secure,value=on",
                      "-nic", "user,restrict=on,model=virtio-net-pci"]
    tar = os.path.join(lab.work, "vmswitch-test.tar")
    with tarfile.open(tar, "w") as t:
        t.add(os.path.join(ROOT, "vmswitch/test/vm"), arcname=".")
    lab.extra_qemu_tail = ["-drive", f"if=virtio,format=raw,readonly=on,file={tar}"]


def recovery_boot(lab, ser):
    ser.expect(e2e.PASS_PROMPT, 300)
    ser.send(lab.env["LAB_RECOVERY"])
    lab.wait_shell(300)


def wait_for(ser, cmd, pred, timeout, every=2):
    end = time.time() + timeout
    got = None
    while time.time() < end:
        got = ser.value(cmd)
        if pred(got):
            return got
        time.sleep(every)
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    a = ap.parse_args()
    # The vfido gadget is one per host: wait for other users of it (e2e runs, a play VM).
    lock = open("/var/tmp/vfido-gadget.lock", "a")
    log("waiting for the vfido gadget lock")
    fcntl.flock(lock, fcntl.LOCK_EX)
    lab = e2e.Lab(a.work)
    configure(lab)
    results = []

    def step(name, ok, detail=""):
        results.append((name, ok))
        log(f"{'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}")

    try:
        lab.fido_down()
        # ---- boot 1
        ser = lab.boot("vmswitch-1", fido=True, no_reboot=False)
        recovery_boot(lab, ser)
        step("SELinux enforcing", ser.value("getenforce") == "Enforcing")
        step("usbguard active", ser.value("systemctl is-active usbguard") == "active")
        step("usbguard-firstboot wrote a policy",
             ser.value("systemctl show -p Result --value usbguard-firstboot") == "success"
             and ser.value("test -s /etc/usbguard/rules.conf && echo y") == "y",
             ser.value("wc -l < /etc/usbguard/rules.conf"))
        step("the key isn't in the first-boot policy", ser.value(f"grep -c 'id {KEY}' /etc/usbguard/rules.conf || true") == "0")
        policy = ser.value("sha256sum /etc/usbguard/rules.conf | cut -c1-64")
        lab.fido_up()
        got = wait_for(ser, f"usbguard list-devices | grep 'id {KEY}' | awk '{{print $2}}'", lambda v: v != "", 30)
        step("usbguard blocks the key plugged in later", got == "block", got)
        step("ip_forward off before any uplink", ser.value("cat /proc/sys/net/ipv4/ip_forward") == "0")
        # The WAN: QEMU's restricted slirp NIC, set up by hand (slirp's fixed
        # 10.0.2.15/24 via 10.0.2.2), so the test doesn't depend on NetworkManager.
        wan = ser.value("for n in /sys/class/net/*; do n=${n##*/}; case $n in lo|vs*) ;; *) echo $n; break;; esac; done")
        ser.check(f"nmcli device set {wan} managed no 2>/dev/null; ip link set {wan} up; "
                  f"ip -4 addr flush dev {wan}; ip addr add 10.0.2.15/24 dev {wan}; "
                  f"ip route replace default via 10.0.2.2 dev {wan}")
        wanip = "10.0.2.15"
        step("WAN up (slirp, restricted)", ser.value("ip -4 route show default | awk '{print $5}'") == wan, wan)
        # Lab counters on the WAN's egress (no heredoc: the harness appends to each line).
        ser.check(f"nft add table netdev labwan && nft add chain netdev labwan out "
                  f"'{{ type filter hook egress device \"{wan}\" priority filter; policy accept; }}' && "
                  f"nft add rule netdev labwan out ip saddr {wanip} ip daddr 198.51.100.7 icmp type echo-request counter && "
                  "nft add rule netdev labwan out ip saddr 10.88.0.0/16 counter")

        # ---- nested guests
        ser.check("rm -rf /root/vsw && mkdir /root/vsw && tar -xf /dev/vdb -C /root/vsw")
        out = ser.check("/root/vsw/setup-guests.sh /root/vsw 2>&1 | tail -5", 600)
        step("guests defined", "setup-guests: ok" in out, out.strip()[-300:])
        step("ip_forward on with a NIC on uplink", ser.value("cat /proc/sys/net/ipv4/ip_forward") == "1")
        for g in ("ga", "gb", "gc"):
            out = ser.check(f"virsh -q -c qemu:///system start {g} 2>&1 || journalctl -b -u virtqemud --no-pager | tail -5")
            step(f"{g} starts", "error" not in out.lower(), out.strip()[-300:])
        for g, peer in (("ga", "192.168.77.2"), ("gb", "192.168.77.1")):
            got = wait_for(ser, f"grep -c 'VSW-PING-OK {peer}' {SER.format(g)} || true", lambda v: v not in ("", "0"), 120)
            step(f"{g} reaches its peer on shared", got not in ("", "0"))
        wait_for(ser, f"grep -c VSW-PINGS-DONE {SER.format('gc')} || true", lambda v: v not in ("", "0"), 120)
        gc = ser.check(f"grep -a VSW- {SER.format('gc')} | grep -v VSW-USB")
        log(gc.strip())
        counters = ser.check("nft list chain netdev labwan out")
        masq = re.search(r"198\.51\.100\.7 icmp type echo-request counter packets (\d+)", counters)
        raw = re.search(r"10\.88\.0\.0/16 counter packets (\d+)", counters)
        step("gc's internet ping leaves the WAN masqueraded",
             bool(masq and int(masq.group(1)) > 0 and raw and int(raw.group(1)) == 0), counters.strip())
        step("gc can't reach the shared network", "VSW-PING-OK 192.168.77.1" not in gc)
        step("gc can't reach the host", "VSW-PING-OK 10.88.0.1" not in gc)

        # ---- USB
        dev = ser.value(f"vmswitch usb list | awk -F'\\t' '$3==\"{KEY}\"{{print $1}}'")
        out = ser.check(f"vmswitch usb attach gb {dev} 2>&1")
        step("usb attach", ser.value(f"usbguard list-devices | grep 'id {KEY}' | awk '{{print $2}}'") == "allow", out.strip())
        got = wait_for(ser, f"tail -1 {SER.format('gb')}", lambda v: "1209" in v and "7f1d" in v, 30)
        step("gb sees the key", "1209" in got and "7f1d" in got, got)
        step("ga doesn't", "1209" not in ser.value(f"tail -1 {SER.format('ga')}"))
        out = ser.check(f"vmswitch usb detach gb {dev} 2>&1")
        got = wait_for(ser, f"tail -1 {SER.format('gb')}", lambda v: v.startswith("VSW-USB") and "1209" not in v, 30)
        step("usb detach: gb loses the key", "1209" not in got, got)
        step("usb detach: usbguard blocks it again",
             ser.value(f"usbguard list-devices | grep 'id {KEY}' | awk '{{print $2}}'") == "block", out.strip())
        log(ser.check("vmtui --dump"))

        # ---- reboot
        ser.send("systemctl reboot")
        ser.expect(r"reboot: Restarting system", 180)
        recovery_boot(lab, ser)
        step("vmswitch.service at boot", ser.value("systemctl is-active vmswitch") == "active")
        step("TAPs back", ser.value("ls /sys/class/net | grep -c '^vs' || true") == "3")
        step("table back", ser.value("nft list table netdev vmswitch | grep -c 'hook ingress'") == "3")
        step("ip_forward on after boot (uplink)", ser.value("cat /proc/sys/net/ipv4/ip_forward") == "1")
        step("usbguard keeps the first boot's policy",
             ser.value("sha256sum /etc/usbguard/rules.conf | cut -c1-64") == policy
             and ser.value("systemctl show -p ExecMainStartTimestampMonotonic --value usbguard-firstboot") in ("0", ""))
        # By domain or command (not a bare "tun": that matches tuned's own denials).
        avc = ser.check("ausearch -m AVC -ts yesterday 2>/dev/null | grep -E "
                        "'scontext=[^ ]*:(svirt|virtqemud|usbguard)_t|comm=\"(vmswitch|nft|qemu[^\"]*|usbguard[^\"]*)\"' "
                        "|| true")
        # Denials in a permissive domain (Fedora ships virtqemud_t permissive) are logged,
        # not counted: nothing was refused.
        log("AVC (permissive domains): " + "\n".join(l for l in avc.splitlines() if "permissive=1" in l)[-1500:])
        enforced = "\n".join(l for l in avc.splitlines() if "permissive=0" in l)
        step("no AVC for qemu, vmswitch, usbguard", enforced == "", enforced[-1500:])
        lab.poweroff()
    except Fail as e:
        log(f"FAIL: {e}")
        results.append(("(aborted) " + str(e).splitlines()[0][:100], False))
    finally:
        lab.kill()
        lab.fido_down()
    print("\n==== vmswitch VM e2e results ====")
    for n, ok in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {n}")
    return 0 if results and all(ok for _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())
