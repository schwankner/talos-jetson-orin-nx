# Talos Linux on NVIDIA Jetson Orin — GPU Compute / CUDA

[![Talos](https://img.shields.io/badge/Talos-v1.12.6-blue)](https://github.com/siderolabs/talos/releases/tag/v1.12.6)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.35.2-blue)](https://kubernetes.io/)
[![Kernel](https://img.shields.io/badge/kernel-6.18.18--talos-orange)](https://github.com/siderolabs/pkgs)
[![nvgpu](https://img.shields.io/badge/nvgpu-5.10.7-green)](https://github.com/OE4T/linux-nvgpu)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](LICENSE)
[![Build](https://github.com/schwankner/talos-jetson-orin/actions/workflows/release.yaml/badge.svg)](https://github.com/schwankner/talos-jetson-orin/actions/workflows/release.yaml)

Run [Talos Linux](https://www.talos.dev/) on any **NVIDIA Jetson Orin** module with full CUDA GPU
compute support in Kubernetes pods. One USB image boots the entire Orin family (AGX Orin,
Orin NX, Orin Nano) — all share the same T234 SoC, GA10B GPU, and UEFI boot path.

Developed and tested on a **[Seeed Studio reComputer J4012](https://www.seeedstudio.com/reComputer-J4012-p-5586.html)**
(Jetson Orin NX 16 GB). Verified result as of 2026-04-10:

- GPU inference: **~30 tok/s** decode (qwen2.5:0.5b) / **~12 tok/s** (qwen2.5:7b, gemma4:e4b) — all layers on CUDA
- All models that fit in memory work
- Hardware syncpoint interrupts via `nvhost-ctrl-shim` — `cudaStreamSynchronize` uses interrupt-driven wait (no CPU polling)
- Dynamic GPU frequency scaling: **306–918 MHz** via `nvhost_podgov` governor (`governor_pod_scaling.ko`)

---

## What makes this image different

Running a Jetson Orin with GPU access in Kubernetes is surprisingly hard to do properly. Most
guides end up with `privileged: true` containers, manual `/dev` bind-mounts, and hardcoded
library paths — because the generic NVIDIA toolchain simply does not support Tegra.
This project solves the problem at every layer:

### 1 — Custom CDI-native Kubernetes device plugin

The standard [`nvidia-device-plugin`](https://github.com/NVIDIA/k8s-device-plugin) **does not
work on Jetson**. It relies on NVML (`libnvidia-ml.so`), which does not exist on Tegra — the
Tegra GPU stack has no NVML. As a result, `nvidia.com/gpu` cannot be exposed as a Kubernetes
resource with the upstream plugin.

This project ships a **purpose-built device plugin** (`ghcr.io/schwankner/jetson-device-plugin`)
that uses the CDI path instead of NVML:

1. Pod requests `resources.limits["nvidia.com/gpu": "1"]`
2. The plugin returns a `CDIDevices` response: `nvidia.com/gpu=0`
3. kubelet passes the CDI device ID to containerd via the CRI interface
4. containerd reads `/var/run/cdi/nvidia-jetson.yaml` and **automatically injects**:
   - All `/dev/nvgpu/igpu0/*` device nodes
   - `/dev/nvmap` (GPU memory allocator)
   - `/dev/nvhost-ctrl` (syncpoint wait — provided by `nvhost-ctrl-shim`)
   - JetPack r36.5 library bind-mount → `/usr/lib/aarch64-linux-gnu/nvidia`
   - `LD_LIBRARY_PATH` pointing at the real CUDA libraries

The CDI spec is written dynamically at boot by the `nvidia-cdi-setup` DaemonSet, so it always
reflects the actual devices present on the node.

### 2 — No manual device mounts or library paths in workload pods

With the official NVIDIA JetPack Ubuntu + Kubernetes approach, every GPU pod must either:
- run as `privileged: true` with a full `/dev` hostPath mount, or
- explicitly enumerate each device node (`/dev/nvgpu/igpu0/ctrl`, `/dev/nvmap`, …) and
  manually bind-mount the JetPack library directory

This is fragile, insecure, and breaks when device nodes change between kernel versions.

With our CDI stack, a GPU pod only needs:

```yaml
resources:
  limits:
    nvidia.com/gpu: "1"    # that's it — containerd handles the rest via CDI
```

No `privileged: true`. No hostPath volumes. No hardcoded `LD_LIBRARY_PATH`.
The system-level daemons (`nvidia-cdi-setup`, `nvidia-device-plugin`) run privileged because
they are node infrastructure — equivalent to kubelet itself needing root. User workloads do not.

### 3 — nvhost-ctrl-shim: hardware syncpoint interrupts for CUDA

Without this kernel module, CUDA's `cudaStreamSynchronize` falls back to **CPU semaphore
polling** — burning CPU cycles waiting for each GPU operation. This cuts inference throughput
by ~4× (7 tok/s → 30 tok/s on qwen2.5:0.5b).

The shim provides `/dev/nvhost-ctrl` with the full `NVHOST_IOCTL_CTRL_SYNCPT_WAITMEX` interface,
allowing the CUDA driver to block on a kernel wait queue and be woken by a hardware interrupt
when the GPU signals the syncpoint. This is how JetPack Ubuntu works — our shim brings the
same behavior to a custom Talos kernel where the NVIDIA host1x driver (`CONFIG_TEGRA_GK20A_NVHOST`)
is deliberately disabled (`=n`) to avoid the kernel module signing problem.

### Comparison with official NVIDIA JetPack Ubuntu + Kubernetes

| | Official JetPack Ubuntu + K8s | This project |
|---|---|---|
| Device plugin | ❌ None that works on Tegra (no NVML) | ✅ Custom CDI-native plugin |
| GPU scheduling | ❌ Manual or third-party workarounds | ✅ `nvidia.com/gpu: 1` resource |
| CDI support | ❌ Not supported for Tegra | ✅ Full CDI stack |
| Pod privileges | ❌ `privileged: true` + manual `/dev` mounts | ✅ No `privileged`, no hostPath mounts (verified) |
| `cudaStreamSynchronize` | ✅ Hardware interrupts (nvhost in kernel) | ✅ Hardware interrupts via `nvhost-ctrl-shim` |
| CUDA inference throughput | ✅ ~12 tok/s (7b) when GPU is used | ✅ ~12 tok/s (7b) — same GPU hardware |
| Silent CPU fallback risk | ⚠️ Common — GPU stack misconfiguration silently degrades to ~5.6 tok/s | ✅ CDI + device plugin guarantees GPU is used |
| Talos / immutable OS | ❌ JetPack ships Ubuntu only | ✅ Talos (immutable, no SSH, Kubernetes-native) |

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
> - `ollama/ollama:0.20.5` — **recommended** (official Ollama, GA10B-tuned `cuda_jetpack6` backend, requires `JETSON_JETPACK=6` env var — see [§2](#2-llm-inference-with-ollama))
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
2. [LLM Inference with Ollama](#2-llm-inference-with-ollama)
3. [GPU Verification](#3-gpu-verification)
4. [GPU Power Modes](#4-gpu-power-modes)
5. [Build Prerequisites](#5-build-prerequisites)
6. [Local Build & Flash](#6-local-build--flash)
7. [GitHub Actions Pipeline](#7-github-actions-pipeline)
8. [Build Pipeline Details](#8-build-pipeline-details)
9. [Component Versions](#9-component-versions)
10. [Known Bugs](#10-known-bugs-and-limitations)
11. [Design Limitations](#11-known-limitations)
12. [Contributing](#12-contributing)
13. [References](#13-references)
14. [AI Disclaimer](#14-ai-disclaimer)

---

## 1. Installation

### Option A — Fresh Install (USB)

No build environment needed. Download the pre-built USB image from the
[latest release](https://github.com/schwankner/talos-jetson-orin/releases/latest),
flash it to a USB drive and boot.

#### Download

```bash
# Find the latest release URL
LATEST=$(curl -s https://api.github.com/repos/schwankner/talos-jetson-orin/releases/latest \
  | grep browser_download_url | grep '\.raw' | cut -d'"' -f4)

curl -L -O "${LATEST}"
```

Or go to **[Releases](https://github.com/schwankner/talos-jetson-orin/releases)** and
download the `.raw` file manually.

#### Flash

```bash
# macOS (replace rdiskN with your USB drive — check: diskutil list)
sudo dd if=talos-usb-nvgpu5.10.7.raw of=/dev/rdiskN bs=4m && sync

# Linux (replace sdX with your USB drive — check: lsblk)
sudo dd if=talos-usb-nvgpu5.10.7.raw of=/dev/sdX bs=4M status=progress && sync
```

> **Tip**: On macOS use `diskutil unmountDisk /dev/diskN` before flashing.

#### Prerequisites

> ⚠️ **JetPack 6.2 (L4T r36.5) must be present on the Jetson before installing this image.**
>
> The GPU firmware files (`pmu_pkc_prod_sig.bin` and friends) are sourced from JetPack r36.5.
> Older JetPack versions (6.1 / r36.4 or earlier) will cause the nvgpu driver to fail at firmware load.
>
> Jetsons ship with JetPack pre-installed. If yours already runs JetPack 6.2 (r36.5), proceed directly
> to [Boot & Install](#boot--install). If it runs an older version, update to JetPack 6.2 first using
> [NVIDIA SDK Manager](https://developer.nvidia.com/sdk-manager).

#### Generate a machine config

> **Do not use a plain `talosctl gen config` without the GPU patch.** A vanilla Talos machine
> config uses the wrong installer image (no nvgpu) and does not load the GPU kernel modules.
> The result: Talos boots, Kubernetes runs, but CUDA fails silently.

```bash
# Generate a controlplane config with both GPU patches applied in one step:
talosctl gen config <cluster-name> https://<jetson-ip>:6443 \
  --config-patch @manifests/talos/machine-patch-gpu.yaml \
  --config-patch @manifests/talos/machine-patch-cdi.yaml \
  --output-types controlplane \
  --output controlplane.yaml
```

The two patches add:
- **`machine-patch-gpu.yaml`** — correct installer image + explicit `kernel.modules` load order
  (nvhost_ctrl_shim has no device-tree entry; without explicit loading, CUDA uses CPU polling)
- **`machine-patch-cdi.yaml`** — CDI support in containerd + Jetson node labels

#### Boot & Install

1. Plug the USB drive into the Jetson.
2. Enter the **UEFI boot menu** (press **F11** during POST / on the UART splash screen).
3. Select **Boot Manager → USB drive** and confirm.
4. Talos boots into **maintenance mode** (no STATE partition found on NVMe yet).
5. Apply your machine config:
   ```bash
   talosctl apply-config --insecure -n <jetson-ip> --file controlplane.yaml
   ```
6. **Remove the USB drive immediately** when the node starts rebooting (watch the UART log
   for `rebooting`). If the USB stays in, the UEFI boots USB again on every restart and the
   NVMe EFI bootloader is never written — resulting in `reboot into firmware interface` when
   the USB is eventually removed.
7. Talos boots from NVMe, comes up fully operational.
8. Bootstrap the cluster (first boot only):
   ```bash
   talosctl bootstrap -n <jetson-ip>
   ```

> If you missed the USB removal window and are stuck with `reboot into firmware interface`:
> re-insert USB, boot into Talos maintenance mode, apply the config again, and remove USB
> before the reboot completes. Alternatively run `talosctl upgrade --preserve` (see Option B)
> which rewrites the NVMe EFI partition regardless of USB state.

---

### Option B — Upgrade from an Existing Talos Installation

If you already have any Talos version running on a Jetson Orin NX, you can switch to this
custom image **without USB** using `talosctl upgrade`. No data is lost — `--preserve` keeps
your machine config, etcd state, and Kubernetes workloads intact.

#### Prerequisites

- JetPack 6.2 (L4T r36.5) must have been flashed at some point — the GPU firmware it writes
  to the Jetson's eMMC persists across Talos upgrades.
- `talosctl` v1.12.x and a working `talosconfig` for the node.

#### Upgrade command

```bash
talosctl upgrade \
  --nodes <jetson-ip> \
  --talosconfig ./talosconfig \
  --image ghcr.io/schwankner/custom-installer:v1.12.6-6.18.18-nvgpu5.10.7 \
  --preserve
```

The installer image is publicly available on `ghcr.io` — no registry credentials needed.

#### What happens

1. Talos downloads the installer image from `ghcr.io`.
2. The node reboots into the installer, which writes the new system partition.
3. On the next boot, Talos v1.12.6 starts with the custom kernel (6.18.18-talos), nvgpu
   5.10.7 extension, and nvhost-ctrl-shim — CUDA is available immediately.
4. Your machine config, etcd data, and workloads are preserved.

> **Note**: the node will be unavailable for ~2–3 minutes during the upgrade reboot.
> Monitor with `talosctl health --nodes <ip> --talosconfig ./talosconfig`.

---

### Option C — Standard Talos ARM64 Image (no GPU)

The **standard Talos ARM64 installer** (`factory.talos.dev/installer/<schematic>`) boots and
runs fine on Jetson Orin NX without any modifications — because the Orin NX is an ARM64 UEFI
machine that Talos supports out of the box.

You get a fully functional Talos + Kubernetes node, but **without GPU access**:

- No `nvidia.com/gpu` resource — GPU pods are not schedulable
- Ollama and other CUDA workloads fall back to CPU-only (~5.6 tok/s for 7B models)
- No nvgpu OOT driver, no CDI stack, no nvhost-ctrl-shim

This image (schwankner/talos-jetson-orin) is a drop-in replacement that adds GPU support on
top of standard Talos — same Talos version, same upgrade path, just with the nvgpu extension
and CDI stack pre-installed.

---

## 2. LLM Inference with Ollama

### Recommended Image: `ollama/ollama`

The **official `ollama/ollama`** image is the recommended way to run LLM inference on this setup.
Starting with Ollama 0.6.x, the image ships a `cuda_jetpack6/libggml-cuda.so` backend that is
specifically tuned for the GA10B GPU (compute capability 8.7) on Jetson Orin — it is compiled
with `CMAKE_CUDA_ARCHITECTURES=87` and handles the Tegra UMA memory model correctly.

> **Why not `dustynv/ollama`?**
> The [`dustynv/ollama`](https://hub.docker.com/r/dustynv/ollama) image (from
> [dusty-nv/jetson-containers](https://github.com/dusty-nv/jetson-containers)) was the standard
> recommendation for Jetson CUDA workloads for a long time, but **has not been updated since
> July 7, 2025**. It is missing all Ollama improvements from the past year (newer model support,
> quantization fixes, performance improvements) and cannot load many modern models at all.
> Use `ollama/ollama` instead.

### Critical: `JETSON_JETPACK=6` env var

Without this environment variable, `ollama/ollama` silently falls back to **CPU-only mode**:

```
# Without JETSON_JETPACK=6 — CPU only (wrong):
time=... level=INFO msg="inference compute" library=cpu

# With JETSON_JETPACK=6 — GPU (correct):
time=... level=INFO msg="inference compute" library=CUDA compute=8.7 name=CUDA0 \
  description=Orin driver=12.6 total="15.2 GiB"
```

Ollama detects the JetPack version via this variable and loads `cuda_jetpack6/libggml-cuda.so`.
If the variable is missing, Ollama logs: `"jetpack not detected (set JETSON_JETPACK or OLLAMA_LLM_LIBRARY to override)"`.

### Required environment variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `JETSON_JETPACK` | `6` | Activates `cuda_jetpack6` CUDA backend — **required** |
| `OLLAMA_FLASH_ATTENTION` | `1` | Enables Flash Attention (significant speedup) |
| `OLLAMA_NUM_PARALLEL` | `1` | Single parallel request — avoids wasted KV cache |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | KV cache quantization — halves KV cache bandwidth |
| `LD_LIBRARY_PATH` | see below | Ensures `libcuda.so.1` from JetPack is found |

```
LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/nvidia:/usr/local/cuda/lib:/usr/local/cuda/lib64:/usr/lib/ollama/cuda_jetpack6
```

### Verified performance (Orin NX 16 GB, MAXN mode, nvgpu 5.10.7)

> **Bottleneck: GA10B memory bandwidth (~68 GB/s LPDDR5)**
> Token decoding reads the entire model once per token — decode throughput is therefore
> memory-bandwidth-bound, not compute-bound. This is the hard ceiling for all models on
> this hardware. Quantization (fewer bytes per weight) is the only way to push past it.
>
> This also means **higher GPU clocks provide no benefit**: tested at MAXN_SUPER (1,173 MHz
> vs. MAXN's 918 MHz), decode throughput stays at ~11–12 tok/s — the GPU never reaches its
> compute ceiling because it is always waiting for memory, not crunching numbers.
>
> **Clock configuration matters**: EMC (memory controller) must be locked to 3199 MHz and
> CPU governor set to `performance`. Without this, BPMP scales EMC to 2133 MHz at idle
> and the CPU idles at 268 MHz between tokens — costing up to 50% prompt eval throughput
> and doubling first-token latency for small models.

| Model | Size | Quantization | GPU layers | Prompt eval | Decode (GPU) | Decode (CPU fallback) |
|-------|------|-------------|-----------|------------|-------------|----------------------|
| qwen2.5:0.5b | 397 MB | Q4_K_M | 28/28 | ~1100 tok/s | **~60 tok/s** | ~39 tok/s¹ |
| qwen2.5:7b | 4.7 GB | Q4_K_M | 29/29 | ~425 tok/s | **~11–12 tok/s** | ~5.6 tok/s |
| gemma4:e4b | 9.6 GB | — | all | ~160–275 tok/s | **~12 tok/s** | n/a (OOM) |
| qwen3.5:9b ²| ~5.5 GB | Q4_K_M | all | ~63 tok/s | **~7.7 tok/s** | n/a |
| ministral-3:14b | ~8 GB | Q4_K_M | all | ~197 tok/s | **~6.8 tok/s** | n/a |

> ¹ qwen2.5:0.5b is small enough to benefit from CPU cache locality — ARM Cortex-A78AE at this
> model size is competitive with GPU. The GPU advantage grows substantially with model size:
> at 7B, GPU is **2.1× faster** than CPU-only. At 9.6 GB (gemma4:e4b), the model doesn't fit
> in memory without the GPU's UMA access pattern and causes OOM on CPU.
>
> ² qwen3.5:9b is a reasoning (thinking) model — it generates an internal chain-of-thought trace
> before the final answer. The decode rate reflects raw hardware throughput; a single response
> may produce 5,000+ tokens of reasoning, so wall-clock time per query is much higher than the
> tok/s figure suggests. Use `/no_think` in the prompt to disable thinking mode if not needed.
>
> **Memory bandwidth ceiling**: all models above 1 GB decode at 6–12 tok/s despite their size
> differences. This is expected: the GA10B has ~68 GB/s of LPDDR5 memory bandwidth, and token
> decoding is purely memory-bound (one full model read per token). The only practical lever is
> quantization: lower bit-width means fewer bytes per weight per token, which translates directly
> to higher decode throughput.

**The common failure mode** on Jetson is Ollama silently falling back to CPU because the GPU
stack isn't set up correctly (no device plugin, no CDI spec, missing `JETSON_JETPACK=6`). This
image solves that — the GPU is guaranteed to be detected and used.

#### Comparison: Talos (this image) vs. stock JetPack 6.2

Measured on the same hardware (Orin NX 16 GB) with the same Ollama version (0.20.5) and
identical prompts — JetPack 6.2 running natively on Ubuntu 22.04, Talos running in a
Kubernetes pod via CDI.

| Model | Talos (this image) | JetPack 6.2 (native) | Delta |
|-------|-------------------|----------------------|-------|
| qwen2.5:0.5b | ~30 tok/s | ~35 tok/s | −14% |
| qwen2.5:7b | ~12 tok/s | ~13.5 tok/s | −11% |
| gemma4:e4b (9.6 GB) | ~12 tok/s | ~14.75 tok/s | −19% |
| qwen3.5:9b ²| ~7.7 tok/s | ~9.8 tok/s | −21% |
| ministral-3:14b | ~6.8 tok/s | ~8.3 tok/s | −18% |

> ² qwen3.5:9b is a reasoning (thinking) model — it performs internal chain-of-thought before
> answering. The decode rate (9.8 tok/s) reflects raw hardware throughput; the model generates
> far more tokens per response than non-thinking models due to the reasoning trace.

> **Takeaway**: Talos + Kubernetes adds less than ~20% overhead compared to bare-metal JetPack
> for all model sizes — and the difference is consistent with a thin container shim (CDI lib
> bind-mount) rather than a fundamental driver gap.
>
> For large models (7B+, memory-bandwidth-bound), the difference is negligible in practice
> (~1–2 tok/s). For the small 0.5b model, JetPack has a slight edge, likely because stock
> Ubuntu has the full NVHOST syncpoint stack available by default (no shim needed).

> **Community reference**: NVIDIA's official JetPack 6.2 benchmark reports **~20 tok/s** for
> qwen2.5:7b on Orin NX 16GB using the [MLC inference API](https://developer.nvidia.com/blog/nvidia-jetpack-6-2-brings-super-mode-to-nvidia-jetson-orin-nx-modules/)
> (INT4 quantization, not Ollama/GGUF). Our ~12 tok/s with Ollama Q4_K_M is a different stack
> — Ollama uses llama.cpp/GGUF, which trades some raw throughput for broad model compatibility.

> **Note on large models (7B+)**: nvgpu 5.10.7 fixes the previous `CUDA error: unknown error`
> crash for `qwen2.5:7b` and similar models. The root cause was a SYNCPT_WAITMEX timeout —
> CUDA passed a ~5s deadline to the kernel wait, which the GA10B exhausted during warmup for
> large embedding tables. The shim now enforces a 30-second minimum floor. See
> [BUGS.md — Bug 19](BUGS.md) for the full analysis.

### Debug GPU detection

```bash
# Check shim on the node
talosctl -n <node-ip> dmesg | grep nvhost-ctrl-shim

# Enable verbose ioctl logging (requires privileged pod):
echo "file nvhost_ctrl_shim.c +p" > /sys/kernel/debug/dynamic_debug/control
```

---

## 3. GPU Verification

### Check module loaded + devfreq governor active

```bash
talosctl -n <node-ip> dmesg | grep -E "nvgpu|ga10b|podgov|devfreq"
# Expected: nvgpu probe, ga10b firmware loaded

talosctl -n <node-ip> read /sys/bus/platform/devices/17000000.gpu/devfreq/17000000.gpu/governor
# performance  (after power-mode DaemonSet)

talosctl -n <node-ip> read /sys/bus/platform/devices/17000000.gpu/devfreq/17000000.gpu/cur_freq
# 918000000  (918 MHz in MAXN mode)
```

### Check nvhost-ctrl-shim loaded

```bash
talosctl -n <node-ip> dmesg | grep nvhost-ctrl-shim
# Expected: nvhost-ctrl-shim: /dev/nvhost-ctrl ready (major 505)
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

## 4. GPU Power Modes

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
| `MAXN_SUPER` | 8 | 1,984 MHz | up to 1,173 MHz | `performance` | ⛔ **Blocked on J401** — no inference benefit (memory-bandwidth-bound) |

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

> This will allow the GPU to boost up to 1,173 MHz (Orin NX 16 GB). The DaemonSet logs a
> prominent warning when this override is active. **Note:** LLM inference is memory-bandwidth-bound
> on the GA10B — tested at 1,173 MHz, decode throughput remains at ~11–12 tok/s (identical to
> MAXN at 918 MHz). Higher GPU clocks do not help if the bottleneck is LPDDR5 bandwidth.

### Verify Frequencies at Runtime

```bash
# GPU frequency
talosctl -n <node-ip> read \
  /sys/bus/platform/devices/17000000.gpu/devfreq/17000000.gpu/cur_freq

# GPU governor
talosctl -n <node-ip> read \
  /sys/bus/platform/devices/17000000.gpu/devfreq/17000000.gpu/governor

# Active CPU cores
talosctl -n <node-ip> read /sys/devices/system/cpu/online
```

---

## 5. Build Prerequisites

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
| `NVGPU_VERSION` | `5.10.7` | nvgpu extension version |

---

## 6. Local Build & Flash

Only needed if you want to modify the kernel, nvgpu driver, or extensions.
For most users, the [pre-built release image](#1-installation) is the right choice.

```bash
# 1. Generate signing key (once per repo clone / fork)
./scripts/00-setup-keys.sh
# If you want CI builds to work in a fork, also add the generated keys as
# GitHub Actions secrets — see §7 (GitHub Actions Pipeline → Required GitHub Secrets).

# 2. Build all extensions + kernel (~60–90 min, cold cache)
make build-extensions

# 3. Build UKI + bootable USB image
make usb

# 4. Flash to USB drive (macOS — replace rdiskN)
sudo dd if=dist/talos-usb-nvgpu5.10.7.raw of=/dev/rdiskN bs=4m && sync

# Linux:
# sudo dd if=dist/talos-usb-nvgpu5.10.7.raw of=/dev/sdX bs=4M status=progress && sync
```

---

## 7. GitHub Actions Pipeline

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
git tag v1.12.6-nvgpu5.10.7
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

## 8. Build Pipeline Details

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
                              │  nvidia-tegra-nvgpu:5.10.7-…     │
                              │  kernel-modules-clang:1.3.0-…    │
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
| `custom-installer` | `v1.12.6-6.18.18-nvgpu5.10.7` | **Full installer with all extensions** — use this for `talosctl upgrade` |
| `nvidia-tegra-nvgpu` | `5.10.7-6.18.18-talos` | `nvgpu.ko` (NVHOST=n) + `nvhost-ctrl-shim.ko` (all CUDA ioctls, 30s SYNCPT floor) + `nvmap.ko` + `governor_pod_scaling.ko` + friends |
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

Getting GPU compute to work required solving 19 non-trivial problems. The full
root-cause analysis (firmware ELOOP, signing key reproducibility, GCC 15/Clang 22
toolchain mismatch, kernel 6.18 API changes, undefined L4T symbols, CUDA error 999,
devfreq governor, CDI / containerd 2.x, UBSAN netlist bug, CI extension image
distribution, nvhost-ctrl-shim ioctl implementation, USB boot masking NVMe upgrades,
pkg.yaml source pin management, SYNCPT_WAITMEX timeout for large models) is
documented in **[BUGS.md](BUGS.md)**.

---

## 9. Component Versions

| Component | Version | Notes |
|---|---|---|
| Talos Linux | **v1.12.6** | pkgs commit `a92bed5`, branch `release-1.12` |
| Kubernetes | **v1.35.2** | |
| Kernel | **6.18.18-talos** | Clang/LLVM build, reproducible module signing key |
| LLVM/Clang | `v1.14.0-alpha.0` | `ghcr.io/siderolabs/llvm` |
| OE4T linux-nvgpu | `d530a48` | patches-r36.5 — the GA10B GPU driver |
| OE4T linux-nv-oot | `ccf7646` | NVIDIA OOT framework (nvmap, conftest, devfreq) |
| OE4T linux-hwpm | `4d8a699` | Hardware Performance Monitor |
| `nvidia-tegra-nvgpu` ext | **5.10.7** | `NVHOST=n` + `nvhost-ctrl-shim` (all ioctls incl. POLL_FD_CREATE; SYNCPT_WAITMEX 30s floor fixes 7B+ model crashes) |
| `kernel-modules-clang` ext | **1.3.0** | Full Clang-compiled kernel module tree, signed with `talos_signing_key.pem` |
| `nvidia-firmware-ext` | **v5** | `pmu_pkc_prod_sig.bin` added; sourced from L4T r36.5 apt (`t234` repo) |

---

## 10. Known Bugs and Limitations

All non-trivial bugs encountered during development — including the full investigation of
CUDA error 999, the NVHOST=y attempt history, the GPU decode speed bottleneck, and the
qwen2.5:7b SYNCPT_WAITMEX timeout root cause — are documented with detailed root-cause
analysis in **[BUGS.md](BUGS.md)**.

Notable items relevant to day-to-day use:

| # | Issue | Impact | Status |
|---|-------|--------|--------|
| [Bug 6](BUGS.md#bug-6--cuda-error-999-cudastreamsynchronize--nvhost-syncpoint) | CUDA error 999 (`cudaStreamSynchronize`) | GPU compute fails | ✅ Fixed — `NVHOST=n` |
| [Bug 14](BUGS.md#bug-14--cuda-error-999-persists-with-nvhosty-nvgpu-590--591) | CUDA error 999 with NVHOST=y (5.9.0/5.9.1) | GPU pool not signable | ✅ Diagnosed — NVHOST=n stable |
| [Bug 15](BUGS.md#bug-15--gpu-decode-speed-7-toks-cpu-polling-overhead-with-nvhostn) | GPU decode ~7 tok/s (CPU polling) | Slow inference | ✅ Fixed — `nvhost-ctrl-shim` SYNCPT_WAITMEX (5.10.4→**~16 tok/s**) + `pr_debug` (5.10.5→**~23 tok/s**) |
| [Bug 16](BUGS.md) | Jetson boots from USB instead of NVMe after upgrade | `talosctl upgrade` silently ignored | ✅ Fixed — remove USB stick |
| [Bug 17](BUGS.md) | nvhost-ctrl-shim missing SYNCPT_WAITMEX + GET_CHARACTERISTICS | CUDA error 999 with shim loaded | ✅ Fixed — implemented in nvhost_ctrl_shim.c (5.10.3) |
| [Bug 18](BUGS.md) | pkg.yaml shim source pin not updated after code change | Old shim code shipped despite version bump | ✅ Fixed — pin `url`+`sha256`+`sha512` in pkg.yaml (5.10.4) |
| [Bug 9](BUGS.md#bug-9--ubsan-array-index-out-of-bounds-in-netlistc-non-fatal) | UBSAN `netlist.c:617` at every boot | Log noise | ✅ Silenced (flexible array) |
| [Bug 19](BUGS.md) | `qwen2.5:7b` (7B+ models) crash on first inference | Large models crash on GPU | ✅ Fixed — nvgpu 5.10.7 SYNCPT_WAITMEX 30s floor |
| [Bug 20](BUGS.md) | NVMe EFI not written when USB left in during post-install reboot | `reboot into firmware interface` — NVMe won't boot standalone | ✅ Documented — remove USB before reboot; see [Installation](#1-installation) |
| [Bug 21](BUGS.md) | `nvhost_ctrl_shim` not auto-loaded on fresh install | `/dev/nvhost-ctrl` missing → CPU polling → ~7 tok/s | ✅ Fixed — `machine.kernel.modules` via `machine-patch-gpu.yaml` |

---

## 11. Known Limitations

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

## 12. Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

Contributions especially welcome for:
- **Other Orin modules** — AGX Orin, Orin Nano (likely compatible, untested)
- **Newer component versions** — Talos, OE4T nvgpu, firmware
- **Other carrier boards** — UART logs + boot results via GitHub Issues
- **Bug reports** — open an issue with Talos version, nvgpu version, and full UART log

---

## 13. References

- [Talos Linux v1.12 Documentation](https://www.talos.dev/v1.12/)
- [Talos System Extensions Guide](https://www.talos.dev/v1.12/talos-guides/configuration/system-extensions/)
- [Talos Boot Assets Guide](https://www.talos.dev/v1.12/talos-guides/install/boot-assets/)
- [siderolabs/pkgs](https://github.com/siderolabs/pkgs) — Talos kernel build system (commit `a92bed5`)
- [OE4T/linux-nvgpu](https://github.com/OE4T/linux-nvgpu) — nvgpu patches (commit `d530a48`)
- [OE4T/linux-nv-oot](https://github.com/OE4T/linux-nv-oot) — NVIDIA OOT framework (commit `ea32e7f`)
- [Seeed Studio reComputer J4012](https://www.seeedstudio.com/reComputer-J4012-p-5586.html) — hardware
- [ollama/ollama](https://hub.docker.com/r/ollama/ollama) — official Ollama image (recommended for Jetson)
- [dusty-nv/jetson-containers](https://github.com/dusty-nv/jetson-containers) — Jetson Docker images (last updated Jul 2025)
- [NVIDIA JetPack SDK](https://developer.nvidia.com/embedded/jetpack) — firmware / CUDA userspace

---

## 14. AI Disclaimer

Parts of this project were developed with the assistance of AI tools (primarily [Claude](https://claude.ai) by Anthropic), in particular:

- **Documentation** — README, inline script comments, and architecture descriptions
- **CI/CD pipeline** — GitHub Actions workflows and Renovate configuration
- **Debugging** — tracing build errors across the kernel/extension/signing-key chain

All generated output was reviewed, tested, and validated on real hardware. The technical decisions, implementation, and final responsibility remain with the author.
