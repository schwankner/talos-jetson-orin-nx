# Talos Linux on NVIDIA Jetson Orin — GPU Compute / CUDA

[![Talos](https://img.shields.io/badge/Talos-v1.12.6-blue)](https://github.com/siderolabs/talos/releases/tag/v1.12.6)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.35.0-blue)](https://kubernetes.io/)
[![Kernel](https://img.shields.io/badge/kernel-6.18.18--talos-orange)](https://github.com/siderolabs/pkgs)
[![nvgpu](https://img.shields.io/badge/nvgpu-5.10.4-green)](https://github.com/OE4T/linux-nvgpu)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](LICENSE)
[![Build](https://github.com/schwankner/talos-jetson-orin-nx/actions/workflows/release.yaml/badge.svg)](https://github.com/schwankner/talos-jetson-orin-nx/actions/workflows/release.yaml)

Run [Talos Linux](https://www.talos.dev/) on any **NVIDIA Jetson Orin** module with full CUDA GPU
compute support in Kubernetes pods. One USB image boots the entire Orin family (AGX Orin,
Orin NX, Orin Nano) — all share the same T234 SoC, GA10B GPU, and UEFI boot path.

Developed and tested on a **[Seeed Studio reComputer J4012](https://www.seeedstudio.com/reComputer-J4012-p-5586.html)**
(Jetson Orin NX 16 GB). Verified result as of 2026-04-09:

- GPU inference: **~16 tok/s** decode, **~1790 tok/s** prefill (qwen2.5:0.5b, 25/25 layers on GPU, Ollama, Flash Attention enabled)
- Hardware syncpoint interrupts via `nvhost-ctrl-shim` — `cudaStreamSynchronize` uses interrupt-driven wait (no CPU polling)
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
> - `ollama/ollama:latest` (arm64) — uses the Tegra CUDA runtime provided by the nvgpu extension in this project
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

| Year | Module | SoC / GPU | Status | Notes |
|------|--------|-----------|--------|-------|
| 2023 | **Jetson AGX Orin** (32/64 GB) | T234 / GA10B Ampere | ✅ Compatible | Same SoC/GPU as NX; more CPU cores, DLA, higher TDP (15–60 W) |
| 2023 | **Jetson Orin NX** (8/16 GB) | T234 / GA10B Ampere | ✅ **Tested** | Developed on Orin NX 16 GB (reComputer J4012) |
| 2023 | **Jetson Orin Nano** (4/8 GB) | T234 / GA10B Ampere | ✅ Compatible | Same SoC/GPU; fewer active CPU cores, lower TDP (7–25 W), no DLA |
| 2025 | **Jetson AGX Thor** | GB10 / Blackwell | ⚠️ Unknown | Different SoC and GPU architecture (Blackwell); nvgpu OOT driver untested — no OE4T support yet |
| 2018 | **Jetson AGX Xavier** (8/32/64 GB) | T194 / GV11B Volta SM 7.2 | ❌ Not compatible | Different GPU architecture; would need a separate `nvgpu` build targeting GV11B |
| 2020 | **Jetson Xavier NX** | T194 / GV11B Volta SM 7.2 | ❌ Not compatible | Same T194/GV11B as AGX Xavier — incompatible OOT driver |
| 2017 | **Jetson TX2** | T186 / GP10B Pascal | ❌ Not compatible | Pascal GPU; completely different OOT driver tree, no UEFI boot |
| 2019 | **Jetson Nano** (4 GB) | T210 / Maxwell | ❌ Not compatible | Maxwell GPU; no UEFI — uses U-Boot + extlinux, requires a [board overlay](https://github.com/siderolabs/overlays) |
| 2015 | **Jetson TX1** | T210 / Maxwell | ❌ Not compatible | Same T210 as Nano — no UEFI, Maxwell GPU |
| 2014 | **Jetson TK1** | T124 / Kepler | ❌ Not compatible | ARMv7 (32-bit only); Talos requires AArch64 |

> **Why one image for all Orin variants?** Jetson Orin uses EDK2 UEFI firmware stored in SPI
> flash for boot. The board-specific Device Tree Blob is supplied by the UEFI firmware from the
> board's own SPI flash, not from the USB image. Our UKI is a standard `platform: metal` UEFI
> image with no board overlay — identical to how Talos boots on x86 servers. Older Jetson
> generations that lack UEFI require a [board-specific overlay](https://github.com/siderolabs/overlays)
> (U-Boot + extlinux), which this project does not provide.

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
8. [GPU Power Modes](#8-gpu-power-modes)
9. [Known Bugs and Limitations](#9-known-bugs-and-limitations)
10. [Known Limitations](#10-known-limitations)
11. [Contributing](#11-contributing)
12. [References](#12-references)
11. [Contributing](#11-contributing)
12. [References](#12-references)

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
sudo dd if=talos-usb-nvgpu5.10.4.raw of=/dev/rdiskN bs=4m && sync

# Linux (replace sdX with your USB drive — check: lsblk)
sudo dd if=talos-usb-nvgpu5.10.4.raw of=/dev/sdX bs=4M status=progress && sync
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
| `NVGPU_VERSION` | `5.10.4` | nvgpu extension version |

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
sudo dd if=dist/talos-usb-nvgpu5.10.4.raw of=/dev/rdiskN bs=4m && sync

# Linux:
# sudo dd if=dist/talos-usb-nvgpu5.10.4.raw of=/dev/sdX bs=4M status=progress && sync
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
Job 2: Build USB image + versioned installer   (ubuntu-24.04-arm, native ARM64)
   ├── make usb → .raw → uploaded as artifact + GitHub Release
   └── talos imager (kind: installer) → custom-installer:<talos>-<kernel>-nvgpu<ver> → ghcr.io
```

Both jobs run on **native ARM64** (`ubuntu-24.04-arm`) — no QEMU, no cross-compilation.

### Trigger a release

```bash
git tag v1.12.6-nvgpu5.10.4
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
                                                                  nvmap.ko  …
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
| `custom-installer` | `v1.12.6-6.18.18` | Official Talos installer + custom Clang vmlinuz (base, no extensions) |
| `custom-installer` | `v1.12.6-6.18.18-nvgpu5.10.4` | **Full installer with all extensions** — use this for `talosctl upgrade` |
| `nvidia-tegra-nvgpu` | `5.10.4-6.18.18-talos` | `nvgpu.ko` (NVHOST=n) + `nvhost-ctrl-shim.ko` (SYNCPT_WAITMEX + GET_CHARACTERISTICS) + `nvmap.ko` + `governor_pod_scaling.ko` + friends |
| `kernel-modules-clang` | `1.3.0-6.18.18-talos` | Full Clang-compiled kernel module tree |
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

Getting GPU compute to work required solving 18 non-trivial problems. The full
root-cause analysis (firmware ELOOP, signing key reproducibility, GCC 15/Clang 22
toolchain mismatch, kernel 6.18 API changes, undefined L4T symbols, CUDA error 999,
devfreq governor, CDI / containerd 2.x, UBSAN netlist bug, CI extension image
distribution, nvhost-ctrl-shim ioctl implementation, USB boot masking NVMe upgrades,
pkg.yaml source pin management) is documented in **[BUGS.md](BUGS.md)**.

---

## 6. Component Versions

| Component | Version | Notes |
|---|---|---|
| Talos Linux | **v1.12.6** | pkgs commit `a92bed5`, branch `release-1.12` |
| Kubernetes | **v1.35.1** | |
| Kernel | **6.18.18-talos** | Clang/LLVM build, reproducible module signing key |
| LLVM/Clang | `v1.14.0-alpha.0` | `ghcr.io/siderolabs/llvm` |
| OE4T linux-nvgpu | `d530a48` | patches-r36.5 — the GA10B GPU driver |
| OE4T linux-nv-oot | `ccf7646` | NVIDIA OOT framework (nvmap, conftest, devfreq) |
| OE4T linux-hwpm | `4d8a699` | Hardware Performance Monitor |
| `nvidia-tegra-nvgpu` ext | **5.10.4** | `NVHOST=n` + `nvhost-ctrl-shim` (SYNCPT_WAITMEX + GET_CHARACTERISTICS for `cudaStreamSynchronize`) |
| `kernel-modules-clang` ext | **1.3.0** | Full Clang-compiled kernel module tree, signed with `talos_signing_key.pem` |
| `nvidia-firmware-ext` | **v5** | `pmu_pkc_prod_sig.bin` added; sourced from L4T r36.5 apt (`t234` repo) |

---

## 7. GPU Verification

### Check module loaded + devfreq governor active

```bash
talosctl -n <node-ip> dmesg | grep -E "nvgpu|ga10b|podgov|devfreq"
# Expected: nvgpu probe, ga10b firmware loaded

talosctl -n <node-ip> read /sys/bus/platform/devices/17000000.gpu/devfreq/17000000.gpu/governor
# performance  (after power-mode DaemonSet)

talosctl -n <node-ip> read /sys/bus/platform/devices/17000000.gpu/devfreq/17000000.gpu/cur_freq
# 918000000  (918 MHz in MAXN mode)
```

### Run a CUDA device check in a pod

```bash
kubectl run cuda-check \
  --image=ghcr.io/schwankner/cuda-device-check:v1 \
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

## 8. GPU Power Modes

> ### ⚠️ MAXN SUPER is permanently blocked on reComputer J401
>
> The **reComputer J401 carrier board** (used in J4011 / J4012) **cannot** dissipate the heat
> generated by **MAXN SUPER** mode on Jetson Orin NX 16 GB or 8 GB modules. Enabling it **will
> cause permanent damage** to the module.
> [(Source: Seeed Studio wiki)](https://wiki.seeedstudio.com/reComputer_J4012_Flash_Jetpack/)
>
> The `jetson-power-mode` DaemonSet in this project enforces this limit and will **fall back to
> MAXN** if MAXN SUPER is requested without an explicit safety override.

### Available Power Modes

The `manifests/gpu/power-mode.yaml` DaemonSet configures GPU and CPU clocks at node startup via
sysfs. It targets the GPU devfreq node at `/sys/bus/platform/devices/17000000.gpu/`.

| Mode | CPU Cores | CPU Max Freq | GPU Max Freq | GPU Governor | Recommended For |
|------|-----------|-------------|-------------|--------------|-----------------|
| `10W` | 4 | 1,190 MHz | 612 MHz | `powersave` | Battery / idle |
| `15W` | 4 | 1,421 MHz | 612 MHz | `nvhost_podgov` | Factory NVIDIA default |
| `25W` | 8 | 1,498 MHz | 408 MHz | `nvhost_podgov` | CPU-heavy workloads |
| **`MAXN`** | **8** | **1,984 MHz** | **918 MHz** | **`performance`** | **AI inference ← DEFAULT** |
| `MAXN_SUPER` | 8 | 1,984 MHz | >918 MHz | `performance` | ⛔ **Blocked on J401** |

### Changing the Power Mode

Edit the `POWER_MODE` env var in `manifests/gpu/power-mode.yaml` before applying:

```yaml
env:
  - name: POWER_MODE
    value: "MAXN"       # 10W | 15W | 25W | MAXN  (MAXN_SUPER blocked)
  - name: ALLOW_MAXN_SUPER
    value: "false"      # ⚠ set "true" ONLY with a custom cooling solution
```

```bash
kubectl apply -f manifests/gpu/power-mode.yaml
kubectl logs -n nvidia-system -l app=jetson-power-mode
# [power-mode] GPU cur_freq=918000000 Hz ✓
# [power-mode] Power mode MAXN applied ✓
```

### MAXN SUPER — Custom Cooling Only

If you have replaced the reComputer J401 cooling with a capable third-party heat sink, you may
enable MAXN SUPER **at your own risk**:

```yaml
env:
  - name: POWER_MODE
    value: "MAXN_SUPER"
  - name: ALLOW_MAXN_SUPER
    value: "true"       # ← explicit acknowledgement of thermal risk
```

> This will push the GPU beyond 918 MHz (up to 1173 MHz on Orin NX 16 GB). The DaemonSet logs
> a prominent warning when this override is active.

### Verify Frequencies at Runtime

```bash
# GPU frequency
talosctl -n 10.0.10.38 read \
  /sys/bus/platform/devices/17000000.gpu/devfreq/17000000.gpu/cur_freq

# GPU governor
talosctl -n 10.0.10.38 read \
  /sys/bus/platform/devices/17000000.gpu/devfreq/17000000.gpu/governor

# Active CPU cores
talosctl -n 10.0.10.38 read /sys/devices/system/cpu/online
```

---

## 9. Known Bugs and Limitations

All non-trivial bugs encountered during development — including the full investigation of
CUDA error 999, the NVHOST=y attempt history, and the GPU decode speed bottleneck — are
documented with detailed root-cause analysis in **[BUGS.md](BUGS.md)**.

Notable items relevant to day-to-day use:

| # | Issue | Impact | Status |
|---|-------|--------|--------|
| [Bug 6](BUGS.md#bug-6--cuda-error-999-cudastreamsynchronize--nvhost-syncpoint) | CUDA error 999 (`cudaStreamSynchronize`) | GPU compute fails | ✅ Fixed — `NVHOST=n` |
| [Bug 14](BUGS.md#bug-14--cuda-error-999-persists-with-nvhosty-nvgpu-590--591) | CUDA error 999 with NVHOST=y (5.9.0/5.9.1) | GPU pool not signable | ✅ Diagnosed — NVHOST=n stable |
| [Bug 15](BUGS.md#bug-15--gpu-decode-speed-7-toks-cpu-polling-overhead-with-nvhostn) | GPU decode ~7 tok/s (CPU polling) | Slow inference | ✅ Fixed — `nvhost-ctrl-shim` SYNCPT_WAITMEX (5.10.4) → **~16 tok/s** |
| [Bug 16](BUGS.md) | Jetson boots from USB instead of NVMe after upgrade | `talosctl upgrade` silently ignored | ✅ Fixed — remove USB stick |
| [Bug 17](BUGS.md) | nvhost-ctrl-shim missing SYNCPT_WAITMEX + GET_CHARACTERISTICS | CUDA error 999 with shim loaded | ✅ Fixed — implemented in nvhost_ctrl_shim.c (5.10.3) |
| [Bug 18](BUGS.md) | pkg.yaml shim source pin not updated after code change | Old shim code shipped despite version bump | ✅ Fixed — pin `url`+`sha256`+`sha512` in pkg.yaml (5.10.4) |
| [Bug 9](BUGS.md#bug-9--ubsan-array-index-out-of-bounds-in-netlistc-non-fatal) | UBSAN `netlist.c:617` at every boot | Log noise | ✅ Silenced (flexible array) |

---

## 10. Known Limitations

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

## 11. Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

Contributions especially welcome for:
- **Other Orin modules** — AGX Orin, Orin Nano (likely compatible, untested)
- **Newer component versions** — Talos, OE4T nvgpu, firmware
- **Other carrier boards** — UART logs + boot results via GitHub Issues
- **Bug reports** — open an issue with Talos version, nvgpu version, and full UART log

---

## 12. References

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

## 13. AI Disclaimer

Parts of this project were developed with the assistance of AI tools (primarily [Claude](https://claude.ai) by Anthropic), in particular:

- **Documentation** — README, inline script comments, and architecture descriptions
- **CI/CD pipeline** — GitHub Actions workflows and Renovate configuration
- **Debugging** — tracing build errors across the kernel/extension/signing-key chain

All generated output was reviewed, tested, and validated on real hardware. The technical decisions, implementation, and final responsibility remain with the author.
