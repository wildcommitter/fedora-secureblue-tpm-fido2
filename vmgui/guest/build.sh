#!/usr/bin/env bash
# Build the vmgui guest addon for every target of the topology, into ./out/:
#
#   vmgui/guest/build.sh [VERSION]          # default 0.1.0
#
#   linux  rpm  x86_64+aarch64  wlroots|xorg  out/linux/rpm/*.noarch.rpm (Fedora 44 container)
#   linux  deb  x86_64+aarch64  wlroots|xorg  out/linux/deb/*_all.deb     (Debian 13 container)
#   win11       amd64|arm64                   out/win11/vmgui-agent-win11-<arch>.zip
#   macos       amd64|arm64                   out/macos/vmgui-agent-macos-<arch>.tar.gz
#
# The Linux packages are noarch: they hold a Python launcher, units and
# environment.d files, and pull waypipe (and xwayland-satellite) for the guest's
# own arch from its distro. The win11/macos agent is one Go program, built per
# arch with CGO_ENABLED=0 (macOS goes through purego, so no Apple SDK). Every
# build runs go vet for all six GOOS/GOARCH pairs and go test first.
# SOURCE_DATE_EPOCH (default: the last commit) fixes archive timestamps.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSION=${1:-0.1.0}
OUT=$HERE/out
die() { echo "build.sh: $*" >&2; exit 1; }

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be X.Y.Z"
SDE=${SOURCE_DATE_EPOCH:-$(git -C "$HERE" log -1 --format=%ct 2> /dev/null || true)}
[[ -n $SDE ]] || die "not a git checkout: set SOURCE_DATE_EPOCH"
export SOURCE_DATE_EPOCH=$SDE

rm -rf "$OUT"
mkdir -p "$OUT/linux/rpm" "$OUT/linux/deb" "$OUT/win11" "$OUT/macos"
src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
tar -C "$HERE/linux" --sort=name --mtime="@$SDE" --owner=0 --group=0 --numeric-owner \
    -cf "$src/vmgui-guest-linux.tar" common wlroots xorg

# --- Linux: rpm ---
podman run --rm -e SOURCE_DATE_EPOCH -v "$src:/src:ro,Z" -v "$HERE/linux/rpm:/spec:ro,Z" \
    -v "$OUT/linux/rpm:/out:Z" registry.fedoraproject.org/fedora:44 bash -euc "
dnf -q install -y rpm-build >/dev/null 2>&1
mkdir -p ~/rpmbuild/SOURCES && cp /src/vmgui-guest-linux.tar ~/rpmbuild/SOURCES/
rpmbuild -bb --quiet --define 'vmgui_version $VERSION' --define 'use_source_date_epoch_as_buildtime 1' \
    --define 'clamp_mtime_to_source_date_epoch 1' --define '_buildhost reproducible' /spec/vmgui-guest.spec
cp ~/rpmbuild/RPMS/noarch/*.rpm /out/"

# --- Linux: deb ---
podman run --rm -e SOURCE_DATE_EPOCH -v "$src:/src:ro,Z" -v "$HERE/linux/deb/debian:/debian:ro,Z" \
    -v "$OUT/linux/deb:/out:Z" docker.io/library/debian:trixie bash -euc "
apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq debhelper >/dev/null 2>&1
mkdir -p /b/vmgui-guest && cd /b/vmgui-guest && tar -xf /src/vmgui-guest-linux.tar && cp -a /debian debian
printf 'vmgui-guest ($VERSION) unstable; urgency=medium\n\n  * vmgui guest addon $VERSION.\n\n -- scroll-secure <noreply@users.noreply.github.com>  %s\n' \
    \"\$(date -u -R -d @$SDE)\" > debian/changelog
dpkg-buildpackage -b -us -uc >/dev/null
cp ../*.deb /out/"

# --- win11 / macos: the Go agent ---
podman run --rm -e SOURCE_DATE_EPOCH -v "$HERE:/src:ro,Z" -v "$OUT:/out:Z" \
    -v vmgui-agent-gocache:/root/go registry.fedoraproject.org/fedora:44 bash -euc "
dnf -q install -y golang zip >/dev/null 2>&1
cp -a /src/agent /b && cd /b
for t in linux/amd64 linux/arm64 windows/amd64 windows/arm64 darwin/amd64 darwin/arm64; do
    GOOS=\${t%/*} GOARCH=\${t#*/} go vet ./...
done
go test ./...
for arch in amd64 arm64; do
    d=/tmp/vmgui-agent-win11-\$arch && mkdir -p \$d
    CGO_ENABLED=0 GOOS=windows GOARCH=\$arch go build -trimpath -ldflags=-buildid= -o \$d/vmgui-agent.exe ./cmd/vmgui-agent
    CGO_ENABLED=0 GOOS=windows GOARCH=\$arch go build -trimpath -ldflags=-buildid= -o \$d/llmctl.exe ./cmd/llmctl
    cp /src/win11/*.ps1 \$d/
    touch -d @$SDE \$d/* \$d && (cd /tmp && zip -q -X -r /out/win11/vmgui-agent-win11-\$arch.zip vmgui-agent-win11-\$arch)
    d=/tmp/vmgui-agent-macos-\$arch && mkdir -p \$d
    CGO_ENABLED=0 GOOS=darwin GOARCH=\$arch go build -trimpath -ldflags=-buildid= -o \$d/vmgui-agent ./cmd/vmgui-agent
    CGO_ENABLED=0 GOOS=darwin GOARCH=\$arch go build -trimpath -ldflags=-buildid= -o \$d/llmctl ./cmd/llmctl
    cp /src/macos/install.sh /src/macos/*.plist \$d/
    tar -C /tmp --sort=name --mtime=@$SDE --owner=0 --group=0 --numeric-owner -czf \
        /out/macos/vmgui-agent-macos-\$arch.tar.gz vmgui-agent-macos-\$arch
done
# The e2e's guest: the agent's Linux demo backend.
mkdir -p /out/test && CGO_ENABLED=0 go build -trimpath -ldflags=-buildid= -o /out/test/vmgui-agent-demo ./cmd/vmgui-agent
CGO_ENABLED=0 go build -trimpath -ldflags=-buildid= -o /out/test/llmctl ./cmd/llmctl"

echo "vmgui guest addon $VERSION:"
(cd "$OUT" && find . -type f ! -path './test/*' -printf '  %P\n' | sort)
