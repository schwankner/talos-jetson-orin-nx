# Talos Linux on NVIDIA Jetson Orin NX — GPU Compute / CUDA

[![Talos](https://img.shields.io/badge/Talos-v1.12.6-blue)](https://github.com/siderolabs/talos/releases/tag/v1.12.6)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.35.0-blue)](https://kubernetes.io/)
[![Kernel](https://img.shields.io/badge/kernel-6.18.18--talos-orange)](https://github.com/siderolabs/pkgs)
[![nvgpu](https://img.shields.io/badge/nvgpu-5.1.0-green)](https://github.com/OE4T/linux-nvgpu)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](LICENSE)
[![Build](https://github.com/schwankner/talos-jetson-orin-nx/actions/workflows/build-usb.yaml/badge.svg)](https://github.com/schwankner/talos-jetson-orin-nx/actions/workflows/build-usb.yaml)

Run [Talos Linux](https://www.talos.dev/) on the **NVIDIA Jetson Orin NX** with full CUDA GPU compute
support in Kubernetes pods.

Developed and tested on a **[Seeed Studio reComputer J4012](https://www.seeedstudio.com/reComputer-J4012-p-5586.html)**
(Jetson Orin NX 16 GB). Verified result as of Boot 15 (2026-04-01):

- GPU inference: **~7–8 tok/s** decode, **~700 tok/s** prefill (qwen2.5:1.5b Q4_K_M, 29/29 layers on GPU, Flash Attention enabled)
- Dynamic GPU frequency scaling: **306–918 MHz** via `nvhost_podgov` governor (`governor_pod_scaling.ko`)
- NVMe online at **13.7 s**, `module.sig_enforce=1` — **zero module rejections**

---

## Hardware Compatibility

This image targets the **NVIDIA GA10B GPU (Ampere, SM 8.7)** found in all Jetson Orin-series modules.

| Module | Supported | Notes |
|---|---|---|
| **Jetson Orin NX 16 GB** | ✅ Tested | Developed on this module (reComputer J4012) |
| **Jetson Orin NX 8 GB** | ⚠️ Likely works | Same GA10B GPU, less VRAM — untested |
| **Jetson Orin Nano 8 GB** | ⚠️ Likely works | Same GA10B GPU, lower TDP — untested |
| **Jetson Orin Nano 4 GB** | ⚠️ Likely works | Same GA10B GPU — untested |
| **Jetson AGX Orin** | ⚠️ Likely works | Same GA10B GPU, different SKU/firmware — untested |
| **Jetson AGX Xavier / Xavier NX** | ❌ Not compatible | Different GPU architecture (Volta/GV11B, SM 7.2) |
| **Jetson TX2** | ❌ Not compatible | Pascal GPU, different OOT driver tree |

> Tried it on a different Orin module? **Open an issue** with your UART boot log — we'd love to
> document it and expand the compatibility matrix.

**Carrier board**: Any carrier with UEFI boot support should work. Tested on the
reComputer J4012 which provides NVMe, 2× GbE, and a standard UART TCU connector.

---

## Table of Contents

1. [Build Prerequisites](#1-build-prerequisites)
2. [Quick Build & Flash](#2-quick-build--flash)
3. [GitHub Actions Build (Recommended)](#3-github-actions-build-recommended)
4. [Build Pipeline Details](#4-build-pipeline-details)
5. [Component Versions](#5-component-versions)
6. [GPU Verification](#6-gpu-verification)
7. [Known Limitations](#7-known-limitations)
8. [Contributing](#8-contributing)
9. [References](#9-references)

---

## 1. Build Prerequisites

### Local Build (macOS)

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
| `NODE_IP` | `192.168.1.50` | Jetson node IP |

---

## 2. Quick Build & Flash

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

Then boot the Jetson from USB. Talos enters maintenance mode when no STATE
partition is found on NVMe. From there, apply your machine config, fix the
NVMe boot entry, and bootstrap the cluster.

> **Tip**: Use [GitHub Actions](#3-github-actions-build-recommended) — no local
> arm64 environment needed. Just push a tag and download the release artifact.

---

## 3. GitHub Actions Build (Recommended)

`.github/workflows/build-usb.yaml` builds the full USB image on GitHub's ARM64
runners. No Colima, no local Docker, no 90-minute wait.

**Trigger**:
```bash
git tag v1.12.6-nvgpu5.1.0
git push --tags
# → GitHub builds the image and creates a release with the .raw file attached
```

Or run manually: **Actions → Build USB Image → Run workflow**

**Required GitHub Secrets** (set once under *Settings → Secrets → Actions*):

| Secret | Value |
|---|---|
| `SIGNING_KEY_PEM` | Content of `keys/signing_key.pem` |
| `SIGNING_KEY_X509` | Content of `keys/signing_key.x509` |

**Two-job design**:
- **Job 1** (`build-extensions`): builds kernel + GPU driver extensions, pushes to `ghcr.io`.
  Requires an ARM64 runner (`ubuntu-24.04-arm`). Skipped automatically when extension
  images are already cached in ghcr.io (version unchanged). If your plan doesn't include
  ARM64 runners, pre-build locally and push to ghcr.io once:
  ```bash
  REGISTRY=ghcr.io/<you> REGISTRY_DOCKER=ghcr.io/<you> make build-extensions
  ```
- **Job 2** (`build-usb`): assembles UKI + USB image from ghcr.io images (~10 min).
  Runs on a standard x86_64 runner. Works independently of Job 1 if extensions are cached.

**Daily Talos check**: `.github/workflows/check-talos.yaml` runs every morning
and opens a GitHub issue automatically when a new Talos release is available,
with step-by-step upgrade instructions.

**Renovate**: `renovate.json` tracks Talos and kernel versions and opens PRs
when updates are available. GitHub Actions workflow updates are auto-merged
for patch versions.

---

## 4. Build Pipeline Details

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
FORCE_NEW_KEY=1 ./scripts/00-setup-keys.sh && make build-extensions

# Verify key serial embedded in running kernel:
talosctl -n 192.168.1.50 read /proc/keys | grep -i asymmetric
```

Current committed key serial: `74FD747A092BD42575ED4CBE6F7E2479A6FEC740`

### Key Technical Challenges

Getting GPU compute to work required solving 9 non-trivial problems. The full
root-cause analysis (firmware ELOOP, signing key reproducibility, Clang toolchain
consistency, kernel 6.18 API changes, undefined L4T symbols, CUDA error 999,
devfreq governor, CDI / containerd 2.x, UBSAN netlist bug) is documented in
**[BUGS.md](BUGS.md)**.

---

## 5. Component Versions

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

## 6. GPU Verification

### Check module loaded + devfreq governor active

```bash
talosctl -n 192.168.1.50 dmesg | grep -E "nvgpu|ga10b|podgov|devfreq"
# Expected: nvgpu probe, ga10b firmware loaded, governor=nvhost_podgov

talosctl -n 192.168.1.50 read /sys/class/devfreq/17000000.gpu/governor
# nvhost_podgov

talosctl -n 192.168.1.50 read /sys/class/devfreq/17000000.gpu/cur_freq
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

## 7. Known Limitations

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

## 8. Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

Contributions especially welcome for:
- **Other Orin modules** — AGX Orin, Orin Nano (likely compatible, untested)
- **Newer component versions** — Talos, OE4T nvgpu, firmware
- **Other carrier boards** — UART logs + boot results via GitHub Issues
- **Bug reports** — open an issue with Talos version, nvgpu version, and full UART log

---

## 9. References

- [Talos Linux v1.12 Documentation](https://www.talos.dev/v1.12/)
- [Talos System Extensions Guide](https://www.talos.dev/v1.12/talos-guides/configuration/system-extensions/)
- [Talos Boot Assets Guide](https://www.talos.dev/v1.12/talos-guides/install/boot-assets/)
- [siderolabs/pkgs](https://github.com/siderolabs/pkgs) — Talos kernel build system (commit `a92bed5`)
- [OE4T/linux-nvgpu](https://github.com/OE4T/linux-nvgpu) — nvgpu patches (commit `d530a48`)
- [OE4T/linux-nv-oot](https://github.com/OE4T/linux-nv-oot) — NVIDIA OOT framework (commit `ea32e7f`)
- [Seeed Studio reComputer J4012](https://www.seeedstudio.com/reComputer-J4012-p-5586.html) — hardware
- [dusty-nv/jetson-containers](https://github.com/dusty-nv/jetson-containers) — Jetson Docker images
- [NVIDIA JetPack SDK](https://developer.nvidia.com/embedded/jetpack) — firmware / CUDA userspace
