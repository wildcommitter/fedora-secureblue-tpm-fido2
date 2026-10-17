# QEMU lab — resume notes

Status as of this session's pause: base VM is fully installed and verified
bootable with the plain password. `enroll.sh` has one confirmed bug fix
applied (see below) and is mid-run, waiting on the first FIDO2 touch, when
we paused for the day. **The real physical FIDO2 key was detached
(USB passthrough) and has been cleanly returned to the host** — `lsusb`/
`fido2-token -L` both show it back under normal host permissions. All VM
processes (qemu, swtpm, the serial bridge) were shut down cleanly; the
qcow2 disk is not corrupted.

## What's done (tasks 1-5, all completed)
- `cachyos-live.iso` — real installer ISO content only (not the whole USB stick).
- `disk.qcow2` (20G) — has a minimal Arch/CachyOS base installed:
  - partitions: vda1 512M ESP (FAT32), vda2 rest (LUKS2 root, ext4 inside)
  - **guest LUKS UUID: `189a2814-10e9-4b8e-a130-3ad421930792`**
  - **lab LUKS/root password: `labtest123`** (test-only, obviously not secret)
  - `/etc/mkinitcpio.conf` HOOKS includes `sd-encrypt` (mirrors the real host)
  - systemd-boot installed, loader entry at `/boot/loader/entries/arch.conf`
    with cmdline `rd.luks.uuid=... root=/dev/mapper/luks-... rw console=tty0 console=ttyS0,115200n8`
    (both consoles needed — ttyS0 alone broke console routing for some reason
    not fully root-caused; tty0-first-then-ttyS0 is what actually works and
    puts both boot messages AND the interactive password prompt on serial)
  - `/root/hardened-boot/` — the whole project copied in (excludes `labvm/`)
- Baseline confirmed: booting the installed disk prompts for the plain
  passphrase and boots to a login prompt, both via screendump (video
  console) and, after the console fix, via serial.

## Bug found and fixed in the real project (already committed to disk, not just the VM)
`enroll.sh` referenced `$LUKS_DEVICE` (for a status echo) and used it in
`[ -b "$LUKS_DEVICE" ]` checks **before** the bootstrap step that installs
`/etc/hardened-boot/hardened-boot.conf` (which is what actually defines
`LUKS_DEVICE`). On a fresh machine with no prior enrollment, that config
file doesn't exist yet, so under `set -u` the script died immediately with
`LUKS_DEVICE: unbound variable`. Fixed by moving the bootstrap block (create
`/etc/hardened-boot`, install default config, re-source `lib/common.sh`)
to the very top of the script, before anything references those variables.
This fix is already saved in `/home/user/hardened-boot/enroll.sh` — nothing
further to do there, just re-sync it into the VM (see below) since the
VM's copy predates the fix... actually it doesn't: we already `cp`'d the
fixed version into the VM via the 9p share before the last run. No further
sync needed unless the VM disk is rebuilt from scratch.

## Exactly where we stopped (task 6, in progress)
Inside the VM, `cd /root/hardened-boot && ./enroll.sh` was run (as root,
password `labtest123`), got past the config bootstrap, printed:
```
-- FIDO2 --
hardened-boot: using device /dev/hidraw1
Touch your security key now to create the credential...
```
and was waiting on `fido2-cred -M` (the physical touch) when we paused.
We sent it a clean Ctrl-C (SIGINT, confirmed in the log) before shutting
the VM down, so nothing is half-written to the LUKS header — the fallback
password keyslot (slot 0) is untouched and slot 1 is still free.

## Exact steps to resume tomorrow (fresh session, no memory of this conversation)
1. Restart swtpm (state dir `tpm2/` persists the emulated TPM's identity —
   do NOT delete it):
   ```
   rm -f tpm2/swtpm-sock tpm2/.lock
   nohup swtpm socket --tpmstate dir=tpm2 \
     --ctrl type=unixio,path=tpm2/swtpm-sock --tpm2 --log level=1 \
     > tpm2/swtpm.log 2>&1 &
   ```
2. Launch the VM **as root** (needed for USB passthrough permissions on
   `/dev/bus/usb/001/010` or wherever the key enumerates) with `--fido2`:
   ```
   sudo chmod 666 tpm2/swtpm-sock
   sudo nohup ./launch-installed.sh --fido2 > qemu-installed.log 2>&1 &
   sudo chmod 666 serial.sock monitor.sock
   ```
3. Start the persistent bridge (do this every time — it doesn't survive a
   VM restart since the socket is new):
   ```
   rm -f bridge.log bridge.fifo
   nohup python3 bridge.py serial.sock bridge.log bridge.fifo > bridge_stderr.log 2>&1 &
   ```
4. Watch `bridge.log` (`tail -f` or repeated `tail -c N bridge.log | cat -v`)
   for the passphrase prompt, then:
   ```
   printf 'labtest123\n' > bridge.fifo
   ```
   wait for login prompt, then `printf 'root\n' > bridge.fifo`, then
   `labtest123` again for the login password.
5. `cd /root/hardened-boot && rm -rf /etc/hardened-boot && ./enroll.sh`
   via the fifo, watch for "Touch your security key now" in bridge.log,
   **then actually ask the user to touch the key and wait for the log to
   show progress — do not race a fixed timeout against their reaction
   time.** The bridge keeps logging continuously across turns now, so it's
   safe to just check back later.
6. enroll.sh needs the touch twice (credential creation, then hmac-secret
   self-test), then two typed passwords (any two different non-empty
   strings — this is a throwaway lab VM), then it self-verifies with
   `cryptsetup open --test-passphrase` and reports PASS/FAIL.
7. Once enroll.sh passes: `./test-unlock.sh` (also needs pw x2 + one
   touch), then `./install.sh` (rebuilds initramfs with the hardened-boot
   hook), then reboot the VM and confirm the *hardened-boot-agent* (not
   the plain passphrase prompt) is what asks for the two passwords + touch
   this time. Test the `skip` escape hatch and `hardened_boot.disable=1`
   cmdline flag on separate boots too (task 7).

## Known rough edges to keep in mind
- swtpm exits when its QEMU client disconnects — always restart it before
  relaunching the VM, using the same `tpm2/` state dir so the emulated
  TPM's identity (and hence anything already sealed to it) is preserved.
- The USB passthrough device IDs are hardcoded in `launch-installed.sh`
  (`vendorid=0x1ea8,productid=0xfc26`) — that's this specific ExcelSecu
  key; if a different key is used, update that.
- Only one client can hold the serial unix socket at a time in practice —
  always go through `bridge.py`/`bridge.fifo` rather than connecting a
  fresh `serial_drive.Session` once the bridge owns the connection.
- `qemu-nbd`/`/dev/nbd0` was used a couple of times to hand-edit the ESP's
  loader entry directly from the host without a live-ISO boot — handy
  trick if the loader entry ever needs tweaking again; remember to
  `qemu-nbd --disconnect /dev/nbd0` afterward (VM won't boot otherwise).
