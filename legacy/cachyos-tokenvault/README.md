# tokenvault — TPM2 + FIDO2 boot unlock for LUKS2 (CachyOS)

> **Superseded.** The machine moved to the sealed-UKI secureblue image in `image/`. The
> current tokenvault is in `image/files-luks/` (see `image/LUKS.md`), and its e2e is in
> `test/bootc/`. This directory is the original CachyOS/mkinitcpio version, kept for
> reference. Its harness uses the shared `test/e2e.py` and `test/vfido/` at the repo root;
> commands below are run from the repo root.


At boot you enter the **TPM2 PIN**, then the **FIDO2 PIN**, and **touch the
key**. Together they open a small encrypted *vault* on the boot partition.
The vault holds a long random passphrase (64 chars, ~420 bits) that is a
keyslot of the root LUKS2 volume, so root unlocks without being asked.

All three are required. Neither token, nor both PINs without the key, nor the
disk moved to another machine, will open the vault. The existing root
passphrase stays as the recovery path.

```
 ESP (/boot, FAT)                                     root LUKS2 (nvme0n1p2)
 └─ tokenvault/vault.img                              ┌──────────────────────┐
    ┌──────────────────────────────────────────┐      │ slot 0: your         │
    │ outer LUKS2  aes-xts-plain64 / 512-bit   │      │   passphrase (kept)  │
    │  token: systemd-tpm2 (PCR 7 + TPM2 PIN)  │      │ slot N: vault        │
    │  ┌────────────────────────────────────┐  │      │   passphrase ◄───────┼─┐
    │  │ inner LUKS2 serpent-xts / 512-bit  │  │      └──────────────────────┘ │
    │  │  token: systemd-fido2              │  │                               │
    │  │   (client PIN + user presence)     │  │                               │
    │  │  payload: 64-char passphrase ──────┼──┼───── keyfile ────────────────-┘
    │  └────────────────────────────────────┘  │
    └──────────────────────────────────────────┘
```

## How the PINs work ("baked into the tokens")

| Token | What the configured plaintext password becomes |
|---|---|
| TPM2 | The PIN in the TPM2 policy of the outer layer (`systemd-cryptenroll --tpm2-with-pin`). It is hardened with Argon2id (fixed 256 MiB, 4 lanes) before reaching the TPM, and wrong PINs count against the TPM's dictionary-attack lockout. |
| FIDO2 | The key's own **client PIN**. `enroll` sets it on a key that has none, keeps it if it already matches, and changes it when `FIDO2_CURRENT_PIN` holds the old PIN. The credential is enrolled with `--fido2-with-client-pin=yes --fido2-with-user-presence=yes`, so a PIN *and* a touch are required. The key enforces its own retry limit (8 on the ExcelSecu). |

The PINs live in plaintext in `/etc/tokenvault/tokenvault.conf` (root, 0600)
so that enrollment and rotation run unattended. That file is **never** put in
the initramfs. `tokenvault install` builds a test image and refuses to finish
if either PIN string shows up in it.

## Boot sequence (initramfs, systemd + sd-encrypt)

1. `run-tokenvault-esp.mount` mounts the ESP read-only at `/run/tokenvault/esp`.
2. `tokenvault-tpm2.service` runs `systemd-cryptsetup attach` on the vault
   file and prompts **"Please enter TPM2 PIN"**.
3. `tokenvault-fido2.service` attaches the inner layer, prompts
   **"Please enter security token PIN"**, then waits for the touch.
4. The root volume's initramfs crypttab entry uses
   `/dev/mapper/tokenvault-fido2` as its keyfile
   (`keyfile-size=64,keyfile-timeout=…`).
5. `tokenvault-close.service` closes both vault layers and unmounts the ESP
   before switch-root, so the running system never sees the vault secret.

If the vault does not open within `KEYFILE_TIMEOUT`, systemd falls back to
the normal **"Please enter passphrase for disk luks-…"** prompt. That happens
on a wrong PIN, a missing or untouched key, a foreign TPM, or a changed
PCR 7. Plymouth handles the prompts just as it does for your current
passphrase.

Only stock systemd code is on the unlock path; this project adds units and
crypttab lines, not a password agent. It does not touch the kernel cmdline:
`rd.luks.uuid=` stays as it is.

## Post-quantum choice for the vault

The vault's confidentiality rests only on symmetric primitives at the
256-bit level. Grover's algorithm halves that to 128-bit, which is the
accepted post-quantum margin.

- **Layers:** a cascade of `aes-xts-plain64` (outer) and
  `serpent-xts-plain64` (inner), each with a 512-bit XTS key (= AES-256 /
  Serpent-256). Two independent cipher families: a break of one still leaves
  the payload behind the other.
- **Keyslots** inherit the 512-bit segment cipher. The digest and keyslot KDF
  use `sha512`. The TPM2 PIN goes through Argon2id first.
- **Payload:** the root passphrase is 64 characters from an 88-symbol
  alphabet, about 413 bits, far beyond the reach of a quantum search.

What is *not* post-quantum, and what that exposes:

- **TPM2 sealing** uses an ECC P-256 SRK and parameter-encryption sessions
  (`tpm2-primary-alg: ecc`). A quantum attacker would also need the TPM chip,
  or a capture of the TPM bus during boot. Even then they only reach the outer
  layer, and the inner FIDO2 layer still holds.
- **FIDO2 hmac-secret** transport uses ECDH P-256 between host and key. A
  recorded USB trace from a boot could, with a quantum computer, reveal that
  boot's hmac-secret output, which opens the inner layer. The attacker would
  still have to get through the TPM2 layer.
- Neither TPM2 nor CTAP2 offers PQ key agreement today. The cascade is
  arranged so that breaking any one asymmetric piece is not enough.

## Install on this machine

```bash
sudo install -d -m 700 /etc/tokenvault
sudo install -m 600 tokenvault.conf.example /etc/tokenvault/tokenvault.conf
sudoedit /etc/tokenvault/tokenvault.conf      # set TPM2_PIN, FIDO2_PIN (+ FIDO2_CURRENT_PIN)
sudo ./tokenvault enroll    # 3 touches: create credential, enroll, verify
sudo ./tokenvault install   # hook + limine-mkinitcpio + initramfs self-check
sudo tokenvault verify      # optional: re-test any time, no reboot
```

Defaults already match this host: target `UUID=c077878a-…`, mapper
`luks-c077878a-…`, ESP `/boot`, PCR 7. Leave `TARGET_PASSPHRASE` empty to be
prompted once for your current passphrase.

Notes for this host:

- Keep **only one FIDO2 key plugged in** during `enroll`/`verify`
  (`FIDO2_DEVICE=auto`), or set `FIDO2_DEVICE=/dev/hidrawN`.
- `limine-mkinitcpio` is used to rebuild, because a plain `mkinitcpio -P`
  leaves Limine's `#hash` on `module_path` stale. Your `conf.d` drop-in
  (`sd-btrfs-overlayfs`) keeps working. tokenvault adds
  `/etc/mkinitcpio.conf.d/tokenvault.conf` with `HOOKS+=(tokenvault)`.
- PCR 7 = Secure Boot policy. It is stable across kernel and Limine updates.
  Toggling Secure Boot or enrolling keys changes it: boot once with the
  passphrase, then run `sudo tokenvault enroll` to reseal.

## Commands

| | |
|---|---|
| `tokenvault enroll` | Bakes the PINs into the tokens and builds a fresh vault in tmpfs. Verifies it through the boot code path, then adds and tests the new root keyslot. Swaps the vault on the ESP atomically, then kills the previous vault keyslot. Re-running it rotates everything. No initramfs rebuild needed. |
| `tokenvault verify` | Opens the installed vault exactly like the initramfs does (PINs from the config, one touch) and tests the result against the root keyslot. |
| `tokenvault install` | Installs to `/usr/local/lib/tokenvault`, adds the hook, rebuilds, and self-checks the image. |
| `tokenvault uninstall [--purge]` | Removes the hook and rebuilds. `--purge` also kills the vault keyslot (only if another keyslot remains) and deletes the vault. |
| `tokenvault status` | Enrollment, keyslot, tokens, FIDO2 PIN retries, TPM lockout counter. |

## Recovery

- **Any failure** → wait for the `KEYFILE_TIMEOUT` passphrase prompt and type
  your normal passphrase. Keyslot 0 is never touched.
- **Broken initramfs** → choose the `fallback` entry in Limine, or boot a live
  ISO, then `cryptsetup open` with your passphrase, chroot, and run
  `tokenvault uninstall`.
- **TPM lockout** after wrong PINs → it decays on its own
  (`tpm2_getcap properties-variable`); meanwhile use the passphrase.

## Tests

`test/e2e.py` boots a KVM guest that mirrors this machine's boot chain:
- linux-cachyos, LUKS2 + btrfs `@`, the same HOOKS including plymouth
- Limine with `limine-mkinitcpio`, stock OVMF measuring into an emulated
  TPM-CRB (swtpm)
- a **virtual CTAP2 key** (`test/vfido/`: CTAPHID over a dummy_hcd USB
  gadget, PIN protocols 1/2, hmac-secret, scriptable touch) passed in with
  QEMU `usb-host`

Your real TPM and FIDO2 key are never touched. Following the `~/edk2-patched`
lesson, the host `/dev/tpm0` is never passed through to an OVMF that would
extend its PCRs.

```bash
sudo legacy/cachyos-tokenvault/test/vm/build-guest.sh legacy/cachyos-tokenvault/test/vm/work     # ~2 min, uses the host pacman cache
test/e2e.py                                  # all scenarios (needs sudo for the USB gadget)
```

| Scenario | Checks |
|---|---|
| setup | Recovery boot through plymouth; `enroll` (PIN set on key, ≥3 touches) and `install` (self-check) inside the guest |
| happy | TPM2 PIN + FIDO2 PIN + exactly one touch; no passphrase prompt; vault closed and ESP unmounted after boot |
| wrong-tpm-pin / wrong-fido-pin | Wrong PIN is re-asked; the right one unlocks; the key counts the bad PIN |
| no-touch | PINs right, touch denied → vault shut → recovery passphrase |
| no-key | FIDO2 key absent → TPM2 alone is not enough → recovery passphrase |
| foreign-tpm | Same disk and key with another TPM → recovery passphrase |
| splash | The host's exact `quiet splash` boot, with PINs typed into plymouth (screenshots in `artifacts/`) |
| rotate | `enroll` again in the guest; the old keyslot is retired; boot with tokens |
| uninstall | `--purge` leaves only the recovery keyslot; the plain passphrase boot works |
