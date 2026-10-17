# scroll-secure image

secureblue Sericea (`sericea-main-hardened`, Fedora 44 Atomic Sway, hardened) with
[dawsers/scroll](https://github.com/dawsers/scroll) built in, plus KVM/libvirt, a FIDO2
lock screen and a software-rendered headless session over VNC.

It is signed from the first boot, with our own keys only:

- **Firmware:** trusts only our PK → KEK → db. The db also lists this machine's option
  ROM hashes, so the GPU still has a display in firmware.
- **Boot:** systemd-boot and the UKI (kernel + initramfs + cmdline) are signed with our
  db key. There's no GRUB, no shim and no Microsoft CA.
- **Root filesystem:** the composefs backend with the image's composefs digest in the
  signed cmdline. A modified `/usr` doesn't boot.
- **TPM:** sealing uses a signed PCR 11 policy (our PCR key) plus PCR 7, so updates
  signed by us keep unlocking and anything else doesn't.

This is built on secureblue's sealed-UKI pipeline, which secureblue still labels
"testing" (vendored in `uki/`, see `uki/VENDORED`).

`main` is correct for this machine: it only means "no NVIDIA driver", and the GPU is an
AMD R9700 on amdgpu.

## Layout

| Path | Purpose |
|---|---|
| `Containerfile` | Root filesystem: build scroll (static wlroots) in `fedora:44`, then layer it onto the pinned secureblue image |
| `build.sh` | Full sealed build: rootfs → kernel → signed systemd-boot → signed addons → base → signed UKI |
| `uki/` | secureblue's sealed-UKI pipeline, plus `create-keys.sh`. `install.sh` is patched for our image and cosign key |
| `uki/keys/` | Public keys only (PK/KEK/db certs, `.auth`, `.esl`, PCR.pem, GUID). Built into the image at `/usr/share/secureblue/uki/keys/` |
| `files/usr/libexec/scroll-secure/enroll-secure-boot-keys` | Firmware enrollment with option ROM hashes. Use this, **not** `ujust enroll-secure-boot-keys` |
| `files/etc/pam.d/swaylock` | Unlock = FIDO2 key + client PIN + touch, mapping file in `/etc` |
| `files/usr/share/wayland-sessions/scroll-pixman.desktop` | SDDM session: scroll with `WLR_RENDERER=pixman` |
| `files/usr/libexec/scroll-headless`, `files/etc/scroll/headless.conf` | Headless pixman session, wayvnc on `127.0.0.1:5900` |
| `files/usr/lib/systemd/user/scroll-headless.service` | Starts it as a user service (off by default) |
| `files-luks/**`, `LUKS.md` | tokenvault: TPM2+PIN, then FIDO2+PIN+touch, unlocks root. The initramfs is built in `uki/Containerfile.uki` |

## Keys (once)

Run this on a trusted machine and keep `SECRETS_DIR` on offline/encrypted media. It needs
`openssl`, `sbsigntools` and `systemd` (for `systemd-id128`); a `fedora:44` container
works.

```sh
SECRETS_DIR=/media/keys/scroll-secure image/uki/create-keys.sh
cosign generate-key-pair      # image signature; cosign.pub goes next to Containerfile
```

| Private key | Used for | If lost |
|---|---|---|
| `db.key` | Signing systemd-boot, the UKI and addons at every build | No more bootable updates. New keys + re-enrollment needed |
| `PCR.key` | Signing the PCR 11 policy at every build | TPM unlock fails on new builds. Re-enroll with a new key |
| `KEK.key`, `PK.key` | Changing firmware keys | Clear keys in firmware setup (Setup Mode) instead |
| `cosign.key` | Signing the container image | Install/update rejects new images |

## Build, sign, publish

```sh
SECRETS_DIR=/media/keys/scroll-secure image/build.sh ghcr.io/<you>/scroll-secure:uki
podman push ghcr.io/<you>/scroll-secure:uki
cosign sign --key cosign.key ghcr.io/<you>/scroll-secure:uki
```

Only `db.key` and `PCR.key` go into the build, as podman secrets. They aren't stored in
any layer.

## Before you install: checks on the real machine

The KVM e2e (`test/bootc`) tests the unlock logic with a virtual TPM, a virtual FIDO2 key
and dev keys, using a serial console. It can't test your hardware, your real keys or the
graphical PIN prompts. Check these yourself. Everything in step 1 is read-only and can be
run on the current OS.

### 1. Before installing

- **FIDO2 key supports what tokenvault needs.** Run `fido2-token -L` to find the device,
  then `fido2-token -I /dev/hidrawN`. Under `extensions` you need `hmac-secret`, and under
  `options` you need `clientPin`. A key with no PIN yet is fine: `tokenvault enroll` sets
  it from `FIDO2_PIN`.
- **TPM 2.0 is present and not locked out.** `systemd-analyze has-tpm2` must report full
  support. `tpm2_getcap properties-variable | grep -i lockout` shows the lockout
  counter. If it isn't 0, earlier failures are counting against you and you'll be locked
  out sooner.
- **Firmware can do custom Secure Boot keys.** In firmware setup, find the option that
  clears the keys (Setup Mode). "Reset to default keys" is a different option. You need
  it for install step 1.
- **The keyboard works before the system is up.** You type the PINs in the initramfs,
  before root is mounted. USB keyboards are covered (the initramfs carries `usbhid` and
  `xhci`). Any other keyboard (laptop i2c, unusual hubs or KVM switches) is untested. Plan
  to find out on the first token boot, with the passphrase as fallback.
- **You have a recovery path.** Write down the install passphrase. It stays as LUKS
  keyslot 0, and tokenvault never removes it.

### 2. While installing (in this order)

1. Install, enroll the Secure Boot keys and turn Secure Boot on, as in "Install" below.
2. Reboot once using only the passphrase. Then run `bootctl status`: it must say Secure
   Boot is **enabled** in **user** mode. Don't enroll tokenvault before this step,
   because enrolling the Secure Boot keys changes PCR 7 and would break a TPM enrollment
   made earlier.
3. Back up the LUKS header to external media. `cryptsetup status root` shows the root
   partition (the `device:` line):
   `run0 cryptsetup luksHeaderBackup <device> --header-backup-file /media/usb/luks-header.img`
4. If usbguard is active, allow the FIDO2 key (`usbguard list-devices`, then
   `run0 usbguard allow-device <n> -p`).
5. Copy `/usr/share/tokenvault/tokenvault.conf.example` to `/etc/tokenvault/tokenvault.conf`,
   set the TPM2 PIN and the FIDO2 PIN, then run `run0 tokenvault enroll`. The PINs live
   in a file that only root and a few system tools can read (SELinux type
   `tokenvault_conf_t`).

### 3. First boot with the tokens

You should see, in this order:

1. a prompt for the **TPM2 PIN**
2. a prompt for the **security token PIN** (the FIDO2 PIN)
3. the key asking for presence (most keys blink): **touch it**
4. the desktop. If you're asked for the disk passphrase as well, something failed;
   type the passphrase and see below.

Then run `run0 tokenvault verify`. It must report OK for the vault, the root keyslot,
the boot image check and the PCR key. It also confirms that the TPM layer now **refuses**
to open: after boot, the vault is sealed until the next boot.

Test what happens when things go wrong, but only once each:

- **Key unplugged:** boot falls back to the passphrase prompt.
- **One wrong TPM2 PIN:** boot falls back to the passphrase. `run0 tokenvault status` then
  shows the lockout counter at 1. The TPM lowers it again over time, at a rate set by the
  TPM itself.
- Don't test the FIDO2 PIN repeatedly. The key blocks after 3 wrong tries per power-up
  and 8 in total, and unblocking it means a reset that wipes its credentials (then run
  `tokenvault enroll` again).

### 4. Later: when the tokens stop working

The passphrase always works. Boot with it, then run `run0 tokenvault enroll` again after:

- a firmware or Secure Boot key change (PCR 7 changes)
- a PCR signing key rotation
- a FIDO2 key reset or a replacement key

The full list is in `LUKS.md`, under "Re-enrolling is required when".

## Install (wipes the target disk)

1. Firmware: put Secure Boot in **Setup Mode** ("Delete Platform Key" / "Clear Secure Boot
   Keys", not "Reset to default").
2. Boot the Fedora CoreOS live ISO, `git clone` this repo, then:
   `sudo image/uki/install.sh ghcr.io/<you>/scroll-secure:uki`. The installer only pulls
   the image if the cosign signature verifies. It creates ESP (2G) + LUKS2 → btrfs and runs
   `bootc install --composefs-backend --bootloader=systemd`. At the Secure Boot prompt,
   choose **2 (Platform Key)**.
3. First boot, still in Setup Mode: `run0 /usr/libexec/scroll-secure/enroll-secure-boot-keys --dry-run`.
   Check that it lists the option ROMs (2 on this machine today), then run it without
   `--dry-run`. Turn Secure Boot on in firmware setup and reboot.
4. Enroll tokenvault only **after** step 3, because enrolling the keys changes PCR 7. Follow
   `LUKS.md` → "On the real machine: order of steps". Keep the install passphrase: it's
   keyslot 0, your recovery key. Re-enrolling is required after a PCR key rotation,
   Secure Boot key/db/dbx changes or a FIDO2 key reset (`LUKS.md` → "Re-enrolling is
   required when").

**If the screen is black after enrolling** (the GPU option ROM was blocked): clear the CMOS
to restore the factory Secure Boot keys, boot, then find out why the hash was missing. The
event log must come from the same GPU and VBIOS.

**Updates to the firmware's revocation list (dbx)** from fwupd are signed by Microsoft's
KEK, which we don't enroll, so they won't apply. This is mostly moot: dbx revokes
Microsoft-signed binaries, and our db trusts none.

## After the first boot

```sh
# Lock-screen key. Register only the real key: unplug or stop any virtual test key first.
pamu2fcfg -u "$USER" -o pam://workstation -i pam://workstation -N | run0 tee /etc/u2f_mappings
run0 chmod 0644 /etc/u2f_mappings

# Optional: enroll a fingerprint, then switch pinverification=1 -> userverification=1
fido2-token -S -e /dev/hidrawN

# libvirt access (groups live in /etc on Atomic, so this is per-machine)
run0 usermod -aG libvirt "$USER"

# Headless remote session
systemctl --user enable --now scroll-headless.service
# client: ssh -L 5900:127.0.0.1:5900 host, then a VNC viewer to localhost:5900
```

Test the lock screen from a second logged-in TTY before relying on it. TTY and SDDM logins
keep the stock authselect stack, so they still work if the key is lost.

Updates: `bootc upgrade` (with `bootc-upgrade.timer` enabled). Each update is a newly signed
UKI. Rollback is available from the systemd-boot menu (3 s timeout).

## Updating the pins

- Base: `podman manifest inspect ghcr.io/secureblue/sericea-main-hardened:latest`, take
  the index digest, and update `BASE_DIGEST` and `FEDORA_VERSION` together (from the
  `org.opencontainers.image.version` label).
- scroll: `git ls-remote https://github.com/dawsers/scroll 'refs/tags/<ver>'`, then update
  `SCROLL_REF` and `SCROLL_COMMIT`.
- `uki/`: re-vendor from secureblue, re-apply the `scroll-secure:` changes and update
  `uki/VENDORED`. secureblue moves fast here.

## Checks in the build

- The rootfs fails if scroll misses a library or a tokenvault CLI dependency is missing.
- `uki/Containerfile.base` runs `bootc container lint --fatal-warnings`.
- `build.sh` finally runs `tokenvault/check-uki` on the signed UKI: sections, PCR
  signature, and the initrd's tokenvault files, binaries, dracut modules and kmods.
- tokenvault e2e (`test/bootc`, KVM + OVMF Secure Boot custom mode + swtpm + virtual
  FIDO2) passes all 11 scenarios on the dev-key build, including `selinux`: the
  `tokenvault_conf_t` module denies confined domains, e.g. NetworkManager_t, read access
  to the PIN config.

## Not done yet

- Seen once in the lab: `bootc install` failed with "Writing UKI: Input/output error",
  with fs-verity reporting "FILE CORRUPTED" on the composefs object (btrfs mounted
  `compress=zstd:1`, as in `install.sh`). The retry worked. If it happens on the real
  install, rerun; if it repeats, install without `compress=` and report it to
  secureblue/bootc.
- e2e for real-key builds: OVMF can boot them (public keys only), but the serial-console
  addon needs the db key. A "blind" mode (PINs typed on VGA) isn't written yet.
- At boot, gpt-auto logs "Could not extend NvPCR". The NvPCR definitions aren't in
  the initrd, and secureblue masks `systemd-tpm2-setup-early` (systemd #40159/#40485).
  The only loss is the extra keyslot measurement. The unlock policy doesn't use it.
- The `uki/` pipeline pulls `quay.io/coreos/chunkah` and bootc from `updates-testing`
  without pinning them (as upstream does).
- wayvnc has no auth configured. It is safe only because it listens on loopback behind SSH.
