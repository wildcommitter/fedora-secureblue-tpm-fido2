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

In the guest (Fedora), as root:

```sh
./install.sh <user>               # from vmgui/guest: waypipe, unit, environment.d, linger
```

Then any Wayland app started in the guest user's session shows up on the host. `vmgui run`
uses systemd's ssh-over-vsock: the guest needs `openssh-server` (systemd-ssh-generator puts
sshd on vsock in a VM) and your public key in `authorized_keys`. **`vmgui run`, `install.sh`
and `vmgui-guest` haven't been exercised by the e2e yet** (it has no real guest, see
below).

## Limits

- **No GPU path.** `--no-gpu` on both ends: shm buffers only, with no dmabuf from the guest.
  That's fine for desktop apps, but video and 3D are CPU-rendered in the guest.
- **No Xwayland.** Wayland apps only, on both sides.
- **Clipboard.** Guest apps use the normal Wayland clipboard with the focused window.
  Qubes' explicit copy between VMs isn't there. A focused guest window can read what you
  copied on the host.
- **waypipe client parses guest data.** It's the trust boundary, so it's confined, but it's
  not a minimal GUI daemon like Qubes'.

## Test

```sh
vmgui/test/vmgui-e2e.sh                               # loads vsock_loopback (sudo) if needed
SCROLL_RPM_DIR=<dir> vmgui/test/vmgui-e2e.sh          # with a scroll RPM not yet in the image
```

The test runs headless scroll in the image rootfs with vmgui-host started by
`exec_privileged`. The "guest" is a waypipe server in the same container on vsock loopback
(CID 1). It checks:

- the security context and the confined waypipe
- that a host client can't claim `scroll-vm`
- that a guest app gets no privileged globals
- the frame color
- that the wrong CID is refused
- that the window goes away with the guest
