#!/usr/bin/env bash
# Mutation test for repro-lint.py: break each premise in a copy of the build files and
# require repro-lint to fail with that premise's code (and pass on the real files).
#   ./repro-lint-test.sh
set -euo pipefail
die() { echo "repro-lint-test: $*" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
python3 -I "${here}/repro-lint.py" > /dev/null || die "fails on the real files"
pass=0
# mutate <code> <file> <python expression on s>
mutate() {
    rm -rf "${t:?}/image"
    mkdir -p "${t}/image"
    cp -a "${here}/." "${t}/image/"
    mkdir -p "${t}/lockscreen" && cp "${here}/../lockscreen/go.sum" "${t}/lockscreen/"
    mkdir -p "${t}/llm" && cp "${here}/../llm/Containerfile" "${here}/../llm/build.sh" "${t}/llm/"
    mkdir -p "${t}/desktop" && cp "${here}/../desktop/"{build.sh,mock-cfg.sh,scroll-secure-desktop.spec.in} "${t}/desktop/"
    python3 -I - "${t}/image/$2" "$3" <<'PY'
import sys
p, expr = sys.argv[1:]
s = open(p).read()
n = eval(expr)
assert n != s, f"mutation changed nothing: {expr}"
open(p, "w").write(n)
PY
    if out=$(python3 -I "${t}/image/repro-lint.py"); then
        die "$1 not caught: $2 <- $3"
    fi
    grep -c "^repro-lint: $1 " <<< "${out}" > /dev/null || die "$1 expected, got: ${out}"
    pass=$((pass + 1))
}
mutate P1 Containerfile 's.replace("@${FEDORA_DIGEST} AS rpm-build", " AS rpm-build")'
mutate P1 Containerfile 's.replace("ARG BASE_DIGEST=sha256:", "ARG BASE_DIGEST=latest:")'
mutate P1 uki/Containerfile.base 's.replace("chunkah@sha256:a2c6ef1cbf47f0c2360fd3c8e580ada5c809f17b2ffc4b0bff9fa5083b980769", "chunkah")'
mutate P1 Containerfile 's.replace("ARG MINIMAL_DIGEST=sha256:", "ARG MINIMAL_DIGEST=")'
mutate P2 Containerfile 's.replace("ARG DNF_VAR_rpmlock=rpm-build\n", "")'
mutate P2 uki/Containerfile.base 's.replace("ARG DNF_VAR_rpmlock=rootfs-base", "ARG DNF_VAR_rpmlock=nosuchstage")'
mutate P2 uki/Containerfile.kernel 's.replace("mv \"/usr/lib/modules", "dnf install -y foo; mv \"/usr/lib/modules")'
mutate P3 uki/Containerfile.uki 's.replace("as initramfs\n# scroll-secure: dracut --reproducible takes its timestamps from SOURCE_DATE_EPOCH\nARG SOURCE_DATE_EPOCH\n", "as initramfs\n")'
mutate P4 rpms.lock 's.replace("https://kojipkgs", "http://kojipkgs", 1)'
mutate P4 rpms.lock 's.replace("  https://", "0  https://", 1)'
mutate P5 build.sh 's.replace(" --rewrite-timestamp\n", "\n")'
mutate P5 build.sh 's.replace("podman build \"${repro[@]}\" \"${offline[@]}\" -t \"${p}-kernel\"", "podman build \"${offline[@]}\" -t \"${p}-kernel\"")'
mutate P5 build.sh 's.replace(":/etc/yum.repos.d:ro", ":/etc/yum.repos.d.x:ro")'
mutate P5 ../desktop/build.sh 's.replace(" --rewrite-timestamp\n", "\n")'
mutate P6 uki/scripts/uki.sh 's.replace("--signtool systemd-sbsign", "--signtool sbsign")'
mutate P6 uki/Containerfile.systemd-boot 's.replace("/usr/lib/systemd/systemd-sbsign sign", "sbsign")'
mutate P6 uki/scripts/uki.sh 's.replace("    --no-sign-kernel\n", "")'
mutate P7 Containerfile 's.replace(" && test \"$(git -C /src rev-parse HEAD)\" = \"${SCROLL_COMMIT}\"", "")'
mutate P7 Containerfile 's.replace("GOFLAGS=-mod=readonly go mod vendor", "go mod vendor", 1)'
mutate P7 ../desktop/scroll-secure-desktop.spec.in 's.replace(" GOPROXY=off", "")'
mutate P7 ../desktop/scroll-secure-desktop.spec.in 's.replace("GOFLAGS=-mod=vendor", "GOFLAGS=-mod=mod")'
mutate P7 Containerfile 's.replace("RUN --network=${RUN_NETWORK} /usr/libexec/scroll-secure/check-virt\n", "RUN --network=${RUN_NETWORK} curl -o /x https://example.org/x\n")'
mutate P8 Containerfile 's.replace("RUN --network=${RUN_NETWORK} semodule -i", "RUN semodule -i")'
mutate P8 Containerfile 's.replace("ARG RUN_NETWORK=none", "ARG RUN_NETWORK=host")'
mutate P8 Containerfile 's.replace("ARG DNF_VAR_rpmlock=rootfs\nARG RUN_NETWORK\n", "ARG DNF_VAR_rpmlock=rootfs\n")'
mutate P8 build.sh 's.replace("\"${offline[@]}\" -t \"${p}-base\"", "-t \"${p}-base\"")'
mutate P8 build.sh 's.replace("offline=(--network=none)", "offline=()")'
mutate P9 Containerfile 's.replace(" && dnf clean all \\\n && /usr/libexec/scroll-secure/dnf-settle \\\n", " && dnf clean all \\\n")'
mutate P9 uki/Containerfile.base 's.replace(" \\\n && /usr/libexec/scroll-secure/dnf-settle\n", "\n")'
mutate P9 uki/Containerfile.base 's.replace("remove-kernel-initrd.sh \\\n && /usr/libexec/scroll-secure/dnf-settle", "remove-kernel-initrd.sh")'
mutate P10 Containerfile 's.replace("%use_source_date_epoch_as_buildtime 1", "%_smp_build_ncpus 4")'
mutate P9 Containerfile 's.replace(" \\\n && /usr/libexec/scroll-secure/dnf-settle \\\n && rpm -q scroll", " \\\n && rpm -q scroll")'
mutate P10 Containerfile 's.replace("printf \x27%s\\n\x27 \x27%_buildhost scroll-secure\x27", "printf \x27%s\\n\x27 \x27%_smp_build_ncpus 4\x27")'
mutate P11 ../desktop/mock-cfg.sh 's.replace("config_opts[\x27use_bootstrap_image\x27] = False", "config_opts[\x27use_bootstrap_image\x27] = True")'
mutate P11 ../desktop/mock-cfg.sh 's.replace("config_opts[\x27rpmbuild_networking\x27] = False", "config_opts[\x27rpmbuild_networking\x27] = True")'
mutate P11 ../desktop/mock-cfg.sh 's.replace("reposdir=/dev/null", "reposdir=/etc/yum.repos.d")'
mutate P11 ../desktop/mock-cfg.sh 's.replace("config_opts[\x27environment\x27][\x27SOURCE_DATE_EPOCH\x27] = \x27${sde}\x27\n", "")'
mutate P11 ../desktop/scroll-secure-desktop.spec.in 's.replace("%global source_date_epoch_from_changelog 0\n", "")'
mutate P11 ../desktop/scroll-secure-desktop.spec.in 's.replace("%global clamp_mtime_to_source_date_epoch 1", "%global clamp_mtime_to_source_epoch 1")'
mutate P11 Containerfile 's.replace(" && /desktop/mock-cfg.sh > /etc/mock/scroll-secure.cfg \\\n", " \\\n")'
mutate P11 Containerfile 's.replace("mock -r scroll-secure --no-clean", "mock -r fedora-44-x86_64 --no-clean")'
mutate P10 Containerfile 's.replace("> ~/.rpmmacros", "> /tmp/rpmmacros")'
# llm/ (the model server image)
mutate P1 ../llm/Containerfile 's.replace("@${FEDORA_DIGEST} AS llm-build", " AS llm-build")'
mutate P1 ../llm/Containerfile 's.replace("ARG FEDORA_DIGEST=sha256:3", "ARG FEDORA_DIGEST=sha256:4")'
mutate P2 ../llm/Containerfile 's.replace("ARG DNF_VAR_rpmlock=llm-server\n", "")'
mutate P5 ../llm/build.sh 's.replace(" --rewrite-timestamp\n", "\n")'
mutate P7 ../llm/Containerfile 's.replace(" && test \"$(git -C /src rev-parse HEAD)\" = \"${LLAMACPP_COMMIT}\"", "")'
mutate P8 ../llm/Containerfile 's.replace("RUN --network=${RUN_NETWORK} cmake", "RUN cmake")'
mutate P8 ../llm/build.sh 's.replace("podman build \"${repro[@]}\"", "podman build --build-arg RUN_NETWORK=host \"${repro[@]}\"")'
echo "repro-lint-test: ${pass} mutations caught, real files pass"
