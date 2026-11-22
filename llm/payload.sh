#!/usr/bin/env bash
# Assemble an llm payload directory (llm/README.md): the server image archive, one
# model and SHA256SUMS pinning both. `llm import DIR` reads it, and so does
# `image/iso/build-iso.sh --payload DIR` (the installer's SCROLL-PAYLOAD partition).
#
#   llm/payload.sh MODEL.gguf [DIR]      # default DIR: llm/out/payload
#
# The archive comes from llm/build.sh (llm/out/llm-server.oci.tar). Files are hard
# links where possible. The model's licence is unknown: this directory, and an image
# made from it, stay on this machine.
set -euo pipefail

die() { echo "llm/payload.sh: $*" >&2; exit 1; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
model=${1:?usage: llm/payload.sh MODEL.gguf [DIR]}
dir=${2:-${here}/out/payload}
archive=${here}/out/llm-server.oci.tar

[[ "${model}" == *.gguf && -f "${model}" ]] || die "not a .gguf file: ${model}"
[[ -f "${archive}" ]] || die "no ${archive}: run llm/build.sh"
name=$(basename "${model}")
[[ "${name}" =~ ^[A-Za-z0-9._+-]+$ ]] || die "model file name must be [A-Za-z0-9._+-]: ${name}"

rm -rf "${dir}"
mkdir -p "${dir}"
for src in "${archive}" "${model}"; do
    ln "${src}" "${dir}/" 2> /dev/null || cp --reflink=auto "${src}" "${dir}/"
done
(cd "${dir}" && sha256sum llm-server.oci.tar "${name}" > SHA256SUMS)
du -sh "${dir}"
cat "${dir}/SHA256SUMS"
