# HANDOFF: tokenvault (TPM2+FIDO2 LUKS unlock on CachyOS), halted 2026-10-17

Stopped on request from session `hardening-b9` (project moving to secureblue / Fedora Atomic).

## Host state: nothing half-applied on the boot path

| Item | State |
|---|---|
| Root LUKS `nvme0n1p2` (`c077878a-…`) | **Untouched.** Only keyslot 0 exists. `cryptsetup`/`systemd-cryptenroll` were never run against it. |
| `/etc/mkinitcpio.conf`, `/etc/mkinitcpio.conf.d/` | Untouched. No `tokenvault.conf` drop-in. |
| `/etc/initcpio/install/tokenvault`, `/usr/local/lib/tokenvault`, `/usr/local/bin/tokenvault` | Never installed. |
| `/etc/crypttab`, `/etc/default/limine`, `/boot` (initramfs, `limine.conf`, `/boot/tokenvault`) | Untouched. The initramfs was never regenerated on the host. |
| Host TPM (`/dev/tpm0`) | Not used. All TPM tests ran on swtpm. |
| Real FIDO2 key (ExcelSecu, hidraw7) | Not used; PIN retries still 8/8. |

## One stray file to remove

`/etc/tokenvault/state` (root, 0600, **no secrets**) was written by a host-side component
test of `tokenvault enroll`. It ran against a throwaway loop-file target (`luks-hosttest`),
because `STATE_DIR` is hardcoded and ignores `TOKENVAULT_CONF`. It references nothing real.
Revert:

```bash
sudo rm -rf /etc/tokenvault
```

## Test harness: stopped

- vfido (`test/vfido/vfido.py`), swtpm and QEMU are no longer running.
- The USB gadget `/sys/kernel/config/usb_gadget/vfido` was removed. The modules
  `dummy_hcd`, `libcomposite` and `usb_f_hid` were unloaded.
- The loop devices are detached, and no `tv-*` dm mappings remain.
- Leftover lab data, safe to delete:
  - `test/vm/work/` (12 GB `disk.raw` guest image, plus artifacts)
  - `/tmp/claude-1000/-home-user-hardening/*/scratchpad/` (host test images and swtpm state)

## Where the work stopped

- **Done and verified on the host:** enroll, verify, rotate and status. The PINs were baked
  into the TPM2 policy and into the FIDO2 client PIN. The nested AES-256 / Serpent-256 vault
  opens only with TPM2+PIN followed by FIDO2+PIN+touch.
- **KVM e2e:** the guest image builds, and the recovery passphrase boot through plymouth
  works. The `setup` scenario (enroll/install inside the guest) had not completed yet. No
  boot scenarios with the initramfs hook have run.

## Findings that carry over to the Fedora / dracut redo

- systemd 262 `systemd-cryptenroll` reads the TPM2 PIN from `$NEWPIN`. It does **not** read
  the FIDO2 PIN from the environment: it asks via ask-password. `lib/askpass.py` answers
  those prompts non-interactively.
- systemd 262 `--tpm2-with-pin=yes` hardens the PIN with Argon2id, auto-sized up to 50% of
  RAM and one lane per CPU. Pin it with `--tpm2-argon2id-memory` and `--tpm2-argon2id-parallelism`.
- `rd.luks.uuid=` on the cmdline makes the initrd generator skip other crypttab entries.
  Extra volumes need static units or their own `rd.luks.*` entries.
- `SYSTEMD_CRYPTSETUP_USE_TOKEN_MODULE=0` gives clear "TPM2 PIN" / "security token PIN"
  prompts, instead of the token module's generic "LUKS2 token PIN".
- `cryptsetup luksKillSlot --batch-mode` still reads stdin; use `</dev/null`.
- `test/vfido/` (a virtual CTAP2 key on a dummy_hcd gadget) and `test/e2e.py` are
  distro-agnostic and can be reused for the dracut version.
