#!/usr/bin/env bash
# common.sh — shared variables for all build scripts
# shellcheck disable=SC2034  # Variables are used by scripts that source this file
set -euo pipefail

# ── Registry ────────────────────────────────────────────────────────────────
REGISTRY="${REGISTRY:-10.0.10.24:5001}"
REGISTRY_DOCKER="${REGISTRY_DOCKER:-host.docker.internal:5001}"

# ── BuildKit layer cache (pushed to ghcr.io, shared across CI runs) ──────────
# mode=max caches ALL intermediate layers (kernel-build, llvm, etc.), not just
# the final image. When only nvgpu changes, the kernel compile is served from
# cache (~60 min → ~15 min). Override to "" to disable caching.
CACHE_REGISTRY="${CACHE_REGISTRY:-}"  # set to ghcr.io/<owner>/build-cache in CI

# ── Talos version ────────────────────────────────────────────────────────────
# Tracked by Renovate — update-talos.yaml is no longer used (removed).
TALOS_VERSION="${TALOS_VERSION:-v1.14.0}"

# ── siderolabs/pkgs pin — derived from TALOS_VERSION ─────────────────────────
# Talos records the exact pkgs commit it was built against in its own
# Makefile, as `PKGS ?= <git-describe>-g<sha>`. Reading it here means the pin
# can never desync from TALOS_VERSION again: whatever Renovate bumps it to,
# PKGS_COMMIT (and KERNEL_VERSION below) follows automatically.
# Override via env: PKGS_COMMIT=<sha> source scripts/common.sh
if [ -z "${PKGS_COMMIT:-}" ]; then
  PKGS_COMMIT="$(curl -fsSL \
    "https://raw.githubusercontent.com/siderolabs/talos/${TALOS_VERSION}/Makefile" \
    | grep '^PKGS ?=' | sed -E 's/^PKGS \?= .*-g([0-9a-f]+)$/\1/')"
  [ -z "${PKGS_COMMIT}" ] && { echo "[ERROR] Could not derive PKGS_COMMIT from Talos ${TALOS_VERSION} Makefile" >&2; exit 1; }
fi
PKGS_BRANCH="${PKGS_BRANCH:-release-$(echo "${TALOS_VERSION}" | sed 's/^v//' | cut -d. -f1,2)}"

# ── Kernel version — derived automatically from siderolabs/pkgs ──────────────
# Reads linux_version from the PINNED PKGS_COMMIT (not the branch HEAD!) so
# the kernel build inside the container matches what we expect. If we read
# from the branch HEAD and siderolabs bumps the kernel mid-release, our
# build container ships kernel X but the post-build path check looks for
# kernel Y → "[ERROR] nvgpu.ko not found in build output" (run #26171068759).
# Override via env: KERNEL_VERSION=6.x.y source scripts/common.sh
if [ -z "${KERNEL_VERSION:-}" ]; then
  KERNEL_VERSION="$(curl -fsSL \
    "https://raw.githubusercontent.com/siderolabs/pkgs/${PKGS_COMMIT}/Pkgfile" \
    | grep '^\s*linux_version:' | head -1 | sed 's/.*linux_version:\s*//' | tr -d ' ')"
  [ -z "${KERNEL_VERSION}" ] && { echo "[ERROR] Could not determine kernel version from pkgs@${PKGS_COMMIT}" >&2; exit 1; }
fi

# ── LLVM (Talos 1.13+) ──────────────────────────────────────────────────────
# LLVM_IMAGE and TOOLS_REV are defined in siderolabs/pkgs/Pkgfile (release-1.13+)
# and used directly by nvidia-tegra-nvgpu/pkg.yaml. No injection into Pkgfile needed.
LLVM_IMAGE="${LLVM_IMAGE:-ghcr.io/siderolabs/llvm}"  # informational only

# ── Extension versions ───────────────────────────────────────────────────────
NVGPU_VERSION="${NVGPU_VERSION:-5.12.0-drm-noshim}" # OE4T DRM stack (tegra-drm + host1x-nvhost + nvhwpm) → /dev/dri/renderD128 → CUDA; 5.12: patch files + KCFLAGS, conftest without -Werror
FIRMWARE_EXT_TAG="${FIRMWARE_EXT_TAG:-v5}"        # v1 / v2 / v3 / v4 / v5 (pmu_pkc_prod_sig.bin added)
KERNEL_MODULES_VERSION="${KERNEL_MODULES_VERSION:-1.3.0}"

# ── Derived image tags ───────────────────────────────────────────────────────
IMG_INSTALLER="${REGISTRY}/custom-installer:${TALOS_VERSION}-${KERNEL_VERSION}-nvgpu${NVGPU_VERSION}"
IMG_KERNEL_MODULES="${REGISTRY}/kernel-modules-clang:${KERNEL_MODULES_VERSION}-${KERNEL_VERSION}-talos"
IMG_NVGPU="${REGISTRY}/nvidia-tegra-nvgpu:${NVGPU_VERSION}-${KERNEL_VERSION}-talos"
IMG_FIRMWARE="${REGISTRY}/nvidia-firmware-ext:${FIRMWARE_EXT_TAG}"

# ── Paths ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"

KEYS_DIR="${REPO_ROOT}/keys"

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_docker() {
  docker info &>/dev/null || error "Docker is not running. Start Colima or Docker Desktop."
}

check_registry() {
  # ghcr.io and other remote registries are always HTTPS — Docker handles auth,
  # no need to ping via HTTP.
  if [[ "${REGISTRY}" == ghcr.io/* || "${REGISTRY}" == *.pkg.github.com/* ]]; then
    return 0
  fi
  curl -fsSL "http://${REGISTRY}/v2/_catalog" &>/dev/null \
    || error "Registry ${REGISTRY} is not reachable. Ensure Mac is on the Jetson network."
}

check_talosctl() {
  # Prefer ~/bin/talosctl (manually installed) over Homebrew version
  if [[ -x "${HOME}/bin/talosctl" ]]; then
    export PATH="${HOME}/bin:${PATH}"
  fi
  command -v talosctl &>/dev/null || error "talosctl not found. Install ${TALOS_VERSION}: https://github.com/siderolabs/talos/releases/tag/${TALOS_VERSION}"
}

check_kubectl() {
  command -v kubectl &>/dev/null || error "kubectl not found. Run: brew install kubectl"
}
