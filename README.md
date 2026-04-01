# Talos Linux on NVIDIA Jetson Orin NX — GPU Compute / CUDA

[![Talos](https://img.shields.io/badge/Talos-v1.12.6-blue)](https://github.com/siderolabs/talos/releases/tag/v1.12.6)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.35.0-blue)](https://kubernetes.io/)
[![Kernel](https://img.shields.io/badge/kernel-6.18.18--talos-orange)](https://github.com/siderolabs/pkgs)
[![nvgpu](https://img.shields.io/badge/nvgpu-5.1.0-green)](https://github.com/OE4T/linux-nvgpu)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](LICENSE)
[![Build](https://github.com/schwankner/talos-jetson-orin-nx/actions/workflows/build-usb.yaml/badge.svg)](https://github.com/schwankner/talos-jetson-orin-nx/actions/workflows/build-usb.yaml)

Run [Talos Linux](https://www.talos.dev/) on the **NVIDIA Jetson Orin NX** with full CUDA GPU compute
support in Kubernetes pods. Tested on a **[Seeed Studio reComputer J4012](https://www.seeedstudio.com/reComputer-J4012-p-5586.html)**
(Jetson Orin NX 16 GB industrial carrier board).

Verified result (Boot 15, 2026-04-01):

- GPU inference: **~7–8 tok/s** decode, **~700 tok/s** prefill (qwen2.5:1.5b, 29/29 GPU layers, Flash Attention)
- Dynamic frequency scaling: **306–918 MHz** (`nvhost_podgov` governor via `governor_pod_scaling.ko`)
- NVMe online at **13.7 s**, `module.sig_enforce=1` — **zero rejections**

---

## Table of Contents

1. [Hardware](#1-hardware)
2. [Quick Start](#2-quick-start)
3. [GitHub Actions Build](#3-github-actions-build-recommended)
4. [Build Pipeline](#4-build-pipeline)
5. [Component Versions](#5-component-versions)
6. [Key Technical Challenges](#6-key-technical-challenges)
7. [GPU Verification](#7-gpu-verification)
8. [Known Limitations](#8-known-limitations)
9. [Contributing](#9-contributing)
10. [References](#10-references)

---

## 1. Hardware

| Component | Details |
|-----------|---------|
| Carrier board | **Seeed Studio reComputer J4012** (industrial, M.2 NVMe, 2× GbE) |
| SoM | NVIDIA Jetson Orin NX 16 GB |
| GPU | NVIDIA GA10B (Ampere, SM 8.7) |
| VRAM | 15.3 GiB (shared LPDDR5) |
| Storage | NVMe SSD (PCIe) — `/dev/nvme0n1` |
| Boot | UEFI via systemd-boot + UKI |
| Serial | UART via TCU (`ttyTCU0,115200`) |

---

## 2. Quick Start

### Prerequisites

**Build host** (macOS tested; Linux also works):

- Docker with BuildKit (Colima on macOS: `colima start --arch aarch64 --cpu 8 --memory 16 --disk 100 --vm-type=vz --mount-type=virtiofs`)
- A `talos-builder` buildx instance: `docker buildx create --name talos-builder --driver docker-container --use`
- Local OCI registry on port 5001: `docker run -d --name registry --restart=always -p 5001:5000 registry:2`
- `talosctl` v1.12.x: `brew install siderolabsio/tap/talosctl`
- `kubectl`: `brew install kubectl`

**Environment variables** (all have sensible defaults in `scripts/common.sh`):

| Variable | Default | Description |
|---|---|---|
| `REGISTRY` | `192.168.1.100:5001` | Local OCI registry (reachable from Jetson) |
| `REGISTRY_DOCKER` | `host.docker.internal:5001` | Registry as seen from inside Docker |
| `TALOS_VERSION` | `v1.12.6` | Talos release |
| `KERNEL_VERSION` | `6.18.18` | Kernel version |
| `NVGPU_VERSION` | `5.1.0` | nvgpu extension version |
| `NODE_IP` | `192.168.1.50` | Jetson node IP |

### Build & Flash

```bash
# 1. Generate signing key (once per repo clone)
./scripts/00-setup-keys.sh

# 2. Build all extensions + kernel (~60-90 min, cold cache)
make build-extensions

# 3. Build UKI + bootable USB image
make usb

# 4. Flash to USB drive (replace /dev/rdiskN with your device)
sudo dd if=dist/talos-usb-nvgpu5.1.0.raw of=/dev/rdiskN bs=4m && sync
```

> **Tip**: Use [GitHub Actions](#3-github-actions-build-recommended) to build the USB image in
> the cloud — no local arm64 build environment needed.

### First-Time Cluster Setup

```bash
# Boot Jetson from USB → maintenance mode appears → then:

# 1. Apply machine config (installs Talos to NVMe)
./scripts/03-apply-config.sh --insecure

# 2. Fix NVMe boot (copy UKI to NVMe EFI partition, set boot order)
./scripts/04-fix-nvme-boot.sh

# 3. Bootstrap etcd + save credentials (run ONCE)
./scripts/05-bootstrap-cluster.sh

# 4. Deploy CDI stack (GPU access in pods)
kubectl apply -f manifests/gpu/cdi-setup.yaml
kubectl apply -f manifests/gpu/device-plugin.yaml
```

After cluster setup, request GPU resources in pods via `nvidia.com/gpu: 1`.

---

## 3. GitHub Actions Build (Recommended)

A pre-configured workflow (`.github/workflows/build-usb.yaml`) builds the full USB image
on GitHub's ARM64 runners — no local Docker/Colima setup needed.

**Trigger**:
- Push a version tag: `git tag v1.12.6-nvgpu5.1.0 && git push --tags`
- Or run manually via **Actions → Build USB Image → Run workflow**

**What it does**:
1. Sets up QEMU + Docker Buildx for arm64 cross-compilation
2. Starts a temporary OCI registry (ghcr.io / localhost)
3. Restores signing keys from GitHub Secrets (`SIGNING_KEY_PEM`, `SIGNING_KEY_X509`)
4. Runs `make build-extensions` (~60–90 min with GHA cache)
5. Runs `make usb` to produce the bootable `.raw` image
6. Uploads the image as a release artifact

**Required GitHub Secrets**:

| Secret | Value |
|---|---|
| `SIGNING_KEY_PEM` | Content of `keys/signing_key.pem` |
| `SIGNING_KEY_X509` | Content of `keys/signing_key.x509` |

**Daily Talos check**: `.github/workflows/check-talos.yaml` runs every day and opens an
issue if a new Talos release is available — so you know when to bump `TALOS_VERSION` and
trigger a new build.

---

## 4. Build Pipeline

### Overview

```
siderolabs/pkgs (commit a92bed5, release-1.12)
    │
    ├─ kernel/build ──(Clang/LLVM, reproducible signing key)──► vmlinuz (6.18.18-talos)
    │                                                             │
    └─ nvidia-tegra-nvgpu ──(OE4T patches-r36.5, Clang)────────► nvgpu.ko + governor_pod_scaling.ko + …
                                                                  │
                              ┌───────────────────────────────────┤
                              │    Local OCI Registry / ghcr.io   │
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
                              │
                              ▼
                    Flash to NVMe via USB boot ──► Jetson Orin NX
```

### Makefile Targets

```
make all              Build UKI + USB image (default)
make build-extensions Full rebuild: nvgpu extension + kernel + installer (~90 min)
make build-kernel     Kernel + installer only, skip nvgpu build (~30 min)
make uki              Assemble UKI from registry images
make usb              Create bootable USB disk image
make keys             (Re-)generate kernel module signing key
make clean            Remove dist/ and intermediate build output
```

### Signing Key

The key pair in `keys/` is committed to the repository — it must match the key embedded
in the running kernel. Generate once:

```bash
./scripts/00-setup-keys.sh
```

Force-regenerate (**breaking** — requires full rebuild of kernel + all extensions):

```bash
FORCE_NEW_KEY=1 ./scripts/00-setup-keys.sh && make build-extensions
```

Current key serial: `74FD747A092BD42575ED4CBE6F7E2479A6FEC740`

### Extension Images

| Image | Tag | Notes |
|---|---|---|
| `custom-installer` | `v1.12.6-6.18.18` | Official Talos installer + custom Clang vmlinuz |
| `nvidia-tegra-nvgpu` | `5.1.0-6.18.18-talos` | GA10B driver — devfreq `nvhost_podgov`, 306–918 MHz |
| `kernel-modules-clang` | `1.1.0-6.18.18-talos` | Clang-compiled kernel module tree |
| `nvidia-firmware-ext` | `v5` | JetPack r36.5 firmware at `ga10b/` + `pmu_pkc_prod_sig.bin` |

---

## 5. Component Versions

| Component | Version | Notes |
|---|---|---|
| Talos Linux | **v1.12.6** | pkgs commit `a92bed5`, branch `release-1.12` |
| Kubernetes | **v1.35.1** | |
| Kernel | **6.18.18-talos** | Clang build, module signing with reproducible key |
| LLVM/Clang | `v1.14.0-alpha.0` | `ghcr.io/siderolabs/llvm` |
| OE4T linux-nvgpu | `d530a48` | patches-r36.5 |
| OE4T linux-nv-oot | `ea32e7f` | NVIDIA OOT framework |
| OE4T linux-hwpm | `4d8a699` | Hardware Performance Monitor |
| nvgpu extension | **5.1.0** | devfreq ccflags fix → `governor_pod_scaling.ko` |
| firmware extension | **v5** | `pmu_pkc_prod_sig.bin` added |

---

## 6. Key Technical Challenges

Getting Talos Linux running with GPU compute on Jetson requires solving several non-trivial
problems. This section summarizes each and points to the fix.

### Challenge Summary

| # | Challenge | Symptom | Fix |
|---|---|---|---|
| 1 | **Firmware ELOOP** | `request_firmware` returns -40 even though files exist | `firmware_class.path=/usr/lib/firmware` kernel cmdline; place firmware at `ga10b/` (not `nvidia/ga10b/`) |
| 2 | **Kernel module signing** | Talos maintenance mode: 6 module rejections, no NVMe | `CONFIG_MODULE_SIG_KEY="certs/talos_signing_key.pem"` (custom filename avoids `make` auto-regen); key committed in `keys/` |
| 3 | **Clang toolchain** | `clang: error: unknown argument: '-fmin-function-alignment=8'` | Build kernel **and** OOT modules with `LLVM=1 LLVM_IAS=1`; run `make olddefconfig LLVM=1` |
| 4 | **Kernel 6.18 API changes** | Compile errors in OE4T sources | `NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS → #if 1`; `class_create(THIS_MODULE, …)` → `class_create(…)` |
| 5 | **Undefined L4T symbols** | Module loads but crashes on specific code paths | `KBUILD_MODPOST_WARN=1` — demotes to warnings; CUDA compute does not invoke these paths |
| 6 | **CUDA Error 999** | `cudaStreamSynchronize` fails instantly | Build nvgpu with `CONFIG_TEGRA_GK20A_NVHOST=n`; inject `/dev/nvhost-ctrl` via CDI hostPath |
| 7 | **devfreq governor missing** | `Unable to find governor for the device`; GPU runs at fixed 918 MHz | Add missing `ccflags-y` include paths to `nvidia-oot/drivers/devfreq/Makefile` in `pkg.yaml` prepare step |
| 8 | **CDI stack / containerd 2.x** | Pod annotation CDI removed in containerd 2.x | Custom `jetson-device-plugin` that returns `CDIDevices: [{Name: "nvidia.com/gpu=0"}]` in AllocateResponse |
| 9 | **UBSAN netlist.c** | Array-index-out-of-bounds at boot (non-fatal) | Known nvgpu 5.x bug: `struct netlist_region regions[1]` (C89 struct hack). Fix: `regions[]` (C99 FAM). GPU works despite warning. |

### Challenge 1 — Firmware ELOOP (−40)

The firmware loader constructs `/lib/firmware/ga10b/…`. On Talos, `/lib` is a symlink to
`usr/lib`, and `usr/lib/firmware` is an overlayfs bind-mount (the extension squashfs).
Symlink resolution across the bind-mount boundary increments the ELOOP counter past the
threshold. **Fix**: `firmware_class.path=/usr/lib/firmware` in the UKI kernel cmdline.

### Challenge 2 — Kernel Module Signing Key Reproducibility

The kernel's `certs/Makefile` contains a `FORCE` rule for the filename `signing_key.pem`
that regenerates a random key on every cache-miss build. Using a custom filename
`talos_signing_key.pem` bypasses this rule — `make` has no knowledge of that name and
will never touch it. The key is committed to `keys/` and verified after every build.

### Challenge 6 — CUDA Error 999 + nvhost-ctrl

nvgpu's `cudaStreamSynchronize` path on Jetson Orin NX depends on nvhost syncpoints
(`/dev/nvhost-ctrl`). On Talos (non-L4T), this device doesn't exist. Building with
`CONFIG_TEGRA_GK20A_NVHOST=n` disables the nvhost path. Additionally, `libcuda.so.1.1`
itself requires `/dev/nvhost-ctrl` — it's injected into GPU-enabled pods via a CDI hostPath
mapping.

### Challenge 7 — devfreq governor_pod_scaling.ko

`platform_ga10b_tegra.c` hardcodes the devfreq governor as `"nvhost_podgov"`, implemented
in `nvidia-oot/drivers/devfreq/governor_pod_scaling.c`. The devfreq Makefile was missing
two `ccflags-y` include paths:

| Missing include | Needed for |
|---|---|
| `-I$(srctree.nvconftest)` | `nvidia/conftest.h` |
| `-I$(srctree.nvidia-oot)/include` | `trace/events/nvhost_podgov.h` |

**Fix** (added to `pkg.yaml` prepare step):

```bash
printf 'ccflags-y += -I$(srctree.nvconftest)\n' \
  >> ${NVIDIA_OOT}/drivers/devfreq/Makefile
printf 'ccflags-y += -I$(srctree.nvidia-oot)/include\n' \
  >> ${NVIDIA_OOT}/drivers/devfreq/Makefile
```

**Result (Boot 15)**: `governor_pod_scaling.ko` loads, `nvhost_podgov` governor registered,
`/sys/class/devfreq/17000000.gpu` active, GPU scales 306→918 MHz dynamically.

### Challenge 9 — UBSAN netlist.c (Non-fatal)

Every boot produces:

```
UBSAN: array-index-out-of-bounds in drivers/gpu/nvgpu/hal/netlist/netlist.c:617:32
index 1 is out of range for type 'struct netlist_region [1]'
```

**Root cause**: `struct netlist_image` uses the C89 struct hack — `regions[1]` as the last
member. The loop iterates `i >= 1`, triggering UBSAN for index 1. The GPU initializes and
runs normally. **Upstream fix**: `regions[]` (C99 flexible array member) in `netlist_priv.h`.

---

## 7. GPU Verification

### Verify nvgpu Module Loads

```bash
talosctl -n 192.168.1.50 dmesg | grep -E "nvgpu|ga10b|devfreq"
# Expected: nvgpu probe, ga10b firmware loaded, devfreq governor=nvhost_podgov
```

### Run CUDA Device Check

```bash
kubectl run cuda-check --image=192.168.1.100:5001/cuda-device-check:v1 \
  --restart=Never --rm -it \
  --overrides='{"spec":{"resources":{"limits":{"nvidia.com/gpu":"1"}}}}'
```

Expected output:

```
cuInit=0 name=CUDA_SUCCESS
Device count: 1
GPU 0: Orin  SM 8.7  15.3 GiB
```

### Check GPU Frequency Scaling

```bash
talosctl -n 192.168.1.50 read /sys/class/devfreq/17000000.gpu/governor
# nvhost_podgov

talosctl -n 192.168.1.50 read /sys/class/devfreq/17000000.gpu/cur_freq
# 306000000 (idle) → scales up during load
```

---

## 8. Known Limitations

| Limitation | Impact | Notes |
|---|---|---|
| Module signing disabled | Any `.ko` can load | Acceptable for a dedicated, network-isolated cluster |
| Undefined L4T symbols (`nvmap_dma_free_attrs`, `tegra_vpr_dev`) | Build warning | Not reached during CUDA compute |
| `install.extensions` deprecated in v1.12 | Validation warning | Functional; migrate to overlay installer in future |
| UBSAN: `netlist.c:617` at every boot | Non-fatal log noise | Known nvgpu 5.x bug; GPU works normally |
| `Can't initialize nvrm channel` at startup | Non-fatal | CUDA channels ARE created; inference works |
| Single control-plane node | No HA | Scale by adding worker nodes via `worker.yaml` |
| Local registry must be plain HTTP | `mirrors` with explicit `http://` endpoint needed | See machine config in `manifests/talos/machine-patch-cdi.yaml` |
| STATE-only wipe leaves stale Kubernetes PKI | Old kubelet certs mismatch new cluster CA | Always use `--wipe-mode all` for clean reinstall |

---

## 9. Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines, fork instructions, and how to generate
your own signing key.

Contributions especially welcome for:
- Other Jetson modules (AGX Orin, Orin Nano, Xavier NX)
- Updated component versions (newer Talos, nvgpu, firmware)
- Bug reports with UART logs via GitHub Issues

---

## 10. References

- [Talos Linux v1.12 Documentation](https://www.talos.dev/v1.12/)
- [Talos System Extensions Guide](https://www.talos.dev/v1.12/talos-guides/configuration/system-extensions/)
- [Talos Boot Assets Guide](https://www.talos.dev/v1.12/talos-guides/install/boot-assets/)
- [siderolabs/pkgs](https://github.com/siderolabs/pkgs) — Talos kernel build system (commit `a92bed5`)
- [siderolabs/bldr](https://github.com/siderolabs/bldr) — BuildKit frontend
- [OE4T/linux-nvgpu](https://github.com/OE4T/linux-nvgpu) — nvgpu OE4T patches (commit `d530a48`)
- [OE4T/linux-nv-oot](https://github.com/OE4T/linux-nv-oot) — NVIDIA OOT framework (commit `ea32e7f`)
- [Seeed Studio reComputer J4012](https://www.seeedstudio.com/reComputer-J4012-p-5586.html) — Hardware
- [dusty-nv/jetson-containers](https://github.com/dusty-nv/jetson-containers) — Jetson Docker images
- [NVIDIA JetPack SDK](https://developer.nvidia.com/embedded/jetpack) — Firmware / CUDA userspace
