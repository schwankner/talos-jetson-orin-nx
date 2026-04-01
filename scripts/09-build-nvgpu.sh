#!/usr/bin/env bash
# 09-build-nvgpu.sh — Build nvidia-tegra-nvgpu OCI extension and rebuild custom-installer.
#
# This script is the SINGLE entry point for building or rebuilding the nvgpu extension.
# It ensures the signing key is always set BEFORE the BuildKit build runs, so kernel
# and modules always share the same signing key embedded in the UKI.
#
# Key invariant:
#   keys/signing_key.pem → copied to BuildKit certs BEFORE build
#   BuildKit compiles kernel WITH this key (embeds public cert)
#   BuildKit signs nvgpu modules WITH this key
#   vmlinuz extracted from build output → injected into custom-installer
#   → UKI kernel and nvgpu modules ALWAYS share the same signing key
#
# Usage:
#   ./scripts/09-build-nvgpu.sh                    # build with versions from common.sh
#   NVGPU_VERSION=5.1.0 ./scripts/09-build-nvgpu.sh
#
# Outputs:
#   - Registry: ${REGISTRY}/nvidia-tegra-nvgpu:${NVGPU_VERSION}-${KERNEL_VERSION}-talos
#   - Registry: ${REGISTRY}/custom-installer:${TALOS_VERSION}-${KERNEL_VERSION}  (updated kernel)
set -euo pipefail
source "$(dirname "$0")/common.sh"

TALOS_PKGS_DIR="${TALOS_PKGS_DIR:-/tmp/talos-pkgs}"
NVGPU_OUT_DIR="${NVGPU_OUT:-/tmp/nvgpu-${NVGPU_VERSION}-output}"
KERNEL_OUT_DIR="${KERNEL_OUT:-/tmp/kernel-${NVGPU_VERSION}-output}"
BUILD_LOG="/tmp/nvgpu-build-${NVGPU_VERSION}.log"

check_docker
check_registry

info "=== nvidia-tegra-nvgpu ${NVGPU_VERSION} build ==="
info "    Talos ${TALOS_VERSION}, kernel ${KERNEL_VERSION}"

# ── Step 1: Ensure signing key is in place BEFORE BuildKit build ───────────────
# This is critical: the kernel compiled by BuildKit MUST use the same signing
# key as all other extensions. Without this, modules are rejected with
# "Loading of module with unavailable key is rejected" → NVMe disappears →
# Talos enters maintenance mode.
info "Step 1: Setting up signing keys..."
bash "$(dirname "$0")/00-setup-keys.sh"

# ── Step 2: Verify talos-pkgs is set up ──────────────────────────────────────
[[ -d "${TALOS_PKGS_DIR}/nvidia-tegra-nvgpu" ]] \
  || error "talos-pkgs not found at ${TALOS_PKGS_DIR}. Clone siderolabs/pkgs@a92bed5 there first."
[[ -f "${TALOS_PKGS_DIR}/Pkgfile" ]] \
  || error "Pkgfile missing from ${TALOS_PKGS_DIR}."
[[ -f "${TALOS_PKGS_DIR}/kernel/build/config-arm64" ]] \
  || error "kernel/build/config-arm64 missing. Fetch from siderolabs/pkgs@a92bed5."

# ── Step 3: BuildKit build — nvidia-tegra-nvgpu ────────────────────────────────
info "Step 2: Building nvidia-tegra-nvgpu (this takes ~60 min)..."
info "    Log: ${BUILD_LOG}"
info "    Builder: talos-builder (insecure registry configured)"
mkdir -p "${NVGPU_OUT_DIR}"

cd "${TALOS_PKGS_DIR}"
docker buildx build \
  --builder talos-builder \
  --file Pkgfile \
  --target nvidia-tegra-nvgpu \
  --platform linux/arm64 \
  --output "type=local,dest=${NVGPU_OUT_DIR}" \
  . 2>&1 | tee "${BUILD_LOG}"

[[ -f "${NVGPU_OUT_DIR}/rootfs/usr/lib/modules/${KERNEL_VERSION}-talos/extra/nvidia-tegra/nvgpu.ko" ]] \
  || error "nvgpu.ko not found in build output!"

info "Build complete. nvgpu.ko: $(ls -lh ${NVGPU_OUT_DIR}/rootfs/usr/lib/modules/${KERNEL_VERSION}-talos/extra/nvidia-tegra/nvgpu.ko | awk '{print $5}')"

# ── Step 4: Extract vmlinuz from BuildKit kernel output ────────────────────────
# The BuildKit kernel was compiled with the signing key set in Step 1.
# We MUST use THIS kernel in custom-installer so kernel and modules share the key.
info "Step 3: Extracting vmlinuz from BuildKit kernel output..."
mkdir -p "${KERNEL_OUT_DIR}"

docker buildx build \
  --builder talos-builder \
  --file Pkgfile \
  --target kernel-build \
  --platform linux/arm64 \
  --output "type=local,dest=${KERNEL_OUT_DIR}" \
  . > "${BUILD_LOG}.kernel" 2>&1

VMLINUZ_SRC="${KERNEL_OUT_DIR}/src/arch/arm64/boot/vmlinuz.efi"
[[ -f "${VMLINUZ_SRC}" ]] || error "vmlinuz.efi not found in kernel output at ${VMLINUZ_SRC}"
info "    vmlinuz.efi: $(ls -lh ${VMLINUZ_SRC} | awk '{print $5}')"

# ── Step 5: Rebuild custom-installer with the new vmlinuz ──────────────────────
# This ensures the kernel embedded in the UKI has the SAME signing key as
# the nvgpu modules. Skipping this step would cause module rejection on boot.
info "Step 4: Rebuilding custom-installer with new vmlinuz..."
INSTALLER_BUILD_DIR=$(mktemp -d)
trap "rm -rf ${INSTALLER_BUILD_DIR}" EXIT

cp "${VMLINUZ_SRC}" "${INSTALLER_BUILD_DIR}/vmlinuz.efi"
cat > "${INSTALLER_BUILD_DIR}/Dockerfile" << 'IMGEOF'
FROM ghcr.io/siderolabs/installer:v1.12.6
COPY vmlinuz.efi /usr/install/arm64/vmlinuz.efi
IMGEOF

docker buildx build \
  --platform linux/arm64 \
  -t "${REGISTRY_DOCKER}/custom-installer:${TALOS_VERSION}-${KERNEL_VERSION}" \
  --push \
  "${INSTALLER_BUILD_DIR}/"

info "    custom-installer pushed: ${REGISTRY_DOCKER}/custom-installer:${TALOS_VERSION}-${KERNEL_VERSION}"

# ── Step 6: Package nvgpu as OCI extension ─────────────────────────────────────
info "Step 5: Packaging nvidia-tegra-nvgpu:${NVGPU_VERSION}-${KERNEL_VERSION}-talos..."
EXT_BUILD_DIR=$(mktemp -d)
trap "rm -rf ${INSTALLER_BUILD_DIR} ${EXT_BUILD_DIR}" EXIT

cat > "${EXT_BUILD_DIR}/manifest.yaml" << EOF
version: v1alpha1
metadata:
  name: nvidia-tegra-nvgpu
  version: ${NVGPU_VERSION}-${KERNEL_VERSION}-talos
  author: custom-build
  description: NVIDIA nvgpu GPU driver for Jetson Orin NX (OE4T patches-r36.5, Clang build)
  compatibility:
    talos:
      version: ">= 1.12.6"
EOF

cat > "${EXT_BUILD_DIR}/Dockerfile" << 'EXTEOF'
FROM scratch
COPY manifest.yaml /manifest.yaml
COPY rootfs /rootfs
EXTEOF

cp -r "${NVGPU_OUT_DIR}/rootfs" "${EXT_BUILD_DIR}/rootfs"

docker buildx build \
  --platform linux/arm64 \
  -t "${REGISTRY_DOCKER}/nvidia-tegra-nvgpu:${NVGPU_VERSION}-${KERNEL_VERSION}-talos" \
  --push \
  "${EXT_BUILD_DIR}/"

info "    nvidia-tegra-nvgpu pushed: ${REGISTRY_DOCKER}/nvidia-tegra-nvgpu:${NVGPU_VERSION}-${KERNEL_VERSION}-talos"

# ── Done ────────────────────────────────────────────────────────────────────────
info ""
info "=== Build complete ==="
info "    Run next: ./scripts/01-build-uki.sh"
info "              ./scripts/02-build-usb-image.sh"
info "              [flash USB, boot, apply-config]"
