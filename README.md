# Talos Linux on Jetson Orin NX — NVIDIA CUDA + GPU Compute

A complete guide to running [Talos Linux](https://www.talos.dev/) on the **NVIDIA Jetson Orin NX**
with full GPU compute (CUDA) support in Kubernetes pods. This covers everything from building
a custom kernel and NVIDIA kernel modules from source, packaging them as Talos system
extensions, generating bootable USB and UKI images, and operating the resulting single-node
cluster.

---

## Table of Contents

0. [Quick Start (Scripts)](#0-quick-start-scripts)
1. [Overview & Architecture](#1-overview--architecture)
2. [Why This Is Non-Trivial](#2-why-this-is-non-trivial)
3. [Repository Layout](#3-repository-layout)
4. [Prerequisites](#4-prerequisites)
5. [Component Versions](#5-component-versions)
6. [Build Pipeline](#6-build-pipeline)
   - [6.1 Local Registry Setup](#61-local-registry-setup)
   - [6.2 Custom Kernel Build](#62-custom-kernel-build)
   - [6.3 nvidia-tegra-nvgpu Extension](#63-nvidia-tegra-nvgpu-extension)
   - [6.4 kernel-modules-clang Extension](#64-kernel-modules-clang-extension)
   - [6.5 nvidia-firmware-ext Extension](#65-nvidia-firmware-ext-extension)
   - [6.6 Custom Installer Image](#66-custom-installer-image)
   - [6.7 UKI Image (Unified Kernel Image)](#67-uki-image-unified-kernel-image)
   - [6.8 USB Boot Image](#68-usb-boot-image)
7. [Cluster Setup](#7-cluster-setup)
   - [7.1 First Boot from USB (Maintenance Mode)](#71-first-boot-from-usb-maintenance-mode)
   - [7.2 Apply Machine Config](#72-apply-machine-config)
   - [7.3 Bootstrap etcd](#73-bootstrap-etcd)
   - [7.4 Retrieve Credentials](#74-retrieve-credentials)
   - [7.5 Fix NVMe Boot (Copy USB UKI to NVMe EFI Partition)](#75-fix-nvme-boot-copy-usb-uki-to-nvme-efi-partition)
8. [Machine Configuration Reference](#8-machine-configuration-reference)
9. [Flashing the USB Drive (macOS)](#9-flashing-the-usb-drive-macos)
10. [Verifying GPU / CUDA](#10-verifying-gpu--cuda)
11. [Root-Cause Analysis: Key Bugs Fixed](#11-root-cause-analysis-key-bugs-fixed)
    - [11.1 Firmware ELOOP Error](#111-firmware-eloop-error)
    - [11.2 Kernel Module Signing](#112-kernel-module-signing)
    - [11.3 Clang Toolchain Consistency](#113-clang-toolchain-consistency)
    - [11.4 Kernel 6.18 API Changes](#114-kernel-618-api-changes)
    - [11.5 Undefined Symbols (L4T-specific)](#115-undefined-symbols-l4t-specific)
12. [Running Ollama with GPU Acceleration](#12-running-ollama-with-gpu-acceleration)
13. [Cluster Recovery](#13-cluster-recovery)
14. [Known Limitations](#14-known-limitations)
15. [Reference: All Image Tags](#15-reference-all-image-tags)

---

## 0. Quick Start (Scripts)

All build and deploy steps are scripted in `scripts/`. Environment variables override
all defaults (registry, versions, node IP). Scripts are idempotent and CI-compatible.

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `REGISTRY` | `10.0.10.24:5001` | Local OCI registry (reachable from Jetson) |
| `REGISTRY_DOCKER` | `host.docker.internal:5001` | Registry as seen from inside Docker |
| `TALOS_VERSION` | `v1.12.6` | Talos release |
| `KERNEL_VERSION` | `6.18.18` | Kernel version (must match extensions) |
| `NVGPU_VERSION` | `4.0.0` | nvgpu extension version to use |
| `FIRMWARE_EXT_TAG` | `v4` | nvidia-firmware-ext tag |
| `NODE_IP` | `10.0.10.38` | Jetson node IP |
| `NODE_HOSTNAME` | `talos-smq-3hh` | Kubernetes node name |

### Fresh Cluster Install (from scratch)

```bash
# 1. Build UKI with all extensions baked in (~3-5 min)
./scripts/01-build-uki.sh

# 2. Build bootable USB image and flash to USB drive
./scripts/02-build-usb-image.sh
sudo dd if=dist/talos-usb-nvgpu4.0.0.raw of=/dev/rdiskN bs=4m && sync

# 3. Boot Jetson from USB, wipe NVMe STATE, enter maintenance mode
#    Then apply machine config (installs Talos to NVMe):
./scripts/03-apply-config.sh --insecure

# 4. Fix NVMe boot (copy full 149MB UKI to NVMe EFI partition)
./scripts/04-fix-nvme-boot.sh

# 5. Bootstrap etcd and save credentials (run ONCE per fresh install)
./scripts/05-bootstrap-cluster.sh

# 6. Install JetPack r36.5 userspace libs for Ollama GPU support
./scripts/07-install-l4t-libs.sh

# 7. Deploy Ollama and pull model
./scripts/06-deploy-ollama.sh
```

### Day-2 Operations

```bash
# Update machine config on running node:
./scripts/03-apply-config.sh

# After any upgrade/reinstall — re-fix NVMe boot:
./scripts/04-fix-nvme-boot.sh

# Re-install JetPack libs (lost after full wipe):
./scripts/07-install-l4t-libs.sh

# Test a different nvgpu extension version (for GPU debugging):
NVGPU_VERSION=3.0.0 FIRMWARE_EXT_TAG=v3 ./scripts/08-test-nvgpu.sh
```

### CI Pipeline Example

```yaml
# .gitlab-ci.yml / GitHub Actions equivalent
build-uki:
  script:
    - NVGPU_VERSION=4.0.0 FIRMWARE_EXT_TAG=v4 ./scripts/01-build-uki.sh
  artifacts:
    paths:
      - dist/uki-nvgpu4.0.0/metal-arm64-uki.efi

build-usb:
  needs: [build-uki]
  script:
    - ./scripts/02-build-usb-image.sh
  artifacts:
    paths:
      - dist/talos-usb-nvgpu4.0.0.raw
```

---

## 1. Overview & Architecture

Talos Linux is an immutable, minimal OS designed exclusively for Kubernetes. There is no shell,
no SSH, no package manager — everything runs in containers, and kernel modules can only be
delivered via **System Extensions** (squashfs overlay images).

The Jetson Orin NX requires three things that the official Talos distribution does not provide:

| Requirement | Solution |
|---|---|
| `nvgpu.ko` kernel module (NVIDIA GPU driver) | Custom-built OE4T patches against kernel 6.18.18 |
| NVIDIA GA10B firmware blobs | `nvidia-firmware-ext` extension with files at `/usr/lib/firmware/ga10b/` |
| Clang-compiled kernel modules (toolchain consistency) | `kernel-modules-clang` extension + custom Clang kernel |

### High-Level Build Flow

```
siderolabs/pkgs (commit a92bed5, branch release-1.12)
    │
    ├── kernel/build ──(Clang, MODULE_SIG off)──► vmlinuz (arm64, 6.18.18-talos)
    │                                               │
    └── nvidia-tegra-nvgpu ──(OE4T patches)──────► nvgpu.ko + host1x.ko
                                                    │
                                                    ▼
                              ┌─────────────────────────────────────┐
                              │          Local OCI Registry          │
                              │         (10.0.10.24:5001)           │
                              │                                     │
                              │  custom-installer:v1.12.6-6.18.18  │
                              │  nvidia-tegra-nvgpu:4.0.0-...      │
                              │  kernel-modules-clang:1.1.0-...    │
                              │  nvidia-firmware-ext:v4            │
                              └──────────────┬──────────────────────┘
                                             │
                                             ▼
                                   Talos Imager v1.12.6
                                             │
                              ┌──────────────┴──────────────┐
                              │                             │
                              ▼                             ▼
                      metal-arm64-uki.efi           USB boot image
                      (149 MB UKI, .zst)          (raw disk, .zst)
                              │
                              ▼
                    Flash to NVMe via USB boot
                    ────────────────────────►
                    Jetson Orin NX @ 10.0.10.38
                    Kubernetes single-node cluster
                    CUDA: cuInit=0 ✓
```

---

## 2. Why This Is Non-Trivial

### 2.1 Talos Enforces Kernel Module Signing

The official Talos kernel has `CONFIG_MODULE_SIG_FORCE=y`. Every `.ko` file must be signed
with the private key generated during that specific kernel build. Siderolabs never publishes
this key. **Solution**: Build a custom kernel with `CONFIG_MODULE_SIG` completely disabled.
The Vermagic string (kernel version + SMP/preempt flags) still must match exactly.

### 2.2 Kernel Version Must Match Exactly

Talos v1.12.6 was built from pkgs commit `a92bed5` (branch `release-1.12`):
- Kernel: **`6.18.18-talos`**
- Toolchain: `TOOLS_REV: v1.12.0-7-g57916cb`

The current `main` branch already has `6.18.19`. Using the wrong commit produces a module
with a mismatched Vermagic string and it will refuse to load.

### 2.3 OE4T Patches for L4T OOT Modules

NVIDIA's `nvgpu` driver is an **Out-of-Tree (OOT)** module written for L4T (Linux for Tegra)
— NVIDIA's Ubuntu-based Jetson OS. It requires many L4T-specific kernel APIs that do not
exist in upstream Linux.

The **OE4T project** (Open Embedded for Tegra) maintains patches to make these modules
compile against a standard upstream kernel:

| Source | Commit | Purpose |
|---|---|---|
| `OE4T/linux-nvgpu` | `d530a48` | patches-r36.5 — the GPU driver itself |
| `OE4T/linux-nv-oot` | `ea32e7f` | NVIDIA OOT framework (host1x, conftest) |
| `OE4T/linux-hwpm` | `4d8a699` | Hardware Performance Monitor (optional) |

### 2.4 GCC vs. Clang — Toolchain Consistency

The Talos build system uses GCC for the kernel by default. A GCC-compiled kernel embeds
GCC-specific flags in its build config (e.g., `-fmin-function-alignment=8`,
`-fconserve-stack`, `-fsanitize=bounds-strict`). When building an external OOT module with
**Clang**, these GCC flags are passed to Clang which promptly aborts.

**Solution**: Build both the kernel **and** all modules with Clang (`LLVM=1 LLVM_IAS=1`),
and run `make olddefconfig LLVM=1` so that Clang's capabilities are detected and
GCC-specific `CC_HAS_*` options are correctly disabled.

### 2.5 Clang 18+ Warnings as Errors

The OE4T nvgpu code triggers several Clang 18+ warnings that are treated as errors:

| File | Problem | Fix |
|---|---|---|
| `clk_prog.c` | `-Wimplicit-fallthrough` | `-Wno-implicit-fallthrough` in ccflags |
| `clk_vf_point.c` | `-Wparentheses-equality` | `-Wno-parentheses-equality` in ccflags |
| `ioctl.c:496ff` | Incompatible `devnode` function pointer | `-Wno-incompatible-function-pointer-types` |
| `scale.c` | `-Wsometimes-uninitialized` | `-Wno-sometimes-uninitialized` |

### 2.6 Kernel 6.18 API Changes

| API | Change | Fix |
|---|---|---|
| `vm_flags` | Since 6.3: `const vm_flags_t` — direct writes forbidden | Set `NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS` → `#if 1` everywhere |
| `class_create()` | Since 6.4: no `THIS_MODULE` parameter | `class_create(THIS_MODULE, name)` → `class_create(name)` |

### 2.7 Firmware ELOOP (-40) via Overlayfs + Symlink

**All** firmware loads failed on the first working builds despite the firmware files being
correctly present. Root cause:

- The kernel firmware loader uses the path `/lib/firmware/ga10b/...`
- In Talos, `/lib` is a symlink → `usr/lib`
- `usr/lib/firmware` is a bind-mount from the squashfs rootfs (overlayfs)
- The kernel's `filp_open()` encounters the symlink **inside** the overlayfs bind-mount,
  triggering `ELOOP (-40)` — "too many levels of symbolic links"

**Fix**: Add `firmware_class.path=/usr/lib/firmware` to the kernel command line. The
firmware subsystem then uses the absolute path `/usr/lib/firmware/ga10b/...` directly,
completely bypassing the `/lib` symlink.

---

## 3. Repository Layout

```
jetson-test/                         ← git repository root
├── .gitignore                       ← excludes credentials, *.efi, *.raw, dist/
├── README.md                        ← this file
├── controlplane.yaml                ← Talos machine config (apply to node)
├── ollama-deployment.yaml           ← Ollama Kubernetes Deployment + Service
│
├── talosconfig                      ← !! gitignored — talosctl PKI credentials
├── kubeconfig                       ← !! gitignored — kubectl PKI credentials
│
├── imager-profiles/                 ← Parameterized imager profiles (committed)
│   ├── uki-nvgpu4.yaml              ← Stable UKI (nvgpu 4.0.0, firmware v4)
│   └── uki-nvgpu3.yaml              ← Test UKI (nvgpu 3.0.0, firmware v3)
│
├── scripts/                         ← Reproducible build + deploy scripts (committed)
│   ├── common.sh                    ← Shared env vars (REGISTRY, versions, etc.)
│   ├── 01-build-uki.sh              ← Build UKI via imager (parameterizable)
│   ├── 02-build-usb-image.sh        ← Build bootable USB raw disk image
│   ├── 03-apply-config.sh           ← Apply Talos machine config (fresh or update)
│   ├── 04-fix-nvme-boot.sh          ← Copy working UKI to NVMe EFI partition
│   ├── 05-bootstrap-cluster.sh      ← Bootstrap etcd + retrieve credentials
│   ├── 06-deploy-ollama.sh          ← Deploy Ollama + pull model
│   ├── 07-install-l4t-libs.sh       ← Download JetPack r36.5 libs via K8s Job
│   └── 08-test-nvgpu.sh             ← Build + deploy UKI with different nvgpu version
│
├── logs/                            ← UART debug logs from boot sessions (committed)
│   └── uart-run-1..5.log
│
└── dist/                            ← !! gitignored — build outputs
    └── uki-nvgpu4.0.0/
        └── metal-arm64-uki.efi      ← 149 MB UKI (built by 01-build-uki.sh)
```

> **Credentials**: `talosconfig` and `kubeconfig` contain TLS private keys and are
> git-ignored. Keep a secure backup (e.g. encrypted password manager or `~/talos-jetson/`).
> After any cluster operation that produces new credentials, save both files immediately.

---

## 4. Prerequisites

### Build Host

- **macOS** with [Colima](https://github.com/abiosoft/colima) — arm64 VM, ≥ 80 GB disk
- Docker with BuildKit, a `talos-builder` buildx instance backed by Colima
- Local OCI registry on port 5001 (accessible as `host.docker.internal:5001` from Docker,
  as `10.0.10.24:5001` from the Jetson)
- `talosctl` v1.12.x (`brew install siderolabsio/tap/talosctl`)

### Colima Setup

```bash
colima start --arch aarch64 --cpu 8 --memory 16 --disk 100 --vm-type=vz \
  --mount-type=virtiofs --vz-rosetta

docker buildx create --name talos-builder --driver docker-container --use
```

> **BuildKit Cache Warning**: The kernel build generates ~15 GB of intermediate objects.
> If the Colima VM has less than ~40 GB free, the final link step fails with
> "No space left on device". Always clear the cache before a full rebuild:
> ```bash
> docker buildx prune --builder talos-builder --force
> ```

### Local Registry Setup

```bash
docker run -d --name registry --restart=always -p 5001:5000 registry:2

# Verify accessible from both Mac and Jetson
curl http://10.0.10.24:5001/v2/_catalog
```

---

## 5. Component Versions

| Component | Version | Notes |
|---|---|---|
| Talos Linux | **v1.12.6** | Running on Jetson |
| Kubernetes | **v1.35.1** | Single control-plane node |
| Kernel | **6.18.18-talos** | Custom Clang build, module signing disabled |
| Talos pkgs commit | **`a92bed5`** | Branch `release-1.12` — must be exact |
| OE4T linux-nvgpu | `d530a48` | patches-r36.5 |
| OE4T linux-nv-oot | `ea32e7f` | NVIDIA OOT framework |
| LLVM/Clang image | `ghcr.io/siderolabs/llvm:v1.14.0-alpha.0` | |
| `nvidia-tegra-nvgpu` | **4.0.0-6.18.18-talos** | Current extension |
| `kernel-modules-clang` | **1.1.0-6.18.18-talos** | Current extension |
| `nvidia-firmware-ext` | **v4** | Firmware at `/usr/lib/firmware/ga10b/` |
| `custom-installer` | **v1.12.6-6.18.18** | Official installer + custom vmlinuz |
| UKI build | **v8** (imager-out-v8/) | 149 MB — definitive |

---

## 6. Build Pipeline

### 6.1 Local Registry Setup

All custom images are stored in the local OCI registry. The Colima Docker daemon accesses
it as `host.docker.internal:5001`; the Jetson accesses it as `10.0.10.24:5001`.

```bash
docker run -d --name registry --restart=always -p 5001:5000 registry:2
```

### 6.2 Custom Kernel Build

The kernel must be built from the **exact** pkgs commit that produced Talos v1.12.6.
Any other commit yields a different `6.18.18-talos` Vermagic string and modules will
be rejected at load time.

```bash
git clone https://github.com/siderolabs/pkgs /tmp/talos-pkgs
cd /tmp/talos-pkgs
git checkout a92bed5

# Apply four modifications (see below), then build:
docker buildx build \
  --builder talos-builder \
  --file Pkgfile \
  --target kernel \
  --platform linux/arm64 \
  --progress plain \
  --output type=local,dest=/tmp/kernel-output \
  .
# Duration: ~40-50 min (cold cache)
```

**Required modifications to `siderolabs/pkgs`**:

| File | Change |
|---|---|
| `Pkgfile` | Add `LLVM_IMAGE: ghcr.io/siderolabs/llvm` and `LLVM_REV: v1.14.0-alpha.0`; update all LLVM references |
| `kernel/build/pkg.yaml` | Use `LLVM=1 LLVM_IAS=1` in all make invocations; run `make olddefconfig LLVM=1` |
| `kernel/build/config-arm64` | Disable module signing (4 lines — see below) |
| `kernel/build/scripts/filter-hardened-check.py` | Add Clang-specific exceptions for `CC_HAS_*` checks |

**`config-arm64` changes** (disable module signing):
```
# CONFIG_MODULE_SIG_ALL is not set
# CONFIG_MODULE_SIG_FORCE is not set
# CONFIG_MODULE_SIG is not set
# CONFIG_MODULE_SIG_KEY is not set
```

### 6.3 nvidia-tegra-nvgpu Extension

Contains: `nvgpu.ko`, `host1x.ko`, and supporting modules for the Jetson Orin NX GPU.

#### Build from pkgs

```bash
docker buildx build \
  --builder talos-builder \
  --file Pkgfile \
  --target nvidia-tegra-nvgpu \
  --platform linux/arm64 \
  --progress plain \
  --output type=local,dest=/tmp/nvgpu-output \
  .
```

#### Package as OCI Extension Image

```bash
mkdir -p /tmp/nvgpu-ext

cat > /tmp/nvgpu-ext/manifest.yaml << 'EOF'
version: v1alpha1
metadata:
  name: nvidia-tegra-nvgpu
  version: 4.0.0-6.18.18-talos
  author: custom-build
  description: NVIDIA nvgpu GPU driver for Jetson Orin NX (OE4T patches-r36.5, Clang build)
  compatibility:
    talos:
      version: ">= 1.12.6"
EOF

cat > /tmp/nvgpu-ext/Dockerfile << 'EOF'
FROM scratch
COPY manifest.yaml /manifest.yaml
COPY rootfs /rootfs
EOF

cp -r /tmp/nvgpu-output/rootfs /tmp/nvgpu-ext/rootfs

docker buildx build --platform linux/arm64 \
  -t host.docker.internal:5001/nvidia-tegra-nvgpu:4.0.0-6.18.18-talos \
  --push /tmp/nvgpu-ext/
```

### 6.4 kernel-modules-clang Extension

Because the custom kernel was compiled with Clang, the standard Talos kernel module tree
(GCC-compiled) is incompatible. This extension delivers Clang-compiled kernel modules.

```bash
mkdir -p /tmp/kmod-ext/rootfs/usr/lib
cp -r /tmp/kernel-output/lib/modules /tmp/kmod-ext/rootfs/usr/lib/modules

cat > /tmp/kmod-ext/manifest.yaml << 'EOF'
version: v1alpha1
metadata:
  name: kernel-modules-clang
  version: 1.1.0-6.18.18-talos
  author: custom-build
  description: Kernel modules compiled with Clang for kernel 6.18.18-talos
  compatibility:
    talos:
      version: ">= 1.12.6"
EOF

cat > /tmp/kmod-ext/Dockerfile << 'EOF'
FROM scratch
COPY manifest.yaml /manifest.yaml
COPY rootfs /rootfs
EOF

docker buildx build --platform linux/arm64 \
  -t host.docker.internal:5001/kernel-modules-clang:1.1.0-6.18.18-talos \
  --push /tmp/kmod-ext/
```

### 6.5 nvidia-firmware-ext Extension

The GA10B GPU requires firmware blobs to be present at `/usr/lib/firmware/ga10b/` when
`nvgpu.ko` loads. This extension delivers the firmware from JetPack r36.5.

> **Critical path**: Files must be at `/usr/lib/firmware/ga10b/` (v4 fix).
> Earlier versions used `/usr/lib/firmware/nvidia/ga10b/` which caused ELOOP failures.
> See [Section 11.1](#111-firmware-eloop-error) for the full root-cause analysis.

```bash
mkdir -p /tmp/nvidia-firmware-v4

# Copy firmware blobs from JetPack r36.5 L4T tarball:
#   /lib/firmware/ga10b/   → /rootfs/usr/lib/firmware/ga10b/
#   /lib/firmware/tegra23x/ → /rootfs/usr/lib/firmware/tegra23x/
#   /lib/firmware/nvidia/ga10b/ → /rootfs/usr/lib/firmware/nvidia/ga10b/ (legacy compat)

cat > /tmp/nvidia-firmware-v4/manifest.yaml << 'EOF'
version: v1alpha1
metadata:
  name: nvidia-firmware-ext
  version: 1.0.0-r36.5
  author: talos-jetson-build
  description: NVIDIA Jetson Orin firmware files (GA10B GPU, tegra23x) from JetPack r36.5
  compatibility:
    talos:
      version: ">= 1.12.6"
EOF

cat > /tmp/nvidia-firmware-v4/Dockerfile << 'EOF'
FROM scratch
COPY rootfs /rootfs
COPY manifest.yaml /manifest.yaml
EOF

docker buildx build --platform linux/arm64 \
  -t host.docker.internal:5001/nvidia-firmware-ext:v4 \
  --push /tmp/nvidia-firmware-v4/
```

### 6.6 Custom Installer Image

The official Talos installer contains a GCC-built kernel. Replace its `vmlinuz` with the
Clang-built kernel so the installed system uses our kernel from the beginning.

```bash
mkdir -p /tmp/custom-installer

# Copy Clang-built vmlinuz from kernel build output
cp /tmp/kernel-output/boot/vmlinuz /tmp/custom-installer/vmlinuz

cat > /tmp/custom-installer/Dockerfile << 'EOF'
FROM ghcr.io/siderolabs/installer:v1.12.6
COPY vmlinuz /usr/install/arm64/vmlinuz
EOF

docker buildx build --platform linux/arm64 \
  -t host.docker.internal:5001/custom-installer:v1.12.6-6.18.18 \
  --push /tmp/custom-installer/
```

### 6.7 UKI Image (Unified Kernel Image)

The UKI is a single PE/EFI binary containing the kernel, initramfs, all system extensions,
and the kernel command line embedded at build time. It boots directly from UEFI.
The **v8 UKI** (149 MB, `imager-out-v8/`) is the definitive artifact with all fixes applied.

**Imager profile** (`/tmp/talos-metal-out/imager-profile-uki.yaml`):

```yaml
arch: arm64
platform: metal
secureboot: false
version: v1.12.6
input:
  kernel:
    path: /usr/install/arm64/vmlinuz
  initramfs:
    path: /usr/install/arm64/initramfs.xz
  sdStub:
    path: /usr/install/arm64/systemd-stub.efi
  sdBoot:
    path: /usr/install/arm64/systemd-boot.efi
  baseInstaller:
    imageRef: host.docker.internal:5001/custom-installer:v1.12.6-6.18.18
    forceInsecure: true
  systemExtensions:
    - imageRef: host.docker.internal:5001/kernel-modules-clang:1.1.0-6.18.18-talos
      forceInsecure: true
    - imageRef: host.docker.internal:5001/nvidia-tegra-nvgpu:4.0.0-6.18.18-talos
      forceInsecure: true
    - imageRef: host.docker.internal:5001/nvidia-firmware-ext:v4
      forceInsecure: true
customization:
  extraKernelArgs:
    - console=ttyTCU0,115200              # Jetson Orin NX serial console (TCU UART)
    - firmware_class.path=/usr/lib/firmware  # ELOOP fix — bypass /lib symlink
output:
  kind: uki
  outFormat: .zst
```

**Build command**:

```bash
mkdir -p ~/PycharmProjects/jetson-test/imager-out-v8

cat /tmp/talos-metal-out/imager-profile-uki.yaml | \
docker run --rm -i \
  --platform linux/arm64 \
  --add-host host.docker.internal:host-gateway \
  -v ~/PycharmProjects/jetson-test/imager-out-v8:/out \
  ghcr.io/siderolabs/imager:v1.12.6 \
  -
```

> **Note**: The imager must receive the profile via stdin (`-`), not as a file path argument.
> `docker run ... imager /path/to/profile.yaml` silently produces a wrong output.

Output: `imager-out-v8/metal-arm64-uki.efi` (149 MB) and `metal-arm64-uki.efi.zst`.

### 6.8 USB Boot Image

A bootable USB disk image with systemd-boot and multiple copies of the UKI placed under
different EFI paths for maximum UEFI firmware compatibility.

The USB image was built as a Kubernetes Job on the Jetson, which:
1. Creates a 4 GB raw disk (GPT + FAT32 EFI partition)
2. Installs systemd-boot to `EFI/BOOT/BOOTAA64.EFI`
3. Copies the v8 UKI under five names (`talos-v8.efi`, `Talos-v1.12.6.efi`, etc.)
4. Writes `loader.conf` (default: `talos-v8.efi`, timeout: 5s)
5. Compresses the result with `xz -T0 -9`

Output: `talos-usb-v3.raw.xz` (~740 MB compressed).

---

## 7. Cluster Setup

### 7.1 First Boot from USB (Maintenance Mode)

When Talos boots from the USB image, it looks for its STATE partition (GPT label
`STATE`) on **any attached disk** — not just the boot device. If no Talos STATE is
found on any disk, it enters **maintenance mode** — a minimal API on port 50000 that
accepts `apply-config` without authentication.

> **Critical**: Talos scans ALL disks for the STATE partition, not just the boot disk.
> Booting from USB does NOT guarantee maintenance mode if the NVMe still has a valid
> STATE partition. You must wipe the NVMe STATE first (see below).

1. Insert the USB drive into the Jetson
2. Power on and select the USB as boot device (UEFI boot menu or boot override)
3. Wait ~30 seconds for the system to initialize and get an IP
4. Verify maintenance mode from the Mac:

```bash
talosctl --endpoints 10.0.10.38 --nodes 10.0.10.38 --insecure version
```

**Success** — maintenance mode:
```
Server:
error getting version: rpc error: code = Unimplemented desc = API is not implemented in maintenance mode
```
(The `Unimplemented` error IS the confirmation — maintenance mode doesn't expose the version API.)

**Failure** — old STATE still present:
```
Server:
error getting version: rpc error: code = Unavailable desc = ... tls: certificate required
```
→ The NVMe has an old STATE partition. See [Section 13](#13-cluster-recovery).

### 7.2 Apply Machine Config

```bash
talosctl --nodes 10.0.10.38 --endpoints 10.0.10.38 --insecure \
  apply-config --file ~/PycharmProjects/jetson-test/controlplane.yaml
```

Talos will now:
1. Pull `custom-installer:v1.12.6-6.18.18` from `10.0.10.24:5001`
2. Pull the three extension images
3. Wipe `/dev/nvme0n1` (because `wipe: true` in config)
4. Install Talos + extensions to NVMe
5. Reboot automatically (~3-5 minutes total)

### 7.3 Bootstrap etcd

After the reboot, wait for the node API to come back up, then bootstrap etcd **exactly
once** per fresh cluster install:

```bash
# Poll until API is available
until talosctl --talosconfig ~/PycharmProjects/jetson-test/talosconfig \
  --endpoints 10.0.10.38 --nodes 10.0.10.38 version &>/dev/null; do
  echo "waiting..."; sleep 10
done

talosctl --talosconfig ~/PycharmProjects/jetson-test/talosconfig \
  --nodes 10.0.10.38 --endpoints 10.0.10.38 \
  bootstrap
```

> **Warning**: Only run `bootstrap` when etcd is empty (fresh install with EPHEMERAL
> wiped). If you get `AlreadyExists desc = etcd data directory is not empty`, etcd was
> already bootstrapped — skip this step and proceed to Step 7.4.
> Running bootstrap on an existing cluster corrupts it.

### 7.4 Retrieve Credentials

```bash
# Kubeconfig for kubectl
talosctl --talosconfig ~/PycharmProjects/jetson-test/talosconfig \
  --nodes 10.0.10.38 --endpoints 10.0.10.38 \
  kubeconfig ~/PycharmProjects/jetson-test/kubeconfig

# Also keep a copy in talos-jetson/
cp ~/PycharmProjects/jetson-test/kubeconfig ~/talos-jetson/kubeconfig

# Verify
KUBECONFIG=~/PycharmProjects/jetson-test/kubeconfig kubectl get nodes
```

Expected:
```
NAME              STATUS   ROLES           AGE   VERSION
talos-<hash>      Ready    control-plane   2m    v1.35.1
```

> **Always save both `talosconfig` and `kubeconfig` to `jetson-test/`** after any
> operation that produces new credentials. This prevents the cert-mismatch situation
> described in Section 13.

### 7.5 Fix NVMe Boot (Copy USB UKI to NVMe EFI Partition)

**Problem**: After `apply-config` or `talosctl upgrade`, Talos writes an 18.8 MB UKI
(without system extensions) to the NVMe EFI partition. On boot, the Jetson kernel
fails to initialize hardware because the required kernel modules are missing → UEFI
falls through to the next boot option (USB).

**Root cause**: `custom-installer:v1.12.6-6.18.18` doesn't have extensions baked in.
The deprecated `install.extensions` writes extensions as runtime overlays but NOT into
the UKI EFI binary. The NVMe UKI at `/EFI/Linux/` is therefore extension-free.

**Fix**: Copy the working 149 MB USB UKI (`talos-v8.efi`) directly to the NVMe EFI
partition. This must be done after every full reinstall or upgrade.

```bash
# Step 1: create privileged pod (namespace must be privileged)
kubectl label namespace default pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest --overwrite

kubectl run efi-fix --image=busybox:latest --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"talos-smq-3hh"},"tolerations":[{"operator":"Exists"}],"containers":[{"name":"efi-fix","image":"busybox:latest","command":["sh","-c","sleep 180"],"securityContext":{"privileged":true},"volumeMounts":[{"name":"dev","mountPath":"/dev"}]}],"volumes":[{"name":"dev","hostPath":{"path":"/dev"}}]}}' \
  -n default

# Step 2: wait for pod to start
kubectl wait --for=condition=ready pod/efi-fix -n default --timeout=30s

# Step 3: mount both partitions and copy UKI
kubectl exec -n default efi-fix -- sh -c "
  mkdir -p /mnt/efi /mnt/usb
  mount -t vfat /dev/nvme0n1p1 /mnt/efi   # NVMe EFI (label: EFI)
  mount -t vfat /dev/sda1      /mnt/usb   # USB EFI  (label: TALOS_EFI)

  # Copy 149 MB UKI (with all extensions) from USB to NVMe
  cp /mnt/usb/EFI/Linux/talos-v8.efi /mnt/efi/EFI/Linux/talos-v8.efi

  # Set as default boot entry
  cat > /mnt/efi/loader/loader.conf << 'EOF'
default talos-v8.efi
timeout 5
console-mode auto
EOF
  sync
  echo 'Done. NVMe will now boot from talos-v8.efi (149 MB, with extensions).'
"

kubectl delete pod efi-fix -n default
```

> **After this fix**: the Jetson can cold-boot directly from NVMe without USB.
> The USB drive may be removed. The USB is still needed if NVMe STATE needs to be wiped.

> **Why `talos-v8.efi`?** It is the v8 UKI built via the imager with all three extensions
> (kernel-modules-clang, nvidia-tegra-nvgpu:4.0.0, nvidia-firmware-ext:v4) baked in.
> Long-term fix: use `output.kind: installer` in the imager profile to create an
> installer image with extensions baked in; then `talosctl upgrade` will write the
> correct UKI automatically.

---

## 8. Machine Configuration Reference

**File**: `~/PycharmProjects/jetson-test/controlplane.yaml`

Key sections explained:

```yaml
machine:
  install:
    disk: /dev/nvme0n1             # Install target — NVMe (NOT the USB drive /dev/sda)
    image: 10.0.10.24:5001/custom-installer:v1.12.6-6.18.18
    wipe: true                     # Wipe NVMe on install (ensures clean state)
    # !! DO NOT set grubUseUKICmdline: true on arm64/Jetson !!
    # That flag is for legacy x86 GRUB only. On arm64 with UKI+systemd-boot, it causes
    # the installer to skip writing the UKI boot entry to the EFI partition.
    # Result: systemd-boot shows ONLY "Reboot Into Firmware Interface" → boot loop.
    # firmware_class.path=/usr/lib/firmware is already embedded in the UKI inside
    # the custom-installer image (set via imager profile cmdline.append).
    extensions:
      # Clang-compiled kernel modules (replaces GCC-compiled defaults)
      - image: 10.0.10.24:5001/kernel-modules-clang:1.1.0-6.18.18-talos
      # NVIDIA GPU driver (nvgpu.ko, host1x.ko)
      - image: 10.0.10.24:5001/nvidia-tegra-nvgpu:4.0.0-6.18.18-talos
      # GA10B firmware blobs at /usr/lib/firmware/ga10b/
      - image: 10.0.10.24:5001/nvidia-firmware-ext:v4

  registries:
    mirrors:
      10.0.10.24:5001:
        endpoints:
          - "http://10.0.10.24:5001"  # Plain HTTP — must use mirrors, NOT config.tls!
    # !! DO NOT add config.tls.insecureSkipVerify for an HTTP registry !!
    # insecureSkipVerify=true still tries HTTPS → "server gave HTTP response to HTTPS client"
    # Using both mirrors+config.tls → "TLS config specified for non-HTTPS registry"

cluster:
  endpoint: https://10.0.10.38:6443
```

> **`grubUseUKICmdline: true`** explanation: When applying config while booted from the
> USB UKI (which has `firmware_class.path=/usr/lib/firmware` and `console=ttyTCU0,115200`
> in its embedded cmdline), this flag copies those args to the installed NVMe system.
> Without it you would need to also add `extraKernelArgs` — but those conflict with
> `grubUseUKICmdline`, so this is the correct approach.

---

## 9. Flashing the USB Drive (macOS)

### Current USB Image

**Location**: `/tmp/talos-usb-v3/talos-usb-v3.raw` (4.0 GB raw) or
`/tmp/talos-usb-v3/talos-usb-v3.raw.xz` (740 MB compressed)

The image contains:
- **1 boot entry only**: `talos-v8.efi` (149 MB UKI with all NVIDIA extensions embedded)
- **systemd-boot**: 3-second timeout, auto-boots `talos-v8.efi`
- **Extensions**: kernel-modules-clang 1.1.0, nvidia-tegra-nvgpu 4.0.0, nvidia-firmware-ext v4
- **Kernel cmdline**: `firmware_class.path=/usr/lib/firmware console=ttyTCU0,115200`

### Flash Command

```bash
# 1. Identify the USB disk (compare before/after inserting)
diskutil list

# 2. Unmount
diskutil unmountDisk /dev/disk7   # adjust disk number!

# 3. Flash from the pre-decompressed raw image (fastest):
sudo dd if=/tmp/talos-usb-v3/talos-usb-v3.raw of=/dev/rdisk7 bs=4m status=progress && sync

# Or flash from compressed image:
xzcat /tmp/talos-usb-v3/talos-usb-v3.raw.xz | sudo dd of=/dev/rdisk7 bs=4m status=progress
```

> **Common pitfall**: `sudo dd if=<(xzcat file.xz) of=/dev/rdisk7` fails on macOS with
> **"dd: /dev/fd/13: Bad file descriptor"**. Process substitution creates a pipe (not a
> seekable file descriptor). Always use `xzcat file | sudo dd of=...` instead.

### Cleaning Up the Boot Menu (if too many entries appear)

If you ever end up with multiple boot entries (because previous UKI builds accumulated in
`/EFI/Linux/`), clean them up **without reflashing** using `mtools` on the raw image:

```bash
brew install mtools

# EFI partition offset = LBA 2048 × 512 bytes = 1048576
IMG=/tmp/talos-usb-v3/talos-usb-v3.raw   # or xzcat first
OFFSET=1048576

# List /EFI/Linux to see what's there
MTOOLS_SKIP_CHECK=1 mdir -i ${IMG}@@${OFFSET} ::/EFI/Linux/

# Delete unwanted UKI files (keep only talos-v8.efi)
MTOOLS_SKIP_CHECK=1 mdel -i ${IMG}@@${OFFSET} "::/EFI/Linux/Talos-v1.12.6.efi"

# Verify loader.conf (should be: default talos-v8.efi / timeout 3)
MTOOLS_SKIP_CHECK=1 mtype -i ${IMG}@@${OFFSET} ::/loader/loader.conf

# Update loader.conf if needed
printf 'default talos-v8.efi\ntimeout 3\nconsole-mode auto\n' > /tmp/loader.conf
MTOOLS_SKIP_CHECK=1 mcopy -i ${IMG}@@${OFFSET} -o /tmp/loader.conf ::/loader/loader.conf
```

Then reflash the modified raw image with `sudo dd`.

---

## 10. Verifying GPU / CUDA

### Check Kernel Module and Firmware Loading

```bash
TC=~/PycharmProjects/jetson-test/talosconfig

# nvgpu module is loaded
talosctl --talosconfig $TC --nodes 10.0.10.38 \
  read /proc/modules | grep nvgpu

# No ELOOP errors — firmware loaded successfully
talosctl --talosconfig $TC --nodes 10.0.10.38 \
  dmesg | grep -E "nvgpu|ga10b|firmware_class" | tail -30

# firmware_class.path is set to the correct value
talosctl --talosconfig $TC --nodes 10.0.10.38 \
  read /sys/module/firmware_class/parameters/path
# Expected output: /usr/lib/firmware
```

### CUDA Device Check

```bash
KC=~/PycharmProjects/jetson-test/kubeconfig

kubectl --kubeconfig $KC run cuda-check \
  --image=10.0.10.24:5001/cuda-device-check:v1 \
  --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "cuda-check",
        "image": "10.0.10.24:5001/cuda-device-check:v1",
        "securityContext": {"privileged": true},
        "volumeMounts": [{"name":"dev","mountPath":"/dev"}]
      }],
      "volumes": [{"name":"dev","hostPath":{"path":"/dev"}}]
    }
  }'

kubectl --kubeconfig $KC logs cuda-check
```

Expected output:
```
cuInit=0 name=CUDA_SUCCESS
Device count: 1
GPU 0: Orin
```

---

## 11. Root-Cause Analysis: Key Bugs Fixed

### 11.1 Firmware ELOOP Error

**Symptom**: `dmesg` shows nvgpu attempting to load firmware files and failing with
error code `-40` (`ELOOP`) even though the files physically exist in the filesystem.

**Root cause chain**:

```
nvgpu → request_firmware("ga10b/acr-gsp.data.encrypt.bin.prod")
       → firmware loader constructs path: /lib/firmware/ga10b/acr-gsp...
                                             │
                              /lib ──(symlink)──► usr/lib
                                                      │
                                      usr/lib/firmware ──(overlayfs bind-mount)──► squashfs
                                                                                         │
                                                        filp_open() inside bind-mount ──► ELOOP (-40)
```

The Linux kernel VFS follows the `/lib → usr/lib` symlink and then encounters an
overlayfs bind-mount boundary. Symlink resolution across this boundary increments the
kernel's internal link-follow counter past the ELOOP threshold.

**Fix**: Kernel command line parameter `firmware_class.path=/usr/lib/firmware`.
The firmware subsystem uses this path directly instead of constructing `/lib/firmware/...`,
completely avoiding the symlink and the ELOOP.

This parameter is embedded in the UKI at build time (see Section 6.7) and is propagated
to the NVMe installation via `grubUseUKICmdline: true` (see Section 8).

### 11.2 Kernel Module Signing

**Symptom**: `insmod nvgpu.ko` returns `Required key not available (-126)`.

**Root cause**: `CONFIG_MODULE_SIG_FORCE=y` in the official Talos kernel. The signing
key is ephemeral — created during the kernel build and destroyed afterward. Third-party
modules cannot be signed with it.

**Fix**: Custom kernel with module signing completely disabled:
```
# CONFIG_MODULE_SIG is not set
# CONFIG_MODULE_SIG_ALL is not set
# CONFIG_MODULE_SIG_FORCE is not set
```

The Vermagic string check (`6.18.18-talos SMP preempt mod_unload aarch64`) still applies
and the kernel version must match exactly.

### 11.3 Clang Toolchain Consistency

**Symptom**: OOT module build fails immediately:
```
clang: error: unknown argument: '-fmin-function-alignment=8'
clang: error: unknown argument: '-fconserve-stack'
clang: error: unknown argument: '-fsanitize=bounds-strict'
```

**Root cause**: The default Talos kernel build uses GCC. GCC-specific compiler flags are
stored in the kernel's `.config` and exported as `$(KBUILD_CFLAGS)` for OOT module builds.
When the OOT module is built with Clang, these GCC-only flags are passed to Clang, which
rejects them.

**Fix**:
1. Build the kernel with `LLVM=1 LLVM_IAS=1`
2. Run `make olddefconfig LLVM=1` before the kernel build — this lets Clang detect its
   own capabilities and disables all `CC_HAS_*` options that only exist in GCC

### 11.4 Kernel 6.18 API Changes

#### `vm_flags` Write Protection (since kernel 6.3)

The `vm_flags` field of `struct vm_area_struct` became `const` in kernel 6.3. All direct
writes via `vma->vm_flags |= ...` must be replaced with accessor functions.

The OE4T patches use a compatibility macro `NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS`. We set
this to `#if 1` unconditionally for kernel 6.18.

#### `class_create()` Signature Change (since kernel 6.4)

```c
// Before kernel 6.4:
struct class *cls = class_create(THIS_MODULE, "nvgpu");

// kernel 6.4 and later:
struct class *cls = class_create("nvgpu");
```

The `THIS_MODULE` parameter was removed. Patched in all affected source files.

### 11.5 Undefined Symbols (L4T-specific)

These symbols exist in L4T kernels but not in upstream Linux:

| Symbol | Where referenced | Runtime impact |
|---|---|---|
| `nvmap_dma_free_attrs` | DMA memory management | Not called during standard CUDA usage |
| `tegra_vpr_dev` | Video Protected Region | Not needed for compute |
| `host1x_fence_extract` | Sync framework | Partial workaround in host1x module |
| `emc_freq_to_bw` | EMC bus bandwidth | Not invoked for GPU compute |

**Build fix**: `KBUILD_MODPOST_WARN=1` — demotes undefined symbol errors to warnings,
allowing the module to build and load. Code paths that dereference these symbols would
produce a kernel oops at runtime, but standard CUDA compute workloads on Jetson Orin NX
with a standard device tree do not invoke them.

---

## 12. Running Ollama with GPU Acceleration

> **Status**: Ollama is deployed and running in **CPU-only mode** (`inference compute: cpu`,
> ~15 tok/s for 1.5B models). GPU acceleration is currently blocked by a kernel-level
> limitation — see "GPU Acceleration Status" below for the complete root-cause analysis.

### Step 1 — Download Real JetPack Userspace Libraries

The `dustynv/ollama` container carries **0-byte stub libraries** for the NVIDIA CUDA
userspace (see Issue 1 below). Before deploying Ollama, these stubs must be replaced with
real JetPack libraries downloaded from the NVIDIA APT repo and stored on the node.

**This must be re-run after every full cluster rebuild** (the libs live in EPHEMERAL at
`/var/lib/nvidia-tegra-libs/` which is wiped by `--wipe-mode all`).

```bash
KC=~/PycharmProjects/jetson-test/kubeconfig

# Create namespace first (needed for the job)
kubectl --kubeconfig $KC create namespace ollama 2>/dev/null || true
kubectl --kubeconfig $KC label namespace ollama \
  pod-security.kubernetes.io/enforce=privileged --overwrite

# Run the download job — pulls r36.5.0 packages from NVIDIA's public APT server
# and extracts them to /var/lib/nvidia-tegra-libs/tegra/ on the Talos node.
# Takes ~30 s (apt install + 3 package downloads).
kubectl --kubeconfig $KC apply -f - << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: install-l4t-r365-libs
  namespace: ollama
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      tolerations:
        - operator: Exists
      containers:
        - name: install-libs
          image: ubuntu:22.04
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -e
              apt-get update -qq && apt-get install -y -qq curl dpkg
              DEST=/nvidia-libs
              rm -rf $DEST/tegra && mkdir -p $DEST/tegra
              cd /tmp
              BASE="https://repo.download.nvidia.com/jetson/t234/pool/main/n"
              VER="36.5.0-20260115194252"
              curl -fsSL -o l4t-core.deb  "$BASE/nvidia-l4t-core/nvidia-l4t-core_${VER}_arm64.deb"
              curl -fsSL -o l4t-cuda.deb  "$BASE/nvidia-l4t-cuda/nvidia-l4t-cuda_${VER}_arm64.deb"
              curl -fsSL -o l4t-3d.deb    "$BASE/nvidia-l4t-3d-core/nvidia-l4t-3d-core_${VER}_arm64.deb"
              for pkg in l4t-core.deb l4t-cuda.deb l4t-3d.deb; do
                dpkg-deb -x $pkg /tmp/extract-$pkg/
                find /tmp/extract-$pkg -path '*/aarch64-linux-gnu/tegra/*' -type f \
                  -exec cp {} $DEST/tegra/ \;
                find /tmp/extract-$pkg -path '*/aarch64-linux-gnu/nvidia/*' -type f \
                  -exec cp {} $DEST/tegra/ \;
              done
              echo "Done. $(ls $DEST/tegra/ | wc -l) libs installed."
              ls -la $DEST/tegra/libnvrm_gpu.so $DEST/tegra/libcuda.so.1.1
          securityContext:
            privileged: true
          volumeMounts:
            - name: nvidia-libs
              mountPath: /nvidia-libs
      volumes:
        - name: nvidia-libs
          hostPath:
            path: /var/lib/nvidia-tegra-libs
            type: DirectoryOrCreate
      restartPolicy: Never
EOF

# Wait for completion
kubectl --kubeconfig $KC wait job/install-l4t-r365-libs -n ollama \
  --for=condition=complete --timeout=120s
kubectl --kubeconfig $KC logs -n ollama job/install-l4t-r365-libs | tail -5
```

Expected output: `57 libs installed. libnvrm_gpu.so 399880 bytes, libcuda.so.1.1 41872560 bytes`

### Step 2 — Deploy Ollama

Use the `ollama-deployment.yaml` from this repository. It includes:
- hostPath PV at `/var/lib/ollama-models` (80 Gi on EPHEMERAL/NVMe)
- `/dev` mounted for GPU device access
- The JetPack r36.5 libs from Step 1 mounted at `/usr/lib/aarch64-linux-gnu/nvidia/`
- `command: ["ollama", "serve"]` — **required**, see Bug 1 below

```bash
KC=~/PycharmProjects/jetson-test/kubeconfig
kubectl --kubeconfig $KC apply -f ~/PycharmProjects/jetson-test/ollama-deployment.yaml

# Verify pod reaches Running (not "Completed"!)
kubectl --kubeconfig $KC get pods -n ollama -w
```

### Step 3 — Pull a Model and Test

```bash
# Pull a model (qwen2.5:1.5b is small and fast for CPU inference)
curl http://10.0.10.38:31434/api/pull -d '{"name":"qwen2.5:1.5b"}'

# Test inference
curl http://10.0.10.38:31434/api/generate \
  -d '{"model":"qwen2.5:1.5b","prompt":"What is 2+2?","stream":false}' | jq .response

# List available models
curl http://10.0.10.38:31434/api/tags | jq '.models[].name'
```

**Confirmed CPU performance** (Jetson Orin NX, 12× ARM Cortex-A78AE, 16 GB LPDDR5):

| Model | Size | Tokens/s (CPU) | Notes |
|---|---|---|---|
| qwen2.5:1.5b | 940 MB | ~15 tok/s | Confirmed working |
| qwen2.5:7b | ~4.7 GB | ~3–5 tok/s | Estimated |

---

### GPU Acceleration Investigation (Blocked — Kernel Limitation)

A complete investigation was performed. Three separate issues were found and diagnosed:

#### Bug 1 — Ollama pod immediately exits ("Completed" state)

**Symptom**: Pod shows `STATUS=Completed` with restarts, never reaches `Running`.

**Root cause**: The `dustynv/ollama:r36.4.0` default entrypoint script starts
`ollama serve` **in the background** and then exits with code 0. Kubernetes sees exit 0
and marks the container "Completed", triggering restart loop.

**Fix**: Override the command in the deployment:
```yaml
command: ["ollama", "serve"]   # runs ollama serve in the foreground directly
```
Without this, the pod flip-flops between `ContainerCreating` → `Completed` → `Running`
indefinitely.

#### Bug 2 — dustynv container uses 0-byte stub libraries

**Symptom**: `cuInit` fails with `Unable to load cudart library: file too short`.

**Root cause**: The `dustynv/ollama:r36.4.0` image was designed for the **NVIDIA
Container Runtime** (`--runtime=nvidia`), which automatically injects real JetPack CUDA
libraries from the host into the container at startup. On Talos, there is no JetPack
userspace stack on the host and no NVIDIA Container Runtime. The container ships
0-byte stubs as placeholders:

```
/usr/lib/aarch64-linux-gnu/nvidia/libnvrm_gpu.so   →  0 bytes  (placeholder)
/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so.1.1   →  0 bytes  (placeholder)
/usr/lib/aarch64-linux-gnu/nvidia/libnvos.so        →  0 bytes  (placeholder)
... and ~50 more stubs
```

A real `libcuda.so.1.1` (41 MB) exists inside the container at
`/usr/local/cuda-12.6/compat/libcuda.so.1.1` but it chains to `libnvrm_gpu.so`,
which is the 0-byte stub.

**How normal JetPack/Docker does it**: On Ubuntu JetPack, `--runtime=nvidia` invokes
the NVIDIA Container Runtime which reads `/proc/driver/nvidia/...` and automatically
bind-mounts the host's real JetPack libs (from `/usr/lib/aarch64-linux-gnu/tegra/`)
over the container's stubs.

**Fix applied**: Download the real JetPack r36.5.0 libraries from NVIDIA's public APT
server and mount them via a hostPath volume over the stub directory. See Step 1 above for
the Job YAML.

Key packages needed (`t234` architecture, L4T 36.5.0):
- `nvidia-l4t-core` → provides `libnvrm_gpu.so`, `libnvos.so`, `libnvrm_mem.so`, etc.
- `nvidia-l4t-cuda` → provides the real `libcuda.so.1.1` (41 MB)
- `nvidia-l4t-3d-core` → provides `libnvidia-nvvm.so`, `libnvidia-ptxjitcompiler.so`, etc.

> **Why r36.5.0 and not r36.4.x?** The `nvidia-tegra-nvgpu:4.0.0-6.18.18-talos`
> extension metadata says `"OE4T wip-r36.5-take-2"`. The kernel module's RM API
> version must match the userspace. Using r36.4.1 userspace against the r36.5 kernel
> module also returns `cuInit=801`. Always match the userspace version to the kernel
> module's target JetPack version.

After the fix, all dependencies resolve correctly (verified via `ldd` inside the pod):
```
libnvrm_gpu.so   →  399 KB  ✓
libcuda.so.1.1   →  41 MB   ✓
libnvos.so       →  68 KB   ✓
libnvrm_mem.so   →  35 KB   ✓
... all real
```

#### Bug 3 — `cuInit` returns 801 even with real libraries

**Symptom**: After fixing the stubs, `cuInit` still returns `801 CUDA_ERROR_NOT_SUPPORTED`.

**Diagnosis**: `strace` on the CUDA init sequence reveals the exact failure:

```
openat("/dev/nvmap",       O_RDWR|O_SYNC|O_CLOEXEC) = 3       # SUCCESS
openat("/dev/nvhost-ctrl", O_RDWR|O_CLOEXEC)        = -1 ENOENT  # FATAL
→ cuInit returns 801 immediately
```

The CUDA driver opens `/dev/nvmap` successfully, then tries `/dev/nvhost-ctrl` and aborts
the moment it gets `ENOENT`. There are no further device open attempts.

**Root cause — missing `/dev/nvhost-ctrl`**: This device is the **generic host1x channel
controller**. On standard JetPack Ubuntu (kernel 5.15.148-tegra), the in-tree `host1x`
driver creates:
- `/dev/nvhost-ctrl` — generic channel manager (required by all CUDA init paths)
- `/dev/nvhost-vic`, `/dev/nvhost-nvenc`, `/dev/nvhost-nvdec`, … (engine channels)

The `nvidia-tegra-nvgpu:4.0.0-6.18.18-talos` extension uses an **OOT (out-of-tree)
`host1x` module** that only implements the syncpt/fence infrastructure needed internally
by the nvgpu kernel module. It registers only:

```
/proc/devices:
  508  host1x-fence    ← only the fence subsystem, no full UAPI
/sys/class:
  host1x-fence        ← no nvhost class
```

The full `nvhost` character device interface (which creates `/dev/nvhost-ctrl` and all
the engine channel devices) is NOT implemented in this OOT build.

**Devices available on Talos with this extension:**
```
/dev/nvhost-gpu          (nvgpu GPU engine — present)
/dev/nvhost-ctrl-gpu     (nvgpu GPU ctrl channel — present)
/dev/nvhost-as-gpu       (nvgpu address space — present)
/dev/nvmap               (nvmap unified memory — present)
/dev/nvhost-ctrl         (generic host1x ctrl — MISSING)
```

There is no userspace workaround. `/dev/nvhost-ctrl` cannot be created without a kernel
module that registers it.

#### Bug 4 — UBSAN array-out-of-bounds during GPU power-on (secondary issue)

**Symptom**: When CUDA's compat path (`/usr/local/cuda-12.6/compat/libcuda.so.1.1`) is
used instead (it bypasses the `/dev/nvhost-ctrl` check), the kernel logs show:

```
UBSAN: array-index-out-of-bounds in common/netlist/netlist.c:613:31
index 1 is out of range for type 'struct netlist_region[1]'
nvgpu: 17000000.gpu nvgpu_grmgr_get_gpu_instance_runlist_id:601
  [ERR] gpu_instance_id[0] >= num_gpu_instances[0]
```

Call stack: `gk20a_channel_open → __gk20a_channel_open → gk20a_busy →
gk20a_pm_runtime_resume → nvgpu_finalize_poweron → nvgpu_netlist_init_ctx_vars`

**Root cause**: The nvgpu module ("wip-r36.5-take-2") has an array bounds bug in the
netlist (GPU context variable) initialization. `num_gpu_instances = 0` means the GPU
Resource Manager was never populated with the GA10B compute instance configuration.
This is a kernel-level bug in the WIP module — it does not affect normal (non-CUDA)
operation but prevents any compute channel from being opened.

#### Summary Table

| Layer | Component | Status | Notes |
|---|---|---|---|
| Kernel module | nvgpu loaded | ✅ | syncpt init succeeds |
| Kernel module | `/dev/nvhost-gpu` device | ✅ | present, openable |
| Kernel module | `/dev/nvhost-ctrl` device | ❌ | NOT created by OOT host1x |
| Kernel module | GPU power-on / netlist init | ❌ | UBSAN bug in netlist.c |
| Firmware | GA10B firmware blobs | ✅ | loaded correctly |
| Userspace | JetPack r36.5 libs (real) | ✅ | installed via Job, mounted via hostPath |
| Userspace | `cuInit(0)` | ❌ | fails with 801 (nvhost-ctrl missing) |
| Application | Ollama serve | ✅ | running, CPU inference |

#### Path Forward for GPU Support

The `nvidia-tegra-nvgpu` extension needs to be rebuilt with a version of the OOT
`host1x` module that includes the full `nvhost` UAPI character device interface — i.e.,
the code that creates `/dev/nvhost-ctrl`. Additionally, the netlist array bounds bug in
`nvgpu_grmgr_get_gpu_instance_runlist_id` needs to be fixed.

The registry has older builds to test (`1.0.0`, `2.0.0`, `3.0.0` of `nvidia-tegra-nvgpu`)
— they may have different host1x implementations. Switching versions requires updating
`controlplane.yaml` and rebooting the node (no full wipe needed):

```bash
# In controlplane.yaml, change the nvgpu extension version, then:
talosctl apply-config \
  --talosconfig ~/PycharmProjects/jetson-test/talosconfig \
  --endpoints 10.0.10.38 --nodes 10.0.10.38 \
  --file ~/PycharmProjects/jetson-test/controlplane.yaml
# Talos will update the extension squashfs layers on next reboot
talosctl reboot --talosconfig ... --nodes 10.0.10.38
```

---

## 13. Cluster Recovery

Use this procedure when `talosctl` fails with certificate errors — typically caused by
the cluster being reinstalled without saving new credentials to `jetson-test/`.

### Diagnosing the Problem

```bash
talosctl --talosconfig ~/PycharmProjects/jetson-test/talosconfig \
  --endpoints 10.0.10.38 --nodes 10.0.10.38 version
```

| Error | Meaning |
|---|---|
| `x509: Ed25519 verification failure` | Cert mismatch — cluster was reinstalled, old talosconfig no longer valid |
| `tls: certificate required` | Node is running normally but rejects our client cert |
| `Unimplemented: API is not implemented in maintenance mode` | Node is in maintenance mode (this is GOOD if you want to apply-config) |

### Recovery Path A — You Still Have Working talosctl Auth

If `talosctl version` succeeds (matching certs), perform a **full authenticated reset**:

```bash
talosctl --talosconfig ~/PycharmProjects/jetson-test/talosconfig \
  --endpoints 10.0.10.38 --nodes 10.0.10.38 \
  reset --wipe-mode all --reboot --graceful=false
```

This wipes ALL partitions (EFI, META, STATE, EPHEMERAL) and reboots to maintenance
mode. Skip to "Apply Config" below.

### Recovery Path B — Certificate Mismatch (No Working Auth)

When the stored talosconfig no longer matches the running cluster, you must wipe the
NVMe STATE partition first to force maintenance mode.

**Step 1 — Boot from USB**

Insert the recovery USB. In the UEFI boot menu, select the USB device.

**Step 2 — Wipe STATE via kernel arg**

In the systemd-boot menu, highlight the first Talos entry and press **`e`** to edit
the kernel cmdline. Append the following at the end of the line (space-separated):

```
talos.experimental.wipe=system:STATE
```

Press **Enter** to boot. Talos will:
1. Detect the STATE partition on NVMe
2. Wipe it completely
3. Automatically reboot

> **Important**: `talos.reset=true` does NOT work in Talos v1.12. The correct
> parameter is `talos.experimental.wipe=system:STATE`.
>
> To wipe only STATE (preserving EPHEMERAL/Kubernetes data):
> `talos.experimental.wipe=system:STATE`
>
> To wipe the entire system disk (clean slate, required for fresh cluster):
> `talos.experimental.wipe=system`

**Step 3 — Confirm maintenance mode**

After the automatic reboot (~30 s), the node returns in maintenance mode:

```bash
talosctl --endpoints 10.0.10.38 --nodes 10.0.10.38 --insecure version
# Expected: Unimplemented desc = API is not implemented in maintenance mode
```

### Apply Config (both paths converge here)

**Step 4 — Apply machine config**

```bash
talosctl apply-config \
  --insecure \
  --endpoints 10.0.10.38 \
  --nodes 10.0.10.38 \
  --file ~/PycharmProjects/jetson-test/controlplane.yaml
```

Expected output: only deprecation warnings, no errors. Talos immediately pulls the
installer from `10.0.10.24:5001` and begins installation (~3-5 min).

> **Registry note**: The local registry at `10.0.10.24:5001` is plain HTTP. The
> machine config must use the `mirrors` section with an explicit `http://` endpoint:
> ```yaml
> registries:
>   mirrors:
>     10.0.10.24:5001:
>       endpoints:
>         - "http://10.0.10.24:5001"
> ```
> Do NOT use `config.tls.insecureSkipVerify: true` alone — that instructs the client
> to use HTTPS and just skip cert verification, which fails against a plain HTTP server
> with error `http: server gave HTTP response to HTTPS client`. Combining both causes
> `TLS config specified for non-HTTPS registry` error.

**Step 5 — Wait for install and reboot**

Watch for the node to come back with proper auth (~5 min):

```bash
until talosctl --talosconfig ~/PycharmProjects/jetson-test/talosconfig \
  --endpoints 10.0.10.38 --nodes 10.0.10.38 version &>/dev/null; do
  echo "waiting..."; sleep 15
done
echo "Node is up!"
```

**Step 6 — Bootstrap etcd** (only if EPHEMERAL was also wiped — fresh install)

```bash
talosctl --talosconfig ~/PycharmProjects/jetson-test/talosconfig \
  --endpoints 10.0.10.38 --nodes 10.0.10.38 \
  bootstrap
```

If you get `AlreadyExists: etcd data directory is not empty`, skip this — etcd is
already running with existing data.

> **Warning**: Wiping only STATE (not EPHEMERAL) leaves old Kubernetes PKI in the
> EPHEMERAL partition. After apply-config with a new machine CA, the kubelet's old
> client certs (signed by the previous CA) will be rejected by the new kube-apiserver.
> This causes `Unauthorized` errors in kubelet logs and broken `kubectl logs`/`exec`.
> **Always use `--wipe-mode all` or `talos.experimental.wipe=system` for a clean
> cluster.** A STATE-only wipe is only useful if you want to recover the same cluster
> with the same Kubernetes state.

**Step 7 — Retrieve and save credentials**

```bash
talosctl --talosconfig ~/PycharmProjects/jetson-test/talosconfig \
  --endpoints 10.0.10.38 --nodes 10.0.10.38 \
  kubeconfig --force ~/PycharmProjects/jetson-test/kubeconfig

# Always keep talos-jetson/ in sync
cp ~/PycharmProjects/jetson-test/kubeconfig ~/talos-jetson/kubeconfig
cp ~/PycharmProjects/jetson-test/talosconfig ~/talos-jetson/talosconfig
```

**Step 8 — Verify**

```bash
KUBECONFIG=~/PycharmProjects/jetson-test/kubeconfig kubectl get nodes -o wide
talosctl --talosconfig ~/PycharmProjects/jetson-test/talosconfig \
  --endpoints 10.0.10.38 --nodes 10.0.10.38 version
```

---

## 14. Known Limitations

| Limitation | Impact | Notes / Workaround |
|---|---|---|
| Module signing disabled | Any `.ko` can load into kernel | Acceptable for a dedicated, network-isolated cluster |
| Undefined L4T symbols | `nvmap_dma_free_attrs`, `tegra_vpr_dev` are stubs | Not reached during CUDA compute; would oops if called |
| `install.extensions` deprecated in v1.12 | Validation warning | Functional; migrate to overlay installer in future |
| CUDA GPU acceleration blocked | `nvidia-tegra-nvgpu:4.0.0` OOT `host1x` module doesn't create `/dev/nvhost-ctrl`; nvgpu has UBSAN bugs in `netlist.c:613` — `cuInit` returns 801 | CPU inference works; GPU needs fixed nvgpu module — see Section 12 |
| dustynv Ollama stub libraries | `dustynv/ollama:r36.4.0` carries 0-byte stubs for `libnvrm_gpu.so`, `libcuda.so.1.1` etc. — NVIDIA Container Runtime normally injects real host libs, not present on Talos | Fixed: download real r36.5 libs from NVIDIA APT and mount via hostPath — see Step 1 in Section 12 |
| JetPack libs lost after full wipe | The real libs in `/var/lib/nvidia-tegra-libs/` live in EPHEMERAL. A `--wipe-mode all` reset deletes them | Re-run the `install-l4t-r365-libs` Job (Section 12 Step 1) after every full cluster rebuild |
| dustynv Ollama entrypoint exits | Default entrypoint starts `ollama serve` in background then exits → pod status "Completed" → restart loop | Override with `command: ["ollama", "serve"]` to keep process in foreground |
| NVMe UKI missing extensions after fresh install | `talosctl upgrade` / `apply-config` writes an 18.8MB UKI (no extensions) to NVMe using `custom-installer:v1.12.6-6.18.18`. Without extensions, the NVMe UKI fails to boot (no kernel modules for Jetson hardware). UEFI falls through to USB. **Fix**: copy the working 149MB USB UKI (`talos-v8.efi`) to `/EFI/Linux/` on NVMe partition (`nvme0n1p1`) and set `default talos-v8.efi` in `loader.conf`. Must be repeated after every full reinstall/upgrade. Long-term fix: build imager installer output with extensions baked in. | Use privileged pod to mount `nvme0n1p1` and copy `talos-v8.efi` from `sda1` (USB) to `/mnt/efi/EFI/Linux/`. See Section 7.5 |
| UEFI boot order | Cannot set USB-first from software | Set manually in UEFI firmware |
| Single control-plane node | No HA, no etcd redundancy | By design; scale by adding worker nodes via `worker.yaml` |
| Registry must be plain HTTP mirror | `10.0.10.24:5001` is HTTP-only; using `insecureSkipVerify: true` alone fails with "server gave HTTP response to HTTPS client". Use `mirrors` with `http://` endpoint instead | See Section 13 registry note |
| Registry must be reachable at install time | `10.0.10.24:5001` must be up during `apply-config` | Ensure the Mac stays on the Jetson network during provisioning |
| STATE-only wipe leaves stale Kubernetes PKI | Wiping STATE but preserving EPHEMERAL reuses old kubelet certs which don't match the new cluster CA | Always wipe all partitions for a clean reinstall (`--wipe-mode all` or `talos.experimental.wipe=system`) |
| `talos.reset=true` is not a valid Talos v1.12 kernel arg | Adding it to the boot cmdline is silently ignored | Use `talos.experimental.wipe=system:STATE` (STATE only) or `talos.experimental.wipe=system` (full disk) |
| `grubUseUKICmdline: true` must NOT be set on arm64/UKI | This flag is for legacy x86 GRUB only. On Jetson (arm64), setting it causes the installer to skip creating the UKI boot entry → systemd-boot shows only "Reboot Into Firmware Interface" and loops | Remove the flag; `firmware_class.path` is already embedded in the UKI inside the custom-installer image |
| `maintenance mode` ≠ USB boot | Booting from USB does NOT guarantee maintenance mode — Talos scans ALL disks for STATE. The NVMe STATE must be absent for maintenance mode to activate | See Section 13 for how to wipe STATE |
| Credentials not auto-saved | New installs require manually saving `talosconfig` + `kubeconfig` | Always copy to `jetson-test/` immediately after bootstrap |

---

## 15. Reference: All Image Tags

Current images in the local registry (`10.0.10.24:5001`):

| Image | Tag | Status | Notes |
|---|---|---|---|
| `custom-installer` | `v1.12.6-6.18.18` | **Active** | Installer with Clang vmlinuz |
| `nvidia-tegra-nvgpu` | `4.0.0-6.18.18-talos` | **Active** | All Clang warnings + API fixes |
| `kernel-modules-clang` | `1.1.0-6.18.18-talos` | **Active** | Clang-compiled module tree |
| `nvidia-firmware-ext` | `v4` | **Active** | Firmware at correct direct path |
| `cuda-device-check` | `v1` | Tool | Verifies `cuInit`, lists GPU devices |
| `jetson-cuda-test` | `v1`–`v5-strace` | Archived | CUDA debugging iterations |

**`nvidia-tegra-nvgpu` version history**:

| Tag | Change | CUDA compute |
|---|---|---|
| `1.0.0-6.18.18-talos` | Initial build | Unknown |
| `2.0.0-6.18.18-talos` | Switch to Clang build | Unknown |
| `3.0.0-6.18.18-talos` | Kernel 6.18 API patches (`vm_flags`, `class_create`) | Unknown |
| `4.0.0-6.18.18-talos` | All Clang warnings fixed; kernel module loads | ❌ Broken — OOT host1x missing `/dev/nvhost-ctrl`; UBSAN in netlist.c |

> Note: "verified working on hardware" above means the module loads and the node boots.
> CUDA compute (`cuInit`) has not been confirmed working with any of these versions yet.

**`nvidia-firmware-ext` version history**:

| Tag | Firmware path | Result |
|---|---|---|
| `v1`, `v2` | `/usr/lib/firmware/nvidia/ga10b/` | ELOOP on all loads |
| `v3` | Both `/nvidia/ga10b/` and `/ga10b/` | ELOOP still on `/lib` path |
| `v4` | `/usr/lib/firmware/ga10b/` (direct) | **Working** — no ELOOP |

---

## References

- [Talos Linux v1.12 Documentation](https://www.talos.dev/v1.12/)
- [Talos System Extensions Guide](https://www.talos.dev/v1.12/talos-guides/configuration/system-extensions/)
- [Talos Boot Assets Guide](https://www.talos.dev/v1.12/talos-guides/install/boot-assets/)
- [Talos Kernel Configuration Reference](https://www.talos.dev/v1.12/reference/kernel/)
- [siderolabs/pkgs](https://github.com/siderolabs/pkgs) — Talos kernel build system (commit `a92bed5`)
- [siderolabs/bldr](https://github.com/siderolabs/bldr) — BuildKit frontend
- [OE4T/linux-nvgpu](https://github.com/OE4T/linux-nvgpu) — nvgpu OE4T patches (commit `d530a48`)
- [OE4T/linux-nv-oot](https://github.com/OE4T/linux-nv-oot) — NVIDIA OOT framework (commit `ea32e7f`)
- [dusty-nv/jetson-containers](https://github.com/dusty-nv/jetson-containers) — Jetson Docker images
- [NVIDIA JetPack SDK](https://developer.nvidia.com/embedded/jetpack) — Firmware / CUDA userspace source
