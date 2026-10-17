#!/usr/bin/env bash
# Reproduces the full boot-time derivation in userspace and checks it
# against the LUKS header with --test-passphrase (never activates a
# mapping, never touches the filesystem). Safe to run any number of times.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

[ "$(id -u)" -eq 0 ] || hb_die "run as root (sudo ./test-unlock.sh)"

echo "== Hardened Boot test-unlock =="
PW1="$(hb_read_secret 'Password 1: ')"
PW2="$(hb_read_secret 'Password 2: ')"

echo "Touch your security key..."
FIDO2_HEX="$(hb_fido2_assert_hex)" || hb_die "FIDO2 assertion failed"

echo "Unsealing TPM2 factor..."
TPM2_HEX="$(hb_tpm2_secret_hex)" || hb_die "TPM2 unseal failed"

DERIVED_HEX="$(hb_derive_key_hex "$PW1" "$PW2" "$FIDO2_HEX" "$TPM2_HEX")" \
    || hb_die "key derivation failed"
unset PW1 PW2 FIDO2_HEX TPM2_HEX

if printf '%s' "$DERIVED_HEX" | cryptsetup open --test-passphrase "$LUKS_DEVICE" --key-file=-; then
    echo "PASS: all four factors reproduce the enrolled key."
else
    echo "FAIL: this combination does not open ${LUKS_DEVICE}."
    unset DERIVED_HEX
    exit 1
fi
unset DERIVED_HEX
