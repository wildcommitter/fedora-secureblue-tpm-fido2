#!/usr/bin/env bash
# LAB ONLY. Prepares Secure Boot for the sealed-UKI e2e:
#   1. OVMF vars in custom mode with exactly the given PK/KEK/db (PUBLIC certs
#      only, so this works for the real keys too), and
#   2. if a db PRIVATE key is given (DEV keys only), a UKI addon adding a
#      serial console to the sealed cmdline, which build-disk.sh drops onto
#      the lab disk's ESP (/loader/addons/). Without it, no addon is made
#      and the e2e has to drive plymouth on the VGA console.
#
#   test/bootc/lab-secureboot.sh <workdir> <keys-dir> [<db.key>]
#     <keys-dir>/{PK,KEK,db}/*.pem and <keys-dir>/GUID (as uki/keys/)
set -euo pipefail
W=$(readlink -f "${1:?workdir}")
K=$(readlink -f "${2:?keys dir (as uki/keys)}")
DBKEY=${3:+$(readlink -f "$3")}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$W"
podman build -q -t localhost/tokenvault-labtools -f "$HERE/Containerfile.labtools" "$HERE" >/dev/null
guid=$(tr -d '[:space:]' < "$K/GUID")
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$W/OVMF_VARS.template.fd"   # pairs with host OVMF_CODE.secboot.4m.fd
rm -f "$W/lab-serial-console.addon.efi"
podman run --rm --security-opt label=disable \
    -v "$K:/keys:ro" ${DBKEY:+-v "$DBKEY:/secrets/db.key:ro"} -v "$W:/w" \
    localhost/tokenvault-labtools bash -euc "
        virt-fw-vars -i /w/OVMF_VARS.template.fd -o /w/OVMF_VARS.sb.fd \
            --set-pk $guid /keys/PK/PK.pem --add-kek $guid /keys/KEK/KEK.pem \
            --add-db $guid /keys/db/db.pem --secure-boot --no-microsoft
        [ -f /secrets/db.key ] || exit 0
        ukify build --cmdline 'console=tty0 console=ttyS0,115200n8' \
            --signtool sbsign --secureboot-private-key /secrets/db.key \
            --secureboot-certificate /keys/db/db.pem \
            --output /w/lab-serial-console.addon.efi
        sbverify --cert /keys/db/db.pem /w/lab-serial-console.addon.efi
        virt-fw-vars -i /w/OVMF_VARS.sb.fd --print | grep -iE 'SecureBoot|SetupMode|PK|KEK|db' | head
    "
rm -f "$W/OVMF_VARS.template.fd"
echo "lab Secure Boot vars: $W/OVMF_VARS.sb.fd; serial addon: $([[ -f $W/lab-serial-console.addon.efi ]] && echo "$W/lab-serial-console.addon.efi" || echo 'none (no db key)')"
