#!/usr/bin/env bash
# Rotates all four factors: new FIDO2 credential, new TPM2 seal, new
# passwords. Enrolls the new combined key into a fresh keyslot first,
# verifies it, and only then removes the previous MFA keyslot. The
# fallback password keyslot (if you still have one) is never touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

[ "$(id -u)" -eq 0 ] || hb_die "run as root (sudo ./rotate.sh)"

OLD_SLOT="$(cat "${HB_DIR}/keyslot" 2>/dev/null || true)"
[ -n "$OLD_SLOT" ] || hb_die "no existing MFA keyslot recorded — use enroll.sh instead"

NEW_SLOT=""
for candidate in 1 2 3 4 5 6 7; do
    [ "$candidate" = "$OLD_SLOT" ] && continue
    if ! cryptsetup luksDump "$LUKS_DEVICE" | grep -q "^  ${candidate}: "; then
        NEW_SLOT="$candidate"
        break
    fi
done
[ -n "$NEW_SLOT" ] || hb_die "no free keyslot found in range 1-7"

echo "== Rotating hardened-boot factors: slot ${OLD_SLOT} -> ${NEW_SLOT} =="
echo "This overwrites your FIDO2 credential, TPM2 seal, and salt files."
echo "You will need to set two new passwords and touch your key twice."
read -r -p "Continue? [y/N] " confirm
[ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { echo "Aborted."; exit 1; }

# Force fresh salt/credential/seal by clearing prior artifacts; enroll.sh
# regenerates whatever is missing.
rm -f "${HB_DIR}/salt.bin" "${HB_DIR}/fido2"/* "${HB_DIR}/tpm2/sealed.cred"

"${SCRIPT_DIR}/enroll.sh" "$NEW_SLOT"

echo
echo "New MFA keyslot ${NEW_SLOT} verified. Removing previous MFA keyslot ${OLD_SLOT}..."
cryptsetup luksKillSlot "$LUKS_DEVICE" "$OLD_SLOT"
echo "Done. If you already ran install.sh, re-run it if agent.sh/common.sh changed"
echo "(they didn't in a plain rotation), otherwise no initramfs rebuild is needed —"
echo "the agent re-reads ${HB_DIR} contents from the initramfs image, so run:"
echo "  sudo mkinitcpio -P"
echo "to bundle the freshly rotated secrets into the initramfs."
