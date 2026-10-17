# hardening

Hardening for this workstation: a sealed, signed secureblue (Fedora Atomic) image with
scroll, plus everything needed to unlock the disk and the screen with hardware tokens.

| Path | What | Docs |
|---|---|---|
| `image/` | The OS image: secureblue Sericea + scroll, bootc/composefs, systemd-boot, a sealed UKI signed with our own keys. Includes install, key handling and the **pre-install checklist** | `image/README.md` |
| `image/files-luks/` | **tokenvault**: boot-time disk unlock. You enter the TPM2 PIN and the FIDO2 PIN and touch the key; together they open a vault on the ESP that holds the root keyslot's passphrase | `image/LUKS.md` |
| `lockscreen/` | **hardened-unlock**: the scroll lock screen. Unlock needs the FIDO2 key PIN, a touch and the account password, each asked separately | `lockscreen/README.md` |
| `test/` | KVM e2e for tokenvault (`test/bootc`: OVMF Secure Boot, swtpm, virtual FIDO2 key) and the shared harness and virtual key (`test/e2e.py`, `test/vfido`) | `image/LUKS.md` → Tests |

Tests never touch the host's TPM, its real FIDO2 key, its disks or its PAM. They use
swtpm, the virtual key in `test/vfido` and containers or VMs only. VM disks and other work
directories (`**/work/`), build outputs and private keys are kept out of git
(`.gitignore`). Private signing keys live in `SECRETS_DIR` on offline media, never here.
