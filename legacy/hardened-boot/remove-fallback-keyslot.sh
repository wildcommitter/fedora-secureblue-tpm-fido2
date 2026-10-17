#!/usr/bin/env bash
# Destroys the ORIGINAL single-password keyslot, leaving the MFA-derived
# keyslot as the only way in. Irreversible. Only run this after you've
# rebooted successfully with MFA several times.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

[ "$(id -u)" -eq 0 ] || hb_die "run as root (sudo ./remove-fallback-keyslot.sh)"

FALLBACK_SLOT="${1:-0}"
MFA_SLOT="$(cat "${HB_DIR}/keyslot" 2>/dev/null || true)"
[ -n "$MFA_SLOT" ] || hb_die "no MFA keyslot recorded — run enroll.sh first"
[ "$FALLBACK_SLOT" != "$MFA_SLOT" ] || hb_die "refusing: that is the MFA keyslot, not the fallback"

echo "== Removing fallback keyslot ${FALLBACK_SLOT} =="
echo "This makes keyslot ${MFA_SLOT} (2 passwords + FIDO2 + TPM2) the ONLY"
echo "way to unlock ${LUKS_DEVICE}. There will be no plain-password fallback."
echo
echo "First, re-verifying the MFA keyslot currently works:"
"${SCRIPT_DIR}/test-unlock.sh" || hb_die "MFA self-test failed — will NOT remove the fallback"

echo
echo "Type exactly: REMOVE FALLBACK"
read -r confirm
[ "$confirm" = "REMOVE FALLBACK" ] || { echo "Aborted."; exit 1; }

cryptsetup luksKillSlot "$LUKS_DEVICE" "$FALLBACK_SLOT"
echo "Fallback keyslot ${FALLBACK_SLOT} removed. MFA (slot ${MFA_SLOT}) is now the only unlock method."
