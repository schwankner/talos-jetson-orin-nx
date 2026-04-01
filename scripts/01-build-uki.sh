#!/usr/bin/env bash
# 01-build-uki.sh — Build a Talos UKI (Unified Kernel Image) with all extensions.
#
# Usage:
#   ./scripts/01-build-uki.sh
#   NVGPU_VERSION=4.0.0 ./scripts/01-build-uki.sh
#
# Output: dist/uki-nvgpu<VERSION>/metal-arm64-uki.efi  (≈150 MB)
#
# Kernel note:
#   The stock ghcr.io imager contains the upstream GCC/GNU kernel which cannot
#   load our modules (different signing key). We extract the LLVM/Clang kernel
#   from our custom-installer registry image and inject it into a temporary
#   imager image before building the UKI.
#
# CI: set REGISTRY, TALOS_VERSION, NVGPU_VERSION via environment variables.
set -euo pipefail
source "$(dirname "$0")/common.sh"

OUT_DIR="${DIST_DIR}/uki-nvgpu${NVGPU_VERSION}"
UKI_OUT="${OUT_DIR}/metal-arm64-uki.efi"
CUSTOM_IMAGER_TAG="custom-imager:${TALOS_VERSION}-llvm"

check_docker
check_registry

info "Building UKI: Talos ${TALOS_VERSION}, nvgpu ${NVGPU_VERSION}, firmware ${FIRMWARE_EXT_TAG}"
info "Output: ${UKI_OUT}"

mkdir -p "${OUT_DIR}"

# ── 1. Ensure signing keys exist and are copied to build directories ──────────
# Keys must match what is embedded in the running kernel.
# See scripts/00-setup-keys.sh for key lifecycle management.
info "Checking signing keys..."
bash "$(dirname "$0")/00-setup-keys.sh"

# ── KEY MISMATCH WARNING ───────────────────────────────────────────────────────
# The UKI kernel comes from custom-installer, but nvgpu modules are signed by
# BuildKit. If custom-installer was built before 00-setup-keys.sh was run, or
# if the signing key changed, modules will be rejected at boot with
# "Loading of module with unavailable key is rejected".
#
# RULE: Whenever you rebuild nvgpu (run BuildKit), ALWAYS also rebuild
# custom-installer using the NEW vmlinuz from the BuildKit output.
# Use ./scripts/09-build-nvgpu.sh which does BOTH in the correct order.
#
# This script assumes custom-installer was already rebuilt correctly.
# To rebuild everything from scratch: ./scripts/09-build-nvgpu.sh

# ── 2. Build custom imager image with the LLVM/Clang kernel ──────────────────
# The custom-installer registry image stores our LLVM kernel at vmlinuz.efi.
# The stock imager only has the GCC kernel at vmlinuz, which cannot load
# our sig_enforce=1 modules (different compiler = different signing key embedded).
#
# IMPORTANT: custom-installer MUST have been rebuilt with 09-build-nvgpu.sh
# after any BuildKit nvgpu build. The kernel in custom-installer and the nvgpu
# modules MUST share the same signing key (74FD747A...) or modules are rejected.
#
# We extract vmlinuz.efi from the custom-installer and override vmlinuz in the
# stock imager image, then use that as the UKI builder.
info "Extracting LLVM kernel from custom-installer registry image..."
KERNEL_DIR=$(mktemp -d)
trap "rm -rf ${KERNEL_DIR}" EXIT

# Pull and extract kernel using docker (handles both Docker v2 and OCI manifest formats)
docker pull --platform linux/arm64 \
  "${REGISTRY_DOCKER}/custom-installer:${TALOS_VERSION}-${KERNEL_VERSION}" >/dev/null 2>&1

CONTAINER_ID=$(docker create --platform linux/arm64 \
  "${REGISTRY_DOCKER}/custom-installer:${TALOS_VERSION}-${KERNEL_VERSION}" 2>/dev/null)
mkdir -p "${KERNEL_DIR}/usr/install/arm64"
docker cp "${CONTAINER_ID}:/usr/install/arm64/vmlinuz.efi" \
  "${KERNEL_DIR}/usr/install/arm64/vmlinuz.efi" 2>/dev/null \
  || docker cp "${CONTAINER_ID}:/usr/install/arm64/vmlinuz" \
       "${KERNEL_DIR}/usr/install/arm64/vmlinuz.efi" 2>/dev/null \
  || error "LLVM kernel not found in custom-installer. Run ./scripts/09-build-nvgpu.sh first."
docker rm "${CONTAINER_ID}" >/dev/null 2>&1

info "  Kernel: $(ls -lh ${KERNEL_DIR}/usr/install/arm64/vmlinuz.efi | awk '{print $5, $6, $7, $8}')"

# Build minimal local imager image that contains our LLVM kernel at vmlinuz
info "Building temporary imager image with LLVM kernel..."
cat > "${KERNEL_DIR}/Dockerfile" <<IMGEOF
FROM ghcr.io/siderolabs/imager:${TALOS_VERSION}
COPY usr/install/arm64/vmlinuz.efi /usr/install/arm64/vmlinuz
IMGEOF
docker build --no-cache --platform linux/arm64 -t "${CUSTOM_IMAGER_TAG}" "${KERNEL_DIR}" >/dev/null 2>&1
info "  Imager image: ${CUSTOM_IMAGER_TAG}"

# ── 3. Generate imager profile ────────────────────────────────────────────────
PROFILE=$(cat <<EOF
arch: arm64
platform: metal
secureboot: false
version: ${TALOS_VERSION}
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
    imageRef: ${REGISTRY_DOCKER}/custom-installer:${TALOS_VERSION}-${KERNEL_VERSION}
    forceInsecure: true
  systemExtensions:
    - imageRef: ${REGISTRY_DOCKER}/kernel-modules-clang:${KERNEL_MODULES_VERSION}-${KERNEL_VERSION}-talos
      forceInsecure: true
    - imageRef: ${REGISTRY_DOCKER}/nvidia-tegra-nvgpu:${NVGPU_VERSION}-${KERNEL_VERSION}-talos
      forceInsecure: true
    - imageRef: ${REGISTRY_DOCKER}/nvidia-firmware-ext:${FIRMWARE_EXT_TAG}
      forceInsecure: true
customization:
  extraKernelArgs:
    - console=ttyTCU0,115200
    - firmware_class.path=/usr/lib/firmware
output:
  kind: uki
  outFormat: raw
EOF
)

# ── 4. Run imager to build UKI ────────────────────────────────────────────────
info "Running imager to assemble UKI..."
echo "${PROFILE}" | docker run --rm -i \
  --platform linux/arm64 \
  --add-host host.docker.internal:host-gateway \
  -v "${OUT_DIR}:/out" \
  "${CUSTOM_IMAGER_TAG}" \
  -

info "UKI built: $(ls -lh "${UKI_OUT}" | awk '{print $5}') → ${UKI_OUT}"
