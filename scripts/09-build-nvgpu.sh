#!/usr/bin/env bash
# 09-build-nvgpu.sh — Build nvidia-tegra-nvgpu OCI extension and rebuild custom-installer.
#
# This script is the SINGLE entry point for building or rebuilding the nvgpu extension.
# It ensures the signing key is always set BEFORE the BuildKit build runs, so kernel
# and modules always share the same signing key embedded in the UKI.
#
# Key invariant (enforced by CONFIG_MODULE_SIG_KEY="certs/talos_signing_key.pem"):
#   keys/signing_key.pem  → single source of truth for the signing key
#   00-setup-keys.sh      → copies it as talos_signing_key.pem to kernel/build/certs/
#                           and as signing_key.pem to nvidia-tegra-nvgpu/
#   kernel-build          → embeds talos_signing_key.pem (make never auto-regenerates it)
#   nvidia-tegra-nvgpu    → signs all .ko with signing_key.pem from /pkg/
#   custom-installer      → gets the vmlinuz from this exact kernel-build
#   → UKI kernel and ALL extension modules ALWAYS share the same signing key
#
# Usage:
#   ./scripts/09-build-nvgpu.sh                       # full build (nvgpu + kernel + installer)
#   NVGPU_VERSION=5.1.0 ./scripts/09-build-nvgpu.sh
#   KERNEL_ONLY=1 ./scripts/09-build-nvgpu.sh         # kernel + installer only (skip nvgpu ~60min)
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

KERNEL_ONLY="${KERNEL_ONLY:-0}"

info "=== nvidia-tegra-nvgpu ${NVGPU_VERSION} build ==="
info "    Talos ${TALOS_VERSION}, kernel ${KERNEL_VERSION}"
[[ "${KERNEL_ONLY}" == "1" ]] && info "    Mode: KERNEL_ONLY (skipping nvgpu build)"

# ── Step 1: Ensure signing key is in place BEFORE BuildKit build ───────────────
# This copies keys/signing_key.pem to:
#   kernel/build/certs/talos_signing_key.pem  (kernel embeds it via CONFIG_MODULE_SIG_KEY)
#   nvidia-tegra-nvgpu/signing_key.pem        (nvgpu pkg.yaml signs modules with it)
# CONFIG_MODULE_SIG_KEY="certs/talos_signing_key.pem" ensures make never auto-overwrites it.
info "Step 1: Setting up signing keys (serial: $(openssl x509 -in ${REPO_ROOT}/keys/signing_key.x509 -noout -serial 2>/dev/null | cut -d= -f2))..."
bash "$(dirname "$0")/00-setup-keys.sh"

# ── Step 2: Verify talos-pkgs is set up ──────────────────────────────────────
[[ -d "${TALOS_PKGS_DIR}/nvidia-tegra-nvgpu" ]] \
  || error "talos-pkgs not found at ${TALOS_PKGS_DIR}. Clone siderolabs/pkgs@a92bed5 there first."
[[ -f "${TALOS_PKGS_DIR}/Pkgfile" ]] \
  || error "Pkgfile missing from ${TALOS_PKGS_DIR}."
[[ -f "${TALOS_PKGS_DIR}/kernel/build/config-arm64" ]] \
  || error "kernel/build/config-arm64 missing. Fetch from siderolabs/pkgs@a92bed5."

# Verify config-arm64 uses talos_signing_key.pem (not signing_key.pem which make auto-regenerates)
if ! grep -q 'CONFIG_MODULE_SIG_KEY="certs/talos_signing_key.pem"' \
    "${TALOS_PKGS_DIR}/kernel/build/config-arm64"; then
  error "kernel/build/config-arm64 must have CONFIG_MODULE_SIG_KEY=\"certs/talos_signing_key.pem\"
  Run: sed -i 's|CONFIG_MODULE_SIG_KEY=.*|CONFIG_MODULE_SIG_KEY=\"certs/talos_signing_key.pem\"|' \\
       ${TALOS_PKGS_DIR}/kernel/build/config-arm64"
fi

cd "${TALOS_PKGS_DIR}"

# ── Step 3: BuildKit build — nvidia-tegra-nvgpu (skip in KERNEL_ONLY mode) ────
if [[ "${KERNEL_ONLY}" != "1" ]]; then
  info "Step 2: Building nvidia-tegra-nvgpu (this takes ~60 min)..."
  info "    Log: ${BUILD_LOG}"
  mkdir -p "${NVGPU_OUT_DIR}"

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
else
  info "Step 2: Skipped (KERNEL_ONLY=1)"
fi

# ── Step 4: Build kernel and extract vmlinuz ───────────────────────────────────
# CONFIG_MODULE_SIG_KEY="certs/talos_signing_key.pem" guarantees make embeds OUR key.
# make has NO auto-generate rule for talos_signing_key.pem, so it can never overwrite it.
info "Step 3: Building kernel + extracting vmlinuz..."
mkdir -p "${KERNEL_OUT_DIR}"

docker buildx build \
  --builder talos-builder \
  --file Pkgfile \
  --target kernel-build \
  --platform linux/arm64 \
  --output "type=local,dest=${KERNEL_OUT_DIR}" \
  . 2>&1 | tee "${BUILD_LOG}.kernel"

VMLINUZ_SRC="${KERNEL_OUT_DIR}/src/arch/arm64/boot/vmlinuz.efi"
[[ -f "${VMLINUZ_SRC}" ]] || error "vmlinuz.efi not found in kernel output at ${VMLINUZ_SRC}"
info "    vmlinuz.efi: $(ls -lh ${VMLINUZ_SRC} | awk '{print $5}')"

# Verify the kernel embedded the correct key
KERNEL_KEY_SERIAL=$(openssl x509 -in "${KERNEL_OUT_DIR}/src/certs/talos_signing_key.x509" \
  -noout -serial 2>/dev/null | cut -d= -f2 || echo "UNKNOWN")
EXPECTED_SERIAL=$(openssl x509 -in "${REPO_ROOT}/keys/signing_key.x509" -noout -serial | cut -d= -f2)
if [[ "${KERNEL_KEY_SERIAL}" != "${EXPECTED_SERIAL}" ]]; then
  error "KEY MISMATCH: kernel has ${KERNEL_KEY_SERIAL}, expected ${EXPECTED_SERIAL}
  This should never happen with CONFIG_MODULE_SIG_KEY=certs/talos_signing_key.pem.
  Check that talos-pkgs/kernel/build/config-arm64 still has the correct setting."
fi
info "    Key verified: kernel serial ${KERNEL_KEY_SERIAL} matches keys/signing_key.x509 ✓"

# ── Step 5: Rebuild custom-installer with the new vmlinuz ──────────────────────
# This ensures the kernel embedded in the UKI has the SAME signing key as
# the nvgpu modules. Skipping this step would cause module rejection on boot.
info "Step 4: Rebuilding custom-installer with new vmlinuz..."
INSTALLER_BUILD_DIR=$(mktemp -d)
trap 'rm -rf "${INSTALLER_BUILD_DIR}"' EXIT

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

# ── Step 6: Package nvgpu as OCI extension (skip in KERNEL_ONLY mode) ──────────
if [[ "${KERNEL_ONLY}" != "1" ]]; then
  info "Step 5: Packaging nvidia-tegra-nvgpu:${NVGPU_VERSION}-${KERNEL_VERSION}-talos..."
  EXT_BUILD_DIR=$(mktemp -d)
  trap 'rm -rf "${INSTALLER_BUILD_DIR}" "${EXT_BUILD_DIR}"' EXIT

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
else
  info "Step 5: Skipped (KERNEL_ONLY=1) — nvgpu extension already in registry"
fi

# ── Done ────────────────────────────────────────────────────────────────────────
info ""
info "=== Build complete ==="
info "    Run next: ./scripts/01-build-uki.sh"
info "              ./scripts/02-build-usb-image.sh"
info "              [flash USB, boot, apply-config]"
