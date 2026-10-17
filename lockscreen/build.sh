#!/usr/bin/env bash
# Builds hardened-unlock and authtest in a Fedora container matching the image
# (Fedora 44), into ./out/. The image build does the same in its own stage.
#
#   lockscreen/build.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p out
podman run --rm -v "$PWD:/src:Z" -w /src \
    -v hardened-unlock-gocache:/root/go -v hardened-unlock-gobuild:/root/.cache/go-build \
    registry.fedoraproject.org/fedora:44 bash -euc '
dnf -q install -y golang gcc pkgconf-pkg-config gtk4-devel gtk4-layer-shell-devel \
    gobject-introspection-devel pam-devel >/dev/null
go vet ./...
go test ./...
go build -trimpath -o out/ ./cmd/...'
ls -la out/
