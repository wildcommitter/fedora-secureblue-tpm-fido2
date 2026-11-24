#!/usr/bin/env bash
# LAB ONLY. Launch a locally built sealed image in a QEMU VM, or override the
# VM with a new image. Everything lives in image/local/ (git-ignored):
#
#   image/local/local.conf   settings (env vars win over the file)
#   image/local/keys/        PK/KEK/db certs (PEM) + GUID, read from the image
#   image/local/vm/          OVMF vars, disk.raw, swtpm state, serial log, sockets
#                            (vnc.sock: attach a frontend any time, image/upsert.sh)
#
#   image/local.sh init                write local.conf with the defaults
#   image/local.sh override [-y] [IMG] (re)build vars + disk from IMG (or IMAGE);
#                                      wipes the old disk, TPM state and vars
#   image/local.sh launch              boot the VM (overrides first if no disk)
#   image/local.sh status              settings and what exists
#   image/local.sh clean [-y]          delete image/local/vm and keys
#
# The VM gets Secure Boot (custom mode, the image's own PK/KEK/db, no
# Microsoft CA) and swtpm. The host TPM, real FIDO2 keys, host disks and
# efivars are never touched; only build-disk.sh (loop device, LUKS on the
# lab disk image) runs under sudo. The fresh disk has no tokens enrolled:
# it asks for the LUKS passphrase LAB_RECOVERY (lab-recovery-passphrase).
# With AUTO_UNLOCK=1 (default) launch types it on the VM's emulated keyboard
# (QEMU monitor sendkey) each time the prompt shows on the serial console;
# that needs the serial addon (DBKEY at override). TPM2/FIDO2 PIN prompts
# are never answered.
#
# The lab disk gets a desktop user for SDDM, LAB_USER / LAB_PASS (tester /
# Acct-Pass-1), created on first boot (lab only, never in the image;
# LAB_USER= turns it off). Root logs in on the serial console without one.
set -euo pipefail

die() { echo "local.sh: $*" >&2; exit 1; }
log() { echo "local.sh: $*" >&2; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
L=$HERE/local
CONF=$L/local.conf
KEYS_DIR=$L/keys
VM=$L/vm
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
VFIDO_VID=0x1209
VFIDO_PID=0x7f1d

write_conf() {
    mkdir -p "$L"
    cat > "$CONF" <<'EOF'
# image/local.sh settings. Each line keeps an env var of the same name if set.
: "${IMAGE:=localhost/e-gui:uki}"     # sealed image in your podman storage
: "${KEYS:=auto}"                     # auto = PK/KEK/db from the image; or a uki/keys-style dir
: "${DBKEY:=}"                        # DEV db.key only: signs a serial-console addon (lab)
: "${LAB_RECOVERY:=lab-recovery-passphrase}"   # LUKS passphrase of the lab disk
: "${AUTO_UNLOCK:=1}"                 # 1 = type LAB_RECOVERY on the VM keyboard at the prompt
: "${LAB_USER=tester}"               # desktop user on the lab disk (empty = none); at override
: "${LAB_PASS:=Acct-Pass-1}"         # its password
: "${LAB_USER_GROUPS:=}"             # extra groups, comma-separated (e.g. wheel)
: "${MEM:=8192}"                      # MiB
: "${CPUS:=4}"
: "${VGA:=virtio}"                    # virtio (SDDM -> scroll on DRM), std
: "${DISPLAY_BACKEND:=auto}"          # auto (gtk with a session, else none), gtk, sdl, none
: "${SERIAL:=auto}"                   # auto (stdio when headless, else file), stdio, file
: "${NET:=none}"                      # none, or user (QEMU slirp, guest-only NAT)
: "${FIDO:=0}"                        # 1 = virtual FIDO2 key (test/vfido, sudo, one per host)
: "${EXTRA_QEMU:=}"                   # extra QEMU args, word-split
EOF
    log "wrote $CONF"
}

load_conf() {
    [[ -f $CONF ]] || write_conf
    # shellcheck source=/dev/null
    source "$CONF"
    : "${SERIAL:=auto}" "${AUTO_UNLOCK:=1}" "${LAB_USER=tester}" "${LAB_PASS:=Acct-Pass-1}" "${LAB_USER_GROUPS:=}"   # older local.conf files lack these
}

confirm() {
    [[ ${YES:-0} == 1 ]] && return 0
    [[ -t 0 ]] || die "$1 (pass -y to confirm)"
    local a
    read -r -p "$1 [y/N] " a
    [[ $a == [yY]* ]] || die "aborted"
}

# PK/KEK/db certs as lab-secureboot.sh wants them ({PK,KEK,db}/*.pem + GUID).
prepare_keys() {
    if [[ $KEYS != auto ]]; then
        [[ -f $KEYS/GUID && -d $KEYS/db ]] || die "KEYS=$KEYS is not a uki/keys-style dir"
        echo "$KEYS"
        return
    fi
    local k tmp
    tmp=$(mktemp -d "$L/.keys.XXXXXX")
    podman run --rm --network=none --entrypoint tar "$IMAGE" \
        -C /usr/share/secureblue/uki/keys -cf - GUID PK.der KEK.der db.der | tar -C "$tmp" -xf -
    for k in PK KEK db; do
        mkdir -p "$tmp/$k"
        openssl x509 -inform der -in "$tmp/$k.der" -out "$tmp/$k/$k.pem"
        rm -f "$tmp/$k.der"
    done
    rm -rf "$KEYS_DIR"
    mv "$tmp" "$KEYS_DIR"
    echo "$KEYS_DIR"
}

cmd_override() {
    [[ ${1:-} ]] && IMAGE=$1
    podman image exists "$IMAGE" || die "no image $IMAGE in your podman storage"
    [[ -f $OVMF_CODE ]] || die "missing $OVMF_CODE (edk2-ovmf)"
    if [[ -e $VM/disk.raw || -d $VM/tpm ]]; then
        confirm "Replace the lab VM in $VM (disk, TPM state, vars) with $IMAGE?"
    fi
    exec 9>"$L/.lock"
    flock -n 9 || die "the lab VM is running (or another local.sh holds $L/.lock)"
    local keys
    keys=$(prepare_keys)
    rm -rf "$VM"
    mkdir -p "$VM"
    log "Secure Boot vars from $keys"
    "$ROOT/test/bootc/lab-secureboot.sh" "$VM" "$keys" ${DBKEY:+"$DBKEY"}
    log "lab disk from $IMAGE (sudo)"
    local user_hash=
    if [[ -n $LAB_USER ]]; then
        user_hash=$(printf '%s' "$LAB_PASS" | openssl passwd -6 -stdin)
        log "lab user: $LAB_USER${LAB_USER_GROUPS:+ (groups $LAB_USER_GROUPS)}, created on first boot"
    fi
    sudo LAB_RECOVERY="$LAB_RECOVERY" LAB_USER="$LAB_USER" LAB_USER_HASH="$user_hash" \
        LAB_USER_GROUPS="$LAB_USER_GROUPS" \
        "$ROOT/test/bootc/build-disk.sh" "$VM" "$IMAGE" 2>&1 | tee "$VM/build-disk.log"
    [[ -f $VM/disk.raw && -f $VM/guest.env ]] || die "build-disk.sh failed, see $VM/build-disk.log"
    cp "$VM/OVMF_VARS.sb.fd" "$VM/OVMF_VARS.fd"
    printf 'IMAGE=%s\nIMAGE_ID=%s\nBUILT=%s\n' "$IMAGE" \
        "$(podman image inspect --format '{{.Id}}' "$IMAGE")" "$(date -Is)" > "$VM/image.env"
    log "ready: $VM/disk.raw ($IMAGE)"
}

cmd_launch() {
    [[ -f $VM/disk.raw ]] || { log "no lab disk yet, overriding first"; cmd_override; }
    [[ -f $VM/OVMF_VARS.fd ]] || cp "$VM/OVMF_VARS.sb.fd" "$VM/OVMF_VARS.fd"
    exec 9>"$L/.lock"
    flock -n 9 || die "the lab VM is already running (or being overridden)"

    local display=$DISPLAY_BACKEND
    if [[ $display == auto ]]; then
        if [[ -n ${WAYLAND_DISPLAY:-} || -n ${DISPLAY:-} ]]; then display=gtk; else display=none; fi
    fi

    mkdir -p "$VM/tpm"
    rm -f "$VM/tpm/swtpm.sock" "$VM/monitor.sock" "$VM/vnc.sock"
    pids=()   # global: the EXIT trap runs after this function returns
    cleanup() {
        set +e
        local p
        for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
        wait 2>/dev/null
        if [[ $FIDO == 1 ]]; then sudo "$ROOT/test/vfido/gadget.sh" down >/dev/null 2>&1; fi
    }
    trap cleanup EXIT INT TERM

    swtpm socket --tpm2 --tpmstate "dir=$VM/tpm" \
        --ctrl "type=unixio,path=$VM/tpm/swtpm.sock" --terminate \
        --log "file=$VM/tpm/swtpm.log,level=1" &
    pids+=($!)
    local _
    for _ in $(seq 50); do [[ -S $VM/tpm/swtpm.sock ]] && break; sleep 0.1; done
    [[ -S $VM/tpm/swtpm.sock ]] || die "swtpm did not start, see $VM/tpm/swtpm.log"

    local q=(qemu-system-x86_64 -name scroll-secure-local
        -machine q35,smm=on,accel=kvm -cpu host -smp "$CPUS" -m "$MEM"
        -global driver=cfi.pflash01,property=secure,value=on
        -global ICH9-LPC.disable_s3=1
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,unit=1,file=$VM/OVMF_VARS.fd"
        -drive "if=virtio,format=raw,cache=writeback,file=$VM/disk.raw"
        -chardev "socket,id=chrtpm,path=$VM/tpm/swtpm.sock"
        -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0
        -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0
        -vga "$VGA" -display "$display" -vnc "unix:$VM/vnc.sock"
        -monitor "unix:$VM/monitor.sock,server=on,wait=off")
    local serial=$SERIAL
    [[ $serial == auto ]] && { [[ $display == none ]] && serial=stdio || serial=file; }
    case $serial in
        # stdio is also logged to serial.log, which the auto-unlock watches.
        stdio) q+=(-chardev "stdio,id=ser0,mux=on,logfile=$VM/serial.log"
                   -serial chardev:ser0 -mon chardev=ser0,mode=readline) ;;
        file) q+=(-serial "file:$VM/serial.log") ;;
        *) die "SERIAL=$SERIAL: use auto, stdio or file" ;;
    esac
    case $NET in
        none) q+=(-nic none) ;;
        user) q+=(-nic user,model=virtio-net-pci) ;;
        *) die "NET=$NET: use none or user" ;;
    esac

    if [[ $FIDO == 1 ]]; then
        exec 8>/var/tmp/vfido-gadget.lock
        flock -n 8 || die "the vfido gadget is in use (an e2e run?); /var/tmp/vfido-gadget.lock"
        local out hidg
        out=$(sudo "$ROOT/test/vfido/gadget.sh" up)
        hidg=$(sed -n 's/.*hidg=\([^ ]*\).*/\1/p' <<<"$out")
        [[ -n $hidg ]] || die "gadget.sh up: $out"
        mkdir -p "$VM/vfido-ctl"
        echo auto > "$VM/vfido-ctl/presence"
        python3 -I "$ROOT/test/vfido/vfido.py" --hidg "$hidg" \
            --state "$VM/vfido-state.json" --ctl "$VM/vfido-ctl" >>"$VM/vfido.log" 2>&1 &
        pids+=($!)
        q+=(-device "usb-host,bus=xhci.0,vendorid=$VFIDO_VID,productid=$VFIDO_PID")
    fi
    if [[ -n $EXTRA_QEMU ]]; then
        local extra
        read -r -a extra <<<"$EXTRA_QEMU"
        q+=("${extra[@]}")
    fi

    [[ -f $VM/image.env ]] && log "image: $(sed -n 's/^IMAGE=//p' "$VM/image.env")"
    log "display=$display vga=$VGA net=$NET fido=$FIDO mem=${MEM}M cpus=$CPUS"
    log "LUKS passphrase (until tokens are enrolled): $LAB_RECOVERY"
    local u
    u=$(sed -n 's/^LAB_USER=//p' "$VM/guest.env" 2>/dev/null || true)
    if [[ -n $u ]]; then
        if [[ $u == "$LAB_USER" ]]; then log "desktop login: $u / $LAB_PASS"
        else log "desktop login: $u (password from when the disk was built)"; fi
    else
        log "desktop login: none on this disk (override with LAB_USER set)"
    fi
    rm -f "$VM/serial.log"
    if [[ $AUTO_UNLOCK == 1 ]]; then
        if [[ -f $VM/lab-serial-console.addon.efi ]]; then
            log "auto-unlock: typing it on the VM keyboard at each prompt (log: $VM/unlock.log)"
            LAB_RECOVERY=$LAB_RECOVERY python3 -I - "$VM" >"$VM/unlock.log" 2>&1 <<'PY' &
import os, re, socket, sys, time
vm = sys.argv[1]
pw = os.environ.pop("LAB_RECOVERY")
log_path, mon_path = os.path.join(vm, "serial.log"), os.path.join(vm, "monitor.sock")
PROMPT = re.compile(rb"Please enter passphrase for disk")
SHIFT = dict(zip('!@#$%^&*()_+{}|:"~<>?', "1234567890-=[]\\;'`,./"))
NAMED = {" ": "spc", "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
         "\\": "backslash", ";": "semicolon", "'": "apostrophe", "`": "grave_accent",
         ",": "comma", ".": "dot", "/": "slash"}
def key(c):
    if c.isascii() and (c.islower() or c.isdigit()):
        return c
    if c.isascii() and c.isupper():
        return "shift-" + c.lower()
    if c in SHIFT:
        return "shift-" + NAMED.get(SHIFT[c], SHIFT[c])
    if c in NAMED:
        return NAMED[c]
    sys.exit(f"auto-unlock: no key for {c!r}, type the passphrase yourself")
keys = [key(c) for c in pw] + ["ret"]
def sendkeys():
    s = socket.socket(socket.AF_UNIX)
    s.connect(mon_path)
    s.settimeout(1)
    for k in keys:
        s.sendall(f"sendkey {k}\n".encode())
        time.sleep(0.05)
    time.sleep(0.5)
    s.close()
def count():
    try:
        return len(PROMPT.findall(open(log_path, "rb").read()))
    except FileNotFoundError:
        return 0
seen = typed = 0
while typed < 5:              # a reboot prompts again; a wrong passphrase would loop
    if count() > seen:
        time.sleep(1)         # let the agent start reading
        sendkeys()
        typed += 1
        # plymouth redraws the prompt for every key: wait until the
        # redraws stop, so only a later, real prompt counts as new
        settled, last = 0, count()
        while settled < 3:
            time.sleep(1)
            n = count()
            settled, last = (settled + 1, n) if n == last else (0, n)
        seen = last
        print(f"{time.strftime('%T')} prompt: passphrase typed", flush=True)
    time.sleep(1)
PY
            pids+=($!)
        else
            log "auto-unlock: off, the lab disk has no serial addon (override with DBKEY); type it yourself"
        fi
    fi
    log "monitor: socat - UNIX-CONNECT:$VM/monitor.sock; frontend: image/upsert.sh"
    "${q[@]}"
}

cmd_status() {
    echo "settings: $CONF"
    local v
    for v in IMAGE KEYS DBKEY AUTO_UNLOCK LAB_USER LAB_USER_GROUPS MEM CPUS VGA DISPLAY_BACKEND SERIAL NET FIDO EXTRA_QEMU; do
        printf '  %-16s %s\n' "$v" "${!v}"
    done
    echo "vm: $VM"
    if [[ -f $VM/image.env ]]; then sed 's/^/  /' "$VM/image.env"; else echo "  no lab disk (run override)"; fi
    if [[ -f $VM/disk.raw ]]; then
        printf '  disk.raw         %s used\n' "$(du -h "$VM/disk.raw" | cut -f1)"
        [[ -f $VM/lab-serial-console.addon.efi ]] && echo "  serial addon     yes" || echo "  serial addon     no"
    fi
    if exec 9>"$L/.lock" && ! flock -n 9; then echo "  running          yes"; else echo "  running          no"; fi
}

cmd_clean() {
    exec 9>"$L/.lock"
    flock -n 9 || die "the lab VM is running"
    confirm "Delete $VM and $KEYS_DIR (local.conf stays)?"
    if [[ -e $VM/disk.raw ]] && ! rm -rf "$VM" 2>/dev/null; then sudo rm -rf "$VM"; fi
    rm -rf "$VM" "$KEYS_DIR"
    log "cleaned"
}

YES=0
args=()
for a in "$@"; do
    case $a in
        -y|--yes) YES=1 ;;
        -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) args+=("$a") ;;
    esac
done
set -- "${args[@]}"
mkdir -p "$L"
cmd=${1:-launch}
shift || true
case $cmd in
    init) [[ -f $CONF ]] && die "$CONF exists; edit it"; write_conf ;;
    override|build) load_conf; cmd_override "$@" ;;
    launch|run) load_conf; cmd_launch ;;
    status) load_conf; cmd_status ;;
    clean) load_conf; cmd_clean ;;
    *) die "unknown command $cmd (init|override|launch|status|clean; -h)" ;;
esac
