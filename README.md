# Talos Linux on NVIDIA Jetson Orin — GPU Compute / CUDA

[![Talos](https://img.shields.io/badge/Talos-v1.12.6-blue)](https://github.com/siderolabs/talos/releases/tag/v1.12.6)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.35.0-blue)](https://kubernetes.io/)
[![Kernel](https://img.shields.io/badge/kernel-6.18.18--talos-orange)](https://github.com/siderolabs/pkgs)
[![nvgpu](https://img.shields.io/badge/nvgpu-5.1.0-green)](https://github.com/OE4T/linux-nvgpu)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](LICENSE)
[![Build](https://github.com/schwankner/talos-jetson-orin-nx/actions/workflows/release.yaml/badge.svg)](https://github.com/schwankner/talos-jetson-orin-nx/actions/workflows/release.yaml)

Run [Talos Linux](https://www.talos.dev/) on any **NVIDIA Jetson Orin** module with full CUDA GPU
compute support in Kubernetes pods. One USB image boots the entire Orin family (AGX Orin,
Orin NX, Orin Nano) — all share the same T234 SoC, GA10B GPU, and UEFI boot path.

Developed and tested on a **[Seeed Studio reComputer J4012](https://www.seeedstudio.com/reComputer-J4012-p-5586.html)**
(Jetson Orin NX 16 GB). Verified result as of 2026-04-01:

- GPU inference: **~7–8 tok/s** decode, **~700 tok/s** prefill (qwen2.5:1.5b Q4_K_M, 29/29 layers on GPU, on Ollama, Flash Attention enabled)
- Dynamic GPU frequency scaling: **306–918 MHz** via `nvhost_podgov` governor (`governor_pod_scaling.ko`)

> ### ⚠️ CUDA Container Compatibility — Read Before You Start
>
> **Not all CUDA images work on Jetson — this is a hardware limitation, not specific to this project.**
>
> The Jetson Orin NX uses NVIDIA's **Tegra SoC GPU** (integrated, not discrete). It exposes
> `/dev/nvhost-*` and `/dev/nvgpu` devices instead of the standard `/dev/nvidia*` found on
> desktop/server GPUs. As a result, generic CUDA container images compiled for SBSA
> (Server Base System Architecture) will **not** work — they link against libraries and device
> paths that simply do not exist on Tegra.
>
> **This is identical behaviour to the official NVIDIA JetPack/L4T Ubuntu image**, which has
> the same restriction. No Jetson setup — official or custom — can run arbitrary CUDA images.
>
> **What works ✅**
> - `ollama/ollama:jetson` — bundles its own Tegra-compatible CUDA runtime
> - `nvcr.io/nvidia/l4t-cuda:*` — NVIDIA's official L4T CUDA base images
> - [dusty-nv/jetson-containers](https://github.com/dusty-nv/jetson-containers) — community Jetson image collection (PyTorch, TensorRT, etc.)
> - Any image built `FROM nvcr.io/nvidia/l4t-*` or explicitly targeting Tegra/L4T
>
> **What does not work ❌**
> - `nvcr.io/nvidia/cuda:12.x-*-ubuntu22.04` (generic arm64 — targets SBSA, not Tegra)
> - Any image that assumes `/dev/nvidia0` or standard NVIDIA desktop GPU device paths

---

## Hardware Compatibility

This image targets the **NVIDIA GA10B GPU (Ampere, SM 8.7)** found in all Jetson Orin-series modules.

All Orin boards share the same T234 SoC and boot via UEFI (EDK2 firmware in SPI flash). The
Device Tree is loaded from the board's own SPI flash — no board-specific image variant is
needed. **One USB image works for the entire Orin family.**

| Module | Status | Notes |
|--------|--------|-------|
| **Jetson Orin NX 16 GB** | ✅ Tested | Developed on this module (reComputer J4012) |
| **Jetson Orin NX 8 GB** | ✅ Compatible | Same T234/GA10B, reduced LPDDR5 |
| **Jetson Orin Nano 8 GB** | ✅ Compatible | Same T234/GA10B, lower TDP (15 W) |
| **Jetson Orin Nano 4 GB** | ✅ Compatible | Same T234/GA10B, fewer CPU cores active |
| **Jetson AGX Orin 32/64 GB** | ✅ Compatible | Same T234/GA10B, more CPU/GPU/DLA enabled |
| **Jetson AGX Xavier / Xavier NX** | ❌ Not compatible | Different GPU: Volta GV11B (SM 7.2), requires separate nvgpu branch |
| **Jetson TX2** | ❌ Not compatible | Pascal GP10B GPU, different OOT driver tree entirely |
| **Jetson Nano (classic)** | ❌ Not compatible | Maxwell GPU, no UEFI boot |

> **Why one image?** Jetson Orin uses EDK2 UEFI firmware (stored in SPI flash) for boot. The
> board-specific Device Tree Blob is supplied by the UEFI firmware from the board's own SPI flash,
> not from the USB image. Our UKI is a standard `platform: metal` UEFI image with no board overlay —
> identical to how Talos boots on x86 servers.

> Tried it on a specific Orin module? **Open an issue** with your UART boot log — we'd love to
> confirm compatibility and update this table.

**Carrier board**: Any carrier with UEFI boot support should work. Tested on the
reComputer J4012 which provides NVMe, 2× GbE, and a standard UART TCU connector.

---

## Table of Contents

1. [Installation](#1-installation)
2. [Build Prerequisites](#2-build-prerequisites)
3. [Local Build & Flash](#3-local-build--flash)
4. [GitHub Actions Pipeline](#4-github-actions-pipeline)
5. [Build Pipeline Details](#5-build-pipeline-details)
6. [Component Versions](#6-component-versions)
7. [GPU Verification](#7-gpu-verification)
8. [Known Limitations](#8-known-limitations)
9. [Contributing](#9-contributing)
10. [References](#10-references)

---

## 1. Installation

No build environment needed. Download the pre-built USB image from the
[latest release](https://github.com/schwankner/talos-jetson-orin-nx/releases/latest),
flash it to a USB drive and boot.

### Download

```bash
# Find the latest release URL
LATEST=$(curl -s https://api.github.com/repos/schwankner/talos-jetson-orin-nx/releases/latest \
  | grep browser_download_url | grep '\.raw' | cut -d'"' -f4)

curl -L -O "${LATEST}"
```

Or go to **[Releases](https://github.com/schwankner/talos-jetson-orin-nx/releases)** and
download the `.raw` file manually.

### Flash

```bash
# macOS (replace rdiskN with your USB drive — check: diskutil list)
sudo dd if=talos-usb-nvgpu5.1.0.raw of=/dev/rdiskN bs=4m && sync

# Linux (replace sdX with your USB drive — check: lsblk)
sudo dd if=talos-usb-nvgpu5.1.0.raw of=/dev/sdX bs=4M status=progress && sync
```

> **Tip**: On macOS use `diskutil unmountDisk /dev/diskN` before flashing.

### Prerequisites

> ⚠️ **JetPack 6.2 (L4T r36.5) must be flashed to the Jetson before booting this image.**
>
> The GPU firmware files (`pmu_pkc_prod_sig.bin` and friends) are sourced from JetPack r36.5.
> Older JetPack versions (6.1 / r36.4 or earlier) will cause the nvgpu driver to fail at firmware load.
>
> Flash JetPack 6.2 using [NVIDIA SDK Manager](https://developer.nvidia.com/sdk-manager) **before** proceeding.

### Boot & Install

1. Plug the USB drive into the Jetson.
2. Enter the **UEFI boot menu** (press **Escape** during POST / on the UART splash screen).
3. Select **Boot Manager → USB drive** and confirm.
4. Talos boots into **maintenance mode** (no STATE partition found on NVMe yet).
5. Apply your machine config:
   ```bash
   talosctl apply-config --insecure -n <jetson-ip> --file your-machine-config.yaml
   ```
6. Talos installs itself to NVMe, reboots automatically, and comes up fully operational.
7. Bootstrap the cluster (first boot only):
   ```bash
   talosctl bootstrap -n <jetson-ip>
   ```

> After step 6 you can remove the USB drive. Talos boots from NVMe on all subsequent reboots.

---

## 2. Build Prerequisites

### Local Build (macOS — optional)

- **Docker + BuildKit** via [Colima](https://github.com/abiosoft/colima):
  ```bash
  colima start --arch aarch64 --cpu 8 --memory 16 --disk 100 --vm-type=vz --mount-type=virtiofs
  docker buildx create --name talos-builder --driver docker-container --use
  ```
- **Local OCI registry** on port 5001:
  ```bash
  docker run -d --name registry --restart=always -p 5001:5000 registry:2
  ```
- `talosctl` v1.12.x: `brew install siderolabsio/tap/talosctl`

> **Disk space**: the kernel build generates ~15 GB of intermediate objects.
> Ensure the Colima VM has ≥ 40 GB free. Clear cache before a full rebuild:
> `docker buildx prune --builder talos-builder --force`

### Environment Variables

All scripts read from `scripts/common.sh`. Override per-run:

| Variable | Default | Description |
|---|---|---|
| `REGISTRY` | `192.168.1.100:5001` | Local OCI registry (reachable from Jetson) |
| `REGISTRY_DOCKER` | `host.docker.internal:5001` | Registry as seen from inside Docker |
| `TALOS_VERSION` | `v1.12.6` | Talos release |
| `KERNEL_VERSION` | `6.18.18` | Kernel version |
| `NVGPU_VERSION` | `5.1.0` | nvgpu extension version |

---

## 3. Local Build & Flash

Only needed if you want to modify the kernel, nvgpu driver, or extensions.
For most users, the [pre-built release image](#1-installation) is the right choice.

```bash
# 1. Generate signing key (once per repo clone / fork)
./scripts/00-setup-keys.sh

# 2. Build all extensions + kernel (~60–90 min, cold cache)
make build-extensions

# 3. Build UKI + bootable USB image
make usb

# 4. Flash to USB drive (macOS — replace rdiskN)
sudo dd if=dist/talos-usb-nvgpu5.1.0.raw of=/dev/rdiskN bs=4m && sync

# Linux:
# sudo dd if=dist/talos-usb-nvgpu5.1.0.raw of=/dev/sdX bs=4M status=progress && sync
```

---

## 4. GitHub Actions Pipeline

Everything runs fully automated on GitHub — no local build environment needed.

### How it works

```
Tag push (v*) or workflow_dispatch
         │
         ▼
Job 1: Build extensions   (ubuntu-24.04-arm, native ARM64)
   ├── Cache hit  → ~2 min, skip build ✓
   └── Cache miss → ~90 min, build kernel + nvgpu + extensions, push to ghcr.io
         │
         ▼  (needs: build-extensions)
Job 2: Build USB image    (ubuntu-24.04-arm, native ARM64)
   └── make usb → .raw → uploaded as artifact + GitHub Release
```

Both jobs run on **native ARM64** (`ubuntu-24.04-arm`) — no QEMU, no cross-compilation.

### Trigger a release

```bash
git tag v1.12.6-nvgpu5.1.0
git push --tags
# → pipeline builds the image and creates a release with the .raw attached
```

Or trigger manually: **Actions → Build USB Image → Run workflow**

### Updating component versions

Change `NVGPU_VERSION`, `KERNEL_VERSION`, or `TALOS_VERSION` in `scripts/common.sh`,
commit, and push a tag. The pipeline detects that the new image tag does not yet
exist in `ghcr.io` and rebuilds everything automatically (~90 min).

### Required GitHub Secrets

Set once under *Settings → Secrets → Actions*:

| Secret | Value |
|---|---|
| `SIGNING_KEY_PEM` | Content of `keys/signing_key.pem` |
| `SIGNING_KEY_X509` | Content of `keys/signing_key.x509` (PEM format) |

### Workflows

| Workflow | Trigger | Runtime |
|---|---|---|
| `release.yaml` | Tag push `v*` or manual | ~5 min (cached) / ~120 min (cold) |
| `build-extensions.yaml` | Manual or called by release.yaml | ~2 min (cached) / ~90 min (cold) |

**Daily Talos check**: `.github/workflows/check-talos.yaml` runs every morning
and opens a GitHub issue automatically when a new Talos release is available,
with step-by-step upgrade instructions.

**Renovate**: `renovate.json` tracks Talos and kernel versions and opens PRs
when updates are available.

---

## 5. Build Pipeline Details

### Architecture

```
siderolabs/pkgs (commit a92bed5, release-1.12)
    │
    ├─ kernel/build ──(Clang/LLVM, reproducible signing key)──► vmlinuz (6.18.18-talos)
    │                                                             │
    └─ nvidia-tegra-nvgpu ──(OE4T patches-r36.5, Clang)────────► nvgpu.ko
                                                                  governor_pod_scaling.ko
                                                                  host1x.ko  …
                                                                  │
                              ┌───────────────────────────────────┤
                              │    Local Registry / ghcr.io       │
                              │                                   │
                              │  custom-installer:v1.12.6-…      │
                              │  nvidia-tegra-nvgpu:5.1.0-…      │
                              │  kernel-modules-clang:1.1.0-…    │
                              │  nvidia-firmware-ext:v5           │
                              └──────────────┬────────────────────┘
                                             │
                                             ▼
                                   Talos Imager v1.12.6
                                             │
                              ┌──────────────┴──────────────┐
                              ▼                             ▼
                      metal-arm64-uki.efi           USB boot image (.raw)
```

### Why a custom kernel?

Talos Linux enforces `MODULE_SIG_FORCE=y` — every `.ko` must be signed with
the key generated during that specific kernel build. NVIDIA's `nvgpu` is an
Out-of-Tree (OOT) module that must be compiled separately; it cannot be signed
with Siderolabs' ephemeral build key.

**Solution**: Build the kernel from the exact pkgs commit (`a92bed5`) that
produced Talos v1.12.6, using a reproducible pre-generated key committed to
`keys/`. The custom filename `talos_signing_key.pem` prevents `make` from
auto-regenerating a random key (see [BUGS.md — Bug 2](BUGS.md#bug-2--kernel-module-signing-key-reproducibility)).

### Why OE4T patches?

NVIDIA's `nvgpu` driver is written for L4T (Linux for Tegra) and depends on
L4T-specific kernel APIs. The [OE4T project](https://github.com/OE4T) maintains
patches to compile these against a standard upstream kernel.

### Extension Images

| Image | Tag | What's inside |
|---|---|---|
| `custom-installer` | `v1.12.6-6.18.18` | Official Talos installer + custom Clang vmlinuz |
| `nvidia-tegra-nvgpu` | `5.1.0-6.18.18-talos` | `nvgpu.ko` + `governor_pod_scaling.ko` + `host1x.ko` + friends |
| `kernel-modules-clang` | `1.1.0-6.18.18-talos` | Full Clang-compiled kernel module tree |
| `nvidia-firmware-ext` | `v5` | JetPack r36.5 firmware at `/usr/lib/firmware/ga10b/` incl. `pmu_pkc_prod_sig.bin` |

### Signing Key

```bash
# Generate once per clone / fork:
./scripts/00-setup-keys.sh

# Force-regenerate (BREAKING — rebuilds kernel + all extensions):
FORCE_NEW_KEY=1 ./scripts/setup-keys.sh && make build-extensions

# Verify key serial embedded in running kernel:
talosctl -n <node-ip> read /proc/keys | grep -i asymmetric
```

Current committed key serial: `74FD747A092BD42575ED4CBE6F7E2479A6FEC740`

### Key Technical Challenges

Getting GPU compute to work required solving 9 non-trivial problems. The full
root-cause analysis (firmware ELOOP, signing key reproducibility, Clang toolchain
consistency, kernel 6.18 API changes, undefined L4T symbols, CUDA error 999,
devfreq governor, CDI / containerd 2.x, UBSAN netlist bug) is documented in
**[BUGS.md](BUGS.md)**.

---

## 6. Component Versions

| Component | Version | Notes |
|---|---|---|
| Talos Linux | **v1.12.6** | pkgs commit `a92bed5`, branch `release-1.12` |
| Kubernetes | **v1.35.1** | |
| Kernel | **6.18.18-talos** | Clang/LLVM build, reproducible module signing key |
| LLVM/Clang | `v1.14.0-alpha.0` | `ghcr.io/siderolabs/llvm` |
| OE4T linux-nvgpu | `d530a48` | patches-r36.5 — the GA10B GPU driver |
| OE4T linux-nv-oot | `ea32e7f` | NVIDIA OOT framework (host1x, conftest) |
| OE4T linux-hwpm | `4d8a699` | Hardware Performance Monitor |
| `nvidia-tegra-nvgpu` ext | **5.1.0** | devfreq ccflags fix → `governor_pod_scaling.ko` built |
| `nvidia-firmware-ext` | **v5** | `pmu_pkc_prod_sig.bin` added |

---

## 7. GPU Verification

### Check module loaded + devfreq governor active

```bash
talosctl -n <node-ip> dmesg | grep -E "nvgpu|ga10b|podgov|devfreq"
# Expected: nvgpu probe, ga10b firmware loaded, governor=nvhost_podgov

talosctl -n <node-ip> read /sys/class/devfreq/17000000.gpu/governor
# nvhost_podgov

talosctl -n <node-ip> read /sys/class/devfreq/17000000.gpu/cur_freq
# 306000000 (idle) → scales up dynamically under load
```

### Run a CUDA device check in a pod

```bash
kubectl run cuda-check \
  --image=192.168.1.100:5001/cuda-device-check:v1 \
  --restart=Never --rm -it \
  --overrides='{"spec":{"resources":{"limits":{"nvidia.com/gpu":"1"}}}}'
```

Expected output:

```
cuInit=0 name=CUDA_SUCCESS
Device count: 1
GPU 0: Orin  SM 8.7  15.3 GiB
```

---

## 8. Known Limitations

| Limitation | Impact | Notes |
|---|---|---|
| Signing key committed to repo | Anyone who clones the repo has the build key | It's a throw-away build key; each fork should regenerate via `00-setup-keys.sh --force` |
| Undefined L4T symbols (`nvmap_dma_free_attrs`, `tegra_vpr_dev`) | Build warnings during `modpost` | Not called during CUDA compute; would oops if invoked — acceptable for this use case |
| `install.extensions` deprecated in Talos v1.12 | Validation warning at apply time | Functional; migration to overlay installer planned for next Talos bump |
| UBSAN: `netlist.c:617` at every boot | Non-fatal log noise | nvgpu 5.x upstream bug; GPU works normally — see [BUGS.md — Bug 9](BUGS.md#bug-9--ubsan-array-index-out-of-bounds-in-netlistc-non-fatal) |
| `Can't initialize nvrm channel` in GPU container logs | Non-fatal warning | GPU channels are created successfully; inference works |
| Single control-plane node | No etcd HA | By design; add worker nodes via separate `worker.yaml` to scale |
| Tested on one carrier board only | Other carriers may need adjustments | Tested on Seeed Studio reComputer J4012; feedback on other carriers welcome |

---

## 9. Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

Contributions especially welcome for:
- **Other Orin modules** — AGX Orin, Orin Nano (likely compatible, untested)
- **Newer component versions** — Talos, OE4T nvgpu, firmware
- **Other carrier boards** — UART logs + boot results via GitHub Issues
- **Bug reports** — open an issue with Talos version, nvgpu version, and full UART log

---

## 10. References

- [Talos Linux v1.12 Documentation](https://www.talos.dev/v1.12/)
- [Talos System Extensions Guide](https://www.talos.dev/v1.12/talos-guides/configuration/system-extensions/)
- [Talos Boot Assets Guide](https://www.talos.dev/v1.12/talos-guides/install/boot-assets/)
- [siderolabs/pkgs](https://github.com/siderolabs/pkgs) — Talos kernel build system (commit `a92bed5`)
- [OE4T/linux-nvgpu](https://github.com/OE4T/linux-nvgpu) — nvgpu patches (commit `d530a48`)
- [OE4T/linux-nv-oot](https://github.com/OE4T/linux-nv-oot) — NVIDIA OOT framework (commit `ea32e7f`)
- [Seeed Studio reComputer J4012](https://www.seeedstudio.com/reComputer-J4012-p-5586.html) — hardware
- [dusty-nv/jetson-containers](https://github.com/dusty-nv/jetson-containers) — Jetson Docker images
- [NVIDIA JetPack SDK](https://developer.nvidia.com/embedded/jetpack) — firmware / CUDA userspace

---

## AI Disclaimer

Parts of this project were developed with the assistance of AI tools (primarily [Claude](https://claude.ai) by Anthropic), in particular:

- **Documentation** — README, inline script comments, and architecture descriptions
- **CI/CD pipeline** — GitHub Actions workflows and Renovate configuration
- **Debugging** — tracing build errors across the kernel/extension/signing-key chain

All generated output was reviewed, tested, and validated on real hardware. The technical decisions, implementation, and final responsibility remain with the author.
