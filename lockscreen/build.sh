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
    gobject-introspection-devel pam-devel libxcrypt-devel >/dev/null
go vet ./...
go vet -tags duresstest ./...
go test ./...
go build -trimpath -o out/ ./cmd/hardened-unlock ./cmd/authtest
# The root-side reset helper: static, no libc, no libcrypt.
CGO_ENABLED=0 go build -trimpath -o out/ ./cmd/duress-reset
# Test-only locker whose duress reset writes a marker (lockscreen/test/duress-e2e.sh).
go build -trimpath -tags duresstest -o out/duresstest/ ./cmd/hardened-unlock
# The production locker must not contain the test hook.
if grep -q HARDENED_UNLOCK_DURESS_MARKER out/hardened-unlock; then
    echo "out/hardened-unlock contains the duresstest hook" >&2; exit 1
fi
grep -q HARDENED_UNLOCK_DURESS_MARKER out/duresstest/hardened-unlock'
ls -la out/ out/duresstest/
