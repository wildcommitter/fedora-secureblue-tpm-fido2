#!/usr/bin/env bash
# LAB ONLY. Spawn a graphical frontend (VNC viewer) on the lab VM of
# image/local.sh. "Upsert": if the VM runs, attach to it; if not, start it
# headless first. A frontend this script opened earlier is replaced, not
# doubled. The viewer talks to QEMU over image/local/vm/vnc.sock (a unix
# socket, no TCP) and runs detached; closing it leaves the VM running.
#
#   image/upsert.sh            attach (start the VM first if needed)
#   image/upsert.sh -w         same, but wait for the viewer in the foreground
#   image/upsert.sh close      close the frontend (the VM keeps running)
#
#   VIEWER=auto|gvncviewer|remote-viewer   (auto: the first one installed)
#
# Stop the VM from inside the guest (poweroff) or with the QEMU monitor:
#   echo system_powerdown | socat - UNIX-CONNECT:image/local/vm/monitor.sock
set -euo pipefail

die() { echo "upsert.sh: $*" >&2; exit 1; }
log() { echo "upsert.sh: $*" >&2; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
L=$HERE/local
VM=$L/vm
SOCK=$VM/vnc.sock
PIDF=$VM/viewer.pid
VIEWER=${VIEWER:-auto}

vm_running() {
    [[ -f $L/.lock ]] || return 1
    # local.sh launch holds this lock for as long as QEMU runs.
    ! flock -n "$L/.lock" true
}

close_viewer() {
    local pid
    [[ -f $PIDF ]] || return 0
    pid=$(<"$PIDF")
    rm -f "$PIDF"
    # Only kill it if the pid is still our viewer (not a recycled pid).
    if [[ $pid =~ ^[0-9]+$ ]] && grep -qa -- "$SOCK" "/proc/$pid/cmdline" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        log "closed the previous frontend (pid $pid)"
    fi
}

pick_viewer() {
    case $VIEWER in
        auto)
            if command -v gvncviewer >/dev/null; then echo gvncviewer
            elif command -v remote-viewer >/dev/null; then echo remote-viewer
            else die "no VNC viewer: install gtk-vnc (gvncviewer) or virt-viewer (remote-viewer)"
            fi ;;
        gvncviewer|remote-viewer)
            command -v "$VIEWER" >/dev/null || die "VIEWER=$VIEWER is not installed"
            echo "$VIEWER" ;;
        *) die "VIEWER=$VIEWER: use auto, gvncviewer or remote-viewer" ;;
    esac
}

start_vm() {
    if [[ ! -f $VM/disk.raw ]]; then
        [[ -t 0 ]] || die "no lab disk yet: run image/local.sh override"
        log "no lab disk yet, running image/local.sh override first"
        "$HERE/local.sh" override
    fi
    log "starting the VM headless (log: $VM/launch.log, serial: $VM/serial.log)"
    rm -f "$SOCK"
    DISPLAY_BACKEND=none SERIAL=file setsid "$HERE/local.sh" launch \
        </dev/null >>"$VM/launch.log" 2>&1 &
    local pid=$! _
    for _ in $(seq 100); do
        [[ -S $SOCK ]] && return 0
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    tail -n 20 "$VM/launch.log" >&2 || true
    die "the VM did not come up"
}

WAIT=0
case ${1:-} in
    "") ;;
    -w|--wait) WAIT=1 ;;
    close) close_viewer; exit 0 ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument $1 (-w, close, -h)" ;;
esac

[[ -n ${WAYLAND_DISPLAY:-} || -n ${DISPLAY:-} ]] || die "no graphical session (WAYLAND_DISPLAY/DISPLAY unset)"
viewer=$(pick_viewer)

if vm_running; then
    [[ -S $SOCK ]] || die "the VM runs without $SOCK (started by an older local.sh); it has its own window, or restart it"
    log "VM is running, attaching"
else
    start_vm
fi

close_viewer
case $viewer in
    gvncviewer) cmd=(gvncviewer "$SOCK") ;;
    remote-viewer) cmd=(remote-viewer --title "scroll-secure-local" "vnc+unix://$SOCK") ;;
esac
if [[ $WAIT == 1 ]]; then
    exec "${cmd[@]}"
fi
setsid "${cmd[@]}" </dev/null >>"$VM/viewer.log" 2>&1 &
echo $! > "$PIDF"
log "frontend: $viewer (pid $!), log $VM/viewer.log"
