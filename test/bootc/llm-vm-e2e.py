#!/usr/bin/env python3
"""llm e2e on the sealed-UKI image under KVM: the host side of llm/README.md.

The lab VM has no GPU, so the server runs on the CPU (llm.conf DEVICE=none) with a
small model; everything else is the real thing: sysusers, tmpfiles, the units,
rootful podman without a user namespace (secureblue denies containers one), SELinux
enforcing.

  1. Before import: the llm user and /var/lib/llm exist, llm.service and
     llm-proxy.socket stay off (no model).
  2. llm import from a payload filesystem (/dev/vdb, label SCROLL-PAYLOAD:
     SHA256SUMS, llm-server.oci.tar, the model): checks, loads, starts. The server
     process runs as llm, no capabilities, no_new_privs, the host's user namespace,
     a network namespace with only lo, container_t.
  3. The guests' endpoint 10.89.255.1:8080 on vmswitch's llm network (a NIC plugged
     into llm; tapprobe.py as the guest end of its TAP): a SYN from the guest side
     gets a SYN-ACK; /health, the API key (none/wrong 401), /slots off, a completion;
     socket-proxyd runs as a dynamic user in systemd_socket_proxyd_t.
  4. llmctl over vsock loopback (CID 1): status, use, a CID not allowed gets nothing.
  5. llm key rotate: the old key stops working, the new one works.
  6. Reboot: the server comes back by itself. No AVC for the container, podman,
     conmon, crun or the proxy.

  sudo test/bootc/lab-secureboot.sh <work> <dev keys> <dev db.key>
  sudo test/bootc/build-disk.sh <work> <dev image>
  llm/build.sh                                    # llm/out/llm-server.oci.tar
  test/bootc/llm-vm-e2e.py --work <work> [--model small.gguf]
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "test"))
import e2e  # noqa: E402
from e2e import Fail, log  # noqa: E402

e2e.SHELL_PROMPT = r"(-bash-[0-9.]+# |root@tokenvault-lab# )"
e2e.PASS_PROMPT = r"Please enter passphrase for disk [^\n]*\broot\b"
MODEL = "/srv/models/qwen2.5-coder-1.5b/qwen2.5-coder-1.5b-q8_0.gguf"
ARCHIVE = os.path.join(ROOT, "llm/out/llm-server.oci.tar")
ADDR = "10.89.255.1:8080"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while b := f.read(1 << 22):
            h.update(b)
    return h.hexdigest()


def payload(work, model):
    """An ext4 image like the installer's SCROLL-PAYLOAD partition (step 4), plus the
    guest llmctl client for this test (not in SHA256SUMS, so llm import ignores it)."""
    d = os.path.join(work, "llm-payload")
    img = os.path.join(work, "llm-payload.img")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    names = {"llm-server.oci.tar": ARCHIVE, os.path.basename(model): model}
    for name, src in names.items():
        try:
            os.link(src, os.path.join(d, name))
        except OSError:
            shutil.copyfile(src, os.path.join(d, name))
    with open(os.path.join(d, "SHA256SUMS"), "w") as f:
        for name, src in names.items():
            f.write(f"{sha256(src)}  {name}\n")
    shutil.copy(os.path.join(ROOT, "vmgui/guest/linux/common/usr/bin/llmctl"), os.path.join(d, "llmctl"))
    shutil.copy(os.path.join(ROOT, "vmswitch/test/tapprobe.py"), os.path.join(d, "tapprobe.py"))
    size = sum(os.path.getsize(os.path.join(d, n)) for n in os.listdir(d)) * 11 // 10 + (64 << 20)
    if os.path.exists(img):
        os.unlink(img)
    subprocess.run(["mkfs.ext4", "-q", "-F", "-L", "SCROLL-PAYLOAD", "-d", d, img, str(size // 1024) + "k"], check=True)
    shutil.rmtree(d)
    return img, sha256(model)


def configure(lab, img):
    lab.ovmf_code = "/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd"
    lab.vars_template = os.path.join(lab.work, "OVMF_VARS.sb.fd")
    lab.machine = "q35,accel=kvm,smm=on"
    lab.extra_qemu = ["-global", "driver=cfi.pflash01,property=secure,value=on"]
    # The model runs on the CPU here: more memory than the harness default (last -m wins).
    lab.extra_qemu_tail = ["-m", "8192", "-drive", f"if=virtio,format=raw,readonly=on,file={img}"]


def recovery_boot(lab, ser):
    ser.expect(e2e.PASS_PROMPT, 300)
    ser.send(lab.env["LAB_RECOVERY"])
    lab.wait_shell(300)


def wait_for(ser, cmd, pred, timeout, every=3):
    end = time.time() + timeout
    got = None
    while time.time() < end:
        got = ser.value(cmd)
        if pred(got):
            return got
        time.sleep(every)
    return got


def code(ser, url, key=None, sock=False):
    h = f"-H 'Authorization: Bearer {key}' " if key else ""
    s = "--unix-socket /run/llm/llm.sock " if sock else ""
    return ser.value(f"curl -s -m 10 -o /dev/null -w '%{{http_code}}' {s}{h}{url}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--model", default=MODEL)
    a = ap.parse_args()
    if not os.path.exists(ARCHIVE):
        sys.exit(f"no {ARCHIVE}: run llm/build.sh")
    lab = e2e.Lab(a.work)
    log("building the payload filesystem")
    img, msha = payload(a.work, a.model)
    configure(lab, img)
    results = []

    def step(name, ok, detail=""):
        results.append((name, ok))
        log(f"{'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}")

    try:
        ser = lab.boot("llm-1", fido=False, no_reboot=False)
        recovery_boot(lab, ser)
        step("SELinux enforcing", ser.value("getenforce") == "Enforcing")
        # ---- 1. before import
        step("llm user (sysusers)", ser.value("id -un llm 2>&1") == "llm")
        step("/var/lib/llm root:llm 0750, /run/llm llm:llm 0750",
             ser.value("stat -c '%U:%G %a' /var/lib/llm /var/lib/llm/models /run/llm | tr '\\n' ' '")
             == "root:llm 750 root:llm 750 llm:llm 750")
        step("off without a model",
             ser.value("systemctl is-active llm.service llm-proxy.socket llmctl.service | tr '\\n' ' '")
             == "inactive inactive inactive")

        # ---- 2. import
        ser.check("mkdir -p /mnt/payload && mount -o ro,noload LABEL=SCROLL-PAYLOAD /mnt/payload")
        # The lab VM has no GPU: run on the CPU.
        ser.check("mkdir -p /etc/llm && printf 'DEVICE=none\\nCTX=4096\\nSLOTS=2\\n' > /etc/llm/llm.conf")
        out = ser.check("llm import /mnt/payload 2>&1; echo rc=$?", 1200)
        step("llm import", "rc=0" in out, out.strip()[-400:])
        got = wait_for(ser, "curl -s -m 5 -o /dev/null -w '%{http_code}' --unix-socket /run/llm/llm.sock http://x/health",
                       lambda v: v == "200", 600)
        step("server up on /run/llm/llm.sock", got == "200",
             got + " " + ser.check("journalctl -b -u llm --no-pager | tail -8"))
        step("model selected", ser.value("readlink /var/lib/llm/current") == f"models/{msha}.gguf")
        step("model file root:llm 0640", ser.value(f"stat -c '%U:%G %a' /var/lib/llm/models/{msha}.gguf") == "root:llm 640")
        pid = ser.value("podman inspect llm --format '{{.State.Pid}}'")
        step("server process runs as llm", ser.value(f"stat -c %U /proc/{pid}") == "llm", pid)
        step("no capabilities, no_new_privs",
             ser.value(f"grep -E '^(CapEff|CapBnd|NoNewPrivs)' /proc/{pid}/status | awk '{{print $2}}' | tr '\\n' ' '")
             == "0000000000000000 0000000000000000 1")
        step("host user namespace (none created)",
             ser.value(f"cat /proc/{pid}/uid_map | tr -s ' ' | sed 's/^ //'") == "0 0 4294967295")
        step("own network namespace with lo only",
             ser.value(f"[ $(readlink /proc/{pid}/ns/net) != $(readlink /proc/1/ns/net) ] && nsenter -t {pid} -n ip -o link | awk '{{print $2}}'")
             == "lo:")
        step("container_t", ":container_t:" in ser.value(f"ps -o label= -p {pid}"), ser.value(f"ps -o label= -p {pid}"))
        step("read-only root", ser.value("podman inspect llm --format '{{.HostConfig.ReadonlyRootfs}}'") == "true")

        # ---- 3. the guests' endpoint
        ser.check("vmswitch nic add probe eth0 && vmswitch plug probe eth0 llm")
        step("vmswitch llm: llm0 holds 10.89.255.1",
             ser.value("ip -4 -o addr show dev llm0 | awk '{print $4}'") == "10.89.255.1/32")
        tap, mac = ser.value("vmswitch show | python3 -I -c 'import json,sys; n = json.load(sys.stdin)[\"nics\"][\"probe/eth0\"]; print(n[\"tap\"], n[\"mac\"])'").split()
        out = ser.check(f"python3 -I /mnt/payload/tapprobe.py tcp {tap} {mac} $(cat /sys/class/net/{tap}/address) "
                        f"10.89.0.2 10.89.255.1 8080 3; echo rc=$?")
        step("SYN-ACK from the guest side of an llm NIC", "rc=0" in out, out.strip()[-200:])
        # The NIC's host end (any port) and other ports of the server's address stay closed:
        # vmswitch's hooks and firewalld's vmswitch-llm zone.
        closed = []
        for dst, port in (("10.89.0.1", 8080), ("10.89.0.1", 22), ("10.89.255.1", 22)):
            r = ser.check(f"python3 -I /mnt/payload/tapprobe.py tcp {tap} {mac} $(cat /sys/class/net/{tap}/address) "
                          f"10.89.0.2 {dst} {port} 2 > /dev/null; echo rc=$?")
            closed.append("rc=1" in r)
        step("guest side: host end and other ports closed", all(closed), str(closed))
        step("endpoint /health", code(ser, f"http://{ADDR}/health") == "200")
        step("no key: 401", code(ser, f"http://{ADDR}/v1/models") == "401")
        step("wrong key: 401", code(ser, f"http://{ADDR}/v1/models", "wrong") == "401")
        key = ser.value("llm key show")
        step("API key from llm key show", key.startswith("llm-") and len(key) > 40)
        step("right key: 200", code(ser, f"http://{ADDR}/v1/models", key) == "200")
        step("/slots off", code(ser, f"http://{ADDR}/slots", key) != "200")
        body = json.dumps({"messages": [{"role": "user", "content": "Reply with the single word: ready"}],
                           "max_tokens": 8, "temperature": 0})
        out = ser.value(f"curl -s -m 300 -H 'Authorization: Bearer {key}' -H 'Content-Type: application/json' "
                        f"http://{ADDR}/v1/chat/completions -d '{body}'", 360)
        try:
            txt = json.loads(out)["choices"][0]["message"]["content"]
        except (ValueError, KeyError, IndexError):
            txt = ""
        step("completion through the endpoint", txt.strip() != "", (txt or out)[:120])
        # comm is cut to 15 characters: match the command line instead.
        who = ser.value("ps -o user=,label= -p \"$(pgrep -d, -f /usr/lib/systemd/systemd-socket-proxyd)\" | sort -u")
        step("socket-proxyd: dynamic user, systemd_socket_proxyd_t",
             who.split()[:1] != ["root"] and ":systemd_socket_proxyd_t:" in who, who)

        # ---- 4. llmctl over vsock loopback
        ser.check("modprobe vsock_loopback 2>&1 || true")
        out = ser.check("llm allow 3 && echo 1 >> /etc/llm/clients.conf && systemctl is-active llmctl.service")
        step("llm allow: llmctl.service on", out.strip().endswith("active"), out.strip()[-200:])
        ctl = "LLMCTL_HOST_CID=1 python3 -I /mnt/payload/llmctl"
        out = ser.check(f"{ctl} status 2>&1")
        try:
            st = json.loads(out[out.index("{"):])
        except ValueError:
            st = {}
        step("llmctl status", st.get("ok") is True and st.get("up") is True and st.get("model") == msha, out.strip()[-300:])
        out = ser.check(f"{ctl} use {msha} 2>&1; echo rc=$?", 300)
        step("llmctl use (checked, restarted)", "rc=0" in out, out.strip()[-200:])
        got = wait_for(ser, "curl -s -m 5 -o /dev/null -w '%{http_code}' --unix-socket /run/llm/llm.sock http://x/health",
                       lambda v: v == "200", 600)
        step("server back after use", got == "200")
        out = ser.check(f"{ctl} use ../../etc/shadow 2>&1; echo rc=$?")
        step("llmctl use with a path refused", "rc=1" in out and '"ok": false' in out, out.strip()[-200:])
        ser.check("sed -i '/^1$/d' /etc/llm/clients.conf")
        out = ser.check(f"{ctl} status 2>&1; echo rc=$?")
        step("CID not allowed: no answer", "rc=1" in out and "no answer" in out, out.strip()[-200:])

        # ---- 5. key rotation
        ser.check("llm key rotate")
        got = wait_for(ser, "curl -s -m 5 -o /dev/null -w '%{http_code}' --unix-socket /run/llm/llm.sock http://x/health",
                       lambda v: v == "200", 600)
        new = ser.value("llm key show")
        step("key rotate: old key 401, new key 200",
             got == "200" and new != key and code(ser, f"http://{ADDR}/v1/models", key) == "401"
             and code(ser, f"http://{ADDR}/v1/models", new) == "200")

        # ---- 6. reboot
        uid = ser.value("id -u llm")
        ser.send("systemctl reboot")
        ser.expect(r"reboot: Restarting system", 300)
        recovery_boot(lab, ser)
        got = wait_for(ser, "curl -s -m 5 -o /dev/null -w '%{http_code}' --unix-socket /run/llm/llm.sock http://x/health",
                       lambda v: v == "200", 600)
        step("server back after reboot", got == "200", ser.value("systemctl is-active llm.service llm-proxy.socket | tr '\\n' ' '"))
        step("llm keeps its uid", ser.value("id -u llm") == uid)
        # Both boots (the import ran in the first).
        avc = ser.check("ausearch -m AVC -ts yesterday 2>/dev/null | grep -E "
                        "'scontext=[^ ]*:(container|container_runtime|spc)_t|comm=\"(llama-server|podman|conmon|crun|systemd-socket-|llm|llm-run|python3)\"' "
                        "|| true")
        log("AVC (permissive domains): " + "\n".join(l for l in avc.splitlines() if "permissive=1" in l)[-1500:])
        # podman probes for a user namespace at start; secureblue's harden_container_userns
        # denies it by design and podman goes on without one (logged, not counted).
        userns = [l for l in avc.splitlines() if "tclass=user_namespace" in l and ":container_runtime_t:" in l]
        log(f"podman user_namespace probes denied (expected): {len(userns)}")
        enforced = "\n".join(l for l in avc.splitlines() if "permissive=0" in l and l not in userns)
        step("no AVC for the server, podman or the proxy", enforced == "", enforced[-1500:])
        lab.poweroff()
    except Fail as e:
        log(f"FAIL: {e}")
        results.append(("(aborted) " + str(e).splitlines()[0][:100], False))
    finally:
        lab.kill()
    print("\n==== llm VM e2e results ====")
    for n, ok in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {n}")
    return 0 if results and all(ok for _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())
