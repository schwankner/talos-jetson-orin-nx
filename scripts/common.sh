#!/usr/bin/env bash
# common.sh — shared variables for all build scripts
set -euo pipefail

# ── Registry ────────────────────────────────────────────────────────────────
REGISTRY="${REGISTRY:-192.168.1.100:5001}"
REGISTRY_DOCKER="${REGISTRY_DOCKER:-host.docker.internal:5001}"

# ── Talos version ────────────────────────────────────────────────────────────
TALOS_VERSION="${TALOS_VERSION:-v1.12.6}"
KERNEL_VERSION="${KERNEL_VERSION:-6.18.18}"

# ── Extension versions ───────────────────────────────────────────────────────
NVGPU_VERSION="${NVGPU_VERSION:-5.1.0}"          # 1.0.0 / 2.0.0 / 3.0.0 / 4.0.0 / 5.0.0 / 5.1.0 (devfreq fix)
FIRMWARE_EXT_TAG="${FIRMWARE_EXT_TAG:-v5}"        # v1 / v2 / v3 / v4 / v5 (pmu_pkc_prod_sig.bin added)
KERNEL_MODULES_VERSION="${KERNEL_MODULES_VERSION:-1.1.0}"

# ── Derived image tags ───────────────────────────────────────────────────────
IMG_INSTALLER="${REGISTRY}/custom-installer:${TALOS_VERSION}-${KERNEL_VERSION}"
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
  curl -fsSL "http://${REGISTRY}/v2/_catalog" &>/dev/null \
    || error "Registry ${REGISTRY} is not reachable. Ensure Mac is on the Jetson network."
}

check_talosctl() {
  command -v talosctl &>/dev/null || error "talosctl not found. Run: brew install siderolabsio/tap/talosctl"
}

check_kubectl() {
  command -v kubectl &>/dev/null || error "kubectl not found. Run: brew install kubectl"
}
