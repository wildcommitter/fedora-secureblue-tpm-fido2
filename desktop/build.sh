#!/usr/bin/env bash
# Build the desktop RPMs, scroll (our hardened fork) and scroll-secure-desktop,
# with mock inside a container, exactly as the image build does (stage rpm-build of
# image/Containerfile: same pins, rpms.lock as the only repo, offline), and put
# them in desktop/out/. Needs podman only; see desktop/README.md.
#
#   desktop/build.sh                 # SOURCE_DATE_EPOCH: the commit time of HEAD
#   SOURCE_DATE_EPOCH=... ...        # or set it (reproducible: same input, same RPMs)
#   RPMLOCK_CACHE=dir ...            # downloaded RPMs (default ~/.cache/scroll-secure/rpms)
#   NO_CACHE=1 ...                   # no layer cache
set -euo pipefail

die() { echo "desktop/build.sh: $*" >&2; exit 1; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "${here}/../image"
command -v podman > /dev/null || die "podman not found"
sde="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2> /dev/null || true)}"
[[ "${sde}" =~ ^[0-9]+$ ]] || die "not a git checkout: set SOURCE_DATE_EPOCH"
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]] && [[ -n "$(git status --porcelain -- . ../lockscreen ../desktop)" ]]; then
    echo "warning: uncommitted changes; these RPMs are not the commit's" >&2
fi

# Same premises and frozen repo as image/build.sh.
python3 -I repro-lint.py
lock=$(python3 -I rpmlock.py fetch)
repro=(
    --source-date-epoch "${sde}" --rewrite-timestamp
    --volume "${lock}:/rpmlock:ro,z" --volume "${lock}/repos.d:/etc/yum.repos.d:ro,z"
)
[[ -z "${NO_CACHE:-}" ]] || repro+=(--no-cache)

rm -rf "${here}/out"
# SYS_ADMIN: mock unshares namespaces and mounts in its chroot (inside the rootless
# build's user namespace only).
podman build "${repro[@]}" --cap-add=SYS_ADMIN --target rpms --output "type=local,dest=${here}/out" \
    -f Containerfile --build-context lockscreen=../lockscreen --build-context desktop=../desktop .
shopt -s nullglob
rpms=("${here}"/out/*.rpm)
[[ ${#rpms[@]} -eq 2 ]] || die "expected 2 RPMs in ${here}/out, got ${#rpms[@]}"
ls -l "${rpms[@]}"
echo "SOURCE_DATE_EPOCH=${sde}"
