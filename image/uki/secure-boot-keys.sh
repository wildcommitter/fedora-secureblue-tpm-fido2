#!/usr/bin/env bash
# secure-boot-keys: create this machine's own Secure Boot keys and enroll them
# into the firmware ("BIOS"), in plain bash.
#
#   secure-boot-keys.sh create [--keys DIR] [--secrets DIR]
#   secure-boot-keys.sh enroll [--keys DIR] [--esp DIR] [--backup DIR]
#                              [--dry-run] [--no-option-roms] [--force]
#   secure-boot-keys.sh status [--keys DIR] [--esp DIR]
#
# create  Generates PK -> KEK -> db (RSA-4096, 10 years) and the PCR 11
#         policy key (RSA-2048). Public halves go to --keys (default: keys/
#         next to this script, i.e. image/uki/keys, which the image build
#         embeds); private halves go to --secrets (default $SECRETS_DIR or
#         ~/.local/share/scroll-secure/secrets). Keep the secrets offline.
#         Same layout as create-keys.sh.
#
# enroll  Writes db, KEK, then PK into the firmware. Run as root on the
#         installed system with the firmware in Setup Mode (firmware setup:
#         "Clear Secure Boot keys" / "Delete PK", NOT "Reset to default").
#         --keys defaults to the image's /usr/share/secureblue/uki/keys.
#         Guards, in order:
#           - refuses unless the firmware is in Setup Mode;
#           - refuses unless every .efi on the ESP is signed by the db cert
#             being enrolled (else Secure Boot would refuse to boot it);
#           - adds the Authenticode SHA-256 of every option ROM the firmware
#             measured (TPM event log, PCR 2) to db, so the GPU still has a
#             display with only our keys (no Microsoft CA), as sbctl
#             --tpm-eventlog does;
#           - backs up the current PK/KEK/db/dbx first, and reads the
#             variables back afterwards.
#         Then turn Secure Boot on in firmware setup and reboot.
#
# status  Secure Boot / Setup Mode state, whether the enrolled variables hold
#         our certs, and whether the ESP's binaries are signed by our db.
#
# Keys must exist before the image is built (the UKI and systemd-boot are
# signed with db.key, and PCR.pem is embedded), so the real order is:
# create (trusted machine) -> build -> install -> enroll (installed system).
set -euo pipefail

PROG=secure-boot-keys
EFIVARS=${EFIVARS:-/sys/firmware/efi/efivars}
EVENTLOG=${EVENTLOG:-/sys/kernel/security/tpm0/binary_bios_measurements}
GUID_GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c      # PK, KEK, SecureBoot, SetupMode
GUID_IMAGE_DB=d719b2cb-3d3a-4596-a3bc-dad00e67656f    # db, dbx
GUID_CERT_SHA256=c1c41626-504c-4092-aca9-41f936934328
IMAGE_KEYS=/usr/share/secureblue/uki/keys
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die()  { echo "$PROG: $*" >&2; exit 1; }
warn() { echo "$PROG: warning: $*" >&2; }
need() { local c; for c; do command -v "$c" >/dev/null || die "$c not found (Fedora: dnf install efitools sbsigntools tpm2-tools openssl; Arch: pacman -S efitools sbsigntools tpm2-tools openssl)"; done; }

# ---- EFI variables ------------------------------------------------------------
var_path() {   # var_path <name>
    case $1 in db|dbx) echo "$EFIVARS/$1-$GUID_IMAGE_DB" ;; *) echo "$EFIVARS/$1-$GUID_GLOBAL" ;; esac
}
var_byte() {   # var_byte <name>: the first data byte as a number, or "-" if unset
    local p; p=$(var_path "$1")
    [[ -r $p ]] || { echo -; return; }
    od -An -tu1 -j4 -N1 "$p" | tr -d ' '
}
hexof() { od -An -v -tx1 "$1" | tr -d ' \n'; }

# ---- EFI_SIGNATURE_LIST of SHA-256 hashes (binary, built in bash) --------------
guid_le() {    # GUID string -> on-disk (mixed-endian) hex
    local u=${1//-/}
    echo "${u:6:2}${u:4:2}${u:2:2}${u:0:2}${u:10:2}${u:8:2}${u:14:2}${u:12:2}${u:16:16}"
}
u32le() { printf '%02x%02x%02x%02x' $(($1 & 255)) $((($1 >> 8) & 255)) $((($1 >> 16) & 255)) $((($1 >> 24) & 255)); }
hex2bin() { local h=$1 i; for ((i = 0; i < ${#h}; i += 2)); do printf "\\x${h:i:2}"; done; }
sha256_esl() { # sha256_esl <owner guid> <hex sha256>... > file
    local owner=$1 body= h; shift
    for h; do body+=$(guid_le "$owner")$h; done
    hex2bin "$(guid_le "$GUID_CERT_SHA256")$(u32le $((28 + 48 * $#)))$(u32le 0)$(u32le 48)$body"
}

# ---- keys -----------------------------------------------------------------------
keyfile() {    # keyfile <dir> <name>: flat (image) or nested (create) layout
    local p
    for p in "$1/$2" "$1/${2%%.*}/$2"; do [[ -f $p ]] && { echo "$p"; return; }; done
    die "missing $2 in $1"
}
default_keys() { [[ -d $IMAGE_KEYS ]] && echo "$IMAGE_KEYS" || echo "$HERE/keys"; }

# Authenticode SHA-256 of every EFI driver the firmware loaded from an option
# ROM (PCR 2, EV_EFI_BOOT_SERVICES_DRIVER), deduplicated, from the YAML that
# tpm2_eventlog printed.
option_rom_hashes() {
    awk '
        $1 == "-" && $2 == "EventNum:" { pcr = ""; type = ""; alg = "" }
        $1 == "PCRIndex:"              { pcr = $2 }
        $1 == "EventType:"             { type = $2 }
        $NF ~ /^sha256$/ && /AlgorithmId:/ { alg = "sha256"; next }
        /AlgorithmId:/                 { alg = "" }
        $1 == "Digest:" && alg == "sha256" && pcr == "2" && type == "EV_EFI_BOOT_SERVICES_DRIVER" {
            d = $2; gsub(/"/, "", d); if (!seen[d]++) print d; alg = "" }'
}

# Every .efi under the ESP must verify against the db cert, or Secure Boot
# will refuse it after enrollment.
check_esp() {  # check_esp <esp> <db.der>; prints a summary, returns 1 on any failure
    local esp=$1 pem bad=0 n=0 f
    pem=$(mktemp); openssl x509 -inform DER -in "$2" -out "$pem"
    while IFS= read -r -d '' f; do
        n=$((n + 1))
        if sbverify --cert "$pem" "$f" >/dev/null 2>&1; then
            echo "  signed   ${f#"$esp"/}"
        else
            echo "  UNSIGNED ${f#"$esp"/}"; bad=1
        fi
    done < <(find "$esp" -type f \( -iname '*.efi' \) -print0 | sort -z)
    rm -f "$pem"
    [[ $n -gt 0 ]] || { echo "  no .efi files under $esp"; return 1; }
    return $bad
}
esp_path() { [[ -n ${1:-} ]] && { echo "$1"; return; }; bootctl --print-esp-path 2>/dev/null || echo /boot; }

# ---- create -----------------------------------------------------------------------
cmd_create() {
    local keys="$HERE/keys" secrets=${SECRETS_DIR:-$HOME/.local/share/scroll-secure/secrets}
    while [[ $# -gt 0 ]]; do
        case $1 in
            --keys) keys=$2; shift 2 ;;
            --secrets) secrets=$2; shift 2 ;;
            *) die "create: unknown option $1" ;;
        esac
    done
    need openssl sbsiglist sbvarsign
    [[ -e $keys || -e $secrets ]] && die "$keys or $secrets already exists; refusing to overwrite"

    local title=scroll-secure days=3650 uuid key
    umask 077
    mkdir -p "$secrets" "$keys"
    chmod 0700 "$secrets"
    uuid=$(cat /proc/sys/kernel/random/uuid)
    echo "$uuid" > "$keys/GUID"
    for key in PK KEK db; do
        mkdir -p "$keys/$key"
        openssl req -new -x509 -nodes -newkey rsa:4096 -sha256 -days "$days" \
            -subj "/CN=$title $key $(date +%Y)/" \
            -keyout "$secrets/$key.key" -out "$keys/$key/$key.pem" 2>/dev/null
        openssl x509 -outform DER -in "$keys/$key/$key.pem" -out "$keys/$key/$key.der"
        sbsiglist --owner "$uuid" --type x509 --output "$keys/$key/$key.esl" "$keys/$key/$key.der"
    done
    mkdir -p "$keys/PCR"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$secrets/PCR.key" 2>/dev/null
    openssl pkey -in "$secrets/PCR.key" -pubout -out "$keys/PCR/PCR.pem"

    # PK self-signs and signs KEK; KEK signs db. enroll adds option ROM hashes to db.
    local attr=NON_VOLATILE,RUNTIME_ACCESS,BOOTSERVICE_ACCESS,TIME_BASED_AUTHENTICATED_WRITE_ACCESS
    sbvarsign --attr "$attr" --key "$secrets/PK.key" --cert "$keys/PK/PK.pem" \
        --output "$keys/PK/PK.auth" PK "$keys/PK/PK.esl" >/dev/null
    sbvarsign --attr "$attr" --key "$secrets/PK.key" --cert "$keys/PK/PK.pem" \
        --output "$keys/KEK/KEK.auth" KEK "$keys/KEK/KEK.esl" >/dev/null
    sbvarsign --attr "$attr" --key "$secrets/KEK.key" --cert "$keys/KEK/KEK.pem" \
        --output "$keys/db/db.auth" db "$keys/db/db.esl" >/dev/null
    chmod -R a+rX "$keys"

    cat <<EOF
Public keys:  $keys
Private keys: $secrets  <- back these up offline, then keep them off this machine

Next: build the image with these keys (SECRETS_DIR=$secrets image/build.sh ...),
install it, and on the installed system, in Setup Mode:
  run0 $PROG enroll --dry-run
  run0 $PROG enroll
EOF
}

# ---- enroll -------------------------------------------------------------------------
cmd_enroll() {
    local keys esp= backup= dry=0 roms=1 force=0
    keys=$(default_keys)
    while [[ $# -gt 0 ]]; do
        case $1 in
            --keys) keys=$2; shift 2 ;;
            --esp) esp=$2; shift 2 ;;
            --backup) backup=$2; shift 2 ;;
            --dry-run) dry=1; shift ;;
            --no-option-roms) roms=0; shift ;;
            --force) force=1; shift ;;
            *) die "enroll: unknown option $1" ;;
        esac
    done
    [[ $EUID -eq 0 ]] || die "enroll must run as root (run0 $PROG enroll)"
    [[ -d $EFIVARS ]] || die "$EFIVARS missing: not booted in UEFI mode?"
    need efi-updatevar sbverify openssl od chattr
    [[ $roms -eq 0 ]] || need tpm2_eventlog

    local pk_auth kek_esl db_esl db_der owner
    pk_auth=$(keyfile "$keys" PK.auth); kek_esl=$(keyfile "$keys" KEK.esl)
    db_esl=$(keyfile "$keys" db.esl); db_der=$(keyfile "$keys" db.der)
    owner=$(tr -d '[:space:]' < "$(keyfile "$keys" GUID)")

    local setup; setup=$(var_byte SetupMode)
    if [[ $setup != 1 ]]; then
        [[ $dry -eq 1 ]] || die "firmware is not in Setup Mode (SetupMode=$setup). In firmware setup clear the Secure Boot keys / delete the PK, then boot here and run this again"
        warn "not in Setup Mode (SetupMode=$setup); a real run would refuse"
    fi

    esp=$(esp_path "$esp")
    echo "ESP $esp, checked against $db_der:"
    if ! check_esp "$esp" "$db_der"; then
        [[ $force -eq 1 ]] || die "some ESP binaries are not signed by this db key: with Secure Boot on the firmware would refuse them (wrong keys for this image?). --force overrides"
        warn "--force: enrolling anyway; keep Secure Boot OFF until everything on the ESP is signed"
    fi

    local hashes=()
    if [[ $roms -eq 1 ]]; then
        # read in this shell, not a pipeline: a failure here must stop the
        # enrollment, not silently drop the hashes (black screen)
        [[ -r $EVENTLOG ]] || die "no TPM event log at $EVENTLOG (use --no-option-roms only if this machine has no GPU/NIC option ROMs)"
        local evlog
        evlog=$(tpm2_eventlog "$EVENTLOG" 2>/dev/null) || die "tpm2_eventlog could not parse $EVENTLOG"
        grep -q 'EventNum:' <<<"$evlog" || die "TPM event log is empty"
        mapfile -t hashes < <(option_rom_hashes <<<"$evlog")
        echo "option ROMs measured by the firmware: ${#hashes[@]}"
        printf '  sha256 %s\n' "${hashes[@]}"
        [[ ${#hashes[@]} -gt 0 ]] || warn "no option ROMs in the event log; fine for an iGPU, but a discrete GPU's GOP would be blocked"
    else
        warn "--no-option-roms: a GPU/NIC option ROM will be blocked under Secure Boot (black screen with a discrete GPU)"
    fi

    local tmp; tmp=$(mktemp -d)
    cat "$db_esl" > "$tmp/db.esl"
    [[ ${#hashes[@]} -eq 0 ]] || sha256_esl "$owner" "${hashes[@]}" >> "$tmp/db.esl"

    if [[ $dry -eq 1 ]]; then
        echo "dry run: would back up PK/KEK/db/dbx, then write db ($(stat -c %s "$tmp/db.esl") bytes: our cert + ${#hashes[@]} hash(es)), KEK, PK"
        rm -rf "$tmp"
        return 0
    fi

    backup=${backup:-/root/secure-boot-backup-$(date +%Y%m%d-%H%M%S)}
    mkdir -p "$backup"
    local v p
    for v in PK KEK db dbx; do
        p=$(var_path "$v"); [[ -f $p ]] && cp "$p" "$backup/"
    done
    echo "previous variables backed up to $backup"

    for v in db KEK PK; do
        p=$(var_path "$v"); [[ -f $p ]] && chattr -i "$p"
    done
    efi-updatevar -e -f "$tmp/db.esl" db
    efi-updatevar -e -f "$kek_esl" KEK
    efi-updatevar -f "$pk_auth" PK   # last: leaves Setup Mode
    rm -rf "$tmp"

    # read back
    local dbhex; dbhex=$(hexof "$(var_path db)")
    [[ $dbhex == *"$(hexof "$db_der")"* ]] || die "db does not contain our cert after writing"
    for v in "${hashes[@]}"; do [[ $dbhex == *"$v"* ]] || die "db lacks option ROM hash $v after writing"; done
    [[ $(hexof "$(var_path KEK)") == *"$(hexof "$(keyfile "$keys" KEK.der)")"* ]] || die "KEK does not contain our cert after writing"
    [[ $(hexof "$(var_path PK)") == *"$(hexof "$(keyfile "$keys" PK.der)")"* ]] || die "PK does not contain our cert after writing"
    [[ $(var_byte SetupMode) == 0 ]] || die "still in Setup Mode after writing PK"
    echo "Enrolled: PK, KEK, db (+${#hashes[@]} option ROM hash(es)); the firmware left Setup Mode."
    if [[ $(var_byte SecureBoot) == 1 ]]; then
        echo "Secure Boot is already on; reboot."
    else
        echo "Now turn Secure Boot ON in firmware setup (it may already turn on by itself at the next boot), reboot, and check: bootctl status"
    fi
}

# ---- status -------------------------------------------------------------------------
cmd_status() {
    local keys esp=
    keys=$(default_keys)
    while [[ $# -gt 0 ]]; do
        case $1 in
            --keys) keys=$2; shift 2 ;;
            --esp) esp=$2; shift 2 ;;
            *) die "status: unknown option $1" ;;
        esac
    done
    [[ -d $EFIVARS ]] || die "$EFIVARS missing: not booted in UEFI mode?"
    echo "SecureBoot=$(var_byte SecureBoot) SetupMode=$(var_byte SetupMode) AuditMode=$(var_byte AuditMode) DeployedMode=$(var_byte DeployedMode)"
    local v f
    for v in PK KEK db; do
        if [[ ! -r $(var_path "$v") ]]; then echo "$v: empty"; continue; fi
        f=$(find "$keys" -name "$v.der" -print -quit 2>/dev/null)
        if [[ -n $f && $(hexof "$(var_path "$v")") == *"$(hexof "$f")"* ]]; then
            echo "$v: holds our cert ($f)"
        else
            echo "$v: set, without our cert from $keys"
        fi
    done
    f=$(find "$keys" -name db.der -print -quit 2>/dev/null)
    if [[ -n $f ]] && command -v sbverify >/dev/null; then
        esp=$(esp_path "$esp")
        echo "ESP $esp:"
        check_esp "$esp" "$f" || true
    fi
}

main() {
    local cmd=${1:-}
    shift || true
    case $cmd in
        create) cmd_create "$@" ;;
        enroll) cmd_enroll "$@" ;;
        status) cmd_status "$@" ;;
        *) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; [[ $cmd == -h || $cmd == --help ]] ;;
    esac
}

[[ ${BASH_SOURCE[0]} != "$0" ]] || main "$@"
