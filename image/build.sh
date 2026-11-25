#!/usr/bin/env bash
# Build the sealed scroll-secure image locally, mirroring secureblue's
# build-sealed-image workflow with our own keys:
#
#   rootfs (Containerfile) -> kernel -> signed systemd-boot -> signed UKI addons
#   -> base (prepared, linted, rechunked) -> UKI (signed, composefs-sealed)
#
#   SECRETS_DIR=... ./build.sh [tag]          # default tag: localhost/scroll-secure:uki
#   BUILD_PREFIX=localhost/x ...              # intermediate images (default localhost/scroll-secure)
#   SOURCE_DATE_EPOCH=... ...                 # default: the commit time of HEAD
#   RPMLOCK_CACHE=dir ...                     # downloaded RPMs (default ~/.cache/scroll-secure/rpms)
#   NO_CACHE=1 ...                            # no layer cache anywhere (independent rebuilds)
#
# Reproducible (REPRODUCIBLE.md): every RPM comes from rpms.lock (sha256-checked), served
# as the only repo; builder images are pinned; all timestamps are SOURCE_DATE_EPOCH.
# The same commit, lock and keys give a byte-identical image.
#
# Needs: uki/keys/ from `uki/secure-boot-keys.sh create`, and db.key + PCR.key in $SECRETS_DIR.
# Only those two private keys are mounted into the build, as podman secrets;
# PK.key and KEK.key are never used here.
set -euo pipefail

cd "$(dirname "$0")"
tag="${1:-localhost/scroll-secure:uki}"
secrets="${SECRETS_DIR:-${HOME}/.local/share/scroll-secure/secrets}"
release=$(sed -n 's/^ARG FEDORA_VERSION=//p' Containerfile)
minimal="quay.io/fedora/fedora-minimal:${release}@$(sed -n 's/^ARG MINIMAL_DIGEST=//p' Containerfile)"
sde="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2> /dev/null || true)}"
[[ "${sde}" =~ ^[0-9]+$ ]] || { echo "not a git checkout: set SOURCE_DATE_EPOCH" >&2; exit 1; }
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]] && [[ -n "$(git status --porcelain -- . ../lockscreen ../desktop ../vmgui ../vmswitch)" ]]; then
    echo "warning: uncommitted changes; this build is not the commit's" >&2
fi
# Intermediate image names; BUILD_PREFIX keeps parallel (lab) builds apart.
p=${BUILD_PREFIX:-localhost/scroll-secure}

for f in uki/keys/db/db.pem uki/keys/PCR/PCR.pem "${secrets}/db.key" "${secrets}/PCR.key"; do
    [[ -r "${f}" ]] || { echo "missing ${f}; run uki/secure-boot-keys.sh create first" >&2; exit 1; }
done
sign=(
    --secret "id=secureboot_key,src=${secrets}/db.key"
    --secret "id=secureboot_crt,src=uki/keys/db/db.pem"
    --secret "id=pcr_key,src=${secrets}/PCR.key"
)

# The frozen repo: rpms.lock, downloaded and checked. It replaces /etc/yum.repos.d in
# every build step (volumes are not committed), so dnf sees nothing else.
# The premises of the reproducibility argument (REPRODUCIBLE.md) hold, or no build.
python3 -I repro-lint.py
lock=$(python3 -I rpmlock.py fetch)
repro=(
    --source-date-epoch "${sde}" --rewrite-timestamp
    --volume "${lock}:/rpmlock:ro,z" --volume "${lock}/repos.d:/etc/yum.repos.d:ro,z"
)
[[ -z "${NO_CACHE:-}" ]] || repro+=(--no-cache)
uki=(--build-arg "RELEASE=${release}" --build-arg "MINIMAL_DIGEST=${minimal##*@}")
# uki/ needs nothing from the network: its dnf reads the frozen repo.
offline=(--network=none)

# chunkah writes its OCI layout into the context (./out); start clean.
rm -rf out
trap 'rm -rf out' EXIT

set -x
# SYS_ADMIN: the rpm-build stage runs mock, which unshares namespaces and mounts in
# its chroot (only inside this rootless build's user namespace).
podman build "${repro[@]}" --cap-add=SYS_ADMIN -t "${p}-rootfs" -f Containerfile \
    --build-context lockscreen=../lockscreen --build-context desktop=../desktop \
    --build-context vmgui=../vmgui --build-context vmswitch=../vmswitch --build-context llm=../llm .
podman build "${repro[@]}" "${offline[@]}" -t "${p}-kernel" -f uki/Containerfile.kernel --build-arg "BASE=${p}-rootfs" .
# --no-cache on every signing build: podman's layer cache doesn't key on secret
# contents, so a cached layer from a build with other keys would be reused and the
# image would carry binaries signed by those keys.
podman build "${repro[@]}" --no-cache "${offline[@]}" -t "${p}-systemd-boot" -f uki/Containerfile.systemd-boot \
    "${uki[@]}" "${sign[@]}" .
podman build "${repro[@]}" --no-cache "${offline[@]}" -t "${p}-uki-addons" -f uki/Containerfile.addons \
    "${uki[@]}" "${sign[@]}" .
# chunkah writes ./out; the next build turns it into the base image (two builds, so that
# oci:out is read only after chunkah has run).
podman build "${repro[@]}" "${offline[@]}" -t "${p}-chunkah" -f uki/Containerfile.base \
    --target chunkah \
    --build-arg "BASE=${p}-rootfs" \
    --build-arg "SYSTEMDBOOT=${p}-systemd-boot" \
    --build-arg "UKIADDONS=${p}-uki-addons" \
    --skip-unused-stages=false --security-opt=label=disable \
    --volume "${PWD}:/run/src" .
[[ -f out/index.json ]] || { echo "chunkah wrote no OCI layout to ./out" >&2; exit 1; }
podman build "${repro[@]}" "${offline[@]}" -t "${p}-base" -f uki/Containerfile.chunked .
podman build "${repro[@]}" --no-cache "${offline[@]}" -t "${tag}" -f uki/Containerfile.uki \
    --build-arg "BASE=${p}-base" \
    --build-arg "KERNEL=${p}-kernel" \
    "${uki[@]}" "${sign[@]}" .

# The signed UKI must carry the tokenvault initrd pieces and the PCR signature.
podman run --rm --tmpfs /t "${tag}" \
    sh -c 'exec /usr/libexec/tokenvault/check-uki --tmpdir /t /boot/EFI/Linux/*.efi'
# systemd-boot (what bootc installs to the ESP) and the UKI must be signed by our db.
podman run --rm -v "${PWD}/uki/keys/db/db.pem:/db.pem:ro,Z" \
    --mount "type=image,src=${tag},dst=/img" "${minimal}" \
    sh -euc 'dnf -q install -y sbsigntools >/dev/null
             for f in /img/usr/lib/systemd/boot/efi/systemd-bootx64.efi /img/boot/EFI/Linux/*.efi; do
                 sbverify --cert /db.pem "$f"
             done'
set +x

echo "Built ${tag}: image $(podman image inspect --format '{{.Id}}' "${tag}"), SOURCE_DATE_EPOCH=${sde}"
echo "Sign before pushing: cosign sign --key cosign.key <registry ref>"
