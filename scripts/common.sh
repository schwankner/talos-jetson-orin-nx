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
TALOS_VERSION="${TALOS_VERSION:-v1.12.6}"
KERNEL_VERSION="${KERNEL_VERSION:-6.18.18}"

# ── siderolabs/pkgs pin (must match the Talos release above) ─────────────────
PKGS_COMMIT="${PKGS_COMMIT:-a92bed5}"    # exact commit that produced Talos v1.12.6
PKGS_BRANCH="${PKGS_BRANCH:-release-1.12}"

# ── Custom LLVM build used by nvidia-tegra-nvgpu/pkg.yaml ────────────────────
# These vars must be injected into siderolabs/pkgs/Pkgfile before building
# (the official Pkgfile does not include them)
LLVM_IMAGE="${LLVM_IMAGE:-ghcr.io/siderolabs/llvm}"
LLVM_REV="${LLVM_REV:-v1.14.0-alpha.0}"

# ── Extension versions ───────────────────────────────────────────────────────
NVGPU_VERSION="${NVGPU_VERSION:-5.10.2}"         # .../ 5.10.0 (nvhost_ctrl_shim.ko first working version) / 5.10.1 (shim: debug logging, GET_VERSION=1, pr_err on syncpt lookup miss) / 5.10.2 (fix CUDA error 999: retry loop in nvgpu_nvhost_get_syncpt_client_managed)
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
  # Prefer ~/bin/talosctl (manually installed v1.12.6) over Homebrew version
  if [[ -x "${HOME}/bin/talosctl" ]]; then
    export PATH="${HOME}/bin:${PATH}"
  fi
  command -v talosctl &>/dev/null || error "talosctl not found. Install v1.12.6: https://github.com/siderolabs/talos/releases/tag/v1.12.6"
}

check_kubectl() {
  command -v kubectl &>/dev/null || error "kubectl not found. Run: brew install kubectl"
}
