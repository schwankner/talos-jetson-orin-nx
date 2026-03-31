#!/usr/bin/env bash
# 01-build-uki.sh — Build a Talos UKI (Unified Kernel Image) with all extensions.
#
# Usage:
#   ./scripts/01-build-uki.sh
#   NVGPU_VERSION=3.0.0 FIRMWARE_EXT_TAG=v3 ./scripts/01-build-uki.sh
#
# Output: dist/metal-arm64-uki.efi  (≈150 MB, contains kernel + all extensions)
#
# CI: set REGISTRY, TALOS_VERSION, NVGPU_VERSION via environment variables.
set -euo pipefail
source "$(dirname "$0")/common.sh"

OUT_DIR="${DIST_DIR}/uki-nvgpu${NVGPU_VERSION}"
UKI_OUT="${OUT_DIR}/metal-arm64-uki.efi"

check_docker
check_registry

info "Building UKI: Talos ${TALOS_VERSION}, nvgpu ${NVGPU_VERSION}, firmware ${FIRMWARE_EXT_TAG}"
info "Output: ${UKI_OUT}"

mkdir -p "${OUT_DIR}"

# Generate imager profile from template (substitutes registry and versions)
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

echo "${PROFILE}" | docker run --rm -i \
  --platform linux/arm64 \
  --add-host host.docker.internal:host-gateway \
  -v "${OUT_DIR}:/out" \
  "ghcr.io/siderolabs/imager:${TALOS_VERSION}" \
  -

info "UKI built: $(ls -lh "${UKI_OUT}" | awk '{print $5}') → ${UKI_OUT}"
