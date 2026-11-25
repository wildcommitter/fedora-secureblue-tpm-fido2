#!/usr/bin/env python3
"""repro-lint: check the premises of the reproducibility argument (REPRODUCIBLE.md).

  python3 -I repro-lint.py        exit 0 if every obligation holds, else list the failures

The argument: the image is a composition of build stages; if every input of every
stage is pinned by content and every stage is a deterministic function of its inputs,
two builds are byte-identical (induction over the stage graph). This checks the first
premise and the ways we know a stage can stop being deterministic. It reads the build
files only; build.sh runs it before building.

  P1  every FROM is a digest (@sha256:...), an earlier stage, scratch, oci:out, or an
      image build.sh itself built (an ARG it passes); llm/ uses the image's Fedora pin
  P2  every stage that runs dnf (directly or through uki/scripts) names its lines of
      rpms.lock (ARG DNF_VAR_rpmlock=<stage>), and that stage has lines in the lock
  P3  every stage with a RUN declares ARG SOURCE_DATE_EPOCH
  P4  rpms.lock: each line is a sha256, an https URL and a known stage
  P5  build.sh, llm/build.sh and desktop/build.sh pass --source-date-epoch and --rewrite-timestamp to every
      podman build and mount the lock over /etc/yum.repos.d
  P6  signing uses systemd-sbsign only (sbsign puts the clock into signingTime), and a
      ukify build with a kernel says whether to sign it (systemd-sbsign can't check)
  P7  network inputs outside dnf are pinned: the scroll and llama.cpp clones check their
      commits, Go modules are read-only against go.sum (go mod vendor under
      -mod=readonly; the desktop spec builds -mod=vendor with GOPROXY=off)
  P8  isolation: no RUN step has the network except those fetches (git clone, go build,
      go mod vendor) (Containerfile and
      llm/Containerfile:
      RUN --network=${RUN_NETWORK}, default none; build.sh: uki/ builds --network=none),
      so a stage reads only its declared inputs
  P9  every dnf or rpm -i/-U step in a stage whose files ship (the image stage, rootfs-base) runs
      dnf-settle in the same RUN, and so does the rootfs stage's last RUN (chunkah's
      input): dnf5's and rpm's SQLite -wal/-shm files are random
  P10 every stage that runs rpmbuild writes ~/.rpmmacros with a fixed _buildhost and
      use_source_date_epoch_as_buildtime first: rpm puts the host and the clock into the
      header (Buildhost, Buildtime, Cookie)
  P11 every mock build uses the config of desktop/mock-cfg.sh, generated in the same
      RUN before it: the stage's own repos (rpms.lock), no bootstrap image (a network
      pull), no network for rpmbuild, no caches, fixed _buildhost, build time and
      mtimes from SOURCE_DATE_EPOCH; the desktop spec takes it from there, not from a
      changelog
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ["Containerfile", "uki/Containerfile.kernel", "uki/Containerfile.systemd-boot",
         "uki/Containerfile.addons", "uki/Containerfile.base", "uki/Containerfile.chunked", "uki/Containerfile.uki",
         "../llm/Containerfile"]
# ARGs build.sh sets to images it built itself (BUILD_PREFIX), or that resolve to "scratch"
BUILT = {"BASE", "KERNEL", "SYSTEMDBOOT", "UKIADDONS"}
DNF = re.compile(r"\bdnf5?\s+(-\S+\s+)*(install|upgrade|builddep|reinstall|downgrade|swap|distro-sync)\b")
# rpm writing the rpmdb (P9 only: no repo, so not P2)
RPMI = re.compile(r"\brpm\s+(-\S+\s+)*-(i|U)\b")
fails = []


def fail(msg):
    fails.append(msg)


def read(p):
    return open(os.path.join(HERE, p)).read()


def lock_stages():
    stages = set()
    for n, line in enumerate(read("rpms.lock").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        f = line.split()
        if len(f) != 3 or not re.fullmatch(r"[0-9a-f]{64}", f[0]) or not f[1].startswith("https://") \
                or not f[1].endswith(".rpm"):
            fail(f"P4 rpms.lock:{n}: not '<sha256> <https URL of an .rpm> <stage>': {line[:80]}")
            continue
        stages.add(f[2])
    return stages


def stages(path):
    """[(line, from, alias, body lines, ARG defaults)] for one Containerfile; the global
    ARGs (before the first FROM) come first as the defaults for FROM lines."""
    text = re.sub(r"\\\n", " ", read(path))
    out, glob = [], {}
    cur = None
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        m = re.match(r"(?i)FROM\s+(\S+)(?:\s+AS\s+(\S+))?", s)
        if m:
            cur = [n, m.group(1), (m.group(2) or "").lower(), [], {}]
            out.append(cur)
            continue
        a = re.match(r"ARG\s+(\w+)(?:=(\S*))?", s)
        if a and cur is None:
            glob[a.group(1)] = a.group(2)
        elif cur is not None:
            if a:
                cur[4][a.group(1)] = a.group(2)
            cur[3].append(s)
    return glob, out


def expand(ref, glob):
    return re.sub(r"\$\{?(\w+)\}?", lambda m: glob.get(m.group(1)) or f"<{m.group(1)}>", ref)


def scripts_run(body):
    """uki/scripts/*.sh a stage runs, with their text."""
    out = []
    for name in re.findall(r"/run/scripts/([\w.-]+\.sh)", " ".join(body)):
        out.append(read(f"uki/scripts/{name}"))
    return out


def passed_args():
    """ARGs build.sh passes to uki/ with values from Containerfile (one source)."""
    g, _ = stages("Containerfile")
    s = read("build.sh")
    out = {}
    if re.search(r'--build-arg "MINIMAL_DIGEST=\$\{minimal##\*@\}"', s) and \
            "sed -n 's/^ARG MINIMAL_DIGEST=//p' Containerfile" in s:
        out["MINIMAL_DIGEST"] = g.get("MINIMAL_DIGEST")
    if re.search(r'--build-arg "RELEASE=\$\{release\}"', s):
        out["RELEASE"] = g.get("FEDORA_VERSION")
    return out


def check_containerfiles(locked):
    passed = passed_args()
    for path in FILES:
        glob, sts = stages(path)
        aliases = set()
        for n, ref, alias, body, args in sts:
            where = f"{path}:{n}"
            vars_ = set(re.findall(r"\$\{?(\w+)\}?", ref))
            if ref in ("scratch",) or ref.lower() in aliases or ref.startswith("oci:"):
                pass
            elif vars_ and vars_ <= BUILT:
                pass
            else:
                full = expand(ref, {**glob, **passed})
                if not re.search(r"@sha256:[0-9a-f]{64}$", full):
                    fail(f"P1 {where}: FROM {ref} is not pinned by digest ({full})")
            if alias:
                aliases.add(alias)
            runs = [l for l in body if l.startswith("RUN")]
            if runs and "SOURCE_DATE_EPOCH" not in args:
                fail(f"P3 {where}: stage {alias or ref} has RUN but no ARG SOURCE_DATE_EPOCH")
            text = "\n".join(body + scripts_run(body))
            # heredoc bodies are in `body` too (they follow the RUN line)
            if DNF.search(text):
                st = args.get("DNF_VAR_rpmlock")
                if not st:
                    fail(f"P2 {where}: stage {alias or ref} runs dnf but sets no ARG DNF_VAR_rpmlock")
                elif st not in locked:
                    fail(f"P2 {where}: DNF_VAR_rpmlock={st} has no lines in rpms.lock")
            if re.search(r"(^|[\s/])sbsign\s", text):
                fail(f"P6 {where}: sbsign (use systemd-sbsign)")
    # llm/ builds on the same Fedora pin as the image (one base to bump).
    img_g, _ = stages("Containerfile")
    llm_g, _ = stages("../llm/Containerfile")
    for k in ("FEDORA_VERSION", "FEDORA_DIGEST"):
        if llm_g.get(k) != img_g.get(k):
            fail(f"P1 ../llm/Containerfile: ARG {k}={llm_g.get(k)} differs from Containerfile's {img_g.get(k)}")
    for name in os.listdir(os.path.join(HERE, "uki/scripts")):
        t = read(f"uki/scripts/{name}")
        if re.search(r"--signtool\s+sbsign\b|(^|\s)sbsign\s", t):
            fail(f"P6 uki/scripts/{name}: sbsign (use systemd-sbsign)")
        if "--signtool systemd-sbsign" in t and "--linux" in t and \
                not re.search(r"--(no-)?sign-kernel\b", t):
            fail(f"P6 uki/scripts/{name}: systemd-sbsign with --linux needs --sign-kernel or "
                 "--no-sign-kernel (ukify can't check the kernel with it)")


def check_build_sh():
    for path in ("build.sh", "../llm/build.sh", "../desktop/build.sh"):
        check_one_build_sh(path)


def check_one_build_sh(path):
    s = read(path)
    flat = re.sub(r"\\\n", " ", s)
    if not re.search(r'repro=\([^)]*--source-date-epoch "\$\{sde\}" --rewrite-timestamp', flat, re.S):
        fail(f"P5 {path}: repro=(...) lacks --source-date-epoch \"${{sde}}\" --rewrite-timestamp")
    if not re.search(r'repro=\([^)]*:/etc/yum\.repos\.d:ro', flat, re.S):
        fail(f"P5 {path}: repro=(...) doesn't mount the lock over /etc/yum.repos.d")
    for m in re.finditer(r"^\s*podman build\b.*$", flat, re.M):
        if '"${repro[@]}"' not in m.group(0):
            fail(f"P5 {path}: podman build without \"${{repro[@]}}\": {m.group(0).strip()[:90]}")


def check_network():
    c = read("Containerfile")
    if not re.search(r'git -C /src rev-parse HEAD\)" = "\$\{SCROLL_COMMIT\}"', c) or \
            not re.search(r"ARG SCROLL_COMMIT=[0-9a-f]{40}\n", c):
        fail("P7 Containerfile: the scroll clone doesn't check a pinned 40-hex SCROLL_COMMIT")
    code = "\n".join(l for l in c.splitlines() if not l.lstrip().startswith("#"))
    for m in re.finditer(r"go (build|mod vendor)[^\n]*", code):
        if "GOFLAGS=-mod=readonly" not in code[max(0, m.start() - 120):m.start()]:
            fail(f"P7 Containerfile: {m.group(1)} without GOFLAGS=-mod=readonly: {m.group(0)[:60]}")
    spec = read("../desktop/scroll-secure-desktop.spec.in")
    for m in re.finditer(r"\bgo build[^\n]*", spec):
        pre = spec[:m.start()]
        if not re.search(r"export [^\n]*GOFLAGS=-mod=vendor[^\n]*", pre) or \
                not re.search(r"export [^\n]*GOPROXY=off", pre):
            fail(f"P7 desktop spec: go build without exported GOFLAGS=-mod=vendor and GOPROXY=off: {m.group(0)[:60]}")
    if not os.path.exists(os.path.join(HERE, "../lockscreen/go.sum")):
        fail("P7 lockscreen/go.sum missing")
    lc = read("../llm/Containerfile")
    if not re.search(r'git -C /src rev-parse HEAD\)" = "\$\{LLAMACPP_COMMIT\}"', lc) or \
            not re.search(r"ARG LLAMACPP_COMMIT=[0-9a-f]{40}\n", lc):
        fail("P7 llm/Containerfile: the llama.cpp clone doesn't check a pinned 40-hex LLAMACPP_COMMIT")
    for f in FILES:
        for m in re.finditer(r"\b(curl|wget|git clone|pip install|go install)\b[^\n]*", read(f)):
            if "git clone" in m.group(0) and ("SCROLL_REPO" in m.group(0) or
                                              (f == "../llm/Containerfile" and "LLAMACPP_REPO" in m.group(0))):
                continue
            fail(f"P7 {f}: unpinned network fetch: {m.group(0)[:70]}")


def check_isolation():
    for path in ("Containerfile", "../llm/Containerfile"):
        glob, sts = stages(path)
        if glob.get("RUN_NETWORK") != "none":
            fail(f"P8 {path}: no global ARG RUN_NETWORK=none")
        for n, ref, alias, body, args in sts:
            runs = [l for l in body if l.startswith("RUN")]
            fetch = [l for l in runs if "git clone" in l or "go build" in l or "go mod vendor" in l]
            for l in runs:
                if l in fetch:
                    continue
                if not l.startswith("RUN --network=${RUN_NETWORK} "):
                    fail(f"P8 {path} stage {alias or ref}: RUN with network: {l[:70]}")
            if len(runs) > len(fetch) and "RUN_NETWORK" not in args:
                fail(f"P8 {path} stage {alias or ref}: no ARG RUN_NETWORK")
    if "RUN_NETWORK" in read("../llm/build.sh"):
        fail("P8 llm/build.sh: sets RUN_NETWORK (only rpmlock.py update may)")
    s = re.sub(r"\\\n", " ", read("build.sh"))
    if "offline=(--network=none)" not in s:
        fail("P8 build.sh: no offline=(--network=none)")
    for m in re.finditer(r"^\s*podman build\b.*$", s, re.M):
        if "-f uki/" in m.group(0) and '"${offline[@]}"' not in m.group(0):
            fail(f"P8 build.sh: uki/ build with network: {m.group(0).strip()[:90]}")
    if "RUN_NETWORK" in s:
        fail("P8 build.sh: sets RUN_NETWORK (only rpmlock.py update may)")


SHIPPED = {("Containerfile", ""), ("uki/Containerfile.base", "rootfs-base")}


def check_settle():
    for path, alias in SHIPPED:
        _, sts = stages(path)
        for n, ref, a, body, args in sts:
            if a != alias:
                continue
            for line in body:
                if line.startswith("RUN") and (DNF.search(line) or RPMI.search(line)
                                               or any(DNF.search(t) for t in scripts_run([line]))) \
                        and "dnf-settle" not in line:
                    fail(f"P9 {path} stage {alias or ref}: dnf/rpm without dnf-settle: {line[:70]}")
    # chunkah takes the rootfs stage's whole tree: a later rpm query (even read-only)
    # would bring rpmdb.sqlite-shm back, so its last RUN ends with dnf-settle
    _, sts = stages("uki/Containerfile.base")
    for n, ref, a, body, args in sts:
        runs = [l for l in body if l.startswith("RUN")]
        if a == "rootfs" and not (runs and runs[-1].rstrip().endswith("/usr/libexec/scroll-secure/dnf-settle")):
            fail(f"P9 uki/Containerfile.base:{n}: stage rootfs doesn't end with dnf-settle")


def check_rpmbuild():
    for path in FILES:
        _, sts = stages(path)
        for n, ref, alias, body, args in sts:
            text = "\n".join(l for l in body if l.startswith("RUN"))
            i = text.find("rpmbuild ")
            if i < 0 and "make-srpm.sh" not in text:
                continue
            j = min(k for k in (i, text.find("make-srpm.sh")) if k >= 0)
            pre = text[:j]
            if not (re.search(r"%_buildhost \S+", pre) and "%use_source_date_epoch_as_buildtime 1" in pre
                    and "~/.rpmmacros" in pre):
                fail(f"P10 {path}:{n}: stage {alias or ref} runs rpmbuild without ~/.rpmmacros "
                     "setting _buildhost and use_source_date_epoch_as_buildtime")


MOCK_CFG = {
    "config_opts['use_bootstrap_image'] = False": "a bootstrap image (pulled from the network)",
    "config_opts['use_bootstrap'] = False": "a bootstrap chroot (its own dnf and repos)",
    "config_opts['rpmbuild_networking'] = False": "network for rpmbuild",
    "config_opts['plugin_conf']['root_cache_enable'] = False": "a root cache",
    "config_opts['macros']['%_buildhost'] = 'scroll-secure'": "the build host in the header",
    "config_opts['macros']['%use_source_date_epoch_as_buildtime'] = '1'": "the clock as build time",
    "config_opts['macros']['%clamp_mtime_to_source_date_epoch'] = '1'": "unclamped file mtimes",
    "config_opts['environment']['SOURCE_DATE_EPOCH'] = '${sde}'": "no SOURCE_DATE_EPOCH for rpmbuild",
    'reposdir=/dev/null': "repos other than the stage's",
}


def check_mock():
    cfg = read("../desktop/mock-cfg.sh")
    for line, why in MOCK_CFG.items():
        if line not in cfg:
            fail(f"P11 desktop/mock-cfg.sh: lacks `{line}` ({why})")
    if '/etc/yum.repos.d/*.repo' not in cfg:
        fail("P11 desktop/mock-cfg.sh: repos don't come from the stage's /etc/yum.repos.d")
    spec = read("../desktop/scroll-secure-desktop.spec.in")
    if "%global source_date_epoch_from_changelog 0" not in spec:
        fail("P11 desktop spec: SOURCE_DATE_EPOCH from the changelog, not the build")
    # rpm's macro is clamp_mtime_to_source_date_epoch; Fedora ties it to
    # source_date_epoch_from_changelog, which the spec turns off
    if "%global clamp_mtime_to_source_date_epoch 1" not in spec:
        fail("P11 desktop spec: file mtimes not clamped (%global clamp_mtime_to_source_date_epoch 1)")
    for path in FILES:
        _, sts = stages(path)
        for n, ref, alias, body, args in sts:
            for line in body:
                # mock as a command: at the start of the RUN or after && ; ||
                cmd = re.compile(r"(?:^RUN(?:\s+--\S+)*|&&|;|\|\|)\s+mock\s+(-r\s+\S+)?")
                if not line.startswith("RUN") or not cmd.search(line):
                    continue
                i = line.find("mock-cfg.sh > /etc/mock/scroll-secure.cfg")
                uses = [m.group(1) for m in cmd.finditer(line)]
                if i < 0 or i > cmd.search(line).start():
                    fail(f"P11 {path}:{n}: stage {alias or ref} runs mock without generating "
                         "/etc/mock/scroll-secure.cfg with mock-cfg.sh first in the same RUN")
                if any(u != "-r scroll-secure" for u in uses):
                    fail(f"P11 {path}:{n}: stage {alias or ref} runs mock with another config: {line[:70]}")


def main():
    locked = lock_stages()
    check_rpmbuild()
    check_mock()
    check_isolation()
    check_settle()
    check_containerfiles(locked)
    check_build_sh()
    check_network()
    for f in fails:
        print(f"repro-lint: {f}")
    print(f"repro-lint: {'FAIL' if fails else 'ok'} (P1-P11, {len(FILES)} Containerfiles, "
          f"{len(locked)} locked stages)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
