# llm: a local model server on the host GPU, for the guests

**Status: steps 1–3 of the [plan](#plan) are built and tested**: the server image (from
source, reproducible), the host side (units, `llm` CLI, the endpoint, `llmctl`) and
vmswitch's `llm` network. The host side ran on the sealed image under KVM, on the CPU
(the lab VMs have no GPU); the GPU ran on this workstation's current OS. Not done: the
installer payload (step 4) and a GPU run on the sealed image (step 5). See
[What was verified](#what-was-verified).

```sh
llm/build.sh [tag]                      # -> llm/out/llm-server.oci.tar (reproducible)
llm import DIR                          # on the host: SHA256SUMS, llm-server.oci.tar, one .gguf
vmswitch plug <guest> <nic> llm         # the guest gets 10.89.N.2/30; API at http://10.89.255.1:8080/v1
llm key show                            # the key guests send
llm allow <cid>                         # llmctl for that guest
```

## Decisions (2026-11-22)

| Question | Decided |
|---|---|
| Podman socket to guests | **No.** Guests get the inference API only. Control goes through `llmctl` over vsock, with fixed verbs and a CID allowlist |
| Transport | **vmswitch network `llm`**: one port on one host address, opt-in per NIC |
| Model | **`RVN-Q6_K-multilingual-mtp.gguf`** (22.5 GB, Q6_K) |
| Installer | **Local USB image with a payload partition**, built only on this machine, never published |

## Goal

The host runs llama.cpp's OpenAI-compatible server in podman on the Radeon AI PRO R9700
(amdgpu), with the 27B model already on this machine. Guests reach that one endpoint over
their vmswitch network. The installer brings the container image and the model, so a
fresh install serves without a download.

## What was verified

On 2026-11-22, on this workstation (CachyOS kernel 7.3.4, rootless podman 6.2.0):

| Item | Result |
|---|---|
| GPU | Navi 48, Radeon AI PRO R9700 `1002:7551`, RDNA4 (gfx1201), 31.9 GiB VRAM, amdgpu |
| Driver path | Vulkan through Mesa RADV (`AMD Radeon AI PRO R9700 (RADV GFX1201)`), render node `/dev/dri/renderD128` only. No `/dev/kfd`, no ROCm |
| Server | `ghcr.io/ggml-org/llama.cpp:server-vulkan` `sha256:ea76d71d…` (built 2026-11-22), `-ngl 999 -c 16384`, 4 slots |
| Model | `/srv/models/RVN-Q6_K-multilingual-mtp.gguf`, 22.5 GB: GGUF name "Qwen38 Ara v5", 27B, arch `qwen35`, 262k native context |
| Load | All layers on Vulkan0. llama.cpp ignores block 64 (the MTP / `nextn` head). Flash attention fell back to off on this backend |
| Speed | Generation 24.1 tokens/s, prompt 96.7 tokens/s (61-token prompt, 152 tokens out) |
| VRAM | 22.1 GiB in use while serving at 16k context (desktop included) |

The image built from source (`llm/build.sh`, llama.cpp `b12634` = `42f6a58f`, Vulkan only):

| Item | Result |
|---|---|
| Size | 436 MB: Fedora 44 runtime tree from `rpms.lock` (stages `llm-build`, `llm-server`), no shell, no dnf/rpm, uid 65534 |
| Reproducible | Two `NO_CACHE=1` builds: the same image ID (`8e157b12…`) and the same `llm-server.oci.tar` (sha256 `f32bd5d8…`) |
| Run | `--read-only --cap-drop all --security-opt no-new-privileges`, render node only: all layers on Vulkan0 |
| Speed | Generation 23.9 tokens/s, prompt 99.0 tokens/s (the same prompt): on par with upstream's image |
| Not built | The web UI (upstream fetches a prebuilt copy at configure time) and HTTPS client support. Guests use the API |

The host side on the sealed image (`test/bootc/llm-vm-e2e.py`, dev keys, SELinux
enforcing, the 1.5B model on the CPU with `DEVICE=none`): **35/35**.

| Area | Checked |
|---|---|
| Before import | sysusers `llm`, tmpfiles modes, every unit off |
| `llm import` | From an ext4 payload labelled `SCROLL-PAYLOAD`: sha256s, `podman load` (narrow policy file, see below), model 0640 root:llm, selected, key created, units on |
| The server process | uid `llm`, `CapEff`/`CapBnd` 0, `NoNewPrivs` 1, uid_map `0 0 4294967295` (no user namespace), a network namespace with only `lo`, `container_t`, read-only root |
| The endpoint | vmswitch `llm` NIC: a SYN from the guest side of the TAP gets a SYN-ACK; the NIC's host end and other ports don't answer. `/health`, no or wrong key 401, right key 200, `/slots` off, a completion. The proxy is a dynamic user in `systemd_socket_proxyd_t` |
| `llmctl` (vsock loopback) | `status`, `use` (checked, restarted, back up), a path refused, a CID not allowed gets nothing |
| Key, reboot | `llm key rotate`: the old key 401, the new 200. After a reboot the server is back by itself, `llm` keeps its uid |
| SELinux | No AVC for the server, podman, conmon, crun or the proxy, except podman's user-namespace probe, which secureblue denies by design (podman goes on without one) |

Found on the way, by the VM e2e, and fixed in the design:

| Found | Fix |
|---|---|
| secureblue's `/etc/containers/policy.json` rejects unsigned images, local archives too | `llm import` checks the archive's sha256 against `SHA256SUMS`, then loads it with `--signature-policy /usr/share/llm/load-policy.json` (accepts an `oci-archive`, nothing else). The global policy stays |
| systemd can't create a vsock socket labelled for an `unconfined_service_t` service | `llmctl-host` listens itself (`llmctl.service`), one child per connection |
| `systemd_socket_proxyd_t` may neither bind 8080 nor reach a container's socket | `llm.cil`: those rules plus `nnp_transition` and journal logging, for that one domain |
| firewalld rejects port 8080 from the TAP, whatever vmswitch's table accepts | vmswitch ships the firewalld zone `vmswitch-llm` (see `vmswitch/README.md`) |

`llm/test/llm-e2e.sh` (this workstation, no root): 12/12. `llmctl-host` and both clients
over vsock loopback, every verb and the bad inputs; the server image on the R9700 with
`llm-run`'s flags behind `systemd-socket-proxyd`: the key, `/slots` off, a completion
on the GPU (VRAM grows by the model's size).

**Not verified:**
- the GPU on the sealed image (step 5): the SELinux boolean for `/dev/dri` in `container_t`, the `render` group
- ROCm
- a real guest OS using the endpoint and `llmctl` over a real vsock device (the e2e plays the guest with `tapprobe.py` and vsock loopback)
- the installer payload (step 4)

## Which model

Two files on this machine match "27B heretic NVR"; both are "Qwen38 Ara v5":

| File | Size | Quant | Notes |
|---|---|---|---|
| `RVN-Q6_K-multilingual-mtp.gguf` | 22.5 GB | Q6_K | Has an MTP head llama.cpp doesn't use today (about 0.5 GB of unused tensors) |
| `RVN-Q5_K_M-multilingual-vision.gguf` | 21.0 GB | Q5_K_M | The vision variant. llama.cpp needs its separate `mmproj` file for images, and none is in `/srv/models` |

Decided: the Q6_K file. Its licence is unknown, which matters only if the file ever leaves
this machine. This design never publishes it.

## Architecture

```
 guest (vmswitch NIC on network "llm")          host
 ─────────────────────────────────────         ──────────────────────────────────────────────
 app → http://10.89.255.1:8080/v1   ──TAP──▶  nft: only tcp 8080 to 10.89.255.1 from llm NICs (step 3)
                                               │
                                               ▼
                                     llm-proxy.socket 10.89.255.1:8080 → systemd-socket-proxyd
                                       (DynamicUser, group llm, no network of its own, AF_UNIX only)
                                               │ /run/llm/llm.sock
                                               ▼
                                     llm.service: rootful podman, host user namespace
                                       llama-server as uid llm, --network=none, read-only, cap-drop all
                                       --device /dev/dri/renderD128   (Vulkan, RADV)
                                       model: /var/lib/llm/models/<sha256>.gguf, read-only
 llmctl ─────────────── vsock :21000 ──▶  llmctl.service: llmctl-host (CID allowlist, fixed verbs)
```

### Why rootful podman, without a user namespace

The design first said rootless podman. secureblue rules that out as shipped:

| Module (secureblue) | What it denies |
|---|---|
| `harden_userns` | `user_namespace create` to every domain outside a short list (flatpak, bubblewrap, browsers, containers…). A user's or a service's podman is one of the denied |
| `harden_container_userns` | the same to `container_domain`, `container_runtime_domain` and `spc_t`. Active by default; `ujust set-container-userns on` removes it |

Rootless podman needs a user namespace, and so does rootful podman with `--userns=auto`.
Turning `set-container-userns` on would weaken the base image for every container. So
podman runs rootful with the host's user namespace, and the server gets none of root:

| Layer | Setting |
|---|---|
| Identity | `--user llm:llm`: the host uid `llm` (sysusers), not root in a namespace |
| Privileges | `--cap-drop=all`, `no-new-privileges`, `--pids-limit=256`, SELinux `container_t` with its own MCS pair |
| Network | `--network=none`: a namespace with only `lo`. The server can't reach anything, not even the host |
| Files | `--read-only` root, the model `:ro`, `/run/llm` (its socket) the only writable bind |
| Listening | `--host /run/llm/llm.sock`: a unix socket, mode 0770 via `--umask=0007`, in `/run/llm` (0750 llm:llm) |
| Endpoints | `--api-key-file` (podman secret `llm-api-key`); `--no-slots` (`/slots` would show one guest's prompts to the others); no web UI built; `/props` POST off (default) |
| GPU | `--device` for the render node and `--group-add render`; `DEVICE=none` in `llm.conf` runs on the CPU |

The guests' TCP endpoint is `llm-proxy.socket` (`10.89.255.1:8080`, `FreeBind`, so it
can come up before step 3's interface does). Each connection goes through
`systemd-socket-proxyd` to the unix socket. The proxy runs as a dynamic user in group
`llm`, with `PrivateNetwork=yes` and `RestrictAddressFamilies=AF_UNIX`: the listening
socket comes from systemd, and the proxy can open nothing but the server's socket.

### Files

| Path | What |
|---|---|
| `llm/host/usr/lib/systemd/system/llm.service` | Runs `llm-run start`/`stop` (`Type=notify` through conmon). Off until `/var/lib/llm/current` exists |
| `llm/host/usr/libexec/llm/llm-run` | Builds the `podman run` line above from `/etc/llm/llm.conf` (`CTX`, `SLOTS`, `DEVICE`) |
| `llm/host/usr/lib/systemd/system/llm-proxy.{socket,service}` | The guests' endpoint and the relay |
| `llm/host/usr/lib/systemd/system/llmctl.service` | `llmctl-host` on vsock port 21000, one child process per connection |
| `llm/host/usr/libexec/llm/llmctl-host` | One llmctl request: CID check, fixed verbs |
| `llm/host/usr/bin/llm` | The host CLI (root) |
| `llm/host/usr/lib/sysusers.d/llm.conf`, `tmpfiles.d/llm.conf` | User `llm`; `/var/lib/llm{,/models}` root:llm 0750; `/run/llm` llm:llm 0750 |
| `vmgui/guest/linux/common/usr/bin/llmctl` | Guest client, Linux (in the `vmgui-guest` rpm/deb) |
| `vmgui/guest/agent/cmd/llmctl` | Guest client, Windows and macOS (in the agent zip/tarball) |

### The host CLI

| Command | What |
|---|---|
| `llm status` | Units, model, image, key, allowed CIDs |
| `llm import DIR` | A payload directory: `SHA256SUMS` listing `llm-server.oci.tar` and one `.gguf`. Checks every sha256, `podman load`s the image, copies the model to `models/<sha256>.gguf` (0640 root:llm, checked again), selects it if none is, creates the API key if there is none, enables and starts `llm.service` and `llm-proxy.socket` |
| `llm use SHA256` | Checks a model already in `models/` against its name, selects it, restarts |
| `llm key [show\|rotate]` | The key guests send (`Authorization: Bearer …`). Rotate restarts the server |
| `llm allow CID` / `llm deny CID` | `/etc/llm/clients.conf`; the first `allow` enables `llmctl.service` |

A model is checked when it's imported or selected, not at every start: 22 GB take
about 15 s to hash, and the file is root-owned inside the encrypted root.

### Reaching it from guests

Today vmswitch drops every packet from a guest to the host (`inet vmswitch` input:
`iifname "vs*" drop`). This feature needs one exception, which is a design change.
**Decided: A.** The two options were:

| | A: vmswitch network `llm` (recommended) | B: vsock |
|---|---|---|
| Guest side | Static address, a route to `10.89.255.1`, any HTTP client | A small relay (TCP localhost → vsock) in every guest, per OS |
| Host side | A dummy interface with `10.89.255.1/32`. Each NIC on `llm` gets its own /30 (host `10.89.N.1`, guest `10.89.N.2`), like `uplink`. nft input: accept `tcp dport 8080` to `10.89.255.1` from llm NICs only, drop the rest | vmgui-style CID allowlist, relayed to the server |
| Visibility | A network like any other: `vmswitch plug <guest> <nic> llm`, shown in vmtui | A separate allowlist |
| Exposure | IP, one port, opt-in per NIC. Guests on `llm` can't reach each other | No IP at all |

The server binds only `10.89.255.1`, never `0.0.0.0`. So the LAN, `uplink` guests and other
networks never reach it.

### The podman socket: not exposed (rejected)

You asked for the podman socket to be reachable over the guests' networks. **This design
doesn't do that, and recommends against it.** The podman API can start any container
with any mount. Even rootless, a guest holding the socket runs code on the host as the
socket's user, with that user's files. Rootful, it's root on the host. That would undo
what vmswitch and vmgui exist for: a compromised guest stays in the guest.

Decided: guests control the server through **`llmctl`** instead:

| Piece | What |
|---|---|
| Host | `llmctl.service` runs `llmctl-host`, which listens on vsock port 21000 and forks one child per connection (at most 4 at once). Not a socket unit: systemd would create the vsock socket with the service's label, `unconfined_service_t`, and the policy doesn't let `init_t` create that (found by the VM e2e). It answers only CIDs listed in `/etc/llm/clients.conf` (root-owned, `llm allow`), read from the connection's peer address; others are logged and closed |
| Verbs | `status` (up, model sha256, ctx, slots), `restart`, `models` (sha256s under `/var/lib/llm/models`), `use <sha256>` (only a model already there, checked against its name, then restart). One line in (at most 256 bytes), one JSON line out |
| What it can't do | Start other containers, mount anything, pass arguments to podman, or add a model. It restarts the one unit and swaps one symlink. It runs as root without any capability, `ProtectSystem=strict`, writable only `/var/lib/llm`, group `llm` for the server's `/health` |
| Guest | `llmctl <verb>`: Python on Linux (`vmgui-guest` package); Go on Windows and macOS (next to `vmgui-agent`, the same vsock code) |

## The installer: "baked into the ISO"

Today's ISO is a small online installer. It pulls the signed image from the registry and
contains no OS payload. The model can't simply go in:

- **Size:** 21–22.5 GB. ISO9660 caps one file at 4 GiB, and GitHub release assets at 2 GiB.
- **Publication:** the ISO in Releases is public, and the model's licence is unknown.
- **Signing:** the image is cosign-verified, and a model inside it would bloat every update.

Proposal: a **local offline installer image**, built only on this machine and never
published.

| Step | What |
|---|---|
| Build | `image/iso/build-iso.sh --payload llm` writes a raw USB image (at least 32 GB): the usual installer, plus a second partition `SCROLL-PAYLOAD` |
| Payload | `llm-server.oci.tar` (`llm/build.sh`), the model `.gguf`, and `SHA256SUMS` that pins both: the layout `llm import` reads |
| Install | After `bootc install`, the first boot runs `llm import` on the payload: it checks every sha256, loads the OCI archive into root's podman storage, copies the model into `/var/lib/llm/models` and creates the API key |
| Without payload | The normal ISO stays as it is. The feature is then off until a payload is added (`llm import <dir>`) |

Decided: the USB image with a payload partition.

## Knobs

| Knob | Default | Notes |
|---|---|---|
| `LLM_MODEL` | `/srv/models/RVN-Q6_K-multilingual-mtp.gguf` | Path at build, sha256 pinned in the payload |
| `LLM_BACKEND` | `vulkan` | `rocm` adds `/dev/kfd` and the ROCm build |
| `CTX` in `/etc/llm/llm.conf` | `16384` | 22.1 GiB measured at 16k. 32 GiB of VRAM leaves room for more |
| `SLOTS` in `/etc/llm/llm.conf` | `4` | Parallel requests (llama-server `-np`) |
| `DEVICE` in `/etc/llm/llm.conf` | `/dev/dri/renderD128` | A render node, or `none` for the CPU (the lab VM) |
| Endpoint | `10.89.255.1:8080` | Fixed in `llm-proxy.socket`; vmswitch's `llm` network carries it (step 3) |
| `LLAMACPP_REF`, `LLAMACPP_COMMIT` | `b12634`, `42f6a58f…` | Build ARGs in `llm/Containerfile`. The clone must match the commit. Bump both together, never `latest` at build time |

## Rules this touches

| Rule (AGENTS.md) | Effect |
|---|---|
| Guest networks only via vmswitch; guests reach no host service | **Changed (agreed):** one port on one host address, opt-in per NIC. Plus `llmctl` on vsock with a CID allowlist |
| VM windows: no GPU path | Unchanged. The GPU stays with the host, and guests get text over HTTP |
| Virtualization stays bare (`check-virt`) | Unchanged. podman isn't virtualization, and no guest-side package is added |
| No GitHub artifacts, reproducible build | Kept by building llama.cpp from a pinned source tag in a locked stage |
| Secrets never enter the repo | API key generated at install. The model is never in the repo or a published artifact |

## Plan

1. **Done:** `llm/` stage: llama.cpp from source (Vulkan), repro-lint premises (P1, P5, P7, P8 cover `llm/`)
   and `rpms.lock` entries (`rpmlock.py update --only llm-build,llm-server` leaves the other stages alone).
2. **Done:** `llm.service` (rootful podman, no user namespace, see above), `llm` system user,
   tmpfiles, the `llm` CLI, `llm-proxy`, `llmctl-host` (vsock, CID allowlist) and the guest
   `llmctl` clients.
3. **Done:** vmswitch: the `llm` network (option A), the firewalld zone, tests in a container netns
   (`vmswitch-e2e.sh`, 28/28) and on the sealed image (`llm-vm-e2e.py`).
4. Installer payload: `build-iso.sh --payload`, then a KVM e2e: install from the USB image, boot, check that a
   guest on `llm` gets an answer and a guest on `uplink` doesn't.
5. A GPU smoke on the sealed image on this machine. That's the only real-hardware step: the
   lab VMs have no R9700.
