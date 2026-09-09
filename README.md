# Talos Linux on NVIDIA Jetson Orin — GPU Compute / CUDA

[![Talos](https://img.shields.io/badge/Talos-v1.14.0-blue)](https://github.com/siderolabs/talos/releases/tag/v1.14.0)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.37.0-blue)](https://kubernetes.io/)
[![Kernel](https://img.shields.io/badge/kernel-6.18.48--talos-orange)](https://github.com/siderolabs/pkgs)
[![nvgpu](https://img.shields.io/badge/nvgpu-5.11.1--drm-green)](https://github.com/OE4T/linux-nvgpu)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](LICENSE)
[![Build](https://github.com/schwankner/talos-jetson-orin/actions/workflows/release.yaml/badge.svg)](https://github.com/schwankner/talos-jetson-orin/actions/workflows/release.yaml)

Run [Talos Linux](https://www.talos.dev/) on any **NVIDIA Jetson Orin** module with real CUDA GPU
compute in Kubernetes pods. One USB image boots the entire Orin family (AGX Orin, Orin NX, Orin Nano)
— all share the T234 SoC, GA10B GPU (SM 8.7), and UEFI boot path.

Tested on **Jetson Orin NX 16 GB** (reComputer J4012). GPU inference performance vs. native JetPack 6.2:

| Model | Talos (this image) | JetPack 6.2 native | Parity |
|---|---|---|---|
| qwen2.5:0.5b | **64.6 tok/s** | 66.5 tok/s | 97% |
| qwen3:4b | **16.4 tok/s** | 19.5 tok/s | 84% |

All layers on GPU (`cuda_jetpack6`, SM 8.7), 15.3 GiB VRAM available, MAXN power mode.

---

## How it works

Running Jetson Orin GPU in Kubernetes requires solving a problem that standard NVIDIA tooling
does not address: **the Talos mainline kernel ships a `tegra-drm.ko` that is ABI-incompatible
with the OE4T-patched `host1x.ko`**, so the DRM render node (`/dev/dri/renderD128`) never
appears, and `libcuda.so` cannot enumerate the GPU.

This project builds the **complete OE4T DRM stack** from
[linux-nv-oot](https://github.com/OE4T/linux-nv-oot) as a Talos system extension:

```
host1x.ko      OE4T — syncpoint allocator (base for all other modules)
host1x_fence.ko  OE4T — fence/sync primitives
host1x_nvhost.ko OE4T — bridge between host1x and DRM
tegra_drm.ko   OE4T — DRM driver (creates /dev/dri/renderD128)
nvhwpm.ko      OE4T — hardware performance monitoring (tegra-drm dependency)
nvmap.ko       OE4T — GPU memory allocator
mc_utils.ko    OE4T — memory controller bandwidth helper
nvgpu.ko       OE4T — GA10B Ampere CUDA driver
```

The OE4T `tegra-drm.ko` is built against the OE4T `host1x` ABI, so symbols match. The DRM
render node appears at boot, and `libcuda.so` from JetPack r36.5 can open it to initialize the GPU.

For Kubernetes GPU access, a custom CDI (Container Device Interface) stack injects:
- All `/dev/nvgpu/igpu0/*` character devices
- `/dev/dri/renderD128` (DRM render node)
- JetPack r36.5 userspace libraries (`libcuda.so`, `libnvrm_gpu.so`, etc.) from NVIDIA's APT

No `privileged: true`, no manual `/dev` bind-mounts in pod specs.

---

## Requirements

- Jetson Orin module (AGX Orin, Orin NX 16/8 GB, Orin Nano 8/4 GB)
- EDK2 UEFI in SPI flash (factory default on all Orin modules)
- USB stick (16 GB+) for flashing
- `talosctl` v1.14.0: https://github.com/siderolabs/talos/releases/tag/v1.14.0

> **Xavier, TX2, classic Nano**: different GPU architecture — not supported.

---

## Quick Start

### 1. Flash the USB image

Download the latest `.raw` from [Releases](https://github.com/schwankner/talos-jetson-orin/releases):

```bash
# macOS (replace N with disk number from: diskutil list)
sudo dd if=talos-jetson-orin-*.raw of=/dev/rdiskN bs=4m && sync

# Linux (replace X with your USB drive from: lsblk)
sudo dd if=talos-jetson-orin-*.raw of=/dev/sdX bs=4M status=progress && sync
```

Boot your Jetson from the USB stick. Talos enters maintenance mode and waits for configuration.

### 2. Generate machine config

```bash
git clone https://github.com/schwankner/talos-jetson-orin.git
cd talos-jetson-orin

NODE_IP=<jetson-ip>
CLUSTER_NAME=jetson

talosctl gen config "${CLUSTER_NAME}" "https://${NODE_IP}:6443" \
  --config-patch @manifests/talos/machine-patch.yaml \
  --config-patch @manifests/talos/machine-patch-cdi.yaml \
  --output-types controlplane \
  --output controlplane.yaml
```

### 3. Apply config and bootstrap

```bash
export TALOSCONFIG=talosconfig

# Apply config (installs Talos to NVMe, reboots automatically)
talosctl apply-config --insecure --nodes "${NODE_IP}" \
  --file controlplane.yaml \
  --config-patch @manifests/talos/machine-patch.yaml \
  --config-patch @manifests/talos/machine-patch-cdi.yaml

# Wait for node to come back, then bootstrap etcd
talosctl bootstrap --nodes "${NODE_IP}"

# Get kubeconfig
talosctl kubeconfig ./kubeconfig --nodes "${NODE_IP}"
```

### 4. Deploy the GPU stack

```bash
export KUBECONFIG=kubeconfig

# CDI setup: downloads JetPack r36.5 libs, writes CDI spec, sets up firmware
kubectl apply -f manifests/gpu/cdi-setup.yaml

# Wait for libs to download (~2 min, ~50 MB from NVIDIA APT)
kubectl rollout status daemonset/nvidia-cdi-setup -n nvidia-system --timeout=300s

# Device plugin: exposes nvidia.com/gpu resource to Kubernetes
kubectl apply -f manifests/gpu/device-plugin.yaml

# Power mode: sets GPU to MAXN (918 MHz) for maximum inference performance
kubectl apply -f manifests/gpu/power-mode.yaml
```

### 5. Deploy Ollama

```bash
kubectl apply -f manifests/ollama/ollama-cdi.yaml

# Pull a model
curl -X POST http://${NODE_IP}:31434/api/pull \
  -H 'Content-Type: application/json' \
  -d '{"name":"qwen2.5:0.5b"}'

# Run inference
curl -X POST http://${NODE_IP}:31434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5:0.5b","prompt":"Hello!","stream":false}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{d[\"eval_count\"]/(d[\"eval_duration\"]/1e9):.1f} tok/s')"
```

Expected: **~65 tok/s** on Orin NX 16 GB.

---

## Architecture

### System extension: nvidia-tegra-nvgpu

Built from OE4T sources ([linux-nv-oot](https://github.com/OE4T/linux-nv-oot),
[linux-nvgpu](https://github.com/OE4T/linux-nvgpu)), installed as a Talos system extension.

Key insight: the Talos mainline kernel ships `tegra-drm.ko` built against the **vanilla upstream
`host1x` ABI**. The OE4T `host1x.ko` has extensive GA10B syncpoint changes that break symbol
compatibility. When the OE4T `host1x.ko` is loaded first, the vanilla `tegra-drm.ko` fails to
load (`Unknown symbol host1x_job_alloc, err -22`), so `/dev/dri/renderD128` never exists and
`cuInit` returns `801 = CUDA_ERROR_NOT_SUPPORTED`.

The fix: build `tegra-drm.ko` from the **same OE4T source tree** as `host1x.ko`. They share
the same ABI — the module loads, the DRM render node appears, CUDA works.

### CDI (Container Device Interface)

The `nvidia-cdi-setup` DaemonSet:
1. Downloads real JetPack r36.5 userspace libs from NVIDIA's public APT (`libcuda.so.1.1` = 41 MB)
2. Copies GPU firmware to NVMe (avoids `-ETXTBSY` on squashfs inodes)
3. Writes `/var/run/cdi/nvidia-jetson.yaml` — the CDI spec containerd reads per pod

The `nvidia-device-plugin` exposes `nvidia.com/gpu: 1` as a Kubernetes extended resource.
When a pod requests it, containerd reads the CDI spec and injects devices + libs automatically.

**CDI-injected into every GPU pod:**
- `/dev/nvgpu/igpu0/*` — GPU command submission channels
- `/dev/dri/renderD128` — DRM render node (required for `cuInit`)
- `/dev/nvmap` — GPU memory allocator
- `/var/lib/nvidia-tegra-libs/tegra` → `/usr/lib/aarch64-linux-gnu/nvidia` (JetPack r36.5 libs)
- `LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/nvidia:...`

### Power mode

The `jetson-power-mode` DaemonSet sets GPU and CPU clocks at boot:

| Mode | GPU | CPU | EMC | Notes |
|---|---|---|---|---|
| MAXN (default) | 918 MHz | 1984 MHz | 3199 MHz | Maximum inference performance |
| 25W | 408 MHz | 1497 MHz | dynamic | Balanced |
| 15W | 612 MHz | 1420 MHz | dynamic | Power saving |
| 10W | 612 MHz | 1190 MHz | dynamic | Minimum power |

Without MAXN mode, GPU runs at ~400-600 MHz and throughput is roughly halved.

---

## Build from source

The GitHub Actions workflow builds the complete image:

```bash
# Trigger via GitHub Actions (push a tag)
git tag v1.0.0 && git push origin v1.0.0
```

Or build locally (requires Docker + ~2 hours on ARM64):

```bash
source scripts/common.sh
./scripts/build-extensions.sh   # builds kernel-modules + nvidia-tegra-nvgpu extension
./scripts/build-usb-image.sh    # assembles UKI + USB raw image
```

**Custom installer image** (for `talosctl upgrade`):
```
ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
```

> **Talos ≥ 1.14:** `ghcr.io/siderolabs/installer` is no longer published — released installers
> are served by the [Image Factory](https://factory.talos.dev), which cannot take a custom kernel.
> The build therefore uses `ghcr.io/siderolabs/installer-base` as the installer base and lets the
> imager add the custom-signed kernel, which is the same default Talos' own imager uses since 1.11.
> The v1alpha1 fields `.machine.kernel`, `.machine.install` and `.machine.files` used in
> `manifests/talos/` are deprecated in 1.14 in favour of `KernelModuleConfig`,
> `UnattendedInstallConfig` and `EtcFileConfig` documents, but still work unchanged; migrating them
> is tracked separately.

> **Same-version upgrades on Jetson UEFI (Bug 25):** when only the extension changes and the Talos
> version stays the same, the installer writes the new UKI as `Talos-vX.Y.Z~N.efi` and selects it via
> the `LoaderEntryDefault` EFI variable. Jetson UEFI 36.4.3 does not persist that runtime write, so
> sd-boot boots the old UKI and `talosctl upgrade` still reports success. Verify with
> `talosctl get extensions`; if the old version is still running, pick the `~N` entry once in the
> sd-boot menu at boot, then run the same upgrade again to make it stick. Details in
> [BUGS.md](BUGS.md#bug-25--same-version-talosctl-upgrade-never-boots-the-new-uki-on-jetson-uefi-reports-success-anyway).

---

## Versions

| Component | Version |
|---|---|
| Talos Linux | v1.14.0 |
| Kubernetes | v1.37.0 |
| Linux kernel | 6.18.48-talos |
| nvidia-tegra-nvgpu extension | 5.11.1-drm-noshim |
| JetPack libs (userspace) | r36.5.0 |
| Ollama | 0.20.5 |

---

## Supported modules

| Module | Status |
|---|---|
| Jetson AGX Orin (all SKUs) | Supported (same T234 SoC / GA10B GPU) |
| Jetson Orin NX 16 GB | Tested |
| Jetson Orin NX 8 GB | Supported |
| Jetson Orin Nano 8 GB | Supported |
| Jetson Orin Nano 4 GB | Supported |
| Xavier / TX2 / Nano (classic) | Not supported (different GPU architecture) |

All Orin modules use the same T234 SoC with GA10B Ampere GPU and boot via UEFI.
A single USB image works for all variants.

---

## Troubleshooting

### GPU not detected in Ollama (`library=cpu`)

Check if the DRM render node exists:
```bash
talosctl list /dev/dri --nodes <jetson-ip>
# Expected: card0  renderD128
```

If `renderD128` is missing, `tegra_drm` failed to load. Check dmesg:
```bash
talosctl dmesg --nodes <jetson-ip> | grep -i "tegra.drm\|host1x"
```

### CDI injection fails (`not a device node`)

Ensure `/dev/nvhost-ctrl` is not a symlink in the CDI spec. The CDI setup handles this
automatically — if the error persists, restart the `nvidia-cdi-setup` DaemonSet:
```bash
kubectl rollout restart daemonset/nvidia-cdi-setup -n nvidia-system
```

### Low throughput (~30-35 tok/s instead of ~65 tok/s)

Power mode not applied. Deploy the power-mode DaemonSet:
```bash
kubectl apply -f manifests/gpu/power-mode.yaml
kubectl logs -n nvidia-system -l app=jetson-power-mode | grep "cur_freq"
# Expected: GPU cur_freq=918000000 Hz
```

### `cuInit` returns 801 (CUDA_ERROR_NOT_SUPPORTED)

This was the root cause before the DRM fix was applied. With the current extension
(`nvgpu5.11.1-drm-noshim`), this should not occur. Verify the correct extension is loaded:
```bash
talosctl get extensions --nodes <jetson-ip> | grep nvgpu
# Expected: nvidia-tegra-nvgpu  5.11.1-drm-noshim-6.18.48-talos
```

---

## Related projects

- [siderolabs/pkgs](https://github.com/siderolabs/pkgs) — Talos kernel and system extension framework
- [OE4T/linux-nv-oot](https://github.com/OE4T/linux-nv-oot) — NVIDIA out-of-tree drivers for Tegra
- [OE4T/linux-nvgpu](https://github.com/OE4T/linux-nvgpu) — NVIDIA GPU driver for Tegra

---

## License

MPL 2.0. See [LICENSE](LICENSE).

NVIDIA kernel modules are built from OE4T open-source repositories and distributed in object form
under the terms of the GPU License Agreement (GLA).
