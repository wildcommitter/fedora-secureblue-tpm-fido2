#!/usr/bin/env bash
# Build the sealed scroll-secure image locally, mirroring secureblue's
# build-sealed-image workflow with our own keys:
#
#   rootfs (Containerfile) -> kernel -> signed systemd-boot -> signed UKI addons
#   -> base (prepared, linted, rechunked) -> UKI (signed, composefs-sealed)
#
#   SECRETS_DIR=... ./build.sh [tag]          # default tag: localhost/scroll-secure:uki
#   BUILD_PREFIX=localhost/x ...              # intermediate images (default localhost/scroll-secure)
#
# Needs: uki/keys/ from `uki/secure-boot-keys.sh create`, and db.key + PCR.key in $SECRETS_DIR.
# Only those two private keys are mounted into the build, as podman secrets;
# PK.key and KEK.key are never used here.
set -euo pipefail

cd "$(dirname "$0")"
tag="${1:-localhost/scroll-secure:uki}"
secrets="${SECRETS_DIR:-${HOME}/.local/share/scroll-secure/secrets}"
release=$(sed -n 's/^ARG FEDORA_VERSION=//p' Containerfile)
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

# chunkah writes its OCI layout into the context (./out); start clean.
rm -rf out
trap 'rm -rf out' EXIT

set -x
podman build -t "${p}-rootfs" -f Containerfile --build-context lockscreen=../lockscreen .
podman build -t "${p}-kernel" -f uki/Containerfile.kernel --build-arg "BASE=${p}-rootfs" .
# --no-cache on every signing build: podman's layer cache doesn't key on secret
# contents, so a cached layer from a build with other keys would be reused and the
# image would carry binaries signed by those keys.
podman build --no-cache -t "${p}-systemd-boot" -f uki/Containerfile.systemd-boot \
    --build-arg "RELEASE=${release}" "${sign[@]}" .
podman build --no-cache -t "${p}-uki-addons" -f uki/Containerfile.addons \
    --build-arg "RELEASE=${release}" "${sign[@]}" .
podman build -t "${p}-base" -f uki/Containerfile.base \
    --build-arg "BASE=${p}-rootfs" \
    --build-arg "SYSTEMDBOOT=${p}-systemd-boot" \
    --build-arg "UKIADDONS=${p}-uki-addons" \
    --skip-unused-stages=false --security-opt=label=disable \
    --volume "${PWD}:/run/src" .
podman build --no-cache -t "${tag}" -f uki/Containerfile.uki \
    --build-arg "BASE=${p}-base" \
    --build-arg "KERNEL=${p}-kernel" \
    --build-arg "RELEASE=${release}" "${sign[@]}" .

# The signed UKI must carry the tokenvault initrd pieces and the PCR signature.
podman run --rm --tmpfs /t "${tag}" \
    sh -c 'exec /usr/libexec/tokenvault/check-uki --tmpdir /t /boot/EFI/Linux/*.efi'
# systemd-boot (what bootc installs to the ESP) and the UKI must be signed by our db.
podman run --rm -v "${PWD}/uki/keys/db/db.pem:/db.pem:ro,Z" \
    --mount "type=image,src=${tag},dst=/img" "quay.io/fedora/fedora-minimal:${release}" \
    sh -euc 'dnf -q install -y sbsigntools >/dev/null
             for f in /img/usr/lib/systemd/boot/efi/systemd-bootx64.efi /img/boot/EFI/Linux/*.efi; do
                 sbverify --cert /db.pem "$f"
             done'
set +x

echo "Built ${tag}. Sign before pushing: cosign sign --key cosign.key <registry ref>"
