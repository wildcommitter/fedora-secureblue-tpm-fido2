#!/usr/bin/env bash
# llm e2e on this host, as the normal user (no root, no /etc changes):
#
#   llm/test/llm-e2e.sh [MODEL.gguf]      # default: the 1.5B model in /srv/models
#
# A: llmctl-host and the guest llmctl clients (Python; Go if vmgui/guest/out/test/llmctl
#    exists) over vsock loopback (CID 1), with a stub state dir, a stub systemctl and a
#    stub /health server: every verb, the CID allowlist, bad input.
# B: the real server image (localhost/llm-server:latest, llm/build.sh) with llm-run's
#    settings on the host GPU: --network=none, read-only, no capabilities, unix socket
#    only, behind systemd-socket-proxyd. API key enforced, /slots off, a completion.
# The rootful, sealed-image side (units, SELinux, sysusers) is test/bootc's.
set -euo pipefail
die() { echo "llm-e2e: FAIL: $*" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "${here}/../.." && pwd)
model=${1:-/srv/models/qwen2.5-coder-1.5b/qwen2.5-coder-1.5b-q8_0.gguf}
t=$(mktemp -d)
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "${p}" 2> /dev/null || true; done
    podman rm -f llm-e2e > /dev/null 2>&1 || true
    [[ -n "${KEEP:-}" ]] && echo "kept ${t}" || rm -rf "${t:?}"
}
trap cleanup EXIT
pass=0
ok() { echo "ok   $*"; pass=$((pass + 1)); }

python3 -I -c 'import socket; s = socket.socket(socket.AF_VSOCK); s.bind((1, socket.VMADDR_PORT_ANY))' 2> /dev/null ||
    die "no vsock loopback (modprobe vsock_loopback)"

# ---------------------------------------------------------------- A: llmctl ---
st=${t}/state
mkdir -p "${st}/models" "${t}/bin" "${t}/etc"
head -c 1048576 /dev/urandom > "${t}/m1"
head -c 1048576 /dev/urandom > "${t}/m2"
s1=$(sha256sum < "${t}/m1" | cut -c1-64)
s2=$(sha256sum < "${t}/m2" | cut -c1-64)
bad=$(printf 'f%.0s' {1..64})
mv "${t}/m1" "${st}/models/${s1}.gguf"
mv "${t}/m2" "${st}/models/${s2}.gguf"
cp "${st}/models/${s2}.gguf" "${st}/models/${bad}.gguf"   # name doesn't match content
ln -s "models/${s1}.gguf" "${st}/current"
printf 'CTX=8192\nSLOTS=2\n' > "${t}/etc/llm.conf"
printf '# test\n1\n' > "${t}/etc/clients.conf"
printf '#!/bin/sh\necho "$*" >> %q\n' "${t}/systemctl.log" > "${t}/bin/systemctl"
chmod +x "${t}/bin/systemctl"
python3 -I - "${t}/health.sock" <<'PY' &
import http.server, os, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/health" else 404); self.end_headers()
    def log_message(self, *a): pass
    def address_string(self): return "unix"
class S(socketserver.UnixStreamServer):
    def get_request(self):
        r, _ = super().get_request(); return r, ("unix", 0)
S(sys.argv[1], H).serve_forever()
PY
pids+=($!)
port=$((21000 + RANDOM % 1000))
LLM_STATE=${st} LLM_CLIENTS=${t}/etc/clients.conf LLM_CONF=${t}/etc/llm.conf \
    LLM_SOCK=${t}/health.sock LLM_SYSTEMCTL=${t}/bin/systemctl \
    python3 -I "${repo}/llm/host/usr/libexec/llm/llmctl-host" --cid 1 --port "${port}" 2> "${t}/host.log" &
pids+=($!)
for _ in $(seq 50); do [[ -S "${t}/health.sock" ]] && break; sleep 0.1; done
sleep 0.5

export LLMCTL_HOST_CID=1 LLMCTL_PORT=${port}
ctl() { python3 -I "${repo}/vmgui/guest/linux/common/usr/bin/llmctl" "$@"; }
raw() { python3 -I -c '
import socket, sys
s = socket.socket(socket.AF_VSOCK); s.settimeout(10); s.connect((1, int(sys.argv[1])))
s.sendall(sys.argv[2].encode()); print(s.recv(65536).decode().strip())' "${port}" "$1"; }
field() { python3 -I -c 'import json, sys; r = json.load(sys.stdin); print(eval(sys.argv[1], {}, r))' "$1"; }

r=$(ctl status)
[[ $(field 'up' <<< "${r}") == True && $(field 'model' <<< "${r}") == "${s1}" &&
   $(field 'ctx' <<< "${r}") == 8192 && $(field 'slots' <<< "${r}") == 2 ]] || die "status: ${r}"
ok "status: up, model, ctx and slots from llm.conf"
r=$(ctl models)
[[ $(field '[m["sha256"] for m in models if m["current"]]' <<< "${r}") == "['${s1}']" &&
   $(field 'len(models)' <<< "${r}") == 3 ]] || die "models: ${r}"
ok "models: three, the current one marked"
ctl use "${s2}" > /dev/null || die "use ${s2} failed"
[[ $(readlink "${st}/current") == "models/${s2}.gguf" ]] || die "use: current not switched"
grep -cx -- '--no-block restart llm.service' "${t}/systemctl.log" > /dev/null || die "use: no restart"
ok "use: checked, switched, restarted"
if r=$(ctl use "${bad}"); then die "use of a mismatching file succeeded"; fi
[[ $(readlink "${st}/current") == "models/${s2}.gguf" ]] || die "bad use moved current"
grep -c 'match its sha256' <<< "${r}" > /dev/null || die "bad use: ${r}"
ok "use: a file that doesn't match its name is refused"
for req in "use ../../../etc/passwd" "use ${s1} x" "status now" "shell" "use"; do
    r=$(raw "${req}"$'\n')
    [[ $(field 'ok' <<< "${r}") == False ]] || die "accepted '${req}': ${r}"
done
r=$(raw "$(printf 'a%.0s' {1..400})")
[[ $(field 'ok' <<< "${r}") == False ]] || die "oversized line accepted: ${r}"
ok "bad requests refused (paths, extra args, unknown verbs, 400-byte line)"
ctl restart > /dev/null || die restart
ok "restart"
go=${repo}/vmgui/guest/out/test/llmctl   # vmgui/guest/build.sh
if [[ -x "${go}" ]]; then
    r=$("${go}" status) || die "Go llmctl: ${r}"
    [[ $(field 'model' <<< "${r}") == "${s2}" ]] || die "Go llmctl status: ${r}"
    if "${go}" use "${bad}" > /dev/null; then die "Go llmctl: bad use exited 0"; fi
    ok "Go llmctl (the win11/macos client, Linux build): status, refusal"
else
    echo "skip Go llmctl (no ${go}; vmgui/guest/build.sh)"
fi
printf '# nobody\n' > "${t}/etc/clients.conf"
if r=$(ctl status 2>&1); then die "a CID not in clients.conf got an answer: ${r}"; fi
grep -c 'CID 1 not in' "${t}/host.log" > /dev/null || die "refusal not logged"
ok "a CID not in clients.conf gets no answer (and is logged)"

# ------------------------------------------------------- B: the real server ---
[[ -r "${model}" ]] || die "no model ${model}"
podman image exists localhost/llm-server:latest || die "no localhost/llm-server:latest (llm/build.sh)"
mkdir -p "${t}/run" && chmod 0770 "${t}/run"
key=llm-e2e-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
# The render node's card: VRAM in use before and after the load (read-only sysfs).
vram=$(readlink -f /sys/class/drm/renderD128/device)/mem_info_vram_used
[[ -r "${vram}" ]] || die "no ${vram} (amdgpu)"
v0=$(cat "${vram}")
printf '%s' "${key}" > "${t}/key"
# llm-run's flags, minus what needs root (--user llm, --cgroups/--sdnotify, podman secret).
# --user 0:0 here is this user (rootless), still without capabilities; it owns ${t}/run.
podman run --name llm-e2e --rm -d --user 0:0 --env=MESA_SHADER_CACHE_DISABLE=true \
    --pull=never --network=none --read-only \
    --cap-drop=all --security-opt=no-new-privileges --umask=0007 --pids-limit=256 \
    --device=/dev/dri/renderD128 --security-opt=label=disable \
    --volume="${t}/run:/run/llm" \
    --volume="${model}:/models/model.gguf:ro" \
    --volume="${t}/key:/run/secrets/llm-api-key:ro" \
    localhost/llm-server:latest \
    --host /run/llm/llm.sock --port 8080 \
    -m /models/model.gguf -ngl 999 -c 4096 -np 2 \
    --api-key-file /run/secrets/llm-api-key --no-slots > /dev/null
[[ $(podman inspect llm-e2e --format '{{.HostConfig.NetworkMode}}') == none ]] || die "network not none"
hp=$((18100 + RANDOM % 800))
systemd-socket-activate -l "127.0.0.1:${hp}" /usr/lib/systemd/systemd-socket-proxyd "${t}/run/llm.sock" \
    2> "${t}/proxy.log" &
pids+=($!)
for _ in $(seq 120); do
    [[ $(curl -s -o /dev/null -w '%{http_code}' "127.0.0.1:${hp}/health") == 200 ]] && break
    podman container exists llm-e2e || die "server exited: $(podman logs llm-e2e 2>&1 | tail -5)"
    sleep 1
done
[[ $(curl -s -o /dev/null -w '%{http_code}' "127.0.0.1:${hp}/health") == 200 ]] || die "no /health"
ok "server up behind socket-proxyd, network none, unix socket only"
[[ $(curl -s -o /dev/null -w '%{http_code}' "127.0.0.1:${hp}/v1/models") == 401 ]] || die "no key: not 401"
[[ $(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong' "127.0.0.1:${hp}/v1/models") == 401 ]] ||
    die "wrong key: not 401"
ok "API key enforced (none, wrong: 401)"
c=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${key}" "127.0.0.1:${hp}/slots")
[[ "${c}" != 200 ]] || die "/slots is on"
ok "/slots off (${c})"
r=$(curl -sf -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' \
    "127.0.0.1:${hp}/v1/chat/completions" \
    -d '{"messages":[{"role":"user","content":"Reply with the single word: ready"}],"max_tokens":8,"temperature":0}') ||
    die "completion failed"
txt=$(field 'choices[0]["message"]["content"]' <<< "${r}")
[[ -n "${txt}" ]] || die "empty completion: ${r}"
v1=$(cat "${vram}")
size=$(stat -c %s "${model}")
(( v1 - v0 > size * 3 / 4 )) || die "VRAM grew by $(((v1 - v0) >> 20)) MiB for a $((size >> 20)) MiB model: not on the GPU"
ok "completion on the GPU (VRAM +$(((v1 - v0) >> 20)) MiB): ${txt:0:40}"

echo "llm-e2e: ${pass} checks passed"
