#!/usr/bin/env python3
"""rpmlock: every RPM the image build installs, pinned by sha256 (reproducible builds).

  python3 -I rpmlock.py update [--prefix P] [--only S1,S2]
                                              resolve from the live repos, rewrite rpms.lock
                                              (--only: just these stages; the other lines stay)
  python3 -I rpmlock.py fetch [DIR]           download rpms.lock into DIR (verified), make
                                              the repo build.sh mounts; prints DIR

update builds each stage that runs dnf (as build.sh would, but against the live repos
and with a throwaway signing key), then takes the packages each stage added to its base
image. Fedora's RPMs are recorded by their Koji URL (signed copy, byte-identical to the
mirrors' and kept for good); others by their repo's location. fetch never trusts a
download: each file must match its sha256 in rpms.lock.

DIR defaults to $RPMLOCK_CACHE or ~/.cache/scroll-secure/rpms. See REPRODUCIBLE.md.
"""
import argparse
import concurrent.futures
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = os.path.join(HERE, "rpms.lock")
KOJI = "https://kojipkgs.fedoraproject.org/packages"
QF = r"%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\t%{SOURCERPM}\t%{VENDOR}\t%{RSAHEADER:pgpsig}\n"
# createrepo_c for the frozen repo (tooling only: nothing of it lands in the image).
TOOLS = "createrepo_c"


def die(msg):
    sys.exit(f"rpmlock: {msg}")


def arg(name):
    """An ARG default from the Containerfile (one source for the pins)."""
    m = re.search(rf"^ARG {name}=(\S+)$", open(os.path.join(HERE, "Containerfile")).read(), re.M)
    return m.group(1) if m else die(f"no ARG {name} in Containerfile")


def run(*cmd, **kw):
    print("+", " ".join(cmd), file=sys.stderr)
    return subprocess.run(cmd, check=True, text=True, **kw)


def images():
    release = arg("FEDORA_VERSION")
    return {
        "fedora": f"quay.io/fedora/fedora:{release}@{arg('FEDORA_DIGEST')}",
        "minimal": f"quay.io/fedora/fedora-minimal:{release}@{arg('MINIMAL_DIGEST')}",
        "base": f"{arg('BASE_IMAGE')}@{arg('BASE_DIGEST')}",
    }


def rpms(image, root=None):
    """The image's packages; with root, those of a dnf --installroot tree inside it."""
    q = ["--root", root] if root else []
    out = run("podman", "run", "--rm", "--entrypoint", "rpm", image, *q, "-qa", "--qf", QF,
              capture_output=True).stdout
    return {f[0]: f for f in (l.split("\t") for l in out.splitlines()) if not f[0].startswith("gpg-pubkey-")}


# Stages that install a tree with dnf --installroot: their packages are read from there too.
ROOTS = {"llm-server": "/rootfs"}


def build_stages(prefix, keydir, only=None):
    """Build every dnf stage against the live repos; [(stage, its image, its base image)]."""
    img, release = images(), arg("FEDORA_VERSION")
    sign = ["--secret", f"id=secureboot_key,src={keydir}/k", "--secret", f"id=secureboot_crt,src={keydir}/c",
            "--secret", f"id=pcr_key,src={keydir}/k"]
    uki = ["--build-arg", f"RELEASE={release}", "--build-arg", f"MINIMAL_DIGEST={arg('MINIMAL_DIGEST')}"]
    ctx = ["--build-arg", "RUN_NETWORK=host", "--build-context", "lockscreen=../lockscreen", "--build-context", "vmgui=../vmgui",
           "--build-context", "vmswitch=../vmswitch"]
    t = lambda s: f"{prefix}-lock-{s}"
    steps = [
        (["-f", "Containerfile", *ctx, "--target", "scroll-build"], "scroll-build", img["fedora"]),
        (["-f", "Containerfile", *ctx, "--target", "lockscreen-build"], "lockscreen-build", img["fedora"]),
        (["-f", "Containerfile", *ctx], "rootfs", img["base"]),
        (["-f", "uki/Containerfile.systemd-boot", *uki, *sign, "--target", "builder"], "systemd-boot", img["minimal"]),
        (["-f", "uki/Containerfile.addons", *uki, *sign, "--target", "builder"], "addons", img["minimal"]),
        # rootfs-base copies the signed systemd-boot and the addons in: the whole images.
        (["-f", "uki/Containerfile.systemd-boot", *uki, *sign], "systemd-boot-out", None),
        (["-f", "uki/Containerfile.addons", *uki, *sign], "addons-out", None),
        (["-f", "uki/Containerfile.base", "--build-arg", f"BASE={t('rootfs')}",
          "--build-arg", f"SYSTEMDBOOT={t('systemd-boot-out')}", "--build-arg", f"UKIADDONS={t('addons-out')}",
          "--target", "rootfs-base"], "rootfs-base", t("rootfs")),
        (["-f", "uki/Containerfile.uki", *uki, "--build-arg", "BASE=scratch", "--build-arg", "KERNEL=scratch",
          "--target", "uki-tools"], "uki-tools", img["minimal"]),
        # llm/: the model server image (llm/README.md), its own build context.
        (["-f", "../llm/Containerfile", "--build-arg", "RUN_NETWORK=host", "--build-context", "imagefiles=files",
          "--target", "llm-build"], "llm-build", img["fedora"]),
        (["-f", "../llm/Containerfile", "--build-arg", "RUN_NETWORK=host", "--build-context", "imagefiles=files",
          "--target", "llm-server"], "llm-server", img["fedora"]),
    ]
    if only:
        unknown = only - {s for _, s, _ in steps}
        if unknown:
            die(f"--only: unknown stages {' '.join(sorted(unknown))}")
        steps = [st for st in steps if st[1] in only]
    out = []
    for opts, stage, base in steps:
        ctxdir = "../llm" if "../llm/Containerfile" in opts else "."
        run("podman", "build", "--pull=missing", "-t", t(stage), *opts, ctxdir, cwd=HERE)
        if base:
            out.append((stage, t(stage), base))
    return out


def keyid(sig):
    m = re.search(r"Key ID ([0-9a-f]{16})", sig)
    return m.group(1)[-8:] if m else None


def koji_url(nevra, srpm, sig):
    k = keyid(sig)
    if not k or not srpm.endswith(".src.rpm"):
        return None
    n, v, r = srpm[: -len(".src.rpm")].rsplit("-", 2)
    arch = nevra.rsplit(".", 1)[1]
    return f"{KOJI}/{n}/{v}/{r}/data/signed/{k}/{arch}/{nevra}.rpm"


RPM_MAGIC = b"\xed\xab\xee\xdb"


def sha256_url(url):
    """sha256 of the file at url, or None if it isn't an RPM (Koji answers RPMs it may
    not distribute, like Cisco's openh264, with a redirect to a wiki page)."""
    h = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=120) as r:
        first = r.read(1 << 20)
        if not first.startswith(RPM_MAGIC):
            return None
        h.update(first)
        for chunk in iter(lambda: r.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def locations(stage, nevras):
    """Repo locations of packages, from the dnf config of the stage that installed them."""
    out = run("podman", "run", "--rm", "--entrypoint", "dnf", stage, "-q", "repoquery",
              "--location", "--enablerepo=updates-testing", *nevras, capture_output=True).stdout
    return {os.path.basename(loc)[: -len(".rpm")]: loc for loc in out.split()}


def hash_all(urls):
    with concurrent.futures.ThreadPoolExecutor(16) as ex:
        return dict(zip(urls, ex.map(sha256_url, urls.values())))


def update(prefix, only=None):
    with tempfile.TemporaryDirectory() as keydir:
        # Throwaway key: the signing steps run, but only the RPMs matter here.
        run("openssl", "req", "-quiet", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=rpmlock",
            "-days", "1", "-keyout", f"{keydir}/k", "-out", f"{keydir}/c", capture_output=True)
        stages = build_stages(prefix, keydir, only)
    # Per stage: what it added to its base. Each stage gets only its own set at build
    # time: stages resolved at different times can hold different versions of a package.
    per_stage, urls, other = {}, {}, {}
    for stage, image, base in stages:
        have, before = rpms(image), rpms(base)
        added = {n: f for n, f in have.items() if n not in before}
        if stage in ROOTS:   # an installroot tree starts empty: all of it comes from the lock
            added.update(rpms(image, ROOTS[stage]))
        per_stage[stage] = []
        for nevra, srpm, vendor, sig in (f for f in added.values() if f[1] != "(none)"):
            per_stage[stage].append(nevra)
            url = koji_url(nevra, srpm, sig) if vendor == "Fedora Project" else None
            if url:
                urls.setdefault(nevra, url)
            elif keyid(sig):
                other.setdefault(nevra, image)
            else:  # unsigned: a local RPM (scroll from stage 1), not from a repo
                per_stage[stage].remove(nevra)
    print(f"rpmlock: hashing {len(urls)} RPMs from Koji", file=sys.stderr)
    sums = hash_all(urls)
    for nevra in [n for n, h in sums.items() if h is None]:
        other.setdefault(nevra, next(i for st, i, _ in stages if nevra in per_stage[st]))
        del urls[nevra], sums[nevra]
    by_image = {}
    for nevra, image in other.items():
        by_image.setdefault(image, []).append(nevra)
    for image, nevras in by_image.items():
        locs = locations(image, nevras)
        missing = set(nevras) - set(locs)
        if missing:
            die(f"{image}: no repo location for {' '.join(sorted(missing))}")
        got = hash_all({n: locs[n] for n in nevras})
        bad = [locs[n] for n, h in got.items() if h is None]
        if bad:
            die(f"not an RPM: {' '.join(bad)}")
        urls.update({n: locs[n] for n in nevras})
        sums.update(got)
    # --only: the other stages keep their lines, in the lock's stage order.
    kept = [l for l in read_lock() if l[2] not in per_stage] if only else []
    order = list(dict.fromkeys([l[2] for l in read_lock()] if only else []))
    order += [st for st, _, _ in stages if st not in order]
    with open(LOCK, "w") as f:
        f.write("# Every RPM the image build installs, per build stage: sha256, where to get it,\n"
                "# stage. Written by `python3 -I rpmlock.py update`; build.sh gives each stage a\n"
                "# repo of its own lines only.\n")
        for stage in order:
            if stage in per_stage:
                for nevra in sorted(per_stage[stage]):
                    f.write(f"{sums[nevra]}  {urls[nevra]}  {stage}\n")
            else:
                for sha, url, st in kept:
                    if st == stage:
                        f.write(f"{sha}  {url}  {st}\n")
    n = sum(map(len, per_stage.values()))
    print(f"rpmlock: wrote {LOCK} ({len(urls)} RPMs, {n} in {len(stages)} stages)", file=sys.stderr)


def read_lock():
    """[(sha256, url, stage)]"""
    return [tuple(l.split()) for l in open(LOCK) if l.strip() and not l.startswith("#")]


def fetch(d):
    """Download into DIR/files (checked), then DIR/repo/<stage> (hard links) per stage."""
    files = os.path.join(d, "files")
    os.makedirs(files, exist_ok=True)
    lock = read_lock()
    want = {os.path.basename(u): s for s, u, _ in lock}

    def get(name):
        sha, url = want[name], next(u for s, u, _ in lock if os.path.basename(u) == name)
        path = os.path.join(files, name)
        if os.path.exists(path) and hashlib.sha256(open(path, "rb").read()).hexdigest() == sha:
            return
        tmp = path + ".part"
        with urllib.request.urlopen(url, timeout=300) as r, open(tmp, "wb") as f:
            for chunk in iter(lambda: r.read(1 << 20), b""):
                f.write(chunk)
        got = hashlib.sha256(open(tmp, "rb").read()).hexdigest()
        if got != sha:
            os.unlink(tmp)
            raise RuntimeError(f"{url}: sha256 {got}, lock says {sha}")
        os.replace(tmp, path)

    with concurrent.futures.ThreadPoolExecutor(16) as ex:
        list(ex.map(get, want))
    repo = os.path.join(d, "repo")
    if os.path.isdir(repo):
        shutil.rmtree(repo)  # rebuilt from the lock every time: only its lines are served
    stages = []
    for _, url, stage in lock:
        sd = os.path.join(repo, stage)
        if stage not in stages:
            stages.append(stage)
            os.makedirs(sd)
        os.link(os.path.join(files, os.path.basename(url)), os.path.join(sd, os.path.basename(url)))
    # An empty repo stands in for updates-testing (uki/ enables it by name for bootc).
    os.makedirs(os.path.join(repo, "empty"))
    cmds = "; ".join(f"createrepo_c -q /d/repo/{s}" for s in [*stages, "empty"])
    run("podman", "run", "--rm", "--network=host", "-v", f"{d}:/d:z", "--entrypoint", "sh", images()["minimal"], "-euc",
        f"dnf -q install -y {TOOLS} >/dev/null; {cmds}", stdout=sys.stderr)
    rd = os.path.join(d, "repos.d")
    os.makedirs(rd, exist_ok=True)
    with open(os.path.join(rd, "rpmlock.repo"), "w") as f:
        f.write("# rpms.lock as the only repo (build.sh mounts this over /etc/yum.repos.d). Each\n"
                "# stage sets DNF_VAR_rpmlock to its name and sees its own lines of the lock only;\n"
                "# a stage that doesn't fails here. Each file matched its sha256 when fetched.\n"
                "[rpmlock]\nname=rpms.lock ($rpmlock)\nbaseurl=file:///rpmlock/repo/$rpmlock\nenabled=1\ngpgcheck=0\n\n"
                "[updates-testing]\nname=empty (updates-testing is in rpms.lock)\nbaseurl=file:///rpmlock/repo/empty\n"
                "enabled=0\ngpgcheck=0\n")
    print(d)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    u = sub.add_parser("update")
    u.add_argument("--prefix", default="localhost/scroll-secure")
    u.add_argument("--only", default="", help="comma-separated stages to re-resolve")
    f = sub.add_parser("fetch")
    f.add_argument("dir", nargs="?", default=os.environ.get(
        "RPMLOCK_CACHE", os.path.expanduser("~/.cache/scroll-secure/rpms")))
    a = ap.parse_args()
    if a.cmd == "update":
        update(a.prefix, set(filter(None, a.only.split(","))) or None)
    else:
        fetch(os.path.abspath(a.dir))


if __name__ == "__main__":
    main()
