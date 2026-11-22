#!/usr/bin/env bash
# vmgui wire e2e: the win11/macos path. Headless scroll (pixman) in the image
# rootfs, vmgui-host for a PROTO=wire VM started by exec_privileged, and the real
# vmgui-agent (its Linux demo backend) as the guest on vsock loopback (CID 1).
# Lab only.
#
#   vmgui/test/vmgui-wire-e2e.sh       (loads vsock_loopback with sudo if needed)
#
#   IMAGE=<rootfs>         image rootfs (default localhost/scroll-secure-rootfs)
#
# Checks: vmgui-wire runs confined (no_new_privs); the agent's window appears
# with the VM's border and its pixels; the compositor's configure reaches the
# guest; keyboard (wtype) and pointer (wlrctl, a new virtual device per call, so
# the seat's capabilities come and go) input arrive at the guest; a
# guest that breaks the protocol (bad HELLO, damage outside its window, oversized
# window) is dropped without touching the agent's windows; when the agent goes,
# its window does too.
#
# The repo's vmgui/host files are bind-mounted over the image's, so this tests
# the working tree; the agent is built from vmgui/guest/agent.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VG=$(dirname "$HERE")
IMAGE=${IMAGE:-localhost/scroll-secure-rootfs:latest}
TEST_IMAGE=${TEST_IMAGE:-localhost/vmgui-e2e:latest}
W=${WORK:-$HERE/work/wire-e2e}
CT=${CT_NAME:-vmgui-wire-e2e}
PORT=20001     # 20000 + CID 1

die() { echo "vmgui-wire-e2e: $*" >&2; exit 1; }

if [[ $(grep -c '^vsock_loopback ' /proc/modules || true) -eq 0 ]]; then
    sudo modprobe vsock_loopback || die "needs the vsock_loopback module"
fi

rm -rf "$W"
mkdir -p "$W/bin"
chmod 0777 "$W"
podman run --rm -v "$VG/guest/agent:/src:ro,Z" -v "$W/bin:/out:Z" -v vmgui-agent-gocache:/root/go \
    registry.fedoraproject.org/fedora:44 bash -euc '
dnf -q install -y golang >/dev/null 2>&1
cp -a /src /b && cd /b && go test ./... >/dev/null
CGO_ENABLED=0 go build -trimpath -o /out/vmgui-agent ./cmd/vmgui-agent'

empty=$(mktemp -d)
cleanup() {
    set +e
    [[ -n ${KEEP:-} ]] || podman rm -f "$CT" > /dev/null 2>&1   # KEEP=1: leave it for debugging
    rm -rf "$empty"
}
trap cleanup EXIT
podman build -q --build-arg IMAGE="$IMAGE" --build-context scrollrpm="$empty" \
    -t "$TEST_IMAGE" -f "$HERE/Containerfile.e2e" "$HERE" > /dev/null

podman rm -f "$CT" > /dev/null 2>&1 || true
# vsock isn't per network namespace; podman's seccomp denies AF_VSOCK (lab container).
podman run -d --init --name "$CT" --network host --security-opt seccomp=unconfined \
    -v "$VG/host/usr/libexec/vmgui:/usr/libexec/vmgui:ro,Z" \
    -v "$HERE/scroll-vmgui-wire.conf:/vgtest/scroll.conf:ro,Z" \
    -v "$HERE/wire-fuzz.py:/vgtest/wire-fuzz.py:ro,Z" \
    -v "$HERE/wl-probe.py:/vgtest/wl-probe.py:ro,Z" \
    -v "$W:/vgtest/work:Z" \
    --entrypoint sleep "$TEST_IMAGE" infinity > /dev/null
ct() { podman exec -i "$CT" "$@"; }

ct bash -euc "
useradd -m tester
useradd -m guest
install -d -m 0700 -o tester -g tester /run/user/tester
install -d -m 0755 /etc/vmgui
printf 'CID=1\nCOLOR=#ff00ff\nOS=win11\nPROTO=wire\n' > /etc/vmgui/win.conf
chmod 0644 /etc/vmgui/win.conf
"
ENV=(XDG_RUNTIME_DIR=/run/user/tester WLR_BACKENDS=headless WLR_RENDERER=pixman
     WLR_LIBINPUT_NO_DEVICES=1 USER=tester)
podman exec -d "$CT" runuser -u tester -- env "${ENV[@]}" sh -c \
    'exec dbus-run-session -- scroll -c /vgtest/scroll.conf > /vgtest/work/scroll.log 2>&1'
sock=
for _ in $(seq 1 40); do
    sock=$(ct sh -c 'cd /run/user/tester && ls wayland-* 2>/dev/null' | grep -v '\.lock$' | head -1 || true)
    [[ -n $sock ]] && break
    sleep 0.25
done
[[ -n $sock ]] || { cat "$W/scroll.log"; die "scroll did not start"; }
ENV+=(WAYLAND_DISPLAY=$sock)
as_tester() { ct runuser -u tester -- env "${ENV[@]}" "$@"; }

pass=0 fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
wait_for() {   # <file> <regex> <seconds>
    local i
    for i in $(seq 1 $(($3 * 4))); do
        grep -qE -- "$2" "$1" 2> /dev/null && return 0
        sleep 0.25
    done
    return 1
}
shot() {   # <name> <mode> <hex>: pixels matching in a grim screenshot
    as_tester grim -t ppm "/vgtest/work/$1.ppm"
    python3 -I "$HERE/ppm-count.py" "$W/$1.ppm" "$2" "$3"
}
agent_log=$W/agent.log

# 1. vmgui-host up; vmgui-wire (not waypipe) confined
if wait_for "$W/host-win.log" 'security context ready' 10 \
        && wait_for "$W/host-win.log" "listening on vsock port $PORT for CID 1" 5; then
    ok "vmgui-host created the scroll-vm context and listens on vsock"
else
    bad "vmgui-host start"
    cat "$W/host-win.log" "$W/scroll.log"
fi
pid=
for _ in $(seq 1 20); do
    pid=$(ct pgrep -u tester -f 'vmgui-wire -s' | head -1 || true)
    [[ -n $pid ]] && break
    sleep 0.25
done
if [[ -n $pid ]] && ct grep -qx 'NoNewPrivs:[[:space:]]*1' "/proc/$pid/status" \
        && ! ct pgrep -u tester -f '^/usr/bin/waypipe' > /dev/null; then
    ok "vmgui-wire runs instead of waypipe (Landlock via setpriv, no_new_privs)"
else
    bad "vmgui-wire not running confined"
    cat "$W/host-win.log"
fi

# 2. the agent's window: VM border, the demo's pixels, the compositor's size
before=$(shot before eq ff00ff)
podman exec -d "$CT" runuser -u guest -- sh -c \
    'exec /vgtest/work/bin/vmgui-agent -host-cid 1 -cid 1 -fps 10 > /vgtest/work/agent.log 2>&1'
wait_for "$agent_log" 'event resize' 15 || true
sleep 2
border=$(shot window eq ff00ff)
demo=$(shot window-demo red 40)
if ((before == 0 && border > 2000)); then
    ok "agent window drawn with the VM's border color ($border px)"
else
    bad "VM border: before=$before after=$border"
    cat "$agent_log" "$W/host-win.log"
fi
((demo > 20000)) && ok "the guest's pixels are on screen ($demo px of the demo window)" ||
    bad "guest pixels: $demo"
grep -qE 'event resize [0-9]+ [0-9]+' "$agent_log" &&
    ok "compositor configure reached the guest ($(grep -m1 -oE 'resize [0-9]+ [0-9]+' "$agent_log"))" ||
    bad "no CONFIGURE at the guest"

# 3. input: keyboard focus and keys, pointer motion and buttons
# wtype uploads its own keymap, so its keycodes aren't evdev's (a real keyboard's
# are): check that one press and its release arrive, whatever the code.
as_tester wtype -s 300 a
if wait_for "$agent_log" 'event key [0-9]+ true' 5 && wait_for "$agent_log" 'event key [0-9]+ false' 5 \
        && grep -q 'event focus' "$agent_log"; then
    ok "keyboard: focus, then a key press and release ($(grep -m1 -oE 'key [0-9]+ true' "$agent_log"))"
else
    bad "keyboard input"
    cat "$agent_log"
fi
# One virtual pointer stays plugged in, like a real mouse; otherwise each wlrctl
# call adds and removes the seat's only pointer, faster than any client can
# re-get its wl_pointer.
podman exec -d "$CT" runuser -u tester -- env "${ENV[@]}" python3 -I /vgtest/wl-probe.py hold-pointer
sleep 1
as_tester wlrctl pointer move 300 300
as_tester wlrctl pointer click left
if wait_for "$agent_log" 'event motion [0-9]+ [0-9]+' 5 && wait_for "$agent_log" 'event button 0x110 true' 5 \
        && wait_for "$agent_log" 'event button 0x110 false' 5; then
    ok "pointer: motion and left button as BTN_LEFT ($(grep -m1 -oE 'motion [0-9]+ [0-9]+' "$agent_log"))"
else
    bad "pointer input"
    cat "$agent_log"
fi

# 4. protocol violations drop that connection only
for case in bad-hello damage-outside oversized; do
    ct runuser -u guest -- python3 -I /vgtest/wire-fuzz.py "$case" 1 "$PORT" || true
done
if wait_for "$W/host-win.log" 'violation.*first message is not HELLO' 5 \
        && wait_for "$W/host-win.log" 'violation.*DAMAGE .* outside' 5 \
        && wait_for "$W/host-win.log" 'violation.*size 5000x10 out of range' 5; then
    ok "bad HELLO, out-of-window damage and an oversized window are refused"
else
    bad "protocol violations"
    cat "$W/host-win.log"
fi
sleep 1
still=$(shot after-fuzz red 40)
((still > 20000)) && ok "the agent's window survives other connections' violations" ||
    bad "agent window after fuzz: $still"

# 5. the window goes with the agent
ct pkill -u guest -f vmgui-agent || true
sleep 2
gone=$(shot gone red 40)
gb=$(shot gone-border eq ff00ff)
((gone == 0 && gb == 0)) && ok "window gone with the agent" || bad "window left: demo=$gone border=$gb"

echo "vmgui-wire-e2e: $pass passed, $fail failed"
((fail == 0))
