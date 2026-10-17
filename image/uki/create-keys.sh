#!/usr/bin/env bash
# scroll-secure: adapted from secureblue uki/create-uki-keys.sh (Apache-2.0).
#
# Creates this machine's own Secure Boot hierarchy (PK -> KEK -> db) and the
# PCR 11 policy signing key. Public halves go to uki/keys/ (built into the
# image); private halves go to $SECRETS_DIR, which never enters a build context.
#
#   SECRETS_DIR=/path/on/encrypted/usb uki/create-keys.sh
#
# Back up $SECRETS_DIR offline. Losing db.key/PCR.key means no more image
# updates that boot; losing PK.key/KEK.key means re-entering Setup Mode to
# change firmware keys.
set -euo pipefail

cd "$(dirname "$0")"
secrets="${SECRETS_DIR:-${HOME}/.local/share/scroll-secure/secrets}"
title="scroll-secure"
expiry_days=3650

if [[ -e keys || -e "${secrets}" ]]; then
    echo "keys/ or ${secrets} already exists; refusing to overwrite." >&2
    exit 1
fi

umask 077
mkdir -p "${secrets}" keys
chmod 0700 "${secrets}"
uuid=$(systemd-id128 new --uuid)
echo "${uuid}" > keys/GUID

for key in PK KEK db; do
    mkdir -p "keys/${key}"
    openssl req -new -x509 -nodes -newkey rsa:4096 -sha256 -days "${expiry_days}" \
        -subj "/CN=${title} ${key} $(date +%Y)/" \
        -keyout "${secrets}/${key}.key" -out "keys/${key}/${key}.pem" 2> /dev/null
    openssl x509 -outform DER -in "keys/${key}/${key}.pem" -out "keys/${key}/${key}.der"
    sbsiglist --owner "${uuid}" --type x509 \
        --output "keys/${key}/${key}.esl" "keys/${key}/${key}.der"
done

mkdir -p keys/PCR
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${secrets}/PCR.key"
openssl pkey -in "${secrets}/PCR.key" -pubout -out keys/PCR/PCR.pem

# PK self-signs and signs KEK; KEK signs db. The db.auth here holds only our
# db cert: enroll-secure-boot-keys adds the option ROM hashes at enrollment.
attr=NON_VOLATILE,RUNTIME_ACCESS,BOOTSERVICE_ACCESS,TIME_BASED_AUTHENTICATED_WRITE_ACCESS
sbvarsign --attr "${attr}" --key "${secrets}/PK.key" --cert keys/PK/PK.pem \
    --output keys/PK/PK.auth PK keys/PK/PK.esl
sbvarsign --attr "${attr}" --key "${secrets}/PK.key" --cert keys/PK/PK.pem \
    --output keys/KEK/KEK.auth KEK keys/KEK/KEK.esl
sbvarsign --attr "${attr}" --key "${secrets}/KEK.key" --cert keys/KEK/KEK.pem \
    --output keys/db/db.auth db keys/db/db.esl

chmod -R a+rX keys
echo "Public keys: ${PWD}/keys"
echo "Private keys: ${secrets} (back these up offline)"
