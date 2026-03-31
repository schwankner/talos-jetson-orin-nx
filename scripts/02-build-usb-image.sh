#!/usr/bin/env bash
# 02-build-usb-image.sh — Build a bootable USB disk image from a UKI.
#
# Usage:
#   ./scripts/02-build-usb-image.sh
#   NVGPU_VERSION=4.0.0 ./scripts/02-build-usb-image.sh
#
# Prerequisites: run 01-build-uki.sh first (or set UKI_PATH explicitly).
#
# Output: dist/talos-usb.raw  (4 GB GPT disk image, FAT32 EFI partition)
#         Ready to flash with: dd / Balena Etcher / Apple Configurator
#
# CI: runs as a Kubernetes Job on the Jetson node (see job definition below).
set -euo pipefail
source "$(dirname "$0")/common.sh"

UKI_PATH="${UKI_PATH:-${DIST_DIR}/uki-nvgpu${NVGPU_VERSION}/metal-arm64-uki.efi}"
USB_OUT="${DIST_DIR}/talos-usb-nvgpu${NVGPU_VERSION}.raw"
USB_SIZE_MB="${USB_SIZE_MB:-4096}"

[[ -f "${UKI_PATH}" ]] || error "UKI not found at ${UKI_PATH}. Run 01-build-uki.sh first."

check_docker

info "Building USB image from ${UKI_PATH}"
info "Output: ${USB_OUT} (${USB_SIZE_MB} MB)"

mkdir -p "${DIST_DIR}"

# Build USB disk image using a privileged Docker container
docker run --rm \
  --platform linux/arm64 \
  --privileged \
  -v "${UKI_PATH}:/uki.efi:ro" \
  -v "${DIST_DIR}:/out" \
  ubuntu:22.04 \
  bash -euxc "
    apt-get update -qq && apt-get install -y -qq dosfstools mtools gdisk
    IMG=/out/talos-usb-nvgpu${NVGPU_VERSION}.raw

    # Create 4 GB raw image with GPT + FAT32 EFI partition
    dd if=/dev/zero of=\$IMG bs=1M count=${USB_SIZE_MB} status=none
    sgdisk -Z \$IMG
    sgdisk -n 1:2048:+$((USB_SIZE_MB - 2))M -t 1:EF00 -c 1:'TALOS_EFI' \$IMG

    # Format EFI partition (using loop device)
    LOOP=\$(losetup -f --show -P \$IMG)
    mkfs.fat -F 32 -n TALOS_EFI \${LOOP}p1
    losetup -d \$LOOP

    # Mount and populate EFI partition
    LOOP=\$(losetup -f --show -P \$IMG)
    mkdir -p /mnt/usb
    mount \${LOOP}p1 /mnt/usb

    mkdir -p /mnt/usb/EFI/BOOT /mnt/usb/EFI/Linux

    # Copy UKI
    cp /uki.efi /mnt/usb/EFI/Linux/talos-nvgpu${NVGPU_VERSION}.efi
    # Also place as fallback boot path
    cp /uki.efi /mnt/usb/EFI/BOOT/BOOTAA64.EFI

    # Write loader.conf
    cat > /mnt/usb/loader/loader.conf << 'LOADEREOF'
default talos-nvgpu${NVGPU_VERSION}.efi
timeout 3
console-mode auto
LOADEREOF

    umount /mnt/usb
    losetup -d \$LOOP
    echo 'USB image built successfully.'
  "

info "USB image: $(ls -lh "${USB_OUT}" | awk '{print $5}') → ${USB_OUT}"
info ""
info "Flash to USB drive (replace /dev/sdX with your drive):"
info "  sudo dd if=${USB_OUT} of=/dev/sdX bs=4M status=progress && sync"
info "On macOS:"
info "  sudo dd if=${USB_OUT} of=/dev/rdiskN bs=4m && sync"
