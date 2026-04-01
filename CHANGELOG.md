# Changelog

All notable changes to this project are documented in this file.

---

## [1.0.0] — 2026-04-01

### First stable release — Talos v1.12.6 + nvgpu 5.1.0 + CUDA verified

#### What works
- Talos Linux v1.12.6 on NVIDIA Jetson Orin NX (16 GB LPDDR5)
- Custom Linux kernel 6.18.18 (OE4T patches, Clang/LLVM toolchain)
- `nvidia-tegra-nvgpu 5.1.0` out-of-tree GPU driver (GA10B / Ampere)
- CUDA 12.6 compute via `dustynv/ollama:r36.4.0`
- GPU inference verified: **7–8 tok/s** decode, **~700 tok/s** prefill (qwen2.5:1.5b)
- Kubernetes v1.35.0 single-node cluster, node Ready within 95 s

#### Key technical fixes resolved in this release

| Fix | Commit | Root Cause |
|-----|--------|-----------|
| Kernel module signing key reproducibility | `c5cdbea` | `certs/Makefile` FORCE rule auto-regenerated `signing_key.pem` on every fresh build, causing all OOT modules to be rejected at boot with `module.sig_enforce=1`. **Fix:** `CONFIG_MODULE_SIG_KEY="certs/talos_signing_key.pem"` — custom filename has no auto-gen rule. |
| NVMe disappears after `apply-config` | `4ed2d46` | `talosctl apply-config --mode no-reboot` replaced the NVMe UKI with a freshly generated one (different signing key). **Fix:** UKI copy pod overwrites NVMe EFI after every config change. |
| PMU firmware `-ETXTBSY` | `4ed2d46` | rootfs inode `i_writecount > 0` blocks nvgpu firmware loader. **Fix:** copy firmware to XFS (NVMe) before loading. |
| `pmu_pkc_prod_sig.bin` missing | `4ed2d46` | Firmware extension had wrong path (`ga10b/` vs `nvidia/ga10b/`). **Fix:** baked into `nvidia-firmware-ext:v5` at correct path. |
| `devfreq` governor unavailable | `c869283` | nvgpu requested `nvgpu_scaling` (L4T-specific). **Fix:** patched to `simple_ondemand` in `pkg.yaml` build step. Non-fatal: GPU still runs at max clock via BPMP. |
| JetPack stub libraries in dustynv container | `4ed2d46` | `dustynv/ollama:r36.4.0` ships 0-byte stubs. **Fix:** real r36.5 libs mounted via `hostPath` from `/var/lib/nvidia-tegra-libs/tegra/`. |
| hdiutil mount point relative path bug | `c869283` | USB image script parsed hdiutil output incorrectly, mounting inside repo root. **Fix:** explicit `-mountpoint /Volumes/TALOSBOOT`. |

#### Component versions
| Component | Version |
|-----------|---------|
| Talos Linux | v1.12.6 |
| Kubernetes | v1.35.0 |
| Linux kernel | 6.18.18 (OE4T patches, Clang build) |
| nvidia-tegra-nvgpu | 5.1.0-6.18.18-talos |
| kernel-modules-clang | 1.1.0-6.18.18-talos |
| nvidia-firmware-ext | v5 (JetPack r36.5) |
| Ollama | 0.6.5 (dustynv/ollama:r36.4.0) |
| CUDA | 12.6 |

---

## Pre-release history

| Date | Tag | Notes |
|------|-----|-------|
| 2026-04-01 | nvgpu-5.1.0 | devfreq fix, signing key fix applied |
| 2026-03-31 | nvgpu-5.0.0 | First working CUDA inference |
| 2026-03-31 | nvgpu-4.0.0 | CUDA error 999 (nvhost syncpoint) — not working |
| 2026-03-30 | nvgpu-3.0.0 | Initial OE4T driver attempt |
