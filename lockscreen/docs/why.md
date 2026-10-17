# Why not just configure Noctalia's lock screen?

CachyOS's niri setup here ships with Noctalia as the desktop shell, which has
its own built-in lock screen. It authenticates by calling `pam_start()` /
`pam_authenticate()` against a PAM service literally named `pam-helper`
(confirmed via `strings` on `/usr/bin/noctalia`, and in its source at
`src/auth/pam_authenticator.cpp`).

Adding `pam_u2f` to that service's PAM stack does work mechanically — the
FIDO2 touch/fingerprint check happens as part of `pam_authenticate()`
regardless of what called it. What doesn't work is any on-screen feedback
for it. Noctalia's PAM conversation callback is:

```cpp
switch (msg[i]->msg_style) {
case PAM_PROMPT_ECHO_OFF:
  replies[i].resp = ::strdup(data->password != nullptr ? data->password : "");
  break;
case PAM_PROMPT_ECHO_ON:
  replies[i].resp = ::strdup("");
  break;
case PAM_ERROR_MSG:
case PAM_TEXT_INFO:
  replies[i].resp = nullptr;   // <-- message text is never read or forwarded
  break;
```

`pam_u2f`'s `cue` option ("Please touch the device.") is delivered as exactly
a `PAM_TEXT_INFO` message — which this callback discards without even
logging it. So there is no PAM configuration that makes Noctalia's lock
screen show a "touch your security key" prompt; it's compiled into the
binary.

Noctalia's `lock_screen.cpp` does have the right shape for this (an
`m_status`/`m_statusIsError` string and a `handleFingerprintStatus` callback
used for its separate fprintd-based fingerprint feature), so a small patch
mirroring that pattern would fix it — but that means building Noctalia from
source and pinning the package against `pacman -Syu` overwriting the patch on
every upstream update.

`hardened-unlock` sidesteps all of that: it's a small, independent locker
that owns its own PAM conversation callback and forwards every
`PAM_TEXT_INFO` / `PAM_ERROR_MSG` message to the screen live. Noctalia's own
lock screen is simply not used for the lock keybind / idle timeout anymore
(see `niri/autolock.md`); nothing about Noctalia itself needs to change.
