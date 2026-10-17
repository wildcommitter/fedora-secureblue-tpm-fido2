#!/usr/bin/env bash
# GUI e2e for hardened-unlock: headless scroll (pixman) in the image rootfs,
# the real locker, keystrokes through wtype, and the virtual FIDO2 key from
# test/vfido. Same PAM stack and key registration as pam-e2e.sh.
#
#   lockscreen/build.sh && lockscreen/test/gui-e2e.sh     (needs sudo for the USB gadget)
#
# Checks: -f returns once the session is locked; typing the key PIN, touching
# (auto) and typing the password unlocks; a wrong PIN keeps it locked; after
# the locker is killed the session stays locked and a new locker can take
# over and unlock it.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LS=$(dirname "$HERE")
ROOT=$(dirname "$LS")
IMAGE=${IMAGE:-localhost/scroll-secure-rootfs:latest}
W=${WORK:-$HERE/work/gui}
KEY_PIN=246810
ACCT_PASS=Acct-Pass-1
TEST_IMAGE=localhost/hardened-unlock-guitest:latest

[[ -x $LS/out/hardened-unlock ]] || { echo "run lockscreen/build.sh first" >&2; exit 1; }
podman build -q --build-arg IMAGE="$IMAGE" -t "$TEST_IMAGE" -f "$HERE/Containerfile.gui" "$HERE" >/dev/null

rm -rf "$W"; mkdir -p "$W/ctl"; chmod 0777 "$W"   # written by the container's test user
VF= CT=hardened-unlock-guitest
cleanup() {
    set +e
    podman rm -f "$CT" >/dev/null 2>&1
    [[ -n $VF ]] && kill "$VF" 2>/dev/null && wait "$VF" 2>/dev/null
    sudo "$ROOT/test/vfido/gadget.sh" down
}
trap cleanup EXIT

hidg=$(sudo "$ROOT/test/vfido/gadget.sh" up | sed -n 's/.*hidg=\([^ ]*\).*/\1/p')
echo auto > "$W/ctl/presence"
python3 -I "$ROOT/test/vfido/vfido.py" --hidg "$hidg" --state "$W/vfido-state.json" --ctl "$W/ctl" \
    > "$W/vfido.log" 2>&1 &
VF=$!
hidraw=
for _ in $(seq 1 40); do
    for u in /sys/class/hidraw/hidraw*/device/uevent; do
        grep -qi '^HID_ID=0003:00001209:00007F1D$' "$u" && hidraw=/dev/$(basename "$(dirname "$(dirname "$u")")")
    done
    [[ -n $hidraw ]] && break
    sleep 0.25
done
[[ -n $hidraw ]] || { echo "virtual key's hidraw node not found" >&2; exit 1; }
sudo chmod 666 "$hidraw"

podman rm -f "$CT" >/dev/null 2>&1 || true
podman run -d --init --name "$CT" --device "$hidraw:/dev/hidraw0" \
    --cap-add DAC_READ_SEARCH,AUDIT_WRITE \
    -v "$LS/out:/hutest/bin:ro,Z" -v "$LS/etc/pam.d/hardened-unlock:/hutest/pam:ro,Z" \
    -v "$HERE/pty-pin.py:/hutest/pty-pin.py:ro,Z" -v "$HERE/scroll-test.conf:/hutest/scroll.conf:ro,Z" \
    -v "$W:/hutest/work:Z" \
    --entrypoint sleep "$TEST_IMAGE" infinity >/dev/null
ct() { podman exec -i "$CT" "$@"; }

ct bash -euc "
install -m 0644 /hutest/pam /etc/pam.d/hardened-unlock
useradd -m tester
echo 'tester:$ACCT_PASS' | chpasswd
FIDO2_PIN=$KEY_PIN python3 -I /usr/libexec/tokenvault/fido2-pin.py ensure /dev/hidraw0
python3 -I /hutest/pty-pin.py '$KEY_PIN' pamu2fcfg -u tester -o pam://workstation -i pam://workstation -N \
    | tr -d '\r' | grep '^tester:' > /etc/u2f_mappings
chmod 0644 /etc/u2f_mappings
install -d -m 0700 -o tester -g tester /run/user/tester
"
# The session: dbus + headless scroll as the test user.
ENV=(XDG_RUNTIME_DIR=/run/user/tester WLR_BACKENDS=headless WLR_RENDERER=pixman
     WLR_LIBINPUT_NO_DEVICES=1 GSK_RENDERER=cairo HARDENED_UNLOCK_DEBUG=1 USER=tester)
as_tester() { ct runuser -u tester -- env "${ENV[@]}" "$@"; }
podman exec -d "$CT" runuser -u tester -- env "${ENV[@]}" sh -c \
    'exec dbus-run-session -- scroll -c /hutest/scroll.conf > /hutest/work/scroll.log 2>&1'
for _ in $(seq 1 40); do
    ct sh -c "ls /run/user/tester/wayland-*" 2>/dev/null | grep -q . && break
    sleep 0.25
done
sock=$(ct sh -c 'cd /run/user/tester && ls wayland-* 2>/dev/null' | grep -v '\.lock$' | head -1 || true)
[[ -n $sock ]] || { echo "scroll did not start"; cat "$W/scroll.log"; exit 1; }
ENV+=(WAYLAND_DISPLAY=$sock DBUS_SESSION_BUS_ADDRESS=disabled:)

pass=0 fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
LOG=/hutest/work/locker.log
# wait_log <regex> <seconds>: wait until the locker log matches
wait_log() {
    local i
    for i in $(seq 1 $(($2 * 4))); do
        grep -qE -- "$1" "$W/locker.log" 2>/dev/null && return 0
        sleep 0.25
    done
    return 1
}
locker_running() { ct pgrep -u tester -x hardened-unlock >/dev/null; }
start_locker() {
    : > "$W/locker.log"; chmod 0666 "$W/locker.log"
    as_tester sh -c "/hutest/bin/hardened-unlock -f </dev/null >/dev/null 2>>$LOG"
}
# One wtype call per answer: each call is a new virtual keyboard, and keys sent
# before the client has applied its keymap are lost, hence the pause first.
type_text() { as_tester wtype -s 300 -d 20 "$1" -k Return; }

# 1. -f returns 0 only once the compositor confirmed the lock
if start_locker && grep -q '^hardened-unlock: locked$' "$W/locker.log" && locker_running; then
    ok "lock (-f returned after the locked event)"
else
    bad "lock"; cat "$W/locker.log"
fi
as_tester grim /hutest/work/locked.png 2>/dev/null || true

# 2. wrong PIN: stays locked, password never asked
type_text 000000
if wait_log 'result success=false' 20 && ! grep -q 'prompt: Password' "$W/locker.log" && locker_running; then
    ok "wrong PIN keeps the session locked, no password prompt"
else
    bad "wrong PIN"; cat "$W/locker.log"
fi

# 3. kill the locker: the session must stay locked; a new locker takes over
ct pkill -9 -u tester -x hardened-unlock || true
sleep 1
as_tester grim /hutest/work/crashed.png 2>/dev/null || true
if start_locker && grep -q '^hardened-unlock: locked$' "$W/locker.log"; then
    ok "after a crash a new locker takes over the lock"
else
    bad "relock after crash"; cat "$W/locker.log"
fi

# 4. key PIN typed before Enter, touch, then password: unlocks
mark=$(wc -l < "$W/vfido.log")
type_text "$KEY_PIN"
if wait_log 'prompt: Password' 30; then
    type_text "$ACCT_PASS"
    if wait_log 'result success=true' 20; then
        for _ in $(seq 1 20); do locker_running || break; sleep 0.25; done
        if ! locker_running; then ok "PIN + touch + password unlocks"; else
            bad "locker still running after success"
            ct pkill -QUIT -u tester -x hardened-unlock; sleep 1   # Go dumps its goroutines to the log
        fi
        sleep 1
        as_tester grim /hutest/work/unlocked.png
        # An abandoned lock (locker gone without unlocking) is scroll's solid
        # red screen, the same picture as after the crash in step 3.
        if cmp -s "$W/unlocked.png" "$W/crashed.png"; then
            bad "session still locked (abandoned-lock screen) after the locker exited"
        else
            ok "session really unlocked (not the abandoned-lock screen)"
        fi
    else
        bad "password not accepted"; cat "$W/locker.log"
    fi
else
    bad "no password prompt after PIN + touch"; cat "$W/locker.log"
fi
tail -n +"$((mark + 1))" "$W/vfido.log" | grep -q 'up=granted' && ok "the key was touched" || bad "no touch seen by the key"
grep -q 'answered with the text typed before Enter' "$W/locker.log" && ok "PIN typed before Enter answered the PIN prompt" \
    || bad "pre-typed PIN not used"

echo "passed $pass, failed $fail (logs and screenshot in $W)"
[[ $fail -eq 0 ]]
