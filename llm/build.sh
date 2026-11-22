#!/usr/bin/env bash
# Build the llm-server image (llm/Containerfile) reproducibly and export it as an OCI
# archive for the installer payload (llm/README.md):
#
#   llm/build.sh [tag]        # default localhost/llm-server:latest -> llm/out/llm-server.oci.tar
#
# Same rules as image/build.sh: repro-lint first, rpms.lock as the only repo (each
# stage sees its own lines), RUN without network except the pinned llama.cpp clone,
# SOURCE_DATE_EPOCH (default: the last commit) and rewritten timestamps. Two builds
# give the same image ID and the same archive.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
die() { echo "llm/build.sh: $*" >&2; exit 1; }

tag=${1:-localhost/llm-server:latest}
sde=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2> /dev/null || true)}
[[ -n "${sde}" ]] || die "not a git checkout: set SOURCE_DATE_EPOCH"
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]] && [[ -n "$(git status --porcelain -- . ../image/rpms.lock)" ]]; then
    echo "warning: uncommitted changes; this build is not the commit's" >&2
fi

python3 -I ../image/repro-lint.py
lock=$(python3 -I ../image/rpmlock.py fetch)
repro=(
    --source-date-epoch "${sde}" --rewrite-timestamp
    --volume "${lock}:/rpmlock:ro,z" --volume "${lock}/repos.d:/etc/yum.repos.d:ro,z"
)
[[ -z "${NO_CACHE:-}" ]] || repro+=(--no-cache)

podman build "${repro[@]}" --build-context imagefiles=../image/files -t "${tag}" -f Containerfile .
# The archive is reproducible too: one fixed name inside (the installer loads it as
# that), and a tar with fixed order, owner and time instead of podman's save time.
podman tag "${tag}" localhost/llm-server:latest
mkdir -p out
rm -rf out/llm-server.oci.tar out/oci
podman save --format oci-dir -o out/oci localhost/llm-server:latest
tar -C out/oci --sort=name --mtime="@${sde}" --owner=0 --group=0 --numeric-owner \
    -cf out/llm-server.oci.tar .
rm -rf out/oci
id=$(podman image inspect "${tag}" --format '{{.Id}}')
sum=$(sha256sum out/llm-server.oci.tar)
echo "Built ${tag}: image ${id}, SOURCE_DATE_EPOCH=${sde}"
echo "out/llm-server.oci.tar sha256 ${sum%% *}"
