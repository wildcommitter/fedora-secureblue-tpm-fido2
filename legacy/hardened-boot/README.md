# Hardened Boot — 4-factor LUKS unlock (CachyOS)

> **Superseded, kept for reference.** This was the first attempt (September 2026, CachyOS,
> mkinitcpio, Limine). It doesn't apply to the Fedora/secureblue image: there is no
> mkinitcpio or Limine, `/boot` is the ESP behind a sealed UKI, and the unlock is
> `image/files-luks/` (tokenvault, see `image/LUKS.md`). What carried over:
>
> | Here | In tokenvault |
> |---|---|
> | Password 1 + Password 2 + FIDO2 touch + TPM2, all required | TPM2 PIN (in the TPM policy) AND FIDO2 client PIN + touch, all required. The "passwords" are the tokens' own PINs |
> | HKDF of all factors into one keyslot | Two nested LUKS2 layers in `ESP:/tokenvault/vault.img`, one per token; the inner one holds the root keyslot's passphrase |
> | TPM2 sealed to PCR 7 | PCR 7 + signed PCR 11 (our PCR key) + PIN |
> | password agent in the initramfs | dracut generator + systemd-cryptsetup units, passphrase handed over in the kernel keyring |
> | `skip` / `hardened_boot.disable=1` | any failure falls back to the install passphrase (keyslot 0); `rd.tokenvault=0` exists but the cmdline is sealed in the UKI |
> | "Honest threat model": no Secure Boot, evil maid open | closed: own Secure Boot keys, signed UKI, composefs-verified `/usr` |
>
> `labvm/` holds only the scripts and notes; its disk images were not imported.

Unlocks the root LUKS2 volume (`/dev/nvme0n1p2`, UUID
`c077878a-836c-4414-8a17-55ad9ab1d401`) only when **all four** of the
following are presented together at boot:

1. Password 1
2. Password 2
3. A touch of your enrolled FIDO2 security key
4. This machine's TPM2 (sealed to PCR 7 — the Secure Boot policy state)

## Why this needed custom code

LUKS2 keyslots are OR'd: `cryptsetup` tries every enrolled keyslot and
succeeds if *any one* matches. There is no native way — not even with
`systemd-cryptenroll`'s built-in TPM2/FIDO2 support — to require several
keyslots at once. `systemd-cryptenroll --tpm2-with-pin=yes` or
`--fido2-with-client-pin=yes` each combine two factors *within* one
keyslot, but two such keyslots enrolled side by side are still
alternatives to each other, not a joint requirement.

To actually require all four factors simultaneously, this project instead:

- derives **one** combined secret from all four factors using
  HKDF-SHA512 (`openssl kdf ... HKDF`), and
- enrolls *only that derived secret* as a single new LUKS keyslot.

At boot, a small agent running inside the initramfs collects the same four
inputs, re-derives the same secret, and feeds it to `systemd-cryptsetup`
via systemd's password-agent protocol (`systemd-reply-password`). Get any
one factor wrong and the derived key simply doesn't match the keyslot —
there's no partial credit and no way to tell which factor was wrong.

Nothing secret is ever stored at rest. `/etc/hardened-boot/` (bundled into
the initramfs so the boot-time agent can read it) holds only non-secret
metadata:

| File | Contents | Secret? |
|---|---|---|
| `salt.bin` | HKDF salt | no |
| `fido2/credential_id.b64` | FIDO2 credential id | no — useless without the physical key |
| `fido2/rpid`, `client_data_hash.b64`, `hmac_salt.b64` | protocol parameters | no |
| `tpm2/sealed.cred` | TPM2-sealed random secret | no — only unsealable by *this* TPM chip in its current PCR-7 state |
| `keyslot` | which LUKS keyslot holds the derived key | no |

Both passwords are typed at every boot and never written anywhere.

## Honest threat model

This defends against a **stolen or seized, powered-off machine**: without
both passwords, the physical FIDO2 key, and this exact TPM in its current
state, the derived key cannot be reconstructed, so the data is
inaccessible.

It does **not** defend against a sophisticated evil-maid attack that
modifies the unencrypted `/boot` partition (`nvme0n1p1`, plain FAT32) while
the machine is out of your possession — Secure Boot is currently disabled
here, so nothing cryptographically verifies the initramfs/kernel before
they run. An attacker with that kind of access could replace `agent.sh`
with something that exfiltrates your passwords. Closing that gap means
enabling Secure Boot with your own keys (`sbctl`) and signing a measured
UKI — a separate, larger project, not done here. Treat this as raising the
bar against theft/seizure, not as tamper-evidence.

## Layout

```
config/hardened-boot.conf   machine-specific settings, copied to /etc/hardened-boot/
lib/common.sh                shared functions (KDF, FIDO2, TPM2 helpers)
enroll.sh                    one-time interactive setup — adds a NEW keyslot
test-unlock.sh                verify the derivation against the LUKS header, no reboot needed
rotate.sh                     regenerate all four factors, re-enroll, retire the old MFA slot
remove-fallback-keyslot.sh    irreversible: deletes the original single-password keyslot
install.sh                    wires the agent into the initramfs (mkinitcpio) and rebuilds it
uninstall.sh                  reverses install.sh (keeps your keyslots and secrets)
initramfs/agent.sh             the boot-time unlock agent
initramfs/hardened-boot-agent.service   systemd unit that runs it inside the initramfs
initramfs/install/hardened-boot         mkinitcpio install hook
```

## Usage order

```
sudo ./enroll.sh              # creates FIDO2 cred, TPM2 seal, sets 2 passwords,
                               # adds a NEW LUKS keyslot (existing password keyslot untouched)
sudo ./test-unlock.sh         # re-verify any time, safely, no reboot
sudo ./install.sh             # installs the initramfs agent, rebuilds initramfs
# reboot, test MFA unlock — several times
sudo ./remove-fallback-keyslot.sh   # only once you trust it (irreversible)
```

`enroll.sh` targets keyslot 1 by default (`./enroll.sh <slot>` to pick a
different free one) and leaves keyslot 0 — your current single password —
completely alone. That is your safety net: if the agent has a bug, you can
still boot the plain way.

## Escape hatches (read before your first reboot)

1. **Per-attempt skip.** The agent's very first prompt is: type `skip` and
   press Enter within `SKIP_WINDOW` seconds (default 10) to hand the
   request back to the normal console/plymouth password prompt, which
   still works against keyslot 0.
2. **Kernel cmdline flag.** At the Limine boot menu, press `e` to edit the
   command line and add `hardened_boot.disable=1`. The agent exits
   immediately without doing anything; boot proceeds exactly as before
   this project existed.
3. **Live USB.** Keep a CachyOS/Arch ISO on hand for the first several
   reboots regardless. If both of the above somehow fail, boot the live
   ISO, `cryptsetup luksOpen` with the plain password (keyslot 0 is still
   there), chroot in, and run `uninstall.sh`.

Until you've rebooted successfully with MFA a few times, **do not** run
`remove-fallback-keyslot.sh`.

## Design notes / non-obvious decisions

- **TPM2 PCR selection (PCR 7 only).** Secure Boot is disabled on this
  machine and boot is not measured (no UKI), so PCR 4/8/9
  (bootloader/kernel measurements) would drift on every kernel or
  bootloader update and cause spurious lockouts. PCR 7 (Secure Boot
  policy state) is stable as long as firmware Secure Boot settings don't
  change. If you enable Secure Boot later, re-seal via `rotate.sh`.
- **FIDO2 factor uses a non-resident credential, no device PIN, user
  presence only.** Using a resident (discoverable) credential or the
  device's own PIN would fold a fifth factor into what you asked for as
  "two passwords + two tokens." The credential id is stored non-secretly
  in `/etc/hardened-boot`; the touch itself is the "something you have"
  proof.
- **Why a password *agent* rather than a crypttab keyscript.** This
  system's initramfs is systemd-based (`sd-encrypt` in `HOOKS`, driven by
  `rd.luks.uuid=` on the kernel cmdline, no `/etc/crypttab`). systemd's
  crypttab parser deliberately dropped `keyscript=` support; the supported
  extension point is answering `systemd-ask-password` requests, which is
  exactly what `agent.sh` + `hardened-boot-agent.service` do, using the
  same `systemd-reply-password` helper systemd itself ships for this.
- **Plymouth.** The agent calls `plymouth --hide-splash` as soon as it
  sees the matching ask-password request, so its own text prompts are
  visible instead of racing plymouth's single-password splash.
- **HKDF construction.** `IKM = pw1 || 0x00 || pw2 || 0x00 || fido2_hmac_secret || 0x00 || tpm2_secret`,
  salt = random 32 bytes stored in `salt.bin`, info = `"hardened-boot-luks-v1"`,
  output = 64 bytes (128 hex chars), fed to `cryptsetup luksAddKey` as the
  new key material. All arithmetic happens as hex text end-to-end
  (`openssl kdf ... HKDF`) to avoid embedded-NUL/newline pitfalls with raw
  binary in shell variables.

## Maintenance

- **Kernel/system updates:** no action needed — PCR 7 sealing is stable
  across kernel updates (see above).
- **Changing a password, replacing the FIDO2 key, or after any firmware
  Secure Boot setting change:** run `sudo ./rotate.sh`, then
  `sudo mkinitcpio -P`, then reboot and confirm before trusting it.
- **Fully removing this project:** `sudo ./uninstall.sh` (initramfs side),
  then `sudo cryptsetup luksKillSlot <device> <slot>` for the MFA slot
  recorded in `/etc/hardened-boot/keyslot`, then `rm -rf /etc/hardened-boot`.
