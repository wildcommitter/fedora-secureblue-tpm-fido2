#!/usr/bin/env python3
"""repro-diff: are two builds of the image byte-identical, and if not, where do they differ.

  python3 -I repro-diff.py <image A> <image B>

Same image ID (the config digest: it covers every layer's content, the history and
the config) means byte-identical. Otherwise it lists the config fields, then the files
that differ (content, mode, owner, mtime, link target, xattrs) between the two root
filesystems, the UKI included. Rootless: it re-runs itself under `podman unshare` to
mount the images. Exit 0 only if identical. See REPRODUCIBLE.md.
"""
import concurrent.futures
import hashlib
import json
import os
import stat
import subprocess
import sys


def sh(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def inspect(img):
    return json.loads(sh("podman", "image", "inspect", img))[0]


def tree(root):
    """{path: (kind, mode, uid, gid, size, mtime, target, xattrs, file to hash)}"""
    out = {}
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            p = os.path.join(d, n)
            st = os.lstat(p)
            rel = os.path.relpath(p, root)
            try:
                xa = tuple(sorted((k, os.getxattr(p, k, follow_symlinks=False)) for k in
                                  os.listxattr(p, follow_symlinks=False)))
            except OSError:
                xa = ()
            target = os.readlink(p) if stat.S_ISLNK(st.st_mode) else ""
            out[rel] = [stat.S_IFMT(st.st_mode), stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid,
                        st.st_size if stat.S_ISREG(st.st_mode) else 0, int(st.st_mtime), target, xa,
                        p if stat.S_ISREG(st.st_mode) else None]
    return out


def digest(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


FIELDS = ("type", "mode", "uid", "gid", "size", "mtime", "link", "xattrs", "sha256")


def main(a, b):
    ia, ib = inspect(a), inspect(b)
    print(f"A {a}: {ia['Id']}\nB {b}: {ib['Id']}")
    if ia["Id"] == ib["Id"]:
        print("identical: same image ID (config and every layer)")
        return 0
    for k in ("Created", "Config", "Labels", "Annotations"):
        if ia.get(k) != ib.get(k):
            print(f"config {k}: A={json.dumps(ia.get(k))[:300]}\n         B={json.dumps(ib.get(k))[:300]}")
    la, lb = ia["RootFS"]["Layers"], ib["RootFS"]["Layers"]
    same = sum(x == y for x, y in zip(la, lb))
    print(f"layers: A {len(la)}, B {len(lb)}, {same} identical in place")
    # The layer digests are what ships. The file list below is read from podman's local
    # storage, which keeps a build container's directories as they were, so a
    # directory's mtime there can differ from its (clamped) entry in the layer tar.
    hist = [h for h in json.loads(sh("podman", "image", "inspect", "--format", "{{json .History}}", a))
            if not h.get("empty_layer")]
    for i, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            step = hist[i].get("created_by", "") if i < len(hist) else ""
            print(f"layer {i} differs: {step[:160]}")
    ma, mb = sh("podman", "image", "mount", a), sh("podman", "image", "mount", b)
    try:
        ta, tb = tree(ma), tree(mb)
        with concurrent.futures.ThreadPoolExecutor(16) as ex:
            for t in (ta, tb):
                paths = [k for k, v in t.items() if v[8]]
                for k, h in zip(paths, ex.map(lambda k: digest(t[k][8]), paths)):
                    t[k][8] = h
        diffs = 0
        for p in sorted(set(ta) | set(tb)):
            x, y = ta.get(p), tb.get(p)
            if x is None or y is None:
                print(f"only in {'B' if x is None else 'A'}: /{p}")
                diffs += 1
            elif x != y:
                what = [f"{FIELDS[i]} {x[i]!r:.60} != {y[i]!r:.60}" for i in range(9) if x[i] != y[i]]
                print(f"differs: /{p}: {'; '.join(what)}")
                diffs += 1
        print(f"{diffs} paths differ")
    finally:
        sh("podman", "image", "unmount", a)
        sh("podman", "image", "unmount", b)
    return 1


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    if os.geteuid() != 0 and not os.environ.get("REPRO_DIFF_UNSHARED"):
        os.environ["REPRO_DIFF_UNSHARED"] = "1"
        os.execvp("podman", ["podman", "unshare", sys.executable, "-I", os.path.abspath(__file__), *sys.argv[1:]])
    sys.exit(main(*sys.argv[1:]))
