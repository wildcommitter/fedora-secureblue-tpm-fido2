#!/usr/bin/env bash
# PAM e2e for the hardened-unlock stack, without Wayland: runs `authtest`
# (same pamauth code and PAM service as the locker) inside the image's rootfs
# against etc/pam.d/hardened-unlock, with the virtual FIDO2 key from
# test/vfido. The host's real key, PAM and accounts are never touched; only
# the virtual key's hidraw node is passed into the container.
#
#   lockscreen/build.sh && lockscreen/test/pam-e2e.sh     (needs sudo for the USB gadget)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LS=$(dirname "$HERE")
ROOT=$(dirname "$LS")
IMAGE=${IMAGE:-localhost/scroll-secure-rootfs:latest}
W=${WORK:-$HERE/work/pam}
KEY_PIN=246810
ACCT_PASS=Acct-Pass-1

[[ -x $LS/out/authtest ]] || { echo "run lockscreen/build.sh first" >&2; exit 1; }
rm -rf "$W"; mkdir -p "$W/ctl"
VF=
cleanup() {
    set +e
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
echo "virtual key: $hidraw"

presence() { echo "$1" > "$W/ctl/presence"; }

# --- one container for the whole run: setup, then each case via exec -------
CT=hardened-unlock-pamtest
podman rm -f "$CT" >/dev/null 2>&1 || true
podman run -d --name "$CT" --device "$hidraw:/dev/hidraw0" \
    --cap-add DAC_READ_SEARCH,AUDIT_WRITE \
    -v "$LS/out:/hutest/bin:ro,Z" -v "$LS/etc/pam.d/hardened-unlock:/hutest/pam:ro,Z" -v "$HERE/pty-pin.py:/hutest/pty-pin.py:ro,Z" \
    --entrypoint sleep "$IMAGE" infinity >/dev/null
trap 'podman rm -f "$CT" >/dev/null 2>&1; cleanup' EXIT
ct() { podman exec -i "$CT" "$@"; }

ct bash -euc "
install -m 0644 /hutest/pam /etc/pam.d/hardened-unlock
useradd -m tester
echo 'tester:$ACCT_PASS' | chpasswd
FIDO2_PIN=$KEY_PIN python3 -I /usr/libexec/tokenvault/fido2-pin.py ensure /dev/hidraw0
# pamu2fcfg reads the PIN from a terminal only (and the image has no script(1))
python3 -I /hutest/pty-pin.py '$KEY_PIN' pamu2fcfg -u tester -o pam://workstation -i pam://workstation -N \
    | tr -d '\r' | grep '^tester:' > /etc/u2f_mappings
chmod 0644 /etc/u2f_mappings
"
echo "registered: $(ct cut -c1-40 /etc/u2f_mappings)..."

pass=0 fail=0
# run_case <name> <expected exit> <stdin lines> <grep that must match> [<grep that must not match>]
run_case() {
    local name=$1 want=$2 input=$3 must=$4 mustnot=${5:-} out rc
    out=$(printf '%s' "$input" | ct runuser -u tester -- /hutest/bin/authtest 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" > "$W/$name.log"
    if [[ $rc -eq $want ]] && grep -qE -- "$must" <<<"$out" && { [[ -z $mustnot ]] || ! grep -qE -- "$mustnot" <<<"$out"; }; then
        echo "PASS $name"; pass=$((pass + 1))
    else
        echo "FAIL $name (exit $rc, want $want)"; sed 's/^/    /' <<<"$out"; fail=$((fail + 1))
    fi
}

presence auto
run_case good 0 "$KEY_PIN"$'\n'"$ACCT_PASS"$'\n' '^OK'
grep -q 'touch' "$W/good.log" || { echo "FAIL good: no touch cue shown"; fail=$((fail + 1)); }
# prompt order: key PIN, touch cue, then password
order=$(grep -E '^[?>] ' "$W/good.log" | grep -oE 'PIN|touch|Password' | tr '\n' ' ')
[[ $order == "PIN touch Password " ]] && { echo "PASS order ($order)"; pass=$((pass + 1)); } \
    || { echo "FAIL order: $order"; fail=$((fail + 1)); }
run_case wrong-pin 1 "000000"$'\n'"$ACCT_PASS"$'\n' 'FAILED' 'Password'
run_case wrong-password 1 "$KEY_PIN"$'\n'"not-the-password"$'\n' 'FAILED' '^OK'
presence deny
run_case no-touch 1 "$KEY_PIN"$'\n'"$ACCT_PASS"$'\n' 'FAILED' 'Password'
presence auto
run_case same-secret-twice 1 "$KEY_PIN"$'\n'"$KEY_PIN"$'\n' 'FAILED' '^OK'
run_case good-again 0 "$KEY_PIN"$'\n'"$ACCT_PASS"$'\n' '^OK'

echo "vfido: $(grep -c 'pin=wrong' "$W/vfido.log" || true) wrong PIN(s), $(grep -c 'up=granted' "$W/vfido.log" || true) touch(es) granted"
echo "passed $pass, failed $fail"
[[ $fail -eq 0 ]]
