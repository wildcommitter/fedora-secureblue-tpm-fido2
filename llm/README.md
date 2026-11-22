# llm: a local model server on the host GPU, for the guests

**Status: step 1 of the [plan](#plan) is built**: the server image, from source,
reproducible (`llm/Containerfile`, `llm/build.sh`). Not done yet: the host units,
`llmctl`, the vmswitch network and the installer payload. Everything was run on this
workstation's current OS (CachyOS), not on the sealed image, see
[What was verified](#what-was-verified).

```sh
llm/build.sh [tag]     # -> llm/out/llm-server.oci.tar; repro-lint, rpms.lock, no network but the pinned clone
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

**Not verified:**
- the sealed secureblue image: its SELinux policy, user-namespace settings and podman configuration (the run above used `label=disable`)
- ROCm
- guests reaching the endpoint
- anything about the installer

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
 app → http://10.89.255.1:8080/v1   ──TAP──▶  nft: only tcp 8080 to 10.89.255.1 from llm NICs
                                               │
                                               ▼
                                     rootless podman (Quadlet llm.service), pasta publish
                                     10.89.255.1:8080 → llama-server :8080
                                       --device /dev/dri/renderD128   (Vulkan, RADV)
                                       model: /var/lib/llm/models/<sha256>.gguf, read-only
                                       no outbound network, read-only rootfs, cap-drop all
```

### The server container

| Property | Value | Why |
|---|---|---|
| Image | **Built from source** in our own stage: llama.cpp at a pinned release tag, `-DGGML_VULKAN=ON`, on Fedora 44 with Mesa from `rpms.lock` | No GitHub artifacts in the image (the same rule as scroll). Reproducible like the rest (`image/REPRODUCIBLE.md`). "Latest" means a bump script moves the pinned tag, as `rpmlock.py update` does for RPMs |
| Backend | Vulkan (RADV, already in the image) by default. ROCm as a knob | Vulkan needs only the render node. ROCm adds `/dev/kfd` and several GB of stack, and its RDNA4 support is newer |
| Runtime | Rootless podman under a dedicated system user `llm`, Quadlet unit `llm.container`, started at boot (linger) | No root daemon. vmswitch's forward policy drop already rules out rootful bridge networks |
| Devices | `/dev/dri/renderD128` only | No display node, no `/dev/kfd` unless ROCm |
| Model | `/var/lib/llm/models/<sha256>.gguf`, bind-mounted read-only and checked against a pinned sha256 at start | `/var` is inside the LUKS root. Not in `/usr`: a 22 GB layer in every signed image is a non-starter |
| Hardening | `ReadOnly=true`, `DropCapability=all`, `NoNewPrivileges=true`, default seccomp, SELinux label kept (`container_use_dri_devices` if it's needed), no outbound network (pasta with no gateway) | The server parses untrusted guest prompts. That's its attack surface |
| Auth | `--api-key-file` from a podman secret, generated at install. Never in the repo | Guests on the network still need the key |

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
| Host | `llmctl-host`, a socket-activated service as the `llm` user. It listens on vsock port 21000 and accepts only CIDs listed in `/etc/llm/clients.conf` (root-owned, like `/etc/vmgui`) |
| Verbs | `status` (up, model sha256, slots in use), `restart`, `models` (sha256s under `/var/lib/llm/models`), `use <sha256>` (only a model already there, verified, then restart). One line in, one JSON line out. Anything else closes the connection |
| What it can't do | Start other containers, mount anything, pass arguments to podman, or add a model. It runs `systemctl --user` on the one unit and swaps one symlink |
| Guest | `llmctl <verb>`: a few lines, Python on Linux and macOS, PowerShell on Windows |

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
| Payload | `llm-image.oci.tar` (the server image built above, by digest), the model `.gguf`, and `SHA256SUMS` that pins both |
| Install | After `bootc install`, the installer copies the payload into the new root (`/var/lib/llm/`) and checks every sha256. It loads the OCI archive into the `llm` user's storage and writes the Quadlet unit and the API key |
| Without payload | The normal ISO stays as it is. The feature is then off until a payload is added (`llm import <dir>`) |

Decided: the USB image with a payload partition.

## Knobs

| Knob | Default | Notes |
|---|---|---|
| `LLM_MODEL` | `/srv/models/RVN-Q6_K-multilingual-mtp.gguf` | Path at build, sha256 pinned in the payload |
| `LLM_BACKEND` | `vulkan` | `rocm` adds `/dev/kfd` and the ROCm build |
| `LLM_CTX` | `16384` | 22.1 GiB measured at 16k. 32 GiB of VRAM leaves room for more |
| `LLM_SLOTS` | `4` | Parallel requests (llama-server `-np`) |
| `LLM_ADDR` | `10.89.255.1:8080` | The only listen address |
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
2. Quadlet unit, `llm` system user, tmpfiles for `/var/lib/llm`, `llm` CLI (`status`, `import`, `key`),
   and `llmctl-host` (vsock, CID allowlist) with the guest `llmctl` clients.
3. vmswitch: the `llm` network (option A), with an e2e in a container netns like `vmswitch-e2e.sh`.
4. Installer payload: `build-iso.sh --payload`, then a KVM e2e: install from the USB image, boot, check that a
   guest on `llm` gets an answer and a guest on `uplink` doesn't.
5. A GPU smoke on the sealed image on this machine. That's the only real-hardware step: the
   lab VMs have no R9700.
