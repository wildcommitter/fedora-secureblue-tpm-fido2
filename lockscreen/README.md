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

The drop-in locks with **Mod+Alt+L**, after 5 minutes idle, and before suspend.
`hardened-unlock -f` returns once the session is locked (like `swaylock -f`). That's what
`swayidle -w ... before-sleep` needs: the machine suspends only after the lock is in place.

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
| gui: lock | `-f` returns only after the compositor confirmed the lock |
| gui: wrong PIN | stays locked, no password prompt |
| gui: crash | `kill -9` of the locker leaves the session locked; a new locker takes over |
| gui: unlock | PIN typed before Enter, touch, password: unlocked and the locker exits |
| gui: really unlocked | the screen after the unlock isn't scroll's red abandoned-lock screen. A locker that exits before its unlock request reaches the compositor leaves the session locked, which this test caught once |

`go test ./...` (run by `build.sh`) covers the prompt protocol: one answer per prompt,
answers zeroed after sending.
