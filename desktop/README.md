# desktop: the scroll desktop as RPMs

The image's desktop comes in two RPMs, built with
[mock](https://rpm-software-management.github.io/mock/), Fedora's clean-chroot
RPM builder, running inside a container:

| RPM | Source | Contents |
|---|---|---|
| `scroll` | our fork, `wildcommitter/scroll`, pinned tag (`SCROLL_*` in `image/Containerfile`), its `packaging/scroll.spec`, `--with hardened` | the compositor |
| `scroll-secure-desktop` | this directory + `../lockscreen` | `/etc/scroll/config`, `headless.conf`, `config.d/10-desktop.conf`; session entries (`scroll.desktop` reads only `/etc/scroll/config`, `scroll-pixman.desktop`); SDDM's `wayland-session` wrapper; the headless session for wayvnc; the cheatsheet wallpaper (`keys-wallpaper.py`, drawn from the shipped config); `hardened-unlock`, its PAM file and config.d snippet; `duress-reset` with its socket, service and group |

## Build

```sh
desktop/build.sh          # -> desktop/out/scroll-*.hardened.fc44.x86_64.rpm, scroll-secure-desktop-*.rpm
```

It needs podman only. It runs stage `rpm-build` of `image/Containerfile`, the
same stage the image build installs from, so the recipe is the same:

- pinned Fedora builder; `rpms.lock` (this stage's lines) is the only repo, for
  the stage and for mock's chroot (`mock-cfg.sh`);
- offline: the scroll clone is checked against its commit, and the Go modules are
  vendored against `go.sum` before mock runs (`rpmbuild_networking` off);
- reproducible: `SOURCE_DATE_EPOCH` (commit time) is the build time and clamps
  file mtimes; `_buildhost` is fixed (`image/repro-lint.py` P10, P11).

mock needs `--cap-add=SYS_ADMIN` (namespaces and mounts in its chroot). In a
rootless build that only applies inside the build's user namespace.

| File | Role |
|---|---|
| `scroll-secure-desktop.spec.in` | the spec; `@VERSION@` = `0.<UTC date-time of SOURCE_DATE_EPOCH>` |
| `make-srpm.sh` | source tarball (reproducible) + SRPM, offline |
| `mock-cfg.sh` | the mock config: the stage's repos, no bootstrap, no network, fixed macros |
| `files/` | the desktop files, at their installed paths |
| `keys-wallpaper.py` | the cheatsheet; fails the build if a key on it isn't bound |

## In the image

`image/Containerfile` installs both RPMs from stage `rpms`. scroll goes in with
`rpm -i --excludepath` for its stock `/etc/scroll/config` and
`scroll.desktop`, because scroll-secure-desktop ships ours at those paths and
two packages can't own one file. `rpm -V` stays clean.

Changing a dnf dependency of either spec means re-resolving the stage:
`python3 -I image/rpmlock.py update --only rpm-build`.
