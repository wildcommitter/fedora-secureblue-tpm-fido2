# vmgui: VM windows in the scroll session

Apps run inside KVM guests. Each window appears on the host as a normal scroll window,
framed in its VM's color and titled `[vm] …`, as in Qubes OS. The guest never gets a
network path to the host. Windows travel over **vsock**, and only from the VM's own CID.

## How it works

| Where | What | Notes |
|---|---|---|
| Guest | `vmgui-guest` (user unit) runs `waypipe server` on `$XDG_RUNTIME_DIR/wayland-vmgui` | `environment.d` points Wayland apps there. Each app is one vsock connection to host CID 2, port 20000 + the guest's CID |
| Host, kernel | vhost-vsock | Sets the peer CID. A guest can't forge it |
| Host, session | `vmgui-host <vm>`, started by scroll with `exec_privileged` | Accepts vsock only from the VM's CID (`/etc/vmgui/<vm>.conf`, root-owned) and splices to `waypipe client` |
| Host, session | `waypipe client --no-gpu -c none` | Runs under `setpriv`: no new privileges, Landlock (read-only `/usr`, `/etc`; its run dir; no TCP). Connects to scroll through a **security context** |
| Host, compositor | Security context `sandbox_engine=scroll-vm`, `app_id=<vm>` | Our scroll fork allows that engine only from privileged clients (scroll-started), so a host app can't fake a VM frame. Sandboxed clients get none of the privileged protocols (capture, input injection, lock, layer-shell, clipboard managers) |
| Host, compositor | `for_window [sandbox_engine="^scroll-vm$" sandbox_app_id="^<vm>$"] border_color …, title_format "[<vm>] %title"` | `border_color` (fork) beats every other state color (urgent, pinned, …). Unfocused windows use a darker shade |

vmgui-host makes the context over its privileged connection, then closes that connection.
Nothing privileged is left in the process that handles guest traffic. If vmgui-host exits,
the context closes and the VM's windows go with it.

## Host packages (bare)

The image keeps only KVM via libvirt's QEMU driver (modular daemons: qemu, network,
nodedev, secret, storage-core), swtpm, OVMF and waypipe. It removes the base's
virt-manager, SPICE/GTK/SDL UIs, qemu-user, remote block/storage, Xen/VirtualBox/LXC/CH
drivers, virtiofsd, guest agents and podman machine. It ships no default NAT network.
`check-virt` fails the build on any virtualization package outside its allowlist.

## Use

On the host:

```sh
run0 vmgui add work 7 '#cc3333'   # VM name, vsock CID (3..1000000), frame color
virsh edit work                   # add the <vsock> element vmgui printed (also: vmgui xml work)
# log out and in: scroll starts vmgui-host for each VM
vmgui list
vmgui run work firefox            # optional: start an app over ssh on vsock (see below)
```

## Guests: the topology

`vmgui/guest/build.sh` builds the guest half for each (packaging, arch, display) tuple
into `vmgui/guest/out/`:

| Guest | Packaging | Arch | Display | Artifact | Path to the host |
|---|---|---|---|---|---|
| Linux | rpm | x86_64, aarch64 | wlroots | `vmgui-guest` + `vmgui-guest-wlroots` (noarch) | waypipe |
| Linux | rpm | x86_64, aarch64 | xorg | `vmgui-guest` + `vmgui-guest-xorg` (noarch) | xwayland-satellite → waypipe |
| Linux | deb | x86_64, aarch64 | wlroots | `vmgui-guest` + `vmgui-guest-wlroots` (all) | waypipe |
| Linux | deb | x86_64, aarch64 | xorg | `vmgui-guest` + `vmgui-guest-xorg` (all) | xwayland-satellite → waypipe |
| Windows 11 | zip + `install.ps1` | amd64, arm64 | Win32 / DWM | `vmgui-agent-win11-<arch>.zip` | vmgui-agent → wire protocol |
| macOS | tar.gz + LaunchAgent | amd64, arm64 | Quartz | `vmgui-agent-macos-<arch>.tar.gz` | vmgui-agent → wire protocol |

- **Linux packages are noarch.** They contain a Python launcher, units and environment.d
  files. waypipe and xwayland-satellite come from the guest distro for its own arch. The
  install tests ran on x86_64 only, because this host has no aarch64 emulation.
- **wlroots** means native Wayland apps on the vmgui display. The guest needs no
  compositor of its own: waypipe is the display.
- **xorg** runs `xwayland-satellite :7` on that display (`DISPLAY=:7`), so X11-only apps
  become ordinary host windows. **Debian 13 and forky don't package xwayland-satellite**,
  so the deb xorg package won't install there yet. Fedora 44 does.
- **win11 and macos** use `vmgui-agent` (Go, `vmgui/guest/agent`) and the wire protocol in
  [PROTOCOL.md](PROTOCOL.md). On the host, `vmgui add --os win11|macos` writes `PROTO=wire`,
  and vmgui-host runs `vmgui-wire` instead of waypipe client: same security context, same
  confinement, same CID check.

Install in the guest:

```sh
dnf install ./vmgui-guest-*.rpm   # or: apt install ./vmgui-guest_*.deb ./vmgui-guest-wlroots_*.deb
loginctl enable-linger <user>     # so the forwarder runs without a login on the guest
```

```powershell
.\install.ps1 -Cid 7             # Windows 11, elevated; needs virtio-win's viosock driver
```

```sh
./install.sh 7                    # macOS, as the user; then allow Screen Recording and Accessibility
```

Then any app in the guest user's session shows up on the host. `vmgui run` uses systemd's
ssh-over-vsock: the guest needs `openssh-server` (systemd-ssh-generator puts sshd on vsock
in a VM) and your public key in `authorized_keys`.

**What's tested and what isn't.** The Linux packages are built and installed in Fedora 44
and Debian 13 containers. The waypipe path and the xorg path (xwayland-satellite) run in
the e2e. The wire path runs end to end with the real `vmgui-agent` (its Linux demo
backend) as the guest. The Windows and macOS backends compile and pass `go vet` for amd64
and arm64, but **they haven't run in a real Windows 11 or macOS guest yet.** That includes
viosock's address family lookup, PrintWindow under DWM, SendInput, and CoreGraphics through
purego. `vmgui run` and `vmgui-guest` in a real VM aren't exercised either.

**macOS:** Apple's licence allows macOS VMs only on Apple hardware, so the agent's real
target is a macOS VM on a Mac (Virtualization.framework, which has virtio-vsock). Under
QEMU/KVM, macOS has no vsock driver we know of, so the agent can't reach the host there.
Close and resize from the host aren't implemented on macOS: they need the Accessibility API.

## Limits

- **No GPU path.** `--no-gpu` on both ends: shm buffers only, with no dmabuf from the guest.
  That's fine for desktop apps, but video and 3D are CPU-rendered in the guest.
- **No Xwayland on the host.** X11 apps run only in the guest (the xorg variant), and
  reach the host as Wayland windows.
- **Wire keyboard input is raw evdev codes.** The guest maps them to its own codes (set-1
  scancodes on Windows, kVK on macOS), so set the guest's keyboard layout to match the
  host's. There's no cursor image on wire windows yet.
- **Clipboard.** Guest apps use the normal Wayland clipboard with the focused window.
  Qubes' explicit copy between VMs isn't there. A focused guest window can read what you
  copied on the host.
- **waypipe client parses guest data.** It's the trust boundary, so it's confined, but it's
  not a minimal GUI daemon like Qubes'. For wire guests, `vmgui-wire` is the boundary: about
  500 lines of stdlib Python, closer to Qubes' daemon. It checks every length, size and
  rectangle, and any violation drops that connection and its windows.

## Test

```sh
vmgui/test/vmgui-e2e.sh                               # loads vsock_loopback (sudo) if needed
SCROLL_RPM_DIR=<dir> vmgui/test/vmgui-e2e.sh          # with a scroll RPM not yet in the image
vmgui/test/vmgui-wire-e2e.sh                          # the win11/macos path, real agent (demo backend)
vmgui/guest/build.sh                                  # all guest targets; go vet x6, go test
```

`vmgui-wire-e2e.sh` checks:

- vmgui-wire runs confined instead of waypipe
- the agent's window has the VM's border and the guest's pixels
- the compositor's configure reaches the guest
- keyboard and pointer input arrive, including after the seat's pointer is unplugged and
  replugged
- a bad HELLO, damage outside the window and an oversized window each drop only that
  connection
- the window goes away with the agent

The test runs headless scroll in the image rootfs with vmgui-host started by
`exec_privileged`. The "guest" is a waypipe server in the same container on vsock loopback
(CID 1). It checks:

- the security context and the confined waypipe
- that a host client can't claim `scroll-vm`
- that a guest app gets no privileged globals
- the frame color
- that the wrong CID is refused
- that the window goes away with the guest
