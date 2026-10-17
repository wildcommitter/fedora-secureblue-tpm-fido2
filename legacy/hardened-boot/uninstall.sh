#!/usr/bin/env bash
# Reverses install.sh: removes the mkinitcpio hook and HOOKS entry, disables
# and deletes the systemd unit, removes /usr/lib/hardened-boot, rebuilds the
# initramfs. Does NOT touch /etc/hardened-boot (your enrolled secrets/salt)
# or any LUKS keyslot — use remove-fallback-keyslot.sh or `cryptsetup
# luksKillSlot` separately if you also want the MFA keyslot gone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

[ "$(id -u)" -eq 0 ] || hb_die "run as root (sudo ./uninstall.sh)"

echo "This removes the MFA agent from the initramfs. Your enrolled secrets"
echo "in ${HB_DIR} and the LUKS keyslot are left untouched."
read -r -p "Proceed? [y/N] " confirm
[ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { echo "Aborted."; exit 1; }

rm -f /etc/systemd/system/cryptsetup-pre.target.wants/hardened-boot-agent.service
rm -f /etc/systemd/system/hardened-boot-agent.service
rm -f /usr/lib/initcpio/install/hardened-boot
rm -rf /usr/lib/hardened-boot

MKCONF=/etc/mkinitcpio.conf
if grep -qE '^\s*HOOKS=.*\bhardened-boot\b' "$MKCONF"; then
    BACKUP="${MKCONF}.hardened-boot-uninstall-backup.$(date +%Y%m%d%H%M%S)"
    cp -a "$MKCONF" "$BACKUP"
    sed -i -E 's/\bhardened-boot //' "$MKCONF"
    hb_log "removed 'hardened-boot' from HOOKS (backup: $BACKUP)"
fi

read -r -p "Rebuild initramfs now with mkinitcpio -P? [y/N] " confirm2
if [ "$confirm2" = "y" ] || [ "$confirm2" = "Y" ]; then
    mkinitcpio -P
else
    echo "Skipped rebuild — run 'sudo mkinitcpio -P' manually when ready."
fi
