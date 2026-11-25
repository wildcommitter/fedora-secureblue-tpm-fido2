#!/usr/bin/env bash
# Make the scroll-secure-desktop source RPM, offline: a tarball of desktop/files,
# keys-wallpaper.py and the lockscreen tree (its Go modules already vendored, since
# mock builds without network), plus the spec with @VERSION@ filled in.
#
#   desktop/make-srpm.sh <lockscreen dir, with vendor/> <outdir>
#
# Version 0.<UTC date-time of SOURCE_DATE_EPOCH>: the commit time, so it rises with
# each commit. The tarball is reproducible (sorted, fixed owner, mtimes clamped to
# SOURCE_DATE_EPOCH). Needs rpmbuild; ~/.rpmmacros sets _buildhost and
# use_source_date_epoch_as_buildtime (repro-lint P10). Prints the SRPM's path.
set -euo pipefail

die() { echo "make-srpm: $*" >&2; exit 1; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
lock=$(cd "${1:?lockscreen dir}" && pwd)
out=$(mkdir -p "${2:?outdir}" && cd "$2" && pwd)
sde=${SOURCE_DATE_EPOCH:?set SOURCE_DATE_EPOCH}
[[ -d $lock/vendor ]] || die "$lock/vendor missing (go mod vendor first)"
command -v rpmbuild > /dev/null || die "rpmbuild not found"

version=0.$(TZ=UTC date -d "@$sde" +%Y%m%d%H%M%S)
name=scroll-secure-desktop-$version
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/$name/lockscreen" "$work/SOURCES" "$work/SPECS"
cp -a "$here/files" "$here/keys-wallpaper.py" "$work/$name/"
cp -a "$lock/go.mod" "$lock/go.sum" "$lock/cmd" "$lock/internal" "$lock/vendor" \
    "$lock/etc" "$lock/usr" "$work/$name/lockscreen/"
tar --sort=name --mtime="@$sde" --clamp-mtime --owner=0 --group=0 --numeric-owner \
    --format=gnu -C "$work" -cf "$work/SOURCES/$name.tar" "$name"
sed "s/@VERSION@/$version/g" "$here/scroll-secure-desktop.spec.in" > "$work/SPECS/scroll-secure-desktop.spec"
rpmbuild -bs --define "_topdir $work" --define "_srcrpmdir $out" \
    "$work/SPECS/scroll-secure-desktop.spec" > /dev/null
ls "$out/$name-1".*.src.rpm
