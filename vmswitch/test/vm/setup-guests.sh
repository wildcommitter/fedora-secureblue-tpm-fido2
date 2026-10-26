#!/bin/bash
# Runs inside the lab VM (vmswitch KVM e2e): builds the nested guests' initrd from the
# lab VM's own binaries and modules, and defines guests ga, gb (network "shared") and
# gc (uplink) with libvirt, direct kernel boot, serial to a file. Lab only.
#   setup-guests.sh <dir with nested-init.sh>
set -euo pipefail
die() { echo "setup-guests: $*" >&2; exit 1; }
SRC=${1:?dir}
K=$(uname -r)
B=/var/lib/libvirt/boot
R=$(mktemp -d)
mkdir -p "$B" "$R"/{proc,sys,dev,etc,usr/bin,usr/lib64,usr/lib/modules}
# usrmerge and the sbin merge, like the host: /init is #!/bin/bash, command -v
# names /usr/sbin, ldd names /lib64.
for l in bin sbin; do ln -s usr/bin "$R/$l"; done
ln -s usr/lib64 "$R/lib64"
ln -s bin "$R/usr/sbin"
ln -s usr/lib "$R/lib"
for b in bash ip ping modprobe cat sed tr sleep mount paste; do
    p=$(command -v "$b") || die "no $b"
    install -D "$p" "$R$p"
    ldd "$p" | grep -o '/[^ ]*' | while read -r l; do install -D "$l" "$R$l"; done
done
install -D -m 0755 "$SRC/nested-init.sh" "$R/init"
M=/usr/lib/modules/$K
mkdir -p "$R$M"
cp -a "$M"/modules.* "$R$M/"
for d in kernel/drivers/net kernel/drivers/virtio kernel/drivers/usb kernel/drivers/hid kernel/net/core; do
    [[ -d $M/$d ]] && { mkdir -p "$R$M/$(dirname "$d")"; cp -a "$M/$d" "$R$M/$d"; }
done
(cd "$R" && find . | cpio -o -H newc --quiet | gzip -1) > "$B/vsw-initrd.img"
# The sealed image has no vmlinuz: the kernel is only in the UKI. Take the .linux
# section (PE/COFF) out of the first UKI found on the ESP or in the image.
python3 -I - "$K" "$B/vsw-vmlinuz" <<'PY' || die "no UKI with a .linux section"
import glob, struct, sys
k, out = sys.argv[1:]
for f in sorted(glob.glob("/boot/EFI/Linux/*.efi") + glob.glob("/efi/EFI/Linux/*.efi")
                + glob.glob(f"/usr/lib/modules/{k}/*.efi") + glob.glob("/boot/**/*.efi", recursive=True)):
    d = open(f, "rb").read()
    if d[:2] != b"MZ":
        continue
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    nsec, optsz = struct.unpack_from("<HH", d, pe + 6)[0], struct.unpack_from("<H", d, pe + 20)[0]
    sec = pe + 24 + optsz
    for i in range(nsec):
        name, vsize, _, rawsize, rawptr = struct.unpack_from("<8sIIII", d, sec + 40 * i)
        if name.rstrip(b"\0") == b".linux":
            open(out, "wb").write(d[rawptr:rawptr + min(vsize, rawsize)])
            print(f"setup-guests: kernel from {f}")
            sys.exit(0)
sys.exit(1)
PY
rm -rf "$R"
# virtqemud makes its log dir only once a guest has run; the serial files go there.
install -d -m 0700 /var/log/libvirt/qemu
restorecon -R "$B" /var/log/libvirt

mk() {  # mk <guest> <ip> <gw> <pings>
    local xml
    xml=$(vmswitch xml "$1" eth0 | grep -v '^<!--')
    cat > "/tmp/$1.xml" <<XML
<domain type='kvm'>
  <name>$1</name>
  <memory unit='MiB'>384</memory>
  <vcpu>1</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <kernel>$B/vsw-vmlinuz</kernel>
    <initrd>$B/vsw-initrd.img</initrd>
    <cmdline>console=ttyS0 panic=-1 vsw.ip=$2 vsw.gw=$3 vsw.ping=$4</cmdline>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough'/>
  <on_reboot>destroy</on_reboot>
  <devices>
    <controller type='usb' model='qemu-xhci'/>
    $xml
    <serial type='file'><source path='/var/log/libvirt/qemu/$1.serial'/></serial>
    <console type='file'><source path='/var/log/libvirt/qemu/$1.serial'/></console>
  </devices>
</domain>
XML
    virsh -q -c qemu:///system define "/tmp/$1.xml"
}
vmswitch net add shared
for g in ga gb gc; do vmswitch nic add "$g" eth0; done
vmswitch plug ga eth0 shared
vmswitch plug gb eth0 shared
vmswitch plug gc eth0 uplink
mk ga 192.168.77.1/24 "" 192.168.77.2
mk gb 192.168.77.2/24 "" 192.168.77.1
mk gc 10.88.0.2/30 10.88.0.1 198.51.100.7,192.168.77.1,10.88.0.1
echo "setup-guests: ok"
