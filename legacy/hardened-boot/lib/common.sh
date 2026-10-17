#!/usr/bin/env bash
# Shared helpers for hardened-boot. Sourced by host-side scripts (enroll.sh,
# test-unlock.sh, rotate.sh, remove-fallback-keyslot.sh) and by the
# initramfs agent (initramfs/agent.sh, copied in verbatim at build time).
#
# Every function that touches secret material returns it on stdout as a
# lowercase hex string and nothing else — callers are responsible for
# unsetting the variables they store it in once used.

HB_CONF="${HB_CONF:-/etc/hardened-boot/hardened-boot.conf}"
if [ -f "$HB_CONF" ]; then
    # shellcheck source=/dev/null
    . "$HB_CONF"
fi
: "${HB_DIR:=/etc/hardened-boot}"
: "${HKDF_INFO:=hardened-boot-luks-v1}"

hb_log() { printf 'hardened-boot: %s\n' "$*" >&2; }
hb_die() { hb_log "FATAL: $*"; exit 1; }

# Prompt on stderr, read a line from stdin with echo disabled.
hb_read_secret() {
    local prompt="$1" secret
    printf '%s' "$prompt" >&2
    IFS= read -r -s secret
    printf '\n' >&2
    printf '%s' "$secret"
}

hb_hex_of_string() { printf '%s' "$1" | xxd -p | tr -d '\n'; }
hb_hex_of_file()   { xxd -p "$1" | tr -d '\n'; }

# args: pw1 pw2 fido2_hex tpm2_hex -> combined key, 128 lowercase hex chars
hb_derive_key_hex() {
    local pw1="$1" pw2="$2" fido2_hex="$3" tpm2_hex="$4"
    local pw1_hex pw2_hex ikm_hex salt_hex info_hex out

    [ -n "$fido2_hex" ] || { hb_log "derive: empty fido2 factor"; return 1; }
    [ -n "$tpm2_hex" ]  || { hb_log "derive: empty tpm2 factor"; return 1; }
    [ -f "${HB_DIR}/salt.bin" ] || { hb_log "missing ${HB_DIR}/salt.bin"; return 1; }

    pw1_hex=$(hb_hex_of_string "$pw1")
    pw2_hex=$(hb_hex_of_string "$pw2")
    # NUL-separated concatenation; the KDF only needs consistent inputs
    # across enroll/boot, not unambiguous field boundaries.
    ikm_hex="${pw1_hex}00${pw2_hex}00${fido2_hex}00${tpm2_hex}"
    salt_hex=$(hb_hex_of_file "${HB_DIR}/salt.bin")
    info_hex=$(hb_hex_of_string "$HKDF_INFO")

    out=$(openssl kdf -keylen 64 -kdfopt digest:SHA2-512 \
            -kdfopt "key:${ikm_hex}" -kdfopt "salt:${salt_hex}" \
            -kdfopt "info:${info_hex}" HKDF 2>/dev/null) || return 1
    printf '%s' "$out" | tr -d ': \n' | tr 'A-F' 'a-f'
}

hb_fido2_device_list() { fido2-token -L 2>/dev/null | cut -d: -f1; }

# Tries the enrolled credential against every attached FIDO2 device.
# Prints the hmac-secret extension output (hex) on the first success.
hb_fido2_assert_hex() {
    local rpid cred cdh salt dev out hmac_b64

    rpid=$(cat "${HB_DIR}/fido2/rpid" 2>/dev/null) || return 1
    cred=$(cat "${HB_DIR}/fido2/credential_id.b64" 2>/dev/null) || return 1
    cdh=$(cat "${HB_DIR}/fido2/client_data_hash.b64" 2>/dev/null) || return 1
    salt=$(cat "${HB_DIR}/fido2/hmac_salt.b64" 2>/dev/null) || return 1

    for dev in $(hb_fido2_device_list); do
        out=$(printf '%s\n%s\n%s\n%s\n' "$cdh" "$rpid" "$cred" "$salt" |
              fido2-assert -G -h -t up=true -t pin=false "$dev" 2>/dev/null) || continue
        hmac_b64=$(printf '%s\n' "$out" | sed -n '5p')
        [ -n "$hmac_b64" ] || continue
        printf '%s' "$hmac_b64" | base64 -d 2>/dev/null | xxd -p | tr -d '\n'
        return 0
    done
    return 1
}

# Unseals the TPM2-sealed random secret. Prints hex on success.
hb_tpm2_secret_hex() {
    [ -f "${HB_DIR}/tpm2/sealed.cred" ] || return 1
    systemd-creds decrypt "${HB_DIR}/tpm2/sealed.cred" - 2>/dev/null | xxd -p | tr -d '\n'
}
