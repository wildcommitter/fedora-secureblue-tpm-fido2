#!/usr/bin/env bash
# Duress canary e2e for hardened-unlock: headless scroll (pixman) in the image
# rootfs, the locker started the real way (scroll-lock -> lock_command), keys
# typed with wtype, the virtual FIDO2 key from test/vfido. The locker is the
# duresstest build, whose reset writes a marker file instead: nothing here
# can reset any machine. The real reset is tested in a VM (duress-vm-e2e.py).
#
#   lockscreen/build.sh && lockscreen/test/duress-e2e.sh   (needs sudo for the USB gadget)
#
# Checks: `duress set` refuses the account password and tokenvault's PINs;
# the canary typed before Enter, at the key PIN prompt and at the password
# prompt each give the marker, keep the session locked, and send nothing to
# the key or PAM; the real PIN + password still unlock with a canary set; a
# malformed canary file is logged without the hash and doesn't block the
# unlock; with no canary file the unlock works.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LS=$(dirname "$HERE")
ROOT=$(dirname "$LS")
IMAGE=${IMAGE:-localhost/scroll-secure-rootfs:latest}
W=${WORK:-$HERE/work/duress}
KEY_PIN=246810
ACCT_PASS=Acct-Pass-1
CANARY=Blue-Heron-77
TEST_IMAGE=localhost/hardened-unlock-duresstest:latest
CT=hardened-unlock-duresstest

[[ -x $LS/out/duresstest/hardened-unlock && -x $LS/out/hardened-unlock ]] \
    || { echo "run lockscreen/build.sh first" >&2; exit 1; }
podman build -q --build-arg IMAGE="$IMAGE" -t "$TEST_IMAGE" -f "$HERE/Containerfile.gui" "$HERE" >/dev/null

# The USB gadget is one per host: wait for other e2e runs to release it.
exec 9>/var/tmp/vfido-gadget.lock
flock -w 1800 9 || { echo "vfido gadget busy" >&2; exit 1; }

rm -rf "$W"; mkdir -p "$W/ctl"; chmod 0777 "$W"   # written by the container's test user
VF=
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
    -v "$LS/out/duresstest:/hutest/bin:ro,Z" -v "$LS/out:/hutest/prod:ro,Z" \
    -v "$LS/etc/pam.d/hardened-unlock:/hutest/pam:ro,Z" \
    -v "$HERE/pty-pin.py:/hutest/pty-pin.py:ro,Z" -v "$HERE/scroll-duress.conf:/hutest/scroll.conf:ro,Z" \
    -v "$LS/usr/lib/sysusers.d/hardened-unlock.conf:/usr/lib/sysusers.d/hardened-unlock.conf:ro,Z" \
    -v "$W:/hutest/work:Z" \
    --entrypoint sleep "$TEST_IMAGE" infinity >/dev/null
ct() { podman exec -i "$CT" "$@"; }

ct bash -euc "
install -m 0644 /hutest/pam /etc/pam.d/hardened-unlock
useradd -m tester
echo 'tester:$ACCT_PASS' | chpasswd
systemd-sysusers /usr/lib/sysusers.d/hardened-unlock.conf
FIDO2_PIN=$KEY_PIN python3 -I /usr/libexec/tokenvault/fido2-pin.py ensure /dev/hidraw0
python3 -I /hutest/pty-pin.py '$KEY_PIN' pamu2fcfg -u tester -o pam://workstation -i pam://workstation -N \
    | tr -d '\r' | grep '^tester:' > /etc/u2f_mappings
chmod 0644 /etc/u2f_mappings
install -d -m 0700 -o tester -g tester /run/user/tester
install -d -m 0700 /etc/tokenvault
printf 'TPM2_PIN=\"tpm-pin-1234\"\nFIDO2_PIN=\"$KEY_PIN\"\n' > /etc/tokenvault/tokenvault.conf
"

pass=0 fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
duress() { ct /hutest/prod/hardened-unlock duress "$@"; }

# 1. duress set: refusals, then the real canary
for refused in "$ACCT_PASS" "$KEY_PIN" tpm-pin-1234 ""; do
    if printf '%s\n%s\n' "$refused" "$refused" | duress set --user tester 2>"$W/set.err"; then
        bad "duress set accepted '${refused:-<empty>}'"
    else
        ok "duress set refuses '${refused:-<empty>}': $(tail -1 "$W/set.err")"
    fi
done
printf '%s\n%s\n' "$CANARY" other | duress set --user tester 2>/dev/null && bad "mismatched entries accepted" \
    || ok "duress set refuses two different entries"
# root's umask on secureblue is 027: the directory must still end up 0755.
if printf '%s\n%s\n' "$CANARY" "$CANARY" \
        | ct sh -c 'umask 027; exec /hutest/prod/hardened-unlock duress set --user tester' 2>"$W/set.err" \
        && [[ $(ct stat -c '%a %U %G' /etc/hardened-unlock/duress) == "640 root hardened-duress" ]] \
        && [[ $(ct stat -c '%a' /etc/hardened-unlock) == "755" ]] \
        && ct id -nG tester | grep -qw hardened-duress \
        && ct grep -q '^\$y\$' /etc/hardened-unlock/duress && ! ct grep -q "$CANARY" /etc/hardened-unlock/duress; then
    ok "duress set (umask 027): yescrypt hash, root:hardened-duress 0640 in a 0755 dir, tester added to the group"
else
    bad "duress set"; cat "$W/set.err"
fi
duress status --user tester > "$W/status.out" 2>&1 || true
grep -q 'canary: set' "$W/status.out" && ok "duress status reports the canary" || { bad "duress status"; cat "$W/status.out"; }

# The session: dbus + headless scroll as the test user (now in hardened-duress).
ENV=(XDG_RUNTIME_DIR=/run/user/tester WLR_BACKENDS=headless WLR_RENDERER=pixman
     WLR_LIBINPUT_NO_DEVICES=1 GSK_RENDERER=cairo HARDENED_UNLOCK_DEBUG=1 USER=tester)
as_tester() { ct runuser -u tester -- env "${ENV[@]}" "$@"; }
podman exec -d "$CT" runuser -u tester -- env "${ENV[@]}" sh -c \
    'exec dbus-run-session -- scroll -c /hutest/scroll.conf > /hutest/work/scroll.log 2>&1'
sock=
for _ in $(seq 1 40); do
    sock=$(ct sh -c 'cd /run/user/tester && ls wayland-* 2>/dev/null' | grep -v '\.lock$' | head -1 || true)
    [[ -n $sock ]] && break
    sleep 0.25
done
[[ -n $sock ]] || { echo "scroll did not start"; cat "$W/scroll.log"; exit 1; }
spid=$(ct pgrep -u tester -x scroll | head -1)
ENV+=(WAYLAND_DISPLAY=$sock DBUS_SESSION_BUS_ADDRESS=disabled: SCROLL_PID=$spid)

wait_log() {   # wait_log <regex> <seconds>
    local i
    for i in $(seq 1 $(($2 * 4))); do
        grep -qE -- "$1" "$W/locker.log" 2>/dev/null && return 0
        sleep 0.25
    done
    return 1
}
wait_marker() {
    local i
    for i in $(seq 1 $(($1 * 4))); do
        [[ -e $W/duress-marker ]] && return 0
        sleep 0.25
    done
    return 1
}
locker_running() { ct pgrep -u tester -x hardened-unlock >/dev/null; }
locked() { ct test -e "/run/user/tester/scroll-locked.$spid"; }
# fresh_lock: kill any locker (the session stays locked), lock again through scroll-lock.
fresh_lock() {
    ct pkill -9 -u tester -x hardened-unlock 2>/dev/null || true
    sleep 1
    rm -f "$W/duress-marker"
    : > "$W/locker.log"; chmod 0666 "$W/locker.log"
    as_tester scroll-lock </dev/null >/dev/null && wait_log '^hardened-unlock: locked$' 10
}
# One wtype call per answer, with a pause first: each call is a new virtual
# keyboard, and keys sent before its keymap is applied are lost.
type_text() {
    if [[ -n $1 ]]; then as_tester wtype -s 300 -d 20 "$1" -k Return; else as_tester wtype -s 300 -k Return; fi
}
key_activity() { tail -n +"$(($1 + 1))" "$W/vfido.log" | grep -cE 'pin=|op=getAssertion|up=requested' || true; }
# still_locked <what>: no unlock, locker alive, lock state present, no PAM result
still_locked() {
    sleep 2
    if locker_running && locked && ! grep -q 'result success' "$W/locker.log"; then
        ok "$1: session stays locked, PAM gave no result"
    else
        bad "$1: not locked"; cat "$W/locker.log"
    fi
}

# 2. canary typed before the first Enter
fresh_lock || bad "lock"
mark=$(wc -l < "$W/vfido.log")
type_text "$CANARY"
wait_marker 10 && ok "canary before Enter: reset requested" || { bad "canary before Enter: no marker"; cat "$W/locker.log"; }
still_locked "canary before Enter"
grep -q 'prompt:' "$W/locker.log" && bad "canary before Enter: PAM was started" || ok "canary before Enter: PAM never started"
[[ $(key_activity "$mark") == 0 ]] && ok "canary before Enter: no key request" || bad "canary before Enter: key was asked"

# 3. canary at the key PIN prompt
fresh_lock || bad "relock"
type_text ""
if wait_log 'prompt: .*[Pp][Ii][Nn]' 20; then
    mark=$(wc -l < "$W/vfido.log")
    type_text "$CANARY"
    wait_marker 10 && ok "canary at the PIN prompt: reset requested" || { bad "canary at the PIN prompt: no marker"; cat "$W/locker.log"; }
    still_locked "canary at the PIN prompt"
    [[ $(key_activity "$mark") == 0 ]] && ok "canary at the PIN prompt: no PIN sent to the key" \
        || { bad "canary at the PIN prompt: key activity"; tail -n +"$((mark + 1))" "$W/vfido.log"; }
else
    bad "no PIN prompt"; cat "$W/locker.log"
fi

# 4. canary at the password prompt (after the real PIN and the touch)
fresh_lock || bad "relock"
type_text "$KEY_PIN"
if wait_log 'prompt: Password' 30; then
    ct faillock --user tester > "$W/faillock-before" 2>&1 || true
    type_text "$CANARY"
    wait_marker 10 && ok "canary at the password prompt: reset requested" || { bad "canary at the password prompt: no marker"; cat "$W/locker.log"; }
    still_locked "canary at the password prompt"
    ct faillock --user tester > "$W/faillock-after" 2>&1 || true
    cmp -s "$W/faillock-before" "$W/faillock-after" && ok "canary at the password prompt: never reached pam_unix/faillock" \
        || bad "canary at the password prompt: faillock changed"
else
    bad "no password prompt after PIN + touch"; cat "$W/locker.log"
fi

# unlock_works <what>: real PIN + touch + password unlock, no marker
unlock_works() {
    type_text "$KEY_PIN"
    if wait_log 'prompt: Password' 30; then
        type_text "$ACCT_PASS"
        if wait_log 'result success=true' 20; then
            for _ in $(seq 1 20); do locker_running || break; sleep 0.25; done
            if ! locker_running && ! locked && [[ ! -e $W/duress-marker ]]; then ok "$1: unlocks"; return; fi
        fi
    fi
    bad "$1: no unlock"; cat "$W/locker.log"
}

# 5. the real credentials still unlock with a canary set
fresh_lock || bad "relock"
unlock_works "canary set, real PIN + password"

# 6. malformed canary file: logged without the hash, unlock still works
ct sh -c 'printf "garbage\n" > /etc/hardened-unlock/duress'
fresh_lock || bad "relock"
if grep -q 'malformed canary file' "$W/locker.log" && ! grep -q 'garbage' "$W/locker.log"; then
    ok "malformed canary file logged, without its contents"
else
    bad "malformed canary file not logged"; cat "$W/locker.log"
fi
unlock_works "malformed canary file"

# 7. no canary file
duress clear 2>/dev/null
ct test ! -e /etc/hardened-unlock/duress && ok "duress clear removes the canary" || bad "duress clear"
fresh_lock || bad "relock"
grep -q 'duress' "$W/locker.log" && bad "no canary file: locker logged a duress error" || ok "no canary file: nothing logged"
unlock_works "no canary file"

echo "passed $pass, failed $fail (logs in $W)"
[[ $fail -eq 0 ]]
