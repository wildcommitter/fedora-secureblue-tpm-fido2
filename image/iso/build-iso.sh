#!/usr/bin/env bash
# Build the scroll-secure installer ISO: the official Fedora CoreOS live ISO
# (downloaded and GPG-verified by coreos-installer) with an embedded Ignition
# config that drops in uki/install.sh, the db cert (for the shim/MOK option),
# the cosign public key and the image reference. Nothing else is changed.
#
#   image/iso/build-iso.sh <image ref> [out dir]
#   image/iso/build-iso.sh ghcr.io/<owner>/scroll-secure:uki out/
#
# Boot it, then run `sudo scroll-secure-install` on the console. The installer
# pulls the image only if its cosign signature verifies against the embedded key.
# Needs podman. Works without the private keys: only public material goes in.
set -euo pipefail

die() { echo "build-iso: $*" >&2; exit 1; }

image_ref=${1:?usage: build-iso.sh <registry>/<owner>/scroll-secure:uki [out dir]}
out=${2:-out}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
image=$(dirname "${here}")
installer=quay.io/coreos/coreos-installer:release

for f in uki/install.sh uki/keys/db/db.der cosign.pub; do
    [[ -s "${image}/${f}" ]] || die "missing image/${f}"
done
[[ ${image_ref} == */*:* ]] || die "image ref must look like registry/owner/name:tag"

mkdir -p "${out}"
out=$(cd "${out}" && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# coreos-installer checks the stream metadata and the ISO's GPG signature.
podman run --rm --pull=always -v "${work}:/data:Z" -w /data "${installer}" \
    download -s stable -p metal -f iso -C /data
base=$(find "${work}" -maxdepth 1 -name 'fedora-coreos-*-live-iso.x86_64.iso' -print -quit)
[[ -n ${base} ]] || die "Fedora CoreOS ISO download failed"
fcos_version=$(basename "${base}" | sed -E 's/^fedora-coreos-(.*)-live-iso\.x86_64\.iso$/\1/')

# Ignition config for the live system (runs in RAM; nothing touches a disk
# until the user starts the installer and confirms the wipe).
python3 -I - "${image}" "${image_ref}" > "${work}/live.ign" << 'EOF'
import base64, json, sys
image, ref = sys.argv[1], sys.argv[2]

def data(b):
    return "data:;base64," + base64.b64encode(b).decode()

def file(path, content, mode=0o644):
    return {"path": path, "mode": mode, "overwrite": True, "contents": {"source": data(content)}}

def read(p):
    with open(f"{image}/{p}", "rb") as f:
        return f.read()

wrapper = f"""#!/bin/bash
# scroll-secure installer: wipes the disk you choose, after asking twice.
exec /var/lib/scroll-secure/uki/install.sh '{ref}' "$@"
""".encode()

motd = f"""
  scroll-secure installer  ({ref})

  1. Firmware Secure Boot should be in Setup Mode (keys cleared) if you want
     your own Platform Key; otherwise pick the shim option in the installer.
  2. Network must be up (the image is pulled and its cosign signature verified).
  3. Run:  sudo scroll-secure-install

  Docs: https://wildcommitter.github.io/fedora-secureblue-tpm-fido2/

""".encode()

autologin = b"""[Service]
ExecStart=
ExecStart=-/usr/sbin/agetty --autologin core --noclear %I $TERM
"""

print(json.dumps({
    "ignition": {"version": "3.4.0"},
    "storage": {"files": [
        file("/var/lib/scroll-secure/uki/install.sh", read("uki/install.sh"), 0o755),
        file("/var/lib/scroll-secure/uki/keys/db/db.der", read("uki/keys/db/db.der")),
        file("/var/lib/scroll-secure/cosign.pub", read("cosign.pub")),
        file("/usr/local/bin/scroll-secure-install", wrapper, 0o755),
        file("/etc/motd.d/50-scroll-secure.motd", motd),
        # FCOS turns off its live autologin when an Ignition config is
        # embedded; bring it back so the console lands on a shell (core has
        # passwordless sudo on the live system, which runs only in RAM).
        file("/etc/systemd/system/getty@tty1.service.d/50-autologin.conf", autologin),
        file("/etc/systemd/system/serial-getty@.service.d/50-autologin.conf", autologin),
    ]},
}))
EOF

iso="scroll-secure-installer-$(date -u +%Y%m%d).iso"
rm -f "${out}/${iso}" "${out}/${iso}.sha256"
podman run --rm -v "${work}:/data:Z" -v "${out}:/out:Z" -w /data "${installer}" \
    iso ignition embed -f -i live.ign -o "/out/${iso}" "/data/$(basename "${base}")"

cd "${out}"
chmod 0644 "${iso}"
{
    echo "# ${iso}: $(stat -c %s "${iso}") bytes, Fedora CoreOS ${fcos_version}, installs ${image_ref}"
    sha256sum "${iso}"
} > "${iso}.sha256"
cat "${iso}.sha256"
