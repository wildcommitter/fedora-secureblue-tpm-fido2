#!/usr/bin/bash
# systemd generator (initrd only) for tokenvault on the sealed-UKI image.
#
# Nothing machine-specific is on the kernel command line (it is baked into
# the signed UKI), so everything is discovered:
#   ESP   = the partition systemd-boot/stub booted from (LoaderDevicePartUUID)
#   vault = <ESP>/tokenvault/vault.img; all units are conditional on it, so
#           an image that never ran `tokenvault enroll` boots unchanged
#   root  = unlocked by systemd-gpt-auto-generator as systemd-cryptsetup@root;
#           tokenvault only puts the vault's passphrase into systemd's
#           password cache (user key "cryptsetup"), which that unit accepts
#           before it would prompt. No cache entry -> normal passphrase prompt.
#
# Units:
#   run-tokenvault-esp.mount   ESP, read-only
#   tokenvault-tpm2.service    outer layer: TPM2 (signed PCR 11 + PCR 7) + PIN
#   tokenvault-fido2.service   inner layer: FIDO2 client PIN + touch
#   tokenvault-key.service     vault payload -> password cache
#   tokenvault-close.service   wipe cache, close layers, unmount, seal PCR 11
#
# rd.tokenvault=0 on the command line disables all of it.
set -euf   # -f: no globbing of cmdline words

# TOKENVAULT_TEST_* overrides exist only for the offline unit test.
[ -e "${TOKENVAULT_TEST_INITRD_RELEASE:-/etc/initrd-release}" ] || exit 0
out=${1:?}

for arg in $(cat "${TOKENVAULT_TEST_CMDLINE:-/proc/cmdline}"); do
    [ "$arg" = rd.tokenvault=0 ] && exit 0
done

var=${TOKENVAULT_TEST_EFIVAR:-/sys/firmware/efi/efivars/LoaderDevicePartUUID-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f}
[ -r "$var" ] || exit 0
# 4 bytes of attributes, then the UUID as UTF-16LE
esp=$(tail -c +5 "$var" | tr -d '\000' | tr 'A-F' 'a-f')
case $esp in
    ????????-????-????-????-????????????) ;;
    *) echo "tokenvault-generator: unexpected LoaderDevicePartUUID '$esp'" >&2; exit 0 ;;
esac

mnt=/run/tokenvault/esp
vault=$mnt/tokenvault/vault.img
timeout=60s
scd=/usr/lib/systemd/systemd-cryptsetup
root_unit=systemd-cryptsetup@root.service

cat > "$out/run-tokenvault-esp.mount" <<EOF
[Unit]
Description=tokenvault: ESP (read-only)
DefaultDependencies=no
Before=umount.target
Conflicts=umount.target

[Mount]
What=/dev/disk/by-partuuid/$esp
Where=$mnt
Type=vfat
Options=ro,nodev,nosuid,noexec,fmask=0177,dmask=0077
EOF

# SYSTEMD_CRYPTSETUP_USE_TOKEN_MODULE=0 selects the built-in TPM2/FIDO2
# code, which prompts "TPM2 PIN" / "security token PIN" instead of the token
# module's anonymous "LUKS2 token PIN". password-cache=no keeps the PINs out
# of the cache the root unit reads.
cat > "$out/tokenvault-tpm2.service" <<EOF
[Unit]
Description=tokenvault: unlock TPM2 layer
DefaultDependencies=no
IgnoreOnIsolate=true
Conflicts=umount.target
RequiresMountsFor=$vault
ConditionPathExists=$vault
After=cryptsetup-pre.target systemd-udevd-kernel.socket systemd-udevd.service systemd-pcrphase-initrd.service
Before=cryptsetup.target umount.target $root_unit

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutSec=infinity
KeyringMode=shared
Environment=SYSTEMD_CRYPTSETUP_USE_TOKEN_MODULE=0
ExecStart=$scd attach tokenvault-tpm2 $vault none tpm2-device=auto,token-timeout=$timeout,readonly,password-cache=no
ExecStop=-$scd detach tokenvault-tpm2
EOF

cat > "$out/tokenvault-fido2.service" <<EOF
[Unit]
Description=tokenvault: unlock FIDO2 layer
DefaultDependencies=no
IgnoreOnIsolate=true
Conflicts=umount.target
After=tokenvault-tpm2.service
Before=cryptsetup.target umount.target $root_unit
ConditionPathExists=/dev/mapper/tokenvault-tpm2

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutSec=infinity
KeyringMode=shared
Environment=SYSTEMD_CRYPTSETUP_USE_TOKEN_MODULE=0
ExecStart=$scd attach tokenvault-fido2 /dev/mapper/tokenvault-tpm2 none fido2-device=auto,token-timeout=$timeout,readonly,password-cache=no
ExecStop=-$scd detach tokenvault-fido2
EOF

# The payload is the passphrase, NUL-padded to 4 KiB. systemd's password
# cache is the user key "cryptsetup" (NUL-separated list) in root's user
# keyring; KeyringMode=shared links that keyring into the unit's session.
cat > "$out/tokenvault-key.service" <<EOF
[Unit]
Description=tokenvault: hand the vault passphrase to $root_unit
DefaultDependencies=no
IgnoreOnIsolate=true
After=tokenvault-fido2.service
Before=cryptsetup.target $root_unit
ConditionPathExists=/dev/mapper/tokenvault-fido2

[Service]
Type=oneshot
RemainAfterExit=yes
KeyringMode=shared
ExecStart=/bin/sh -c 'id=\$\$(dd if=/dev/mapper/tokenvault-fido2 bs=4096 count=1 status=none | tr -d "\\\\000" | keyctl padd user cryptsetup @u) && keyctl timeout "\$\$id" 120'
EOF

# Runs whether the vault worked or the passphrase fallback was used.
# PCR 11: the TPM2 layer is sealed to the signed "enter-initrd" phase. If
# systemd-pcrphase-initrd is not active (it measures "leave-initrd" when it
# stops), extend PCR 11 here so the layer cannot be unsealed after boot.
cat > "$out/tokenvault-close.service" <<EOF
[Unit]
Description=tokenvault: close vault, drop cached passphrase, seal PCR 11
DefaultDependencies=no
After=cryptsetup.target $root_unit tokenvault-key.service tokenvault-fido2.service tokenvault-tpm2.service
Before=initrd.target initrd-switch-root.target
ConditionPathExists=$vault

[Service]
Type=oneshot
RemainAfterExit=yes
KeyringMode=shared
ExecStart=-/bin/sh -c 'id=\$\$(keyctl search @u user cryptsetup 2>/dev/null) && keyctl revoke "\$\$id" && keyctl unlink "\$\$id" @u'
ExecStart=-$scd detach tokenvault-fido2
ExecStart=-$scd detach tokenvault-tpm2
ExecStart=-/usr/bin/umount $mnt
ExecStart=-/bin/sh -c 'systemctl -q is-active systemd-pcrphase-initrd.service || /usr/lib/systemd/systemd-pcrextend --graceful tokenvault-sealed'
EOF

mkdir -p "$out/cryptsetup.target.wants" "$out/initrd.target.wants"
for u in tokenvault-tpm2 tokenvault-fido2 tokenvault-key; do
    ln -sf "../$u.service" "$out/cryptsetup.target.wants/$u.service"
done
ln -sf ../tokenvault-close.service "$out/initrd.target.wants/tokenvault-close.service"
