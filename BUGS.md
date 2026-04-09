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

## Bug 10 — GCC 15 / Clang 22 Toolchain Mismatch in Kernel 6.18 OOT Build

**Symptom**: OOT module (`nvgpu.ko`) build fails with a cascade of errors:

```
clang: error: unknown argument: '-fmin-function-alignment=8'
clang: error: unknown argument: '-fconserve-stack'
drivers/gpu/nvgpu/…: error: use of undeclared identifier 'latent_entropy'
include/linux/vmstat.h:…: error: implicit conversion changes signedness ('unsigned long' to 'long')
```

**Root cause (layered)**:

1. **GCC-only flags leak into Clang OOT build.** Linux 6.18's top-level
   `Makefile` contains several `$(if $(CONFIG_*), -flag)` expressions that
   are **not** gated on `CONFIG_CC_IS_GCC`. When the *kernel* was compiled
   with GCC these options are stored in `auto.conf` and then unconditionally
   exported as `$(KBUILD_CFLAGS)` for any OOT module build — even when the
   OOT module uses `LLVM=1` (Clang):

   | Flag | Source | Problem |
   |---|---|---|
   | `-fmin-function-alignment=8` | `CONFIG_FUNCTION_ALIGNMENT` | GCC-only |
   | `-fconserve-stack` | `CONFIG_FRAME_WARN` | GCC-only |
   | `-fsanitize=bounds-strict` | UBSAN config | Clang only has `-fsanitize=bounds` |
   | `-Wimplicit-fallthrough=5` | `KBUILD_WFLAGS` | Clang uses `-Wimplicit-fallthrough` (no value) |
   | `-Wno-maybe-uninitialized` | `cc-option` probe | Clang uses `-Wno-uninitialized` |
   | `-Wno-alloc-size-larger-than` | `cc-option` probe | Clang doesn't have this flag |
   | `-fplugin=stackleak_plugin.so` | `CONFIG_GCC_PLUGIN_STACKLEAK` | GCC plugins don't exist in Clang |
   | `-Wgnu-variable-sized-type-not-at-end` | `cgroup-defs.h` include | Clang 22 new default warning |
   | `-Wenum-enum-conversion` | `vmstat.h` implicit conversion | Clang 22 new default warning |

2. **`latent_entropy` undeclared.** `CONFIG_GCC_PLUGIN_LATENT_ENTROPY=y` in
   the GCC kernel build causes the GCC plugin to inject a global `latent_entropy`
   variable declaration into `autoconf.h`. When Clang builds OOT modules, it
   includes `autoconf.h` (via `-include include/generated/autoconf.h`) and then
   hits references to this variable in `drivers/net/` and other subsystems.
   Passing `-UCONFIG_GCC_PLUGIN_LATENT_ENTROPY` on the command line does **not**
   help because `-include autoconf.h` is processed after all `-U` flags.

**Fix — `clang-oot` wrapper** (in `nvidia-tegra-nvgpu/pkg.yaml`):

A shell script at `/usr/local/bin/clang-oot` intercepts every compiler
invocation and filters GCC-specific flags before calling real `clang`. Trailing
overrides (`-Wno-*`) come **after** `${filtered[@]}` so they win over flags that
the kernel build system injects mid-compile:

```bash
case "$arg" in
  -fmin-function-alignment=*|-fconserve-stack) ;;        # drop
  -fsanitize=bounds-strict) filtered+=("-fsanitize=bounds") ;;
  -Wimplicit-fallthrough=*) filtered+=("-Wimplicit-fallthrough") ;;
  -Wno-maybe-uninitialized) filtered+=("-Wno-uninitialized") ;;
  -Wno-alloc-size-larger-than|-Wno-alloc-size-larger-than=*) ;;
  -fplugin=*|-fplugin-arg-*) ;;
  *) filtered+=("$arg") ;;
esac
exec clang "${filtered[@]}" \
  -Wno-unknown-warning-option \
  -Wno-enum-enum-conversion \
  -Wno-implicit-fallthrough \
  -Wno-gnu-variable-sized-type-not-at-end
```

For `latent_entropy`: the `autoconf.h` and `auto.conf` files are patched
in-place before `make` runs:

```bash
sed -i '/CONFIG_GCC_PLUGIN_LATENT_ENTROPY/d' /src/include/config/auto.conf
sed -i '/CONFIG_GCC_PLUGIN_LATENT_ENTROPY/d' /src/include/generated/autoconf.h
```

**Note**: The wrapper is created twice in `pkg.yaml` (once in the `nvidia-oot`
build step, once in the `nvgpu` build step). This is intentional: BuildKit
layer caching can cause the nvgpu step to run in a container that never ran the
nvidia-oot step, so the wrapper must be idempotent and self-contained.

---

## Bug 11 — CI: Extension Images Were Never Pushed to ghcr.io

**Symptom**: UKI assembly fails:

```
error pulling image ghcr.io/schwankner/kernel-modules-clang:1.1.0-6.18.18-talos: DENIED
error pulling image ghcr.io/schwankner/nvidia-firmware-ext:v5: DENIED
```

**Root cause**: Three extension images existed only in the local OCI registry
(`192.168.1.100:5001`) and were never built or pushed in CI:

| Image | Problem |
|---|---|
| `kernel-modules-clang` | No bldr package existed; in-tree modules were never packaged as an extension |
| `nvidia-firmware-ext` | Built manually once, pushed only to local registry; no CI step |

The Talos imager runs inside a Docker container and can pull from ghcr.io
authenticated by the host's Docker credentials — but only if those credentials
are mounted into the container (`-v ~/.docker/config.json:/root/.docker/config.json:ro`).
Even with that fix, images that don't exist in ghcr.io at all cannot be pulled.

**Fix — `kernel-modules-clang`**:

New bldr package `kernel-modules-clang/pkg.yaml` (depends on `base` +
`kernel-build`). The `kernel-build` stage already signs all in-tree `.ko` files
with `talos_signing_key.pem`. The new package simply copies them into
`/rootfs/usr/lib/modules/${KERNEL_RELEASE}/kernel/` — no re-signing needed.

`build-extensions.sh` builds and pushes this image as a new Step 3, reusing
the already-cached `kernel-build` layers (only a few extra minutes).

**Fix — `nvidia-firmware-ext`**:

New CI step in `build-extensions.yaml` that:
1. Queries the NVIDIA L4T r36.5 apt repo (`t234` component, not `common`) to
   find `nvidia-l4t-firmware_36.5.0-*.deb`
2. Downloads the `.deb` directly (no apt-key or sudo needed)
3. Extracts firmware files with `dpkg-deb --extract`
4. Locates `ga10b/` with `find` (path varies by package version)
5. Packages them as a Talos OCI extension and pushes to ghcr.io

**Key lesson**: NVIDIA L4T apt packages are split across board-specific repos.
`nvidia-l4t-firmware` is in `t234` (Orin-specific), not in `common`.

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

---

## Bug 12 — kernel-modules-clang Removed Prematurely; squashfs Module Key Mismatch

**Symptom (run 16/17)**: After the previous session removed `kernel-modules-clang`
from the UKI systemExtensions, Ethernet (r8169/RTL8168h via PCIe) stopped working
and nvgpu failed with `Unknown symbol tegra_vpr_dev / nvmap_dma_alloc_attrs /
nvmap_dma_free_attrs / emc_freq_to_bw`. Three `Loading of module with unavailable
key is rejected` messages appeared at ~14 s (udevd startup).

**Root cause**: The Talos stock installer image (`ghcr.io/siderolabs/installer:v1.12.6`)
bundles an initramfs whose squashfs contains in-tree kernel modules signed with the
**official Talos v1.12.6 release key**. Our custom kernel build uses a **different
throw-away key** (`863dd523`, auto-generated from siderolabs/pkgs). These keys do
not match, so any squashfs module loaded by udevd is rejected with
`"unavailable key"` under `module.sig_enforce=1`.

Rejected squashfs modules included:
- `r8169.ko` — PCIe Ethernet driver (RTL8168h on reComputer J4012)
- Two additional Tegra-specific modules (exact names not in dmesg output)

nvgpu's OOT dependency chain (nvmap → mc-utils) depends on in-tree Tegra modules
from the squashfs. When those squashfs modules are rejected, nvmap cannot initialise
and fails silently. nvgpu then sees missing symbols for `tegra_vpr_dev`,
`nvmap_dma_alloc_attrs`, `nvmap_dma_free_attrs`, `emc_freq_to_bw`.

**Why run 15 worked**: kernel-modules-clang provides **all in-tree modules** signed
with the **same key as the running kernel** (both built in the same bldr run). The
Talos extension overlayfs places extension modules in `extra/` which has higher
depmod priority than `kernel/` (squashfs). udevd therefore loads the extension
versions (correct key, accepted) and never reaches the rejected squashfs versions.

**Misdiagnosis in previous session**: Run 16 had kernel-modules-clang loaded but
the image was built for the April 1 Clang kernel while run 16/17 used the April 3
GCC kernel — a kernel ABI mismatch. The modules could not load (wrong ABI), the
squashfs fallback was rejected (wrong signing key), so Ethernet failed in both
run 16 (WITH kernel-modules-clang) and run 17 (WITHOUT it). This was incorrectly
attributed to "overlayfs shadowing". The actual root cause was the stale
kernel-modules-clang image.

**Fix**:
1. `KERNEL_MODULES_VERSION` bumped `1.1.0 → 1.2.0` in `common.sh` — forces
   a fresh ghcr.io build of kernel-modules-clang for the current kernel.
2. `kernel-modules-clang` re-added to the UKI `systemExtensions` list in
   `scripts/build-uki.sh`.
3. CI will rebuild kernel-modules-clang against the current kernel; all in-tree
   modules get signed with the correct key, shadowing the squashfs modules.

---

## Bug 13 — softdep File in Wrong Path; nvgpu Unknown Symbol (nvmap / mc-utils)

**Symptom (run 19)**: Ethernet ✅ working, NVMe ✅ detected, but nvgpu ❌ fails
with `Unknown symbol` errors:
```
nvgpu: Unknown symbol tegra_vpr_dev (err -2)
nvgpu: Unknown symbol nvmap_dma_alloc_attrs (err -2)
nvgpu: Unknown symbol nvmap_dma_free_attrs (err -2)
nvgpu: Unknown symbol emc_freq_to_bw (err -2)
```
The first three symbols are exported by `nvmap.ko`; `emc_freq_to_bw` is exported
by `mc-utils.ko`. nvmap and mc-utils were not loaded before nvgpu despite a
`softdep nvgpu pre: host1x nvmap host1x-fence mc-utils` declaration.

**Root cause**: The `softdep` configuration file was written to
`/rootfs/usr/local/lib/modprobe.d/nvidia-tegra.conf` inside the nvgpu extension.
kmod searches the following standard paths for `modprobe.d` files:
- `/usr/lib/modprobe.d/`
- `/lib/modprobe.d/`
- `/etc/modprobe.d/`
- `/run/modprobe.d/`

`/usr/local/lib/modprobe.d/` is **not** in the standard search path — kmod silently
ignores it. As a result, the `softdep` was never effective: when nvgpu was loaded
(triggered by its udev alias), modprobe made no effort to load nvmap and mc-utils
first. nvgpu probed, found missing symbols, and aborted.

**Fix**: In `nvidia-tegra-nvgpu/pkg.yaml`, changed the modprobe.d path:
```diff
-          > /rootfs/usr/local/lib/modprobe.d/nvidia-tegra.conf
-          >> /rootfs/usr/local/lib/modprobe.d/nvidia-tegra.conf
+        mkdir -p /rootfs/usr/lib/modprobe.d
+          > /rootfs/usr/lib/modprobe.d/nvidia-tegra.conf
+          >> /rootfs/usr/lib/modprobe.d/nvidia-tegra.conf
```

`NVGPU_VERSION` bumped `5.1.0 → 5.2.0` in `common.sh` to force a clean rebuild
of the nvgpu extension so the corrected path is included in the new image.

**Expected outcome (run 20)**: kmod reads the softdep at boot; when udev triggers
nvgpu's alias, modprobe loads `host1x`, `nvmap`, `host1x-fence`, `mc-utils` first,
then nvgpu — all missing-symbol errors should disappear.

---

## Bug 14 — CUDA Error 999 Persists with NVHOST=y (nvgpu 5.9.0 / 5.9.1)

**Symptom**: After enabling `CONFIG_TEGRA_GK20A_NVHOST=y` and building an OOT host1x
to resolve CRC mismatches (Bug 6 / nvgpu 5.9.0), `cudaStreamSynchronize` still
returns error 999 (`CUDA_ERROR_UNKNOWN`) for NULL streams and explicit streams.
Only `cudaStreamPerThread` (handle `0x2`) succeeded via the driver API.

```
A: cuStreamSynchronize(NULL stream)       → 999  ← FAILS
B: cuStreamSynchronize(explicit stream)   → 999  ← FAILS
C: cuStreamSynchronize(0x2 per-thread)   → 0    ← SUCCESS (driver sentinel only)
```

### nvgpu 5.9.0 — Root Cause: Syncpoint id=0 (NVGPU_ERRATA_SYNCPT_INVALID_ID_0)

With `NVHOST=y`, `cudaStreamSynchronize` uses host1x hardware syncpoints.
The call chain is:

```
nvgpu_channel_sync_syncpt_create()
  → nvgpu_nvhost_get_syncpt_client_managed()
      → host1x_syncpt_alloc(host1x, HOST1X_SYNCPT_CLIENT_MANAGED | HOST1X_SYNCPT_GPU, name)
```

`HOST1X_SYNCPT_GPU` tells `host1x_syncpt_alloc()` to allocate from the GPU pool.
In the OE4T upstream host1x-next driver model, nvgpu is not registered as a host1x
GPU client — so the GPU pool iterator finds nothing and returns `NULL`.

`nvgpu_nvhost_get_syncpt_client_managed()` converts `NULL` → id `0`.
GA10b has `NVGPU_ERRATA_SYNCPT_INVALID_ID_0` set in `hal_ga10b.c`:

```c
if ((nvgpu_is_errata_present(c->g, NVGPU_ERRATA_SYNCPT_INVALID_ID_0)) && (sp->id == 0U)) {
    nvgpu_err(c->g, "failed to get free syncpt");
    goto err_free;  // → channel sync creation fails → error 999
}
```

### nvgpu 5.9.1 — Root Cause: CLIENT_MANAGED Syncpoints Not GPU-Signable

**Attempted fix**: Remove `HOST1X_SYNCPT_GPU` flag from `host1x_syncpt_alloc()` in
`nvhost_host1x.c` so it allocates from the `CLIENT_MANAGED` pool instead of the GPU pool.
Syncpoint id is now non-zero → ERRATA check passes → channel sync created successfully.

**Why error 999 persisted**: The GA10b GPU hardware can only signal syncpoints from the
**GPU pool**. Syncpoints allocated from the `CLIENT_MANAGED` pool are never signaled by
the GPU hardware. When `cudaStreamSynchronize` is called, the driver waits for the GPU to
increment the CLIENT_MANAGED syncpoint — which never happens → timeout → error 999.

`cudaStreamPerThread` (handle `0x2`) is a special CUDA runtime sentinel, not a real stream
with a syncpoint. The driver routes it through a per-thread implicit stream that does not
rely on host1x syncpoint signaling — hence it succeeded while all other streams failed.

### Fix (nvgpu 5.9.2): Revert to NVHOST=n

`CONFIG_TEGRA_GK20A_NVHOST=n` makes nvgpu use GPU semaphore buffers (`sema_buf`) for
stream synchronization. No host1x syncpoints involved. This was the stable path in 5.8.0.

**Additional patch required**: `nvgpu_nvhost_syncpt_init()` in
`platform_ga10b_tegra.c:281` (OE4T d530a48) is unguarded — with NVHOST=n the function
has no stub and the build fails with:
```
platform_ga10b_tegra.c:281:8: error: call to undeclared function 'nvgpu_nvhost_syncpt_init'
```
Fix: wrap the call in `#ifdef CONFIG_TEGRA_GK20A_NVHOST` via awk in `pkg.yaml`.

**Result**: CUDA error 999 fully resolved. Ollama 25/25 GPU layers, HTTP 200, ~7 tok/s decode.
The `Can't initialize nvrm channel` warning remains (libcuda.so discovery phase) but is
non-fatal — GPU channels are created successfully via the NVHOST=n semaphore path.

---

## Bug 15 — GPU Decode Speed: ~7 tok/s (CPU Polling Overhead with NVHOST=n)

**Symptom**: Ollama inference (qwen2.5:0.5b, 25/25 layers on CUDA) delivers only ~7 tok/s
decode on Jetson Orin NX 16 GB. Expected throughput is 20–30 tok/s.

### What Was Ruled Out

All of the following were tested and had **no measurable effect** on decode speed:

| Attempted | Result |
|-----------|--------|
| GPU clock: 306 MHz → 918 MHz (MAXN) | No change — stays at ~7 tok/s |
| `GGML_CUDA_GRAPHS=1` | No change |
| `OLLAMA_FLASH_ATTENTION=1` | No change |
| `OLLAMA_NUM_PARALLEL=1` | No change |
| `OLLAMA_KV_CACHE_TYPE=q8_0` | No change |

GPU clock having **zero effect** is the key diagnostic: the bottleneck is not GPU compute
throughput but CPU-side overhead between tokens.

### Root Cause: sema_buf Polling in `cudaStreamSynchronize` (NVHOST=n)

With `CONFIG_TEGRA_GK20A_NVHOST=n`, nvgpu uses GPU semaphore buffers (`sema_buf`) for
stream synchronization instead of host1x hardware syncpoints. The semaphore mechanism
requires the CPU to actively poll or sleep-wait after each `cudaStreamSynchronize` call —
introducing ~130 ms/token overhead in decode.

Evidence:
- CPU ramps to ~1984 MHz during generation (busy-wait pattern)
- GPU stays at minimum clock during generation (not compute-bound)
- Prefill is fast (~110 tok/s) — proves the GPU CUDA compute path itself is correct

### Why NVHOST=y Was Attempted (nvgpu 5.9.0 / 5.9.1) and Still Failed

`CONFIG_TEGRA_GK20A_NVHOST=y` uses host1x hardware syncpoints for `cudaStreamSynchronize`,
which would eliminate the per-token CPU polling. Both attempts ended with CUDA error 999 —
documented in full in **[Bug 14](#bug-14--cuda-error-999-persists-with-nvhost=y-nvgpu-590--591)**.

### nvgpu 5.9.3 — FAILED: Awk Pattern Never Matched (Source Has Flags on Two Lines)

nvgpu 5.9.3 booted successfully with NVHOST=y and `nvgpu_nvhost_syncpt_init` logged correctly.
All modules loaded: `host1x (O)`, `host1x_fence`, `nvmap`, `mc_utils`, `nvgpu`. But Ollama
still crashed with `CUDA error: unknown error` in `cudaStreamSynchronize` — same error 999.

**Root cause:** The `pkg.yaml` awk patch that was supposed to skip syncpt id=0 in
`nvhost_host1x.c` (`nvgpu_nvhost_get_syncpt_client_managed`) **never fired**.

The awk trigger pattern was:
```
/HOST1X_SYNCPT_CLIENT_MANAGED \| HOST1X_SYNCPT_GPU,/
```

But in the actual OE4T source (d530a48), the call spans **two lines**:
```c
sp = host1x_syncpt_alloc(host1x, HOST1X_SYNCPT_CLIENT_MANAGED |
                 HOST1X_SYNCPT_GPU, syncpt_name);
```

Awk processes one line at a time — the pattern required both flags on the same line → never
matched → `in_alloc` was never set → the `return host1x_syncpt_id(sp);` replacement never
happened → syncpt id=0 was returned to nvgpu → `NVGPU_ERRATA_SYNCPT_INVALID_ID_0` fired →
error 999.

### nvgpu 5.9.4 — Partial Fix: 2 → 1 nvrm Channel Error

`host1x_syncpt_id(sp)` appears exactly **once** in `nvhost_host1x.c`. Simplified awk to
match only on `return host1x_syncpt_id\(sp\);` — no two-condition state machine needed:

```bash
awk '/return host1x_syncpt_id\(sp\);/ { ...insert id=0 skip fix...; next } { print }'
```

Patch applied correctly and reduced `Can't initialize nvrm channel` errors from 2 → 1.
However, CUDA error 999 persisted. One channel still failed.

**Root cause of remaining error:** The nvgpu-level fix in `nvhost_host1x.c` holds id=0
temporarily and allocates id=1+ for that channel, but after `host1x_syncpt_put(sp_skip)`
the id=0 slot is freed again. Subsequent channels (or concurrent allocations) get id=0
again. The OOT host1x `syncpt.c` at commit `ccf7646c` marks syncpt[0] with `name="reserved"`
but does NOT set `kref=1` — so `host1x_syncpt_alloc`'s loop (`if kref_read(&sp->ref) == 0`)
can still return id=0 to any caller.

### Current Fix (nvgpu 5.9.5)

Fix at the **host1x level** rather than the nvgpu level. In `syncpt.c`'s init function,
the OOT host1x at `ccf7646c` does:

```c
if (host->syncpt_base == 0) {
    syncpt[0].name = kstrdup("reserved", GFP_KERNEL);
    // kref NOT initialized → kref_read() == 0 → still allocatable!
}
```

Add `kref_init(&syncpt[0].ref)` **before** the name assignment. This sets the refcount
to 1 permanently, so `host1x_syncpt_alloc`'s free-slot scan skips id=0 for all callers
(nvgpu channels, any direct userspace alloc, etc.):

```c
if (host->syncpt_base == 0) {
    kref_init(&syncpt[0].ref);    // ← added: permanently reserves id=0
    syncpt[0].name = kstrdup("reserved", GFP_KERNEL);
}
```

This matches what newer OE4T commits (e.g. `6e071c0`) already do. The fix is applied via
`sed` in the pkg.yaml prepare step, guarded to be idempotent.

### nvgpu 5.9.5 — FAILED: L4T nvhost subsystem missing (fundamental blocker)

**Tested result:** `kref_init` was already present in `ccf7646c` — patch skipped (idempotent).
Still 1 `Can't initialize nvrm channel` + CUDA error 999.

**True root cause (definitively found):** NVHOST=y requires the **L4T nvhost subsystem** — a
separate NVIDIA kernel module that provides:
- `/dev/nvhost-gpu` — legacy GPU channel device used by `libnvrm_host1x.so`
- `NVHOST_IOCTL_CTRL_SYNC_FILE_EXTRACT` — extracts a Linux sync_file from a syncpoint
- `NVHOST_IOCTL_CTRL_SYNCPT_WAITEX` — user-space syncpoint blocking wait

The CUDA runtime (`libnvrm_host1x.so`) calls these ioctls when `cudaStreamSynchronize`
uses syncpt-based channels (NVHOST=y mode). Without them, the syncpt wait never completes.

**Why they're missing:** The OE4T `linux-nv-oot` only contains the upstream-compatible
`host1x` driver (syncpt kernel API) and video capture drivers (nvdla, vi, isp, etc.).
The full L4T nvhost framework (`drivers/video/tegra/host/`) with the `/dev/nvhost-ctrl`
ioctl implementation is in NVIDIA's proprietary out-of-tree kernel package — not available
in the OE4T community fork.

**Conclusion: NVHOST=y is not achievable with OE4T + JetPack 6 CUDA runtime.** The L4T
nvhost kernel module would need to be ported/compiled separately (very complex, not pursued).

**Stable path: nvgpu 5.9.2 (NVHOST=n, ~7 tok/s).** All 5.9.3–5.9.5 NVHOST=y attempts are
archived here as documentation for future reference.

### nvgpu Version History

| Version | NVHOST | Change | CUDA | Decode |
|---------|--------|--------|------|--------|
| 5.5.0 | n | Strip `-pg`/`-mrecord-mcount` in clang-oot | ✅ | ~7 tok/s |
| 5.6.0 | n | Strip `-fpatchable-function-entry=*` in clang-oot | ✅ | ~7 tok/s |
| 5.7.0 | y | NVHOST=y — nvgpu fails to load (CRC + missing `host1x_fence_extract`) | ❌ | — |
| 5.8.0 | n | Stable NVHOST=n baseline | ✅ | ~7 tok/s |
| 5.9.0 | y | OOT host1x built — syncpt id=0 returned → ERRATA → error 999 | ❌ error 999 | — |
| 5.9.1 | y | HOST1X_SYNCPT_GPU flag removed → CLIENT_MANAGED not GPU-signable | ❌ error 999 | — |
| 5.9.2 | n | NVHOST=n + UBSAN fix (stable fallback) | ✅ | ~7 tok/s |
| 5.9.3 | y | OOT host1x + id=0 skip awk (flags on 2 lines → awk never matched) | ❌ error 999 | — |
| 5.9.4 | y | Fix awk: match `return host1x_syncpt_id(sp)` directly → 2→1 nvrm errors | ❌ error 999 | — |
| 5.9.5 | y | Fix host1x syncpt.c kref_init (already present) — L4T nvhost blocker confirmed | ❌ error 999 | — |
