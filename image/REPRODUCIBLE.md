# Reproducible builds

The same commit, `rpms.lock` and signing keys give a byte-identical image: the same
image ID (the config digest, which covers every layer) and the same signed UKI.

```sh
NO_CACHE=1 SOURCE_DATE_EPOCH=... ./build.sh localhost/a:uki     # two independent builds
NO_CACHE=1 SOURCE_DATE_EPOCH=... ./build.sh localhost/b:uki
python3 -I repro-diff.py localhost/a:uki localhost/b:uki         # exit 0: identical
```

`SOURCE_DATE_EPOCH` defaults to the commit time of HEAD (`git log -1 --format=%ct`).

## Inputs

Every input is named by its content.

| Input | Pinned by | Where |
|---|---|---|
| secureblue base | index digest | `Containerfile` `BASE_DIGEST` |
| Fedora builder images (`fedora`, `fedora-minimal`) | index digest | `Containerfile` `FEDORA_DIGEST`, `MINIMAL_DIGEST` (build.sh passes it to `uki/`) |
| chunkah | manifest digest | `uki/Containerfile.base` |
| Every RPM installed, per stage | sha256 | `rpms.lock` (Koji's signed copies, kept for good; openh264 from Cisco's repo) |
| scroll source | git commit | `Containerfile` `SCROLL_COMMIT`, checked after the clone |
| Go modules | go.sum hashes | `../lockscreen/go.sum`, `-mod=readonly` |
| Our files | the git commit | the build context |
| Time | `SOURCE_DATE_EPOCH` | build.sh |
| db and PCR keys | the key files | `SECRETS_DIR` (not public) |

What it took:

| Source of difference | Fix |
|---|---|
| Base tags move (fedora:44 moved on the day this was written) | Digests |
| dnf resolves against the live repos | `rpms.lock`, served per stage as the only repo (`/etc/yum.repos.d` is a volume during the build, not committed) |
| Stages resolved at different times hold different versions of one package | One repo per stage (`ARG DNF_VAR_rpmlock=<stage>`), never one pool |
| rpm install time, dnf history | rpm and dnf take `SOURCE_DATE_EPOCH` (tested) |
| Layer mtimes, image creation time | `--source-date-epoch --rewrite-timestamp`; chunkah and dracut `--reproducible` take `SOURCE_DATE_EPOCH` |
| `ARG SOURCE_DATE_EPOCH` must be declared | In every stage with a `RUN` (podman exposes it only as a build arg) |
| `sbsign` writes the clock into PKCS#7 `signingTime` | `systemd-sbsign`, which takes `SOURCE_DATE_EPOCH` (tested: same bytes twice, `sbverify` OK) |
| The scroll RPM header: Buildhost (the container's hostname), Buildtime and Cookie (`<host> <time>`, copied from the SRPM) | `~/.rpmmacros` in the builder: `%_buildhost scroll-secure`, `%use_source_date_epoch_as_buildtime 1`. They differed in `rpmdb.sqlite` |
| The SRPM header holds make-srpm.sh's `mktemp` path (in the expanded build scripts) | Fork: a relative `_topdir` (scroll `ae971c6a`, tested: same SRPM twice). The binary RPM never depended on it |
| SQLite in WAL mode leaves random `-wal`/`-shm` files: dnf5's `transaction_history.sqlite`, and rpm's `rpmdb.sqlite` (even a read-only `rpm -q` brings them back) | `dnf-settle` checkpoints both and switches them to rollback-journal mode, after each dnf step in a shipped stage and as the last step of the rootfs stage that chunkah reads. Deleting the files alone isn't enough: a WAL database without `-shm` can't be opened read-only (chunkah failed on it) |
| `systemd-sbsign` can't check whether the kernel is signed, so ukify stops | `--no-sign-kernel`: what sbsign's check found (secureblue already signed it) |
| `FROM oci:out` after chunkah in one build: buildah may resolve it before chunkah has written `./out` (one build of a pair failed) | `uki/Containerfile.chunked`, a build of its own after `--target chunkah` |
| Koji redirects non-distributable RPMs (openh264) to a wiki page | `rpmlock.py` checks the RPM magic; falls back to the repo's location |

## The argument

**Model.** The build is a directed acyclic graph of stages: the Containerfile stages and
the images build.sh feeds from one build into the next. A stage *s* produces its output
as a function of its inputs:

  out(s) = F_s(in(s)),  in(s) = (its FROM image, the outputs of the stages it copies or
  mounts from, its context files, its lines of `rpms.lock`, its pinned network inputs,
  `SOURCE_DATE_EPOCH`, the keys)

The image is the output of the last stage. Its ID is the sha256 of its config, which
lists the sha256 of every layer.

**Premises.**

- **A1 (pinned):** every input of a stage that doesn't come from an earlier stage is
  named by a cryptographic hash, or is the same value in both builds
  (`SOURCE_DATE_EPOCH`, keys).
- **A2 (isolated):** a stage reads nothing but in(s).
- **A3 (deterministic):** each F_s is a function: the same inputs give the same bytes.
- **A4 (same tools):** both builds run the same podman/buildah. The tools inside the
  stages are inputs: pinned images and locked RPMs.

**Theorem.** Under A1–A4, two builds with the same inputs produce the same image ID and
the same UKI.

**Proof.** Strong induction over a topological order of the graph.

- *Stage with no stage inputs.* Its FROM image is identical in both builds: it is named
  by digest (A1), and a digest names one manifest, so one set of layers. Its lock lines
  name the same files (sha256, A1); `fetch` rejects any other bytes. Its context files
  come from the same commit. Its network inputs are a git commit and go.sum hashes (A1).
  `SOURCE_DATE_EPOCH` and the keys are the same. By A2 it reads nothing else, so in(s)
  is equal in both builds. By A3 and A4, out(s) is equal.
- *Stage with stage inputs.* Every stage it copies or mounts from comes earlier in the
  order, so by the induction hypothesis their outputs are equal. Its other inputs are
  equal as in the first case. So in(s) is equal, and so is out(s).

The last stage's output is therefore equal: the same layers and the same config, so the
same config digest (the image ID). The UKI is a file in that output. ∎

The rest follows from that:

- The composefs digest sealed into the UKI's cmdline is a function of the rootfs stage's
  output, so it is the same too.
- Signatures don't break A3: both keys are RSA with PKCS#1 v1.5 padding, which uses no
  random input, and `signingTime` is `SOURCE_DATE_EPOCH`. An ECDSA key would break A3.

**What is checked by machine, and what isn't.**

| Premise | How | Kind |
|---|---|---|
| A1, A2 | `repro-lint.py`, P1–P10, run by build.sh before every build; `repro-lint-test.sh` breaks each premise in a copy (29 mutations) and requires the matching failure | Checked from the files: a build that breaks them doesn't start |
| A2, dnf | P2 + P5: the volume over `/etc/yum.repos.d`; a stage without `DNF_VAR_rpmlock` resolves no repo | Checked |
| A2, network | P8: `RUN --network=none` except the scroll clone and `go build` (both pinned, A1); `uki/` builds run `--network=none` | Enforced by podman |
| A3 | Not provable: gcc, Go, rpm, dracut, ukify and podman are outside this repo. Tested per tool (rpm, dnf, `systemd-sbsign` above) and as a whole by two independent `NO_CACHE=1` builds and `repro-diff.py` | Evidence, not proof |
| A3, rpm, dnf | P9: `dnf-settle` after dnf in a shipped stage and last before chunkah; P10: `~/.rpmmacros` before rpmbuild | Checked that the known fixes are in place; that they suffice is tested, as A3 |
| A4 | Not checked. Use the same podman version (6.1.4 here) | Assumption |

A difference that `repro-diff.py` finds means a premise is broken. It lists the layers and
files, so the broken stage can be found. The layer digests are what ships; its file list
comes from podman's local storage, where a directory's mtime can differ from its clamped
entry in the layer tar, so a directory mtime alone is not a difference.

Hash strength: the scroll pin is a git SHA-1 commit. An attacker who can make a SHA-1
collision in the fork could swap the source under the same pin. Everything else is
SHA-256.

## Updating the lock

```sh
python3 -I rpmlock.py update     # live repos, throwaway signing key, rewrites rpms.lock
```

It builds each stage that runs dnf against the live repos, with `RUN_NETWORK=host`, and
records what each stage added to its base. Commit `rpms.lock` with the change that
needed it. Bumping a base digest needs an update too.

## Results

| Test | Result |
|---|---|
| `repro-lint-test.sh` | 29 mutations caught, real files pass |
| Two `NO_CACHE=1` builds, run in parallel from separate copies with separate RPM caches, `repro-diff.py` | Identical: image `d3b1d72b0445bc07d10cc0fd469d6a35c8340212e8374eba82aef10b47e48147` (257 layers) both times; signed UKI `582868b7…` and signed systemd-boot `39fb36a7…` the same bytes. scroll at `ae971c6a`, `SOURCE_DATE_EPOCH=1793008449`, podman 6.1.4, lab keys (2026-10-26) |

## Not done yet

| What | Plan |
|---|---|
| Verification without our keys | A third party's build has their own signatures (systemd-boot, the addons, the UKI, the PCR signature), so the image ID differs. Compare with the Authenticode signatures and `.pcrsig` removed, then check those against `db.pem` and `PCR.pem` |
| Publish the lock's RPMs | Koji keeps them; a mirror of the 736 files with each release would remove that dependency |
