#!/usr/bin/env bash
# vmgui e2e: headless scroll (pixman) in the image rootfs, vmgui-host started by
# exec_privileged, and a "guest" waypipe server in the same container that
# reaches the host over vsock loopback (CID 1). Lab only.
#
#   vmgui/test/vmgui-e2e.sh            (loads vsock_loopback with sudo if needed)
#
#   IMAGE=<rootfs>         image rootfs (default localhost/scroll-secure-rootfs)
#   SCROLL_RPM_DIR=<dir>   test this scroll RPM instead of the image's
#
# Checks: the security context is up and the waypipe client runs with
# no_new_privs; an ordinary client can't commit the scroll-vm engine but can
# commit another; a guest app sees no privileged globals; its window gets the
# VM's border color; an X11 app through xwayland-satellite (the xorg variant)
# shows up too; a connection from a CID other than the VM's is refused;
# when the guest goes away its window does too.
#
# The repo's vmgui/host files are bind-mounted over the image's, so this tests
# the working tree. vmgui-guest itself needs a real VM (its CID); here the guest
# runs the same waypipe command with the loopback CID.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VG=$(dirname "$HERE")
IMAGE=${IMAGE:-localhost/scroll-secure-rootfs:latest}
TEST_IMAGE=${TEST_IMAGE:-localhost/vmgui-e2e:latest}
# Wiped at every run: its own subdir, so files kept next to it (a SCROLL_RPM_DIR
# under work/) survive.
W=${WORK:-$HERE/work/e2e}
CT=${CT_NAME:-vmgui-e2e}
LAB_PORT=20001     # 20000 + CID 1
OTHER_PORT=20005   # 20000 + CID 5

die() { echo "vmgui-e2e: $*" >&2; exit 1; }

if [[ $(grep -c '^vsock_loopback ' /proc/modules || true) -eq 0 ]]; then
    sudo modprobe vsock_loopback || die "needs the vsock_loopback module"
fi

empty=$(mktemp -d)
trap 'rm -rf "$empty"' EXIT
podman build -q --build-arg IMAGE="$IMAGE" --build-context scrollrpm="${SCROLL_RPM_DIR:-$empty}" \
    -t "$TEST_IMAGE" -f "$HERE/Containerfile.e2e" "$HERE" > /dev/null

if [[ -n ${SCROLL_RPM_DIR:-} ]]; then
    case $(readlink -f "$SCROLL_RPM_DIR")/ in
        "$(readlink -f "$W")"/*) die "SCROLL_RPM_DIR is inside the work dir $W, which each run wipes" ;;
    esac
fi
rm -rf "$W"
mkdir -p "$W"
chmod 0777 "$W"
cleanup() {
    set +e
    [[ -n ${KEEP:-} ]] || podman rm -f "$CT" > /dev/null 2>&1   # KEEP=1: leave it for debugging
    rm -rf "$empty"
}
trap cleanup EXIT

podman rm -f "$CT" > /dev/null 2>&1 || true
# vsock isn't per network namespace: share the host's like a guest would see it.
# podman's default seccomp profile denies socket(AF_VSOCK): unconfined (lab container).
podman run -d --init --name "$CT" --network host --security-opt seccomp=unconfined \
    -v "$VG/host/usr/libexec/vmgui:/usr/libexec/vmgui:ro,Z" \
    -v "$VG/host/usr/bin/vmgui:/usr/bin/vmgui:ro,Z" \
    -v "$HERE/wl-probe.py:/vgtest/wl-probe.py:ro,Z" \
    -v "$HERE/scroll-vmgui.conf:/vgtest/scroll.conf:ro,Z" \
    -v "$W:/vgtest/work:Z" \
    --entrypoint sleep "$TEST_IMAGE" infinity > /dev/null
ct() { podman exec -i "$CT" "$@"; }

ct bash -euc "
useradd -m tester
useradd -m guest
install -d -m 0700 -o tester -g tester /run/user/tester
install -d -m 0700 -o guest -g guest /run/user/guest
install -d -m 0755 /etc/vmgui
printf 'CID=1\nCOLOR=#ff00ff\n' > /etc/vmgui/lab.conf
printf 'CID=5\nCOLOR=#00ff00\n' > /etc/vmgui/other.conf
chmod 0644 /etc/vmgui/*.conf
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
GENV=(XDG_RUNTIME_DIR=/run/user/guest USER=guest WAYLAND_DISPLAY=wayland-vmgui)
as_guest() { ct runuser -u guest -- env "${GENV[@]}" "$@"; }
# The guest side: what vmgui-guest runs, with the loopback CID.
guest_server() {   # <port> <display> <command...>
    local port=$1 display=$2
    shift 2
    podman exec -d "$CT" runuser -u guest -- env "${GENV[@]}" sh -c \
        "exec waypipe --vsock -s 1:$port --no-gpu -c none --display $display server -- $* \
         >> /vgtest/work/guest.log 2>&1"
}

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
# Pixels of one exact color in a screenshot (grim's PPM output).
count_color() {   # <name> <rrggbb>
    as_tester grim -t ppm "/vgtest/work/$1.ppm"
    python3 -I - "$W/$1.ppm" "$2" << 'EOF'
import sys
data = open(sys.argv[1], "rb").read()
fields, pos = [], 0
while len(fields) < 4:
    while data[pos:pos + 1].isspace():
        pos += 1
    if data[pos:pos + 1] == b"#":
        pos = data.index(b"\n", pos)
        continue
    end = pos
    while not data[end:end + 1].isspace():
        end += 1
    fields.append(data[pos:end])
    pos = end
pix = data[pos + 1:]
want = bytes.fromhex(sys.argv[2])
print(sum(1 for i in range(0, len(pix) - 2, 3) if pix[i:i + 3] == want))
EOF
}

# 1. vmgui-host: context created over the privileged connection, vsock listener up
if wait_for "$W/host-lab.log" 'security context ready' 10 \
        && wait_for "$W/host-lab.log" "listening on vsock port $LAB_PORT for CID 1" 5; then
    ok "vmgui-host created the scroll-vm context and listens on vsock"
else
    bad "vmgui-host start"
    cat "$W/host-lab.log" "$W/scroll.log"
fi
wp=
for _ in $(seq 1 20); do
    wp=$(ct pgrep -u tester -f '^/usr/bin/waypipe .* client' | head -1 || true)
    [[ -n $wp ]] && break
    sleep 0.25
done
if [[ -n $wp ]] && ct grep -qx 'NoNewPrivs:[[:space:]]*1' "/proc/$wp/status"; then
    ok "waypipe client runs (Landlock via setpriv, no_new_privs)"
else
    bad "waypipe client not running confined"
    cat "$W/host-lab.log"
fi

# 2. scroll-vm is reserved to privileged clients
r=$(as_tester python3 -I /vgtest/wl-probe.py secctx scroll-vm)
if [[ $r == refused:* ]]; then ok "an ordinary client can't claim the scroll-vm engine ($r)"; else
    bad "ordinary client committed scroll-vm: $r"
fi
r=$(as_tester python3 -I /vgtest/wl-probe.py secctx flatpak)
[[ $r == committed ]] && ok "other sandbox engines still work" || bad "flatpak engine: $r"

# 3. a guest app: no privileged globals, VM frame color on its window
before=$(count_color before ff00ff)
guest_server "$LAB_PORT" wayland-vmgui sleep 120
for _ in $(seq 1 40); do
    as_guest test -S /run/user/guest/wayland-vmgui 2> /dev/null && break
    sleep 0.25
done
globals=$(as_guest python3 -I /vgtest/wl-probe.py globals || true)
echo "$globals" > "$W/guest-globals.txt"
priv=$(grep -E 'screencopy|image_copy_capture|export_dmabuf|session_lock|layer_shell|virtual_keyboard|virtual_pointer|data_control|input_method|security_context|foreign_toplevel|output_manager|output_power|gamma|workspace_manager|transient_seat|drm_lease' \
    <<< "$globals" || true)
if grep -qx xdg_wm_base <<< "$globals" && [[ -z $priv ]]; then
    ok "guest app sees xdg_wm_base and no privileged global"
else
    bad "guest globals: ${priv:-no xdg_wm_base}"
    cat "$W/guest-globals.txt"
fi
podman exec -d "$CT" runuser -u guest -- env "${GENV[@]}" foot --title guestwin sleep 60
sleep 3
after=$(count_color after ff00ff)
if ((before == 0 && after > 2000)); then
    ok "guest window drawn with the VM's border color ($after px)"
else
    bad "VM border color: before=$before after=$after"
    cat "$W/guest.log" "$W/host-lab.log"
fi
green=$(count_color green 00ff00)
((green == 0)) && ok "no other VM's color on it" || bad "other VM's color present ($green px)"

# 3b. the xorg variant (vmgui-guest-xorg): xwayland-satellite on the vmgui display
# as :7, an X11-only app (xterm, white background) through it
white0=$(count_color x11-before ffffff)
podman exec -d "$CT" runuser -u guest -- env "${GENV[@]}" sh -c \
    'exec xwayland-satellite :7 >> /vgtest/work/satellite.log 2>&1'
sleep 2
podman exec -d "$CT" runuser -u guest -- env DISPLAY=:7 xterm -bg white -fg black -title x11win -e sleep 60
sleep 4
white=$(count_color x11 ffffff)
if ((white > white0 + 50000)); then
    ok "X11 app through xwayland-satellite on the vmgui display ($((white - white0)) px of xterm)"
else
    bad "X11 app: white before=$white0 after=$white"
    cat "$W/satellite.log" "$W/guest.log"
fi

# 4. a connection from a CID other than the VM's is refused
guest_server "$OTHER_PORT" wayland-intruder foot --title intruder sleep 30
if wait_for "$W/host-other.log" 'refused vsock connection from CID 1' 10; then
    ok "connection from the wrong CID refused"
else
    bad "wrong CID not refused"
    cat "$W/host-other.log"
fi
sleep 2
green=$(count_color intruder 00ff00)
((green == 0)) && ok "no window from the wrong CID" || bad "wrong-CID window drawn ($green px)"

# 5. the guest goes away: so does its window
# By name: waypipe re-execs each connection as `waypipe ... server-conn`.
ct pkill -u guest -x waypipe || true
ct pkill -u guest -x foot || true
sleep 3
gone=$(count_color gone ff00ff)
((gone == 0)) && ok "window gone with the guest" || bad "VM window still drawn ($gone px)"

echo "vmgui-e2e: $pass passed, $fail failed"
((fail == 0))
