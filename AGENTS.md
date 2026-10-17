# AGENTS.md

Instructions for coding agents working in this repo. Human-facing docs: `README.md`
(index), `image/README.md`, `image/LUKS.md`, `lockscreen/README.md`.

## What this is

A sealed, signed secureblue (Fedora Atomic, Sericea + scroll) image for one workstation:

- **Image:** bootc with the composefs backend, systemd-boot, and a UKI signed with our own
  Secure Boot keys. The cmdline is sealed into the UKI, and the TPM policy uses a signed
  PCR 11.
- **Disk unlock (tokenvault):** two tokens, both required:
  - the TPM2 PIN (in the TPM policy)
  - the FIDO2 key's client PIN plus a touch

  Together they open a two-layer LUKS2 vault on the ESP. The vault holds the root keyslot's
  passphrase.
- **Lock screen (hardened-unlock):** the FIDO2 key PIN plus a touch, then the account
  password.

## Layout

| Path | Contents |
|---|---|
| `image/Containerfile`, `image/build.sh`, `image/files/`, `image/uki/` | Image build, signing pipeline (vendored from secureblue, see `uki/VENDORED`), install, Secure Boot keys (`uki/secure-boot-keys.sh`) |
| `image/files-luks/`, `image/LUKS.md` | tokenvault: dracut module + generator (initrd), `tokenvault` CLI, SELinux CIL (`tokenvault_conf_t`), tmpfiles |
| `lockscreen/` | hardened-unlock (Go, GTK4, `gtk4-layer-shell` session lock), PAM file, scroll config drop-in |
| `test/e2e.py`, `test/vfido/` | Shared KVM harness (`Lab`, `Serial`) and the virtual CTAP2 key (USB HID gadget on `dummy_hcd`) |
| `test/bootc/` | tokenvault e2e and Secure Boot enrollment e2e on the sealed image |
| `legacy/` | Old CachyOS versions. Reference only: not built, not shipped, don't extend |

## Hard rules

- **Never touch the host's security state.** All tests use swtpm, `test/vfido`, containers
  or VMs. Specifically:
  - no `cryptsetup`/`systemd-cryptenroll` on host disks
  - no host TPM (`/dev/tpm0`, `/dev/tpmrm0`)
  - no real FIDO2 key (wrong PINs use up its retries)
  - no changes to host PAM or `/etc`
  - no efivar writes on the host

  Read-only inspection is fine, for example the TPM event log or `status` commands.
- **Never pass the host TPM to a VM running stock OVMF.** It would extend the host's PCRs.
- **Don't touch other people's VMs.** The libvirt VM `qubes-baremetal` (host TPM and USB
  passthrough) belongs to the user.
- **Secrets never enter the repo.** Private keys (`db.key`, `PCR.key`, `PK.key`, `KEK.key`,
  `cosign.key`) live in `SECRETS_DIR` on offline media (default
  `~/.local/share/scroll-secure/secrets`). Only public material goes in `image/uki/keys/`
  and `image/cosign.pub`. `.gitignore` excludes `*.key`; don't weaken it with
  `*.pem`/`*.auth` rules, because `uki/keys/` must stay tracked.
- **Dev keys and lab aids are throwaway and lab-only.** This covers the serial-console UKI
  addon, root autologin in `build-disk.sh`, and the lab passphrases. Never put them in the
  image or the docs' real-machine steps.
- **"Password per token" means the token's own PIN**: the TPM2 PIN goes in the TPM policy,
  the FIDO2 PIN is the key's client PIN. The semantics are AND, never OR. Don't
  reintroduce separate passwords or derived keys.
- **Don't change the security design without the user.** That covers the PCR policy (signed
  PCR 11 + PCR 7 + PIN), the post-quantum vault layout, and dropping the Microsoft CA.
  Propose instead.

## Build

```sh
SECRETS_DIR=... image/build.sh [tag]      # full sealed build; needs uki/keys + db.key + PCR.key
lockscreen/build.sh                       # Fedora 44 container -> lockscreen/out/; runs go vet + go test
image/uki/secure-boot-keys.sh create      # new key hierarchy (refuses to overwrite)
```

The image build runs `bootc container lint --fatal-warnings` (in `uki/Containerfile.base`)
and `/usr/libexec/tokenvault/check-uki` (from `image/files-luks/`) on the signed UKI. Both must pass.

- **Dev builds use a scratch copy.** Put dev keys in a copy of `image/` (with `lockscreen/`
  next to it) and run `secure-boot-keys.sh create --keys <copy>/uki/keys --secrets <scratch>`
  there. Run without `--keys`, it writes into the tracked `image/uki/keys/`, and dev keys
  would be committed and embedded in the image.
- **Key layout:** nested in the repo (`uki/keys/{PK,KEK,db,PCR}/`, plus `GUID`), but flat
  in the image (`/usr/share/secureblue/uki/keys/`, copied by `uki/Containerfile.base`).
  `secure-boot-keys.sh` accepts both.
- **Building `image/Containerfile` by hand** needs `--build-context lockscreen=../lockscreen`.
  `build.sh` passes it.
- **`uki/` is vendored.** Our changes are marked `scroll-secure:`. Re-apply them when
  re-vendoring, and update `uki/VENDORED`.

## Test

KVM tests need `sudo` (USB gadget, loop devices) and take minutes. Run the ones relevant to
the change and report the real result.

```sh
sudo test/bootc/lab-secureboot.sh test/bootc/work <keys-dir> [<dev db.key>]   # OVMF vars (+ serial addon)
sudo test/bootc/build-disk.sh test/bootc/work <image>                          # lab disk
test/bootc/e2e.py [--cli-from-image] [scenario ...]    # tokenvault, 11 scenarios
test/bootc/sb-enroll-e2e.py                            # Secure Boot key enrollment from Setup Mode
lockscreen/test/pam-e2e.sh                             # PAM stack with the virtual key (container)
lockscreen/test/gui-e2e.sh                             # locker under headless scroll + wtype
```

Work directories (`**/work/`) hold multi-GB disks and are git-ignored.

## Gotchas (each cost real debugging time)

- **bootc composefs installs only from a registry.** `build-disk.sh` pushes to a loopback
  registry. containers-storage and save/load both fail (splitstream errors, manifest
  integrity).
- **Nothing may land in the image's `/var`** (bootc lint). `dnf` runs with
  `--mount=type=tmpfs,target=/var`, and state directories come from `tmpfiles.d`.
- **The hardened kernel has no 9p.** Feed files to the guest as a read-only tar disk
  (`/dev/vdb`).
- **Pipes under `set -o pipefail`:** `grep -q` closes the pipe early and the writer dies with
  SIGPIPE. Use `grep -c`, `find -print -quit`, or here-strings.
- **Shell traps:**
  - Don't put an apostrophe inside `${x:?...}`.
  - Split `local a=$2 b=$a` into two `local`s under `set -u`.
  - Give `luksKillSlot` `</dev/null`.
- **systemd 259:**
  - There are no `--tpm2-argon2id-*` flags.
  - `systemd-cryptenroll` reads the FIDO2 PIN only through the ask-password agent
    (`askpass.py`).
- **efivarfs:** db/dbx use GUID `d719b2cb-…`, not the global GUID. Existing variables are
  immutable (`chattr -i` first).
- **wtype:** each call is a new virtual keyboard and loses the first key. Pause first
  (`-s 300`) and send Enter in the same call.
- **ext-session-lock:** a locker must round-trip the unlock (`display.Sync()`) before
  exiting, or the compositor treats it as crashed and stays locked (scroll's red screen).
  `::unlocked` fires synchronously inside `Unlock()`.
- **Option ROM hashes** come from the TPM event log (PCR 2, `EV_EFI_BOOT_SERVICES_DRIVER`).
  Without them in db, a discrete GPU has no display under our keys. Never drop them
  silently.

## Git

- The repo is shared by more than one agent session. Commit only the paths you changed:
  ```sh
  git add <paths>                       # needed for new files
  git commit -m "..." -- <paths>
  ```
  Never use `git add -A`, `git add .`, `git commit -a`, or a plain `git commit`; another
  session may have changes staged.
- Pull with `git pull --rebase` before pushing. The remote is
  `github.com/wildcommitter/fedora-secureblue-tpm-fido2` (private, HTTPS through `gh`).
- Commit message: a short summary line, then what changed and why, plus what was tested and
  the result.

## Style

- **Bash:** `set -euo pipefail`, `die()` helpers, a header comment with usage, quote
  everything, no new dependencies outside the image.
- **Python:** stdlib plus what the image already ships (`python3-fido2`), and run it with
  `python3 -I`.
- **Go:** match the existing comment density; run `go vet` and `go test` through
  `lockscreen/build.sh`.
- **Docs:** short sentences and tables. Real-machine steps must be ones the e2e has actually
  exercised, or they must say they aren't.
