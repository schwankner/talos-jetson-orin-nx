# Root-Cause Analysis: Key Bugs Fixed

Detailed write-up of every non-trivial problem encountered while getting
Talos Linux running with CUDA on the Jetson Orin NX. Listed in roughly
the order they were hit.

---

## Bug 1 — Firmware ELOOP (−40)

**Symptom**: `dmesg` shows nvgpu attempting to load firmware files and
failing with error code `-40` (`ELOOP`) even though the files physically
exist in the filesystem.

**Root cause chain**:

```
nvgpu → request_firmware("ga10b/acr-gsp.data.encrypt.bin.prod")
       → firmware loader constructs path: /lib/firmware/ga10b/acr-gsp…
                                             │
                              /lib ──(symlink)──► usr/lib
                                                      │
                                      usr/lib/firmware ──(overlayfs bind-mount)──► squashfs
                                                                                         │
                                                        filp_open() inside bind-mount ──► ELOOP (-40)
```

The Linux kernel VFS follows the `/lib → usr/lib` symlink and then
encounters an overlayfs bind-mount boundary. Symlink resolution across this
boundary increments the kernel's internal link-follow counter past the
ELOOP threshold.

**Fix**: Kernel cmdline `firmware_class.path=/usr/lib/firmware` — embedded
in the UKI at build time. The firmware subsystem uses this path directly,
bypassing the symlink entirely.

Additionally, firmware files must be placed at `/usr/lib/firmware/ga10b/`
(direct path), **not** `/usr/lib/firmware/nvidia/ga10b/` — the latter
caused identical ELOOP failures in earlier extension versions (`v1`–`v3`).

---

## Bug 2 — Kernel Module Signing Key Reproducibility

**Symptom**: Talos boots into maintenance mode with 6 kernel module
rejections in dmesg, no NVMe, no IP.

**Root cause (original)**: `CONFIG_MODULE_SIG_FORCE=y` in the official
Talos kernel. The signing key is ephemeral — created during the kernel
build and destroyed afterward. Third-party modules cannot be signed with it.

**Root cause (after enabling signing)**: Key mismatch. The Linux kernel's
`certs/Makefile` contains an auto-generation rule for the filename
`signing_key.pem` with a `FORCE` dependency. On every cache-miss build,
`make` regenerates this file with a new random key, overwriting any key we
had placed there.

**Fix**: `CONFIG_MODULE_SIG_KEY="certs/talos_signing_key.pem"` — a custom
filename that `make` has no auto-generation rule for. The file is never
touched by `make`.

1. `00-setup-keys.sh` generates an RSA-4096 key pair on first run and saves
   it to `keys/signing_key.pem` + `keys/signing_key.x509`.
2. The key is **committed to the repository** (it's a build key, not a secret).
3. `00-setup-keys.sh` copies it as `certs/talos_signing_key.pem` to the
   kernel build dir — `make` never touches it.
4. `09-build-nvgpu.sh` verifies the key serial after every kernel build.

Current committed key serial: `74FD747A092BD42575ED4CBE6F7E2479A6FEC740`

> **For forks**: generate a new key pair with `./scripts/00-setup-keys.sh --force`
> then rebuild all extensions — see [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Bug 3 — Clang Toolchain Consistency

**Symptom**: OOT module build fails immediately:

```
clang: error: unknown argument: '-fmin-function-alignment=8'
clang: error: unknown argument: '-fconserve-stack'
clang: error: unknown argument: '-fsanitize=bounds-strict'
```

**Root cause**: The default Talos kernel is compiled with GCC. GCC-specific
compiler flags are stored in the kernel's `.config` and exported as
`$(KBUILD_CFLAGS)` for OOT module builds. When the OOT module is built with
Clang, these GCC-only flags are passed to Clang which rejects them.

**Fix**:
1. Build the kernel with `LLVM=1 LLVM_IAS=1`
2. Run `make olddefconfig LLVM=1` before the kernel build — this lets Clang
   detect its own capabilities and disables all `CC_HAS_*` options that
   only exist in GCC

Additionally, the OE4T nvgpu sources trigger several Clang 18+ warnings
that are treated as errors:

| File | Problem | Fix |
|---|---|---|
| `clk_prog.c` | `-Wimplicit-fallthrough` | `-Wno-implicit-fallthrough` in ccflags |
| `clk_vf_point.c` | `-Wparentheses-equality` | `-Wno-parentheses-equality` |
| `ioctl.c` | Incompatible `devnode` function pointer | `-Wno-incompatible-function-pointer-types` |
| `scale.c` | `-Wsometimes-uninitialized` | `-Wno-sometimes-uninitialized` |

---

## Bug 4 — Kernel 6.18 API Changes

#### `vm_flags` Write Protection (since kernel 6.3)

`vm_flags` in `struct vm_area_struct` became `const` in kernel 6.3. Direct
writes via `vma->vm_flags |= …` must use accessor functions.

The OE4T patches use `NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS`. We set this
to `#if 1` unconditionally for kernel 6.18.

#### `class_create()` Signature Change (since kernel 6.4)

```c
// Before 6.4:
struct class *cls = class_create(THIS_MODULE, "nvgpu");

// 6.4 and later:
struct class *cls = class_create("nvgpu");
```

Patched in all affected OE4T source files.

---

## Bug 5 — Undefined L4T Symbols

These symbols exist in L4T kernels but not in upstream Linux:

| Symbol | Where | Runtime impact |
|---|---|---|
| `nvmap_dma_free_attrs` | DMA memory management | Not called during standard CUDA usage |
| `tegra_vpr_dev` | Video Protected Region | Not needed for compute |
| `host1x_fence_extract` | Sync framework | Partial workaround in host1x module |
| `emc_freq_to_bw` | EMC bus bandwidth | Not invoked for GPU compute |

**Fix**: `KBUILD_MODPOST_WARN=1` — demotes undefined symbol errors to
warnings, allowing the module to build and load. These code paths would
produce a kernel oops at runtime, but standard CUDA compute workloads on
Jetson Orin NX do not invoke them.

---

## Bug 6 — CUDA Error 999 (cudaStreamSynchronize) — nvhost syncpoint

**Symptom**: CUDA programs fail immediately with error 999
(`cudaErrorUnknown`) when calling `cudaStreamSynchronize()`. The GPU is
visible (`nvgpu` loads), but compute fails.

**Root cause (part 1 — synchronization path)**: nvgpu's synchronization
path relies on nvhost syncpoints (hardware semaphores) and
`/dev/nvhost-ctrl`. On Talos (non-L4T), this device doesn't exist. nvgpu
calls `-ENXIO` and maps it to CUDA error 999.

**Fix (part 1)**: Build nvgpu with `CONFIG_TEGRA_GK20A_NVHOST=n`. This
disables the nvhost dependency and forces nvgpu to use the CSL (Channel
Submit and Lock) path for GPU synchronization.

**Root cause (part 2 — libcuda.so.1.1)**: `libcuda.so.1.1` itself
unconditionally opens `/dev/nvhost-ctrl` during `cuInit`. Without the
device, `cuInit` fails with error 999 even though nvgpu's own sync path
works.

**Fix (part 2)**: Inject `/dev/nvhost-ctrl` into GPU-enabled pods via a
CDI hostPath mapping. The custom `jetson-device-plugin` (see
`plugins/jetson-device-plugin/`) returns `CDIDevices: [{Name: "nvidia.com/gpu=0"}]`
in its `AllocateResponse`, and the CDI spec includes a hostPath entry
for `/dev/nvhost-ctrl`.

> Note: The CDI setup scripts are not published in this repo (kept locally),
> but the device plugin source is in `plugins/jetson-device-plugin/`.

---

## Bug 7 — devfreq Governor (`governor_pod_scaling.ko`) Missing

**Symptom** (pre-Boot 15):

```
gk20a 17000000.gpu: devfreq_add_device: Unable to find governor for the device
```

GPU initialized but ran at fixed maximum clock (918 MHz) — no dynamic
frequency scaling.

**Root cause**: `platform_ga10b_tegra.c` (OE4T, `d530a48`) hardcodes the
devfreq governor as `"nvhost_podgov"`, implemented in
`nvidia-oot/drivers/devfreq/governor_pod_scaling.c`. The devfreq Makefile
was missing two `ccflags-y` include paths, causing the module to be
silently skipped at build time:

| Missing include | Needed for |
|---|---|
| `-I$(srctree.nvconftest)` | `nvidia/conftest.h` — NVIDIA compat macros |
| `-I$(srctree.nvidia-oot)/include` | `trace/events/nvhost_podgov.h` — tracepoints |

**Fix** (added to `pkg.yaml` prepare step, before the devfreq build):

```bash
printf 'ccflags-y += -I$(srctree.nvconftest)\n' \
  >> ${NVIDIA_OOT}/drivers/devfreq/Makefile
printf 'ccflags-y += -I$(srctree.nvidia-oot)/include\n' \
  >> ${NVIDIA_OOT}/drivers/devfreq/Makefile
```

**Result (Boot 15)**: `governor_pod_scaling.ko` loads, `nvhost_podgov`
governor registered, `/sys/class/devfreq/17000000.gpu` active, GPU scales
306→918 MHz (7 steps) dynamically during load.

---

## Bug 8 — CDI Stack + containerd 2.x + Custom Device Plugin

Four CDI-specific bugs encountered when enabling GPU access via the
[Container Device Interface](https://github.com/cncf-tags/container-device-interface):

| Bug | Root cause | Fix |
|---|---|---|
| **A** — Talos `op:overwrite` needs existing file | `talos.dev/v1alpha1` machine config `op:overwrite` fails if target file doesn't exist | Embed CDI config directly into `containerd.toml` (no separate file) |
| **B** — containerd 2.x removed pod annotation CDI | `cdi.k8s.io/gpu0: …` pod annotations were the old CDI mechanism; containerd 2.x dropped it | Custom device plugin (`jetson-device-plugin`) returns `CDIDevices` field in `AllocateResponse` — the CRI path that containerd 2.x uses |
| **C** — `containerEdits: []` YAML array rejected | Empty array is invalid in the CDI spec YAML schema | Omit the field entirely when there are no container edits |
| **D** — nvhost-ctrl symlink rejected | CDI spec `symlink` type rejected by containerd; device also missing in container | Switch to CDI `hostPath` type for `/dev/nvhost-ctrl` |

The custom device plugin source is at `plugins/jetson-device-plugin/main.go`.

---

## Bug 9 — UBSAN: array-index-out-of-bounds in netlist.c (Non-fatal)

**Symptom** (every boot, non-fatal):

```
UBSAN: array-index-out-of-bounds in drivers/gpu/nvgpu/hal/netlist/netlist.c:617:32
index 1 is out of range for type 'struct netlist_region [1]'
```

**Root cause**: `struct netlist_image` in `netlist_priv.h` uses the C89
"struct hack" — `regions[1]` as the last member:

```c
struct netlist_image {
    struct netlist_image_header header;   // header.regions = actual count
    struct netlist_region regions[1];     // ← C89 struct hack, UBSAN fires for i >= 1
};
```

The loop in `netlist.c:617` iterates over `header.regions` entries using
index `i >= 1`, which UBSAN correctly flags as out-of-bounds for the
declared array size `[1]`.

**Impact**: None — the GPU initializes and runs normally. UBSAN is a
debug-time sanitizer warning, not a runtime error.

**Upstream fix**: Change `regions[1]` to `regions[]` (C99 flexible array
member) in `netlist_priv.h`. No upstream issue filed as of 2026-04-01.
