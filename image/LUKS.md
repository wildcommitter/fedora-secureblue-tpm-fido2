# tokenvault: TPM2 + FIDO2 root unlock (sealed UKI, composefs, systemd-boot)

Everything is in `image/files-luks/`, which ships in the image and goes into the signed UKI's
initrd. It is inert until a machine runs `tokenvault enroll`.

## What happens at boot

1. You enter the **TPM2 PIN**, then the **FIDO2 PIN**, then **touch the key**.
2. That opens a two-layer vault on the ESP: `ESP:/tokenvault/vault.img`.
3. The vault holds a random 64-character passphrase (~413 bits), which is a keyslot of the
   root LUKS2 volume, so root unlocks without asking.

All of it is required: one token, both PINs without a touch, or the disk in another machine
will **not** open the vault. The passphrase chosen in `install.sh` stays as the recovery
path.

```
ESP (vfat, /boot)  /tokenvault/vault.img
 └─ outer LUKS2  aes-xts-plain64 512-bit
     token systemd-tpm2: PCR 7 (literal) + PCR 11 (signed by our PCR key, phase enter-initrd) + TPM2 PIN
     └─ inner LUKS2  serpent-xts-plain64 512-bit
         token systemd-fido2: client PIN + user presence
         └─ payload: 64-char passphrase ─► keyslot N of the root partition (GPT type 8304)
```

The tokens' passwords are their own PINs:

- **TPM2:** the PIN is part of the TPM2 policy (`--tpm2-with-pin`).
- **FIDO2:** the PIN is the key's **client PIN**. `enroll` sets it, or changes it from
  `FIDO2_CURRENT_PIN`.

Both PINs are plaintext in `/etc/tokenvault/tokenvault.conf` (root, 0600), for unattended
enrollment and rotation. That file never reaches the boot path.

## Initrd flow

Nothing is machine-specific on the cmdline (it is sealed in the UKI), so the dracut module
`90tokenvault` ships only a generator that discovers everything:

| Unit | Does |
|---|---|
| `run-tokenvault-esp.mount` | Mounts the ESP the stub booted from (`LoaderDevicePartUUID`) read-only at `/run/tokenvault/esp` |
| `tokenvault-tpm2.service` | Stock `systemd-cryptsetup attach`, `tpm2-device=auto`. Prompts **"Please enter TPM2 PIN"**. Gated on `ConditionPathExists=` of the vault, so it is inert until enrolled. |
| `tokenvault-fido2.service` | Stock `systemd-cryptsetup attach` of the inner layer, `fido2-device=auto`. Prompts **"Please enter security token PIN"**, then waits for the touch. |
| `tokenvault-key.service` | Puts the payload into systemd's password cache: the user key `cryptsetup` in root's user keyring, with a 120 s timeout |
| *gpt-auto's* `systemd-cryptsetup@root.service` | Unmodified (`tpm2-device=auto`, `tpm2-measure-pcr=yes`, `tpm2-measure-keyslot-nvpcr=cryptsetup`). It takes the cached passphrase before it would prompt. |
| `tokenvault-close.service` | Revokes and unlinks the cached key, closes both layers, unmounts the ESP, and seals PCR 11 (see below) |

All vault units are ordered `Before=systemd-cryptsetup@root.service`. If any step fails
(wrong PINs used up, key absent or untouched, foreign TPM, changed Secure Boot state), no
passphrase is cached and root shows its normal **passphrase prompt**. `rd.tokenvault=0`
disables the module, but the cmdline is sealed, so that is mainly for test images.

`SYSTEMD_CRYPTSETUP_USE_TOKEN_MODULE=0` on the vault units selects systemd's built-in
TPM2/FIDO2 code, which names the PIN it wants. `password-cache=no` on those units keeps the
PINs themselves out of the cache.

## PCR policy

- **PCR 11 (signed):** `ukify --measure --phases enter-initrd` signs PCR 11 with our PCR
  key. The outer layer is enrolled with
  `--tpm2-public-key=/usr/share/secureblue/uki/keys/PCR.pem --tpm2-public-key-pcrs=11`, so it
  opens only inside the initrd of **any UKI we signed**. Image updates need no re-enrollment.
- **PCR 7 (literal):** the Secure Boot state with our PK/KEK/db. Re-enroll if you change the
  keys, firmware Secure Boot settings or dbx.
- **Sealing after the initrd:** `systemd-pcrphase-initrd.service` (not masked) measures
  `leave-initrd` when it stops. If it is not active, `tokenvault-close` extends PCR 11 itself
  (`systemd-pcrextend tokenvault-sealed`). Either way, the booted system cannot unseal the
  TPM2 layer. `tokenvault verify` checks this.

Because of that seal, `enroll` cannot test the TPM2 layer from the running system. It
verifies the FIDO2 layer and the payload while the outer layer is still open with its tmpfs
bootstrap key. The TPM2 layer is proven by the next boot, which falls back to the passphrase
if anything is wrong.

## Use

```sh
run0 install -d -m 700 /etc/tokenvault
run0 install -m 600 /usr/share/tokenvault/tokenvault.conf.example /etc/tokenvault/tokenvault.conf
run0 nano /etc/tokenvault/tokenvault.conf   # TPM2_PIN, FIDO2_PIN (+ FIDO2_CURRENT_PIN)
run0 tokenvault enroll    # 2 touches; asks the current LUKS passphrase once
# reboot: TPM2 PIN, FIDO2 PIN, touch
run0 tokenvault verify    # structure + "TPM2 layer refuses to unseal after boot"
run0 tokenvault status
run0 tokenvault enroll    # rotate everything; the old vault keyslot is retired
run0 tokenvault remove    # kill the vault keyslot, delete the vault
```

Before the first enroll:

- Enroll the Secure Boot keys (`run0 /usr/libexec/scroll-secure/secure-boot-keys enroll`) and reboot, because PCR 7 must be
  final.
- With usbguard, allow the key first: `usbguard allow-device <n> -p`.

## Baked into the image

- **How it gets in:** `Containerfile` runs `COPY files-luks/ /`. `uki/Containerfile.uki`
  (via `rebuild-initrd.sh`, plain `dracut --no-hostonly`) then picks up
  `dracut.conf.d/90-tokenvault.conf`, which puts the module into the signed UKI's initrd.
- **What gets in:** the build context is `image/`, so nothing from `test/` can leak in.
- **Build check:** `/usr/libexec/tokenvault/check-uki [--tmpdir DIR] <uki.efi>...` fails
  unless the UKI meets all of these:
  - it has `.linux`, `.initrd`, `.cmdline`, `.pcrsig` and `.pcrpkey`
  - its cmdline does not contain `rd.tokenvault=0`
  - its initrd carries the tokenvault generator, systemd-cryptsetup, systemd-pcrextend, the
    gpt-auto generator and the TPM2/FIDO2 token plugins
  - its initrd carries `keyctl`, `umount`, `tail`, `tr`, `dd`, `sh` and `systemctl`
  - its initrd includes the dracut modules `tokenvault`, `systemd-cryptsetup`, `crypt`,
    `fido2`, `tpm2-tss` and `systemd-pcrphase`
  - `dm-crypt`, `loop`, `vfat`, `serpent_generic` and `xts` are in the initrd or built in

  The ~240 MB initrd is extracted into DIR (default `$TMPDIR`, else `/var/tmp`).
  `tokenvault verify` and `status` run the same check against every UKI on the ESP.

### Runtime dependencies

| Where | Needs |
|---|---|
| Initrd (dracut module) | `systemd-cryptsetup`, `systemd-pcrextend`, `keyctl` (keyutils), `umount`, `tail`, `tr`, `dd`, `sh`, `systemctl`; the dracut modules `systemd-cryptsetup crypt fido2 tpm2-tss systemd-pcrphase`; the kernel modules `loop dm_crypt xts serpent* vfat nls_* efivarfs` plus USB-HID/xHCI and `tpm_crb`/`tpm_tis` |
| Booted system (`tokenvault` CLI) | bash, `cryptsetup`, `systemd-cryptenroll`, `/usr/lib/systemd/systemd-cryptsetup`, `udevadm`, `python3` + `python3-fido2` (`fido2-pin.py`), util-linux (`findfs blkid findmnt mountpoint`), coreutils (`shred sync dd tr tail head`), `awk`, `openssl` (PCR-key comparison), `objdump`/`objcopy` (binutils) and `lsinitrd` (dracut) for `check-uki`; optional `tpm2_getcap` (tpm2-tools) for `status` |

### /etc and SELinux

`/etc/tokenvault` holds the plaintext PINs. Three things protect it:

1. **DAC:** tmpfiles creates the directory as root:root 0700, and the CLI refuses to read a
   `tokenvault.conf` that is not root:root 0600.
2. **SELinux type `tokenvault_conf_t`:** defined by the policy module
   `/usr/share/selinux/packages/tokenvault/tokenvault.cil`, installed at build time with
   `semodule -i`. It is a *security* file type, like `shadow_t`. It is neither
   `non_security_file_type` nor `non_auth_file_type`, so the broad "read all config" rules
   that many confined root daemons have on `etc_t` do not reach it. Measured in the image
   policy, the subjects that can still read it are:
   - unconfined domains (`files_unconfined_type`, including the `run0` shell's
     `unconfined_t` and the bootc/ostree update path's `install_t`)
   - `kernel_t`
   - whole-system backup and integrity tools: aide, amanda, bacula, snapper, quota, sectool,
     rhc playbooks

   Only unconfined domains and the kernel can write it. `restorecon`, `init_t` and
   `install_t` can relabel it.
3. **Labelling:** `tmpfiles.d/tokenvault.conf` has `d` (create, 0700) and `Z` (restore the
   label on every boot, which covers machines where the directory predates the module). The
   CLI also runs `restorecon` on any stray label before it reads the config.

The e2e `selinux` scenario proves this in the enforcing guest. A process that has really
transitioned into `NetworkManager_t` **can** read the PIN file while it is `etc_t`. After the
relabel it is **denied**, while an identical etc_t 0600 control file stays readable to it.

## On the real machine: order of steps

1. Install the image (`uki/install.sh`). Your LUKS passphrase becomes keyslot 0 and **stays
   as the recovery path**. `tokenvault` never removes it, and `remove` refuses to kill the
   last keyslot.
2. Enroll the Secure Boot keys (`run0 /usr/libexec/scroll-secure/secure-boot-keys enroll`). This changes PCR 7.
3. Reboot with Secure Boot on and check `bootctl status`.
4. If usbguard is active, allow the FIDO2 key (`usbguard allow-device <n> -p`).
5. Fill in `/etc/tokenvault/tokenvault.conf` (PINs) and run `run0 tokenvault enroll`.
6. Reboot, then enter the TPM2 PIN, the FIDO2 PIN and touch the key.
7. Run `run0 tokenvault verify`.

Lockouts:

- **TPM:** wrong TPM2 PINs count against the TPM's dictionary-attack lockout. Check it with
  `tokenvault status` (`TPM2_PT_LOCKOUT_COUNTER`, `MAX_AUTH_FAIL`). While locked out, boot
  with the passphrase.
- **FIDO2 key:** it blocks after 8 wrong PINs (3 per power-up). Resetting a blocked key wipes
  all of its credentials, so run `tokenvault enroll` again afterwards.

## Re-enrolling (`tokenvault enroll`) is required when

- **The PCR signing key (`uki/keys/PCR`) is rotated.** Re-enroll on every machine *before*
  booting an image signed with the new key, while the old image is still booted. Otherwise
  that boot falls back to the passphrase. `status` and `verify` compare the PCR key enrolled
  in the vault with `/usr/share/secureblue/uki/keys/PCR.pem` and warn when they differ.
- **The Secure Boot keys, db/dbx or firmware Secure Boot settings change**, because PCR 7
  changes.
- **The FIDO2 key is replaced or reset.**

## Post-quantum notes

- **Vault confidentiality is purely symmetric at 256-bit strength.** The layers are
  AES-256-XTS and Serpent-256-XTS, a cascade of two independent cipher families. Keyslots
  use 512-bit XTS with sha512. The payload has ~413 bits of entropy. Grover's algorithm
  leaves 128-bit security.
- **Classical parts:**
  - the TPM2 SRK and session salting (ECC P-256)
  - the PCR-signature check (RSA PCR key)
  - FIDO2 hmac-secret transport (ECDH P-256)

  Breaking any of them needs a capture of that bus or the chip, and opens only one layer.
  The other layer, and the AND, still hold.

## systemd 259 notes

- `--tpm2-with-pin` hashes the PIN with salted PBKDF2. The Argon2id options exist from 262
  on; `tokenvault` passes them only if `--help` lists them.
- The TPM2 PIN for enrollment comes from `$NEWPIN`. The FIDO2 PIN is answered on the
  ask-password socket by `askpass.py`.
- `askpass.py` runs its child with stdin on `/dev/null`. With a TTY on stdin,
  `systemd-cryptsetup` prompts on the TTY and skips the agent protocol.

## Tests

`test/bootc/` holds the e2e for this design. `lab-secureboot.sh` takes any `uki/keys`-style
public key directory, so OVMF can also enforce the real keys. Only a DEV db private key adds
the serial-console addon. It runs under KVM with:

- OVMF in Secure Boot custom mode with the dev PK/KEK/db
- swtpm
- the virtual CTAP2 key from `test/vfido`

The disk uses the `install.sh` layout: ESP 2G plus a LUKS2 root of type 8304. The image is
installed with `bootc install to-filesystem --bootloader=systemd --composefs-backend`.
