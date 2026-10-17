#!/usr/bin/env bash
# Wires the hardened-boot MFA agent into the initramfs:
#   - copies agent.sh / common.sh onto the host
#   - installs + enables the hardened-boot-agent.service unit
#   - installs the mkinitcpio hook
#   - adds 'hardened-boot' to HOOKS in /etc/mkinitcpio.conf (before sd-encrypt)
#   - rebuilds the initramfs
#
# Run this only AFTER enroll.sh has succeeded and test-unlock.sh passes.
# The original password keyslot is not touched by this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

[ "$(id -u)" -eq 0 ] || hb_die "run as root (sudo ./install.sh)"
[ -f "${HB_DIR}/hardened-boot.conf" ] || hb_die "run enroll.sh first"
[ -f "${HB_DIR}/keyslot" ] || hb_die "no enrolled keyslot recorded — run enroll.sh first"

echo "== Hardened Boot: install into initramfs =="
echo
echo "This will:"
echo "  - install /usr/lib/hardened-boot/{agent.sh,common.sh}"
echo "  - install + enable /etc/systemd/system/hardened-boot-agent.service"
echo "  - install /usr/lib/initcpio/install/hardened-boot"
echo "  - add 'hardened-boot' to HOOKS in /etc/mkinitcpio.conf (backed up)"
echo "  - run mkinitcpio -P to rebuild every installed kernel's initramfs"
echo
echo "Your existing plain-password keyslot is left untouched. Two escape"
echo "hatches remain if the agent misbehaves at boot: type 'skip' at its"
echo "prompt, or add hardened_boot.disable=1 to the kernel cmdline from the"
echo "Limine boot menu (press 'e' to edit)."
echo
echo "Keep a CachyOS/Arch live USB on hand until you've confirmed a few"
echo "successful MFA boots."
echo
read -r -p "Proceed? [y/N] " confirm
[ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { echo "Aborted."; exit 1; }

install -d -m 755 /usr/lib/hardened-boot
install -m 644 "${SCRIPT_DIR}/lib/common.sh" /usr/lib/hardened-boot/common.sh
install -m 755 "${SCRIPT_DIR}/initramfs/agent.sh" /usr/lib/hardened-boot/agent.sh
hb_log "installed /usr/lib/hardened-boot/{agent.sh,common.sh}"

install -m 644 "${SCRIPT_DIR}/initramfs/hardened-boot-agent.service" \
    /etc/systemd/system/hardened-boot-agent.service
install -d -m 755 /etc/systemd/system/cryptsetup-pre.target.wants
ln -sf ../hardened-boot-agent.service \
    /etc/systemd/system/cryptsetup-pre.target.wants/hardened-boot-agent.service
hb_log "installed + enabled hardened-boot-agent.service"

install -m 644 "${SCRIPT_DIR}/initramfs/install/hardened-boot" \
    /usr/lib/initcpio/install/hardened-boot
hb_log "installed mkinitcpio hook"

MKCONF=/etc/mkinitcpio.conf
BACKUP="${MKCONF}.hardened-boot-backup.$(date +%Y%m%d%H%M%S)"
cp -a "$MKCONF" "$BACKUP"
hb_log "backed up $MKCONF -> $BACKUP"

if grep -qE '^\s*HOOKS=.*\bhardened-boot\b' "$MKCONF"; then
    hb_log "HOOKS already contains hardened-boot, leaving as-is"
elif grep -qE '^\s*HOOKS=.*\bsd-encrypt\b' "$MKCONF"; then
    sed -i -E 's/^(\s*HOOKS=\([^)]*)\bsd-encrypt\b/\1hardened-boot sd-encrypt/' "$MKCONF"
    hb_log "inserted 'hardened-boot' before 'sd-encrypt' in HOOKS"
else
    hb_die "could not find sd-encrypt in HOOKS= — edit $MKCONF manually, then re-run"
fi

echo
echo "New HOOKS line:"
grep -E '^\s*HOOKS=' "$MKCONF"
echo
diff -u "$BACKUP" "$MKCONF" || true
echo
read -r -p "Rebuild initramfs now with mkinitcpio -P? [y/N] " confirm2
if [ "$confirm2" = "y" ] || [ "$confirm2" = "Y" ]; then
    mkinitcpio -P
    echo
    echo "Done. Reboot when ready. Keep the live USB handy for the first few boots."
else
    echo "Skipped rebuild — run 'sudo mkinitcpio -P' manually when ready."
fi
