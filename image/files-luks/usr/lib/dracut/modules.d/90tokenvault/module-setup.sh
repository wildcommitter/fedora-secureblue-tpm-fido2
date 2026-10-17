#!/usr/bin/bash
# dracut module for tokenvault. Ships only a generator: the initramfs is
# generic and sealed into the signed UKI, so the generator discovers the ESP
# and the vault at boot (see tokenvault-generator.sh).

check() {
    require_binaries "$systemdutildir/systemd-cryptsetup" "$systemdutildir/systemd-pcrextend" \
        keyctl umount tail tr dd || return 1
    return 255
}

depends() {
    echo systemd-cryptsetup crypt fido2 tpm2-tss systemd-pcrphase
}

installkernel() {
    hostonly='' instmods loop dm_crypt xts \
        serpent_generic serpent-avx2 serpent-avx-x86_64 serpent-sse2-x86_64 \
        vfat nls_cp437 nls_iso8859-1 nls_utf8 efivarfs \
        usbhid hid-generic xhci-pci xhci-hcd ehci-pci tpm_crb tpm_tis
}

install() {
    inst_multiple umount tail tr dd sh keyctl systemctl "$systemdutildir/systemd-pcrextend"
    inst_script "$moddir/tokenvault-generator.sh" "$systemdutildir/system-generators/tokenvault-generator"
}
