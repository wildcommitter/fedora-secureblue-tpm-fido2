# hardened-unlock (lock screen)

A Wayland screen locker for scroll on the secureblue image. To unlock you need:

1. the **FIDO2 key's PIN**,
2. a **touch** of the key,
3. your **account password**.

All three are required, and each is asked separately.

It exists because swaylock can't do this. swaylock gives the one secret you type to every
PAM prompt, so the key PIN and the account password would have to be the same. It also
drops PAM's info messages, so "Please touch the FIDO authenticator." is never shown. The
image's `/etc/pam.d/swaylock` therefore uses only the key and its PIN (see the comment
there). hardened-unlock shows each PAM prompt and message as it comes. It started as a
locker for niri on CachyOS; `docs/why.md` has that background.

## How it works

- Locking uses Wayland's `ext-session-lock-v1` (which scroll supports), through the GTK4
  session lock API in `gtk4-layer-shell`. While locked, the compositor shows only the
  lock surfaces. If the locker crashes, the session **stays locked**. Start
  `hardened-unlock` again, from a TTY if need be, and it takes over the lock (tested).
- PAM runs in a freshly exec'd helper process, never inside the GTK process. The helper
  sends each prompt to the UI and waits for that one answer.
- The PAM service is `hardened-unlock` (`etc/pam.d/hardened-unlock`):
  1. `pam_u2f` (key PIN + touch). It is `requisite`: with a wrong PIN or no touch, the
     password is never asked, so the password can't be guessed at the lock screen
     without the key.
  2. The stock `system-auth` stack (password via `pam_unix`, plus `pam_faillock`).
- The key registration is shared with swaylock. Both use the root-owned
  `/etc/u2f_mappings` with origin `pam://workstation`, so one `pamu2fcfg` covers both.

On the screen: type the key PIN and press Enter. Touch the key when it blinks. Type the
password and press Enter. Text typed before the first Enter is used only if the first
prompt really asks for a PIN, so a password can never be sent to the key as a PIN
(which would use up one of its retries).

## Build

```sh
lockscreen/build.sh          # Fedora 44 container -> lockscreen/out/{hardened-unlock,authtest}
```

Build dependencies: `golang gcc pkgconf-pkg-config gtk4-devel gtk4-layer-shell-devel
gobject-introspection-devel pam-devel`. Runtime: `gtk4 gtk4-layer-shell pam-u2f`. The image
has `swayidle` and `pam-u2f` already. `gtk4-layer-shell` must be added. The older
`gtk-session-lock` package is GTK3-only and must not be used.

## In the image

| File | Installed as |
|---|---|
| `out/hardened-unlock` | `/usr/bin/hardened-unlock` |
| `etc/pam.d/hardened-unlock` | `/etc/pam.d/hardened-unlock` |
| `etc/scroll/config.d/50-hardened-unlock.conf` | `/etc/scroll/config.d/` (needs the `include /etc/scroll/config.d/*` line in `/etc/scroll/config` enabled) |

The drop-in locks with **Mod+Alt+L**, after 5 minutes idle, and before suspend. The
headless VNC session (`scroll-headless`, which sets `SCROLL_SECURE_HEADLESS=1`) gets the
keybind only, with no idle lock, because a remote user can't touch the key.
`hardened-unlock -f` returns once the session is locked (like `swaylock -f`).

Our scroll gives the session-lock protocol only to clients it starts itself. So scroll
starts the locker: `lock_command hardened-unlock -f`. The `lock` command (bound to
Mod+Alt+L) and SIGUSR1 run it, and `scroll-lock` sends that signal and returns once the
session is locked. That's what `swayidle -w ... before-sleep scroll-lock` needs: the
machine suspends only after the lock is in place. Running `hardened-unlock` by hand
doesn't lock; it gets no session-lock global. With `-f`, the locker hands scroll's
connection (`WAYLAND_SOCKET`) on to its detached child.

## Setup on the machine

1. Register the key once, as in `image/README.md`. That's the same registration swaylock
   uses:
   ```sh
   pamu2fcfg -u "$USER" -o pam://workstation -i pam://workstation -N | run0 tee /etc/u2f_mappings
   ```
2. Before relying on the locker, check the PAM stack from a terminal. `authtest` uses the
   same code and PAM service but never locks anything:
   ```sh
   authtest            # asks the key PIN, waits for the touch, asks the password
   ```
3. Lock once with Mod+Alt+L while a second TTY is logged in, in case something needs
   fixing.

With a fingerprint enrolled on the key, change `pinverification=1` to
`userverification=1` in the PAM file for fingerprint + touch instead of the PIN.

Set `HARDENED_UNLOCK_DEBUG=1` to log every prompt and message, never an answer, to stderr.

## Duress canary

A canary password that, typed at the lock screen, **hard-resets the machine instead of
unlocking**. It's for coercion: someone makes you unlock. You type the canary instead of
the key PIN or the password. The screen shows the usual "Checking…" and the machine
resets at once. After the reset the disk is behind tokenvault again: the TPM2 PIN, the
key PIN and a touch.

What happens:

1. hardened-unlock checks **every answer** you submit, at any prompt, against the canary
   before anything reaches PAM or the key. A canary never touches the key (no PIN retry
   is used) and never reaches `pam_unix` or `pam_faillock`.
2. On a match the locker stays locked for good and sends one byte to
   `/run/hardened-unlock/duress.sock`.
3. `duress-reset` (started by `hardened-unlock-duress.socket`) calls `reboot(2)` with
   `LINUX_REBOOT_CMD_RESTART`. There's no `sync()` and no systemd shutdown sequence. On
   x86 the kernel resets through ACPI by default.
4. If the helper can't be reached, nothing resets. The session stays locked and the error
   goes to the locker's log.

| Piece | Where | Notes |
|---|---|---|
| Canary hash | `/etc/hardened-unlock/duress`, root:hardened-duress 0640 | yescrypt (libxcrypt), one line. Never shipped in the image. No file means no canary. A malformed or unreadable file is logged (never its contents) and the lock screen works as usual |
| Reset helper | `/usr/libexec/hardened-unlock/duress-reset` | Static Go, about 60 lines. It accepts exactly one request byte |
| Socket | `hardened-unlock-duress.socket`: `/run/hardened-unlock/duress.sock`, root:hardened-duress 0660 | Only root and the `hardened-duress` group can connect |
| Service | `hardened-unlock-duress.service` | `DynamicUser`, CAP_SYS_BOOT as its only capability, no network, `ProtectSystem=strict`, syscall filter `@system-service reboot` |
| Group | `hardened-duress` (sysusers.d) | `duress set` adds the user. It takes effect at the next login |

Setup:

```sh
run0 hardened-unlock duress set      # asks twice; adds you to hardened-duress
# log out and back in
run0 hardened-unlock duress status   # canary set, group membership, helper socket
run0 hardened-unlock duress clear    # remove it
```

`set` refuses an empty canary, the account password, and tokenvault's TPM2 and FIDO2
PINs (the FIDO2 PIN is the key PIN the lock screen asks for). Pick something you can type
under stress. It must not be anything you'd type by habit at that screen.

**Trade-offs and limits:**

- **DoS:** any process running as your user can connect to the socket and reset the
  machine, losing unsaved work. Other users can't. That's the cost of a helper the locker
  can reach without the canary.
- **The canary isn't a secret against the machine's own user.** The group can read the
  hash, so a process running as you can guess against it offline. Use a long canary.
- **It doesn't help** against someone who knows about the canary, who saw you set it,
  or who copies the disk or works on the running machine before you're asked to unlock.
  It also doesn't help if you're made to unlock at boot (tokenvault has no duress mode).
- **Cold boot:** a reset doesn't wipe RAM, and the LUKS volume key is in RAM while the
  system runs. See "Reset-attack state" below.
- If the canary is typed while the reset helper is down, the session stays locked and
  can't be unlocked by that locker. Kill it from another TTY and start a new one; the
  session stays locked meanwhile.

**Reset-attack state** (measured in the VM e2e): the image kernel has
`CONFIG_RESET_ATTACK_MITIGATION` off, and the firmware's `MemoryOverwriteRequestControl`
exists but is 0. Nothing asks the firmware to clear RAM after the reset, and the
LUKS volume key is in memory while the system runs. `init_on_free=1` clears freed pages
only, not the live key. A cold-boot attack right after the reset is out of scope; see
`docs/threat-model.html`.

Duress tests:

```sh
lockscreen/build.sh                    # also builds out/duresstest/ (marker instead of reset)
lockscreen/test/duress-e2e.sh          # container, virtual key, wtype; never resets anything
test/bootc/duress-vm-e2e.py --work W   # the real reset, inside a VM (dev image, lab disk)
```

| Test | Checks |
|---|---|
| duress: set | refuses the account password, tokenvault's TPM2 and FIDO2 PINs, an empty canary and two different entries; writes a yescrypt hash as root:hardened-duress 0640 in a 0755 directory, even under root's umask 027; adds the user to the group |
| duress: before Enter / PIN prompt / password prompt | the canary gives the reset request (marker), the session stays locked, PAM gives no result, nothing reaches the key or faillock |
| duress: real credentials | PIN + touch + password still unlock with a canary set |
| duress: malformed / missing file | logged without its contents, the unlock works |
| VM: helper | socket root:hardened-duress 0660, other users can't connect, a malformed request doesn't reset, the helper has CapEff = CAP_SYS_BOOT only, SELinux enforcing, no AVC |
| VM: reset | SDDM session with scroll on DRM, Mod+Alt+L locks through `lock`, the canary on the emulated keyboard: "reboot: Restarting system" with none of the shutdown lines a graceful reboot prints, then the guest boots again; the previous boot's journal has no shutdown sequence |

## Tests

Both tests use the image rootfs (`localhost/scroll-secure-rootfs`) in a container and the
virtual FIDO2 key from `test/vfido`. They need sudo for the USB gadget. The host's real
key, PAM and accounts are never used.

```sh
lockscreen/build.sh
lockscreen/test/pam-e2e.sh     # PAM stack via authtest
lockscreen/test/gui-e2e.sh     # the real locker under headless scroll, typed with wtype
```

| Test | Checks |
|---|---|
| pam: good | key PIN, touch, then password: OK, in that order, with the touch cue shown |
| pam: wrong-pin / no-touch | fails, and the password is never asked |
| pam: wrong-password, same secret twice | fails |
| gui: lock | `scroll-lock` (SIGUSR1 → `lock_command hardened-unlock -f`) returns only once the session is locked; the state file exists |
| gui: wrong PIN | stays locked, no password prompt |
| gui: crash | `kill -9` of the locker leaves the session locked; a new locker takes over |
| gui: unlock | PIN typed before Enter, touch, password: unlocked and the locker exits |
| gui: really unlocked | the screen after the unlock isn't scroll's red abandoned-lock screen. A locker that exits before its unlock request reaches the compositor leaves the session locked, which this test caught once |
| gui: spawned mode | on a second scroll with the default `privileged_clients spawned`: a locker run directly can't lock, grim and wtype are denied, `scroll-lock` still locks |

The main gui instance sets `privileged_clients all` (lab only, `test/scroll-test.conf`), so
that wtype and grim, plain clients, can drive it.

`go test ./...` (run by `build.sh`) covers the prompt protocol: one answer per prompt,
answers zeroed after sending.
