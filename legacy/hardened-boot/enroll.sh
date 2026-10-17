#!/usr/bin/env bash
# Interactive, one-time (or re-run for rotate.sh) enrollment:
#   1. creates a FIDO2 credential on your security key (hmac-secret ext.)
#   2. seals a random secret to this machine's TPM2 (bound to PCR 7)
#   3. prompts for two passwords
#   4. derives one combined key via HKDF-SHA512 from all four factors
#   5. adds that combined key as a NEW LUKS keyslot
#
# The existing password keyslot is never touched or removed here. Run this
# with sudo, while the system is booted normally.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

[ "$(id -u)" -eq 0 ] || hb_die "run as root (sudo ./enroll.sh)"

TARGET_SLOT="${1:-1}"
case "$TARGET_SLOT" in ''|*[!0-9]*) hb_die "keyslot argument must be a number";; esac

WORKDIR="$(mktemp -d /run/hardened-boot-enroll.XXXXXX)"
chmod 700 "$WORKDIR"
cleanup() {
    find "$WORKDIR" -type f -exec shred -u {} + 2>/dev/null
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# ---- 0. bootstrap /etc/hardened-boot -------------------------------------
# Must run before anything below references $LUKS_DEVICE/$LUKS_UUID/etc.,
# since those only exist once the config is in place.
install -d -m 700 "$HB_DIR" "$HB_DIR/fido2" "$HB_DIR/tpm2"
if [ ! -f "$HB_CONF" ]; then
    install -m 600 "${SCRIPT_DIR}/config/hardened-boot.conf" "$HB_CONF"
    hb_log "installed default config to $HB_CONF"
fi
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
if [ ! -f "${HB_DIR}/salt.bin" ]; then
    umask 077
    openssl rand 32 > "${HB_DIR}/salt.bin"
    hb_log "generated HKDF salt at ${HB_DIR}/salt.bin"
fi

echo "== Hardened Boot enrollment =="
echo "Device: ${LUKS_DEVICE}"
echo "Target keyslot: ${TARGET_SLOT}"
echo

[ -b "$LUKS_DEVICE" ] || hb_die "not a block device: $LUKS_DEVICE"
cryptsetup isLuks "$LUKS_DEVICE" || hb_die "$LUKS_DEVICE is not a LUKS device"

if cryptsetup luksDump "$LUKS_DEVICE" | grep -q "^  ${TARGET_SLOT}: "; then
    hb_die "keyslot ${TARGET_SLOT} is already in use — pick a free slot: $0 <slot>"
fi

# ---- 1. FIDO2 credential ---------------------------------------------------
echo
echo "-- FIDO2 --"
mapfile -t devs < <(hb_fido2_device_list)
case "${#devs[@]}" in
    0) hb_die "no FIDO2 device detected — plug in your security key and retry" ;;
    1) FIDO2_DEV="${devs[0]}"; hb_log "using device ${FIDO2_DEV}" ;;
    *)
        echo "Multiple FIDO2 devices found:"
        select FIDO2_DEV in "${devs[@]}"; do [ -n "$FIDO2_DEV" ] && break; done
        ;;
esac

openssl rand 32 | base64 -w0 > "${WORKDIR}/cdh.b64"
openssl rand 32 | base64 -w0 > "${WORKDIR}/userid.b64"
printf '%s' "$FIDO2_RPID" > "${WORKDIR}/rpid"

{
    cat "${WORKDIR}/cdh.b64"; echo
    printf '%s\n' "$FIDO2_RPID"
    printf 'hardened-boot\n'
    cat "${WORKDIR}/userid.b64"; echo
} > "${WORKDIR}/cred_param"

echo "Touch your security key now to create the credential..."
if ! fido2-cred -M -h -i "${WORKDIR}/cred_param" "$FIDO2_DEV" es256 > "${WORKDIR}/cred_out" 2>"${WORKDIR}/cred_err"; then
    cat "${WORKDIR}/cred_err" >&2
    hb_die "fido2-cred failed — is the key's hmac-secret extension supported?"
fi
CRED_ID_B64="$(sed -n '5p' "${WORKDIR}/cred_out")"
[ -n "$CRED_ID_B64" ] || hb_die "could not parse credential id from fido2-cred output"

openssl rand 32 | base64 -w0 > "${WORKDIR}/hmac_salt.b64"

cp "${WORKDIR}/rpid" "${HB_DIR}/fido2/rpid"
printf '%s' "$CRED_ID_B64" > "${HB_DIR}/fido2/credential_id.b64"
cp "${WORKDIR}/cdh.b64" "${HB_DIR}/fido2/client_data_hash.b64"
cp "${WORKDIR}/hmac_salt.b64" "${HB_DIR}/fido2/hmac_salt.b64"
chmod 600 "${HB_DIR}"/fido2/*

echo "Touch your security key again to verify the hmac-secret extension..."
FIDO2_HEX="$(hb_fido2_assert_hex)" || hb_die "hmac-secret self-test failed right after enrollment"
hb_log "FIDO2 factor OK (${#FIDO2_HEX} hex chars)"

# ---- 2. TPM2 seal -----------------------------------------------------------
echo
echo "-- TPM2 --"
openssl rand 32 > "${WORKDIR}/tpm2_secret.bin"
systemd-creds encrypt --with-key=tpm2 --tpm2-pcrs="${TPM2_PCRS}" \
    "${WORKDIR}/tpm2_secret.bin" "${HB_DIR}/tpm2/sealed.cred"
chmod 600 "${HB_DIR}/tpm2/sealed.cred"

TPM2_HEX="$(hb_tpm2_secret_hex)" || hb_die "TPM2 unseal self-test failed right after sealing"
[ "$TPM2_HEX" = "$(hb_hex_of_file "${WORKDIR}/tpm2_secret.bin")" ] \
    || hb_die "TPM2 round-trip mismatch — do not proceed"
hb_log "TPM2 factor OK (bound to PCR ${TPM2_PCRS})"

# ---- 3. passwords -----------------------------------------------------------
echo
echo "-- Passwords --"
while :; do
    PW1="$(hb_read_secret 'Password 1: ')"
    PW1_CONFIRM="$(hb_read_secret 'Confirm password 1: ')"
    [ "$PW1" = "$PW1_CONFIRM" ] && [ -n "$PW1" ] && break
    echo "Mismatch or empty, try again." >&2
done
while :; do
    PW2="$(hb_read_secret 'Password 2: ')"
    PW2_CONFIRM="$(hb_read_secret 'Confirm password 2: ')"
    [ "$PW2" = "$PW2_CONFIRM" ] && [ -n "$PW2" ] && [ "$PW2" != "$PW1" ] && break
    echo "Mismatch, empty, or same as password 1 — try again." >&2
done
unset PW1_CONFIRM PW2_CONFIRM

# ---- 4. derive & enroll -----------------------------------------------------
echo
echo "-- Deriving combined key --"
DERIVED_HEX="$(hb_derive_key_hex "$PW1" "$PW2" "$FIDO2_HEX" "$TPM2_HEX")" \
    || hb_die "key derivation failed"
unset PW1 PW2 FIDO2_HEX TPM2_HEX

printf '%s' "$DERIVED_HEX" > "${WORKDIR}/newkey"
chmod 600 "${WORKDIR}/newkey"

echo
echo "Now enter your CURRENT existing passphrase to authorize adding the new keyslot."
cryptsetup luksAddKey "$LUKS_DEVICE" "${WORKDIR}/newkey" --key-slot "$TARGET_SLOT"

echo "${TARGET_SLOT}" > "${HB_DIR}/keyslot"

echo
echo "-- Self-test --"
if printf '%s' "$DERIVED_HEX" | cryptsetup open --test-passphrase "$LUKS_DEVICE" --key-file=-; then
    echo "PASS: the derived key opens keyslot ${TARGET_SLOT}."
else
    hb_die "self-test FAILED — the new keyslot does not open with the derived key. Investigate before rebooting."
fi
unset DERIVED_HEX

echo
echo "Enrollment complete. Next steps:"
echo "  1. sudo ./test-unlock.sh          # re-verify any time without touching the disk"
echo "  2. sudo ./install.sh              # wire the MFA agent into the initramfs"
echo "  3. reboot and test MFA unlock — keep a live USB on hand until you trust it"
echo "  4. only then: sudo ./remove-fallback-keyslot.sh"
