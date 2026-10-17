#!/usr/bin/env bash
# Hardened Boot MFA unlock agent — runs inside the initramfs as
# hardened-boot-agent.service. Watches for the systemd ask-password
# request that systemd-cryptsetup issues for our root LUKS device, gathers
# password1 + password2 + FIDO2 touch + TPM2 unseal, derives the combined
# key, and answers the request via the systemd password-agent protocol
# (systemd-reply-password). The original password keyslot is left in
# place, so a bug here does not brick the machine: two escape hatches
# exist (kernel cmdline flag, and a per-attempt "skip" prompt) that hand
# the request back to the normal console/plymouth agent instead.
set -uo pipefail

HB_LIB=/usr/lib/hardened-boot/common.sh
# shellcheck source=lib/common.sh
. "$HB_LIB"

ASK_DIR=/run/systemd/ask-password
REPLY_TOOL=/usr/lib/systemd/systemd-reply-password
: "${UNLOCK_TIMEOUT:=180}"
: "${SKIP_WINDOW:=10}"

if grep -qw 'hardened_boot.disable' /proc/cmdline 2>/dev/null; then
    hb_log "disabled via kernel cmdline; standing down"
    exit 0
fi

find_ask_file() {
    local f id
    for f in "${ASK_DIR}"/ask.*; do
        [ -e "$f" ] || continue
        id=$(grep -m1 '^Id=' "$f" 2>/dev/null | cut -d= -f2-)
        case "$id" in
            *"${LUKS_UUID}"*) printf '%s' "$f"; return 0 ;;
        esac
    done
    return 1
}

handle_ask() {
    local ask="$1" socket ans pw1 pw2 fido2_hex tpm2_hex derived

    socket=$(grep -m1 '^Socket=' "$ask" 2>/dev/null | cut -d= -f2-)
    [ -n "$socket" ] && [ -S "$socket" ] || return 1

    command -v plymouth >/dev/null 2>&1 && plymouth --hide-splash 2>/dev/null

    echo
    echo "=== Hardened Boot: multi-factor unlock ==="
    echo "(type 'skip' + Enter within ${SKIP_WINDOW}s for the plain fallback password instead)"
    ans=""
    read -t "$SKIP_WINDOW" -r ans || true
    if [ "$ans" = "skip" ]; then
        hb_log "operator skipped MFA for this attempt"
        return 0
    fi

    pw1="$(hb_read_secret 'Password 1: ')"
    pw2="$(hb_read_secret 'Password 2: ')"

    echo "Touch your security key..."
    if ! fido2_hex="$(hb_fido2_assert_hex)"; then
        echo "FIDO2 step failed — will retry."
        unset pw1 pw2
        return 1
    fi

    echo "Reading TPM2-sealed factor..."
    if ! tpm2_hex="$(hb_tpm2_secret_hex)"; then
        echo "TPM2 step failed — will retry."
        unset pw1 pw2 fido2_hex
        return 1
    fi

    if ! derived="$(hb_derive_key_hex "$pw1" "$pw2" "$fido2_hex" "$tpm2_hex")"; then
        echo "Key derivation failed — will retry."
        unset pw1 pw2 fido2_hex tpm2_hex
        return 1
    fi
    unset pw1 pw2 fido2_hex tpm2_hex

    printf '%s' "$derived" | "$REPLY_TOOL" 1 "$socket"
    unset derived
    return 0
}

deadline=$(( $(date +%s) + UNLOCK_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ask="$(find_ask_file)"; then
        handle_ask "$ask" || sleep 1
    fi
    sleep 0.3
done

hb_log "timed out waiting for/answering the cryptsetup request; standing down"
exit 0
