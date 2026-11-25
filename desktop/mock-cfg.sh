#!/usr/bin/env bash
# Print the mock config of image/Containerfile's rpm-build stage. mock is Fedora's
# clean-chroot RPM builder; here it runs inside that container, so:
#   - isolation=simple, no bootstrap chroot: mock's dnf is the stage's own dnf
#     (from rpms.lock), installing into the chroot with --installroot;
#   - the repos are the stage's /etc/yum.repos.d with $rpmlock expanded: under
#     build.sh that is rpms.lock as the only repo (this stage's lines), under
#     `rpmlock.py update` the live Fedora repos;
#   - no network for rpmbuild, no caches; the chroot stays (--no-cleanup-after)
#     at /var/lib/mock/scroll-secure/root so rpmlock.py can read what it holds;
#   - reproducible headers (repro-lint P10): fixed _buildhost, build time and
#     mtimes from SOURCE_DATE_EPOCH, which rpmbuild gets from the environment.
#
#   SOURCE_DATE_EPOCH=... DNF_VAR_rpmlock=<stage> desktop/mock-cfg.sh > /etc/mock/scroll-secure.cfg
set -euo pipefail

die() { echo "mock-cfg: $*" >&2; exit 1; }

sde=${SOURCE_DATE_EPOCH:?set SOURCE_DATE_EPOCH}
stage=${DNF_VAR_rpmlock:?set DNF_VAR_rpmlock}
[[ $sde =~ ^[0-9]+$ ]] || die "SOURCE_DATE_EPOCH=$sde"
[[ $stage =~ ^[a-z0-9-]+$ ]] || die "DNF_VAR_rpmlock=$stage"
release=$(rpm -E %fedora)
shopt -s nullglob
repos=(/etc/yum.repos.d/*.repo)
[[ ${#repos[@]} -gt 0 ]] || die "no repos in /etc/yum.repos.d"

cat <<EOF
config_opts['root'] = 'scroll-secure'
config_opts['target_arch'] = 'x86_64'
config_opts['legal_host_arches'] = ('x86_64',)
config_opts['releasever'] = '${release}'
config_opts['dist'] = 'fc${release}'
config_opts['macros']['%dist'] = '.fc${release}'
config_opts['package_manager'] = 'dnf5'
config_opts['isolation'] = 'simple'
config_opts['use_bootstrap'] = False
config_opts['use_bootstrap_image'] = False
config_opts['rpmbuild_networking'] = False
config_opts['use_host_resolv'] = False
config_opts['nosync'] = False
# @buildsys-build, spelled out: the frozen repo has no comps groups.
config_opts['chroot_setup_cmd'] = 'install bash bzip2 coreutils cpio diffutils fedora-release-common findutils gawk glibc-minimal-langpack grep gzip info patch redhat-rpm-config rpm-build sed shadow-utils tar unzip util-linux which xz'
config_opts['plugin_conf']['root_cache_enable'] = False
config_opts['plugin_conf']['yum_cache_enable'] = False
config_opts['plugin_conf']['ccache_enable'] = False
config_opts['macros']['%_buildhost'] = 'scroll-secure'
config_opts['macros']['%use_source_date_epoch_as_buildtime'] = '1'
config_opts['macros']['%clamp_mtime_to_source_date_epoch'] = '1'
config_opts['environment']['SOURCE_DATE_EPOCH'] = '${sde}'
config_opts['dnf.conf'] = """
[main]
keepcache=0
assumeyes=1
protected_packages=
install_weak_deps=0
best=1
skip_if_unavailable=False
reposdir=/dev/null

$(sed "s/\$rpmlock/${stage}/g" "${repos[@]}")
"""
EOF
