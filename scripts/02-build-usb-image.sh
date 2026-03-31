#!/usr/bin/env bash
# 02-build-usb-image.sh — Build a bootable USB disk image from a UKI.
#
# Usage:
#   ./scripts/02-build-usb-image.sh
#   NVGPU_VERSION=5.0.0 ./scripts/02-build-usb-image.sh
#
# Prerequisites: run 01-build-uki.sh first (or set UKI_PATH explicitly).
#
# Output: dist/talos-usb-nvgpu<VERSION>.raw  (FAT32 MBR disk image)
#         Ready to flash with: dd / Balena Etcher
#
# On macOS uses hdiutil (native). On Linux uses losetup + mkfs.fat.
#
# Flash command (macOS — replace N with disk number from diskutil list):
#   sudo dd if=dist/talos-usb-nvgpu5.0.0.raw of=/dev/rdiskN bs=4m && sync
# Flash command (Linux):
#   sudo dd if=dist/talos-usb-nvgpu5.0.0.raw of=/dev/sdX bs=4M status=progress && sync
set -euo pipefail
source "$(dirname "$0")/common.sh"

UKI_PATH="${UKI_PATH:-${DIST_DIR}/uki-nvgpu${NVGPU_VERSION}/metal-arm64-uki.efi}"
USB_OUT="${DIST_DIR}/talos-usb-nvgpu${NVGPU_VERSION}.raw"
USB_SIZE_MB="${USB_SIZE_MB:-250}"

[[ -f "${UKI_PATH}" ]] || error "UKI not found at ${UKI_PATH}. Run 01-build-uki.sh first."

info "Building USB image from ${UKI_PATH}"
info "Output: ${USB_OUT} (${USB_SIZE_MB} MB)"

mkdir -p "${DIST_DIR}"

if [[ "$(uname)" == "Darwin" ]]; then
  # ── macOS: use hdiutil (loop devices not accessible inside Docker/Colima) ──
  WORK_DMG="${DIST_DIR}/.talos-usb-work.dmg"

  info "Creating ${USB_SIZE_MB}MB FAT32 image with hdiutil..."
  hdiutil create -size "${USB_SIZE_MB}m" -fs FAT32 -volname "TALOSBOOT" \
    "${WORK_DMG}" -ov >/dev/null

  MOUNT_POINT=$(hdiutil attach "${WORK_DMG}" | grep -E '/Volumes/' | awk '{print $NF}')
  info "Mounted at: ${MOUNT_POINT}"

  mkdir -p "${MOUNT_POINT}/EFI/BOOT"
  mkdir -p "${MOUNT_POINT}/loader"

  # Copy UKI as the default ARM64 fallback boot path
  cp "${UKI_PATH}" "${MOUNT_POINT}/EFI/BOOT/BOOTAA64.EFI"
  info "  Copied UKI → EFI/BOOT/BOOTAA64.EFI ($(ls -lh "${UKI_PATH}" | awk '{print $5}'))"

  # loader.conf — not strictly needed when using BOOTAA64.EFI as fallback
  cat > "${MOUNT_POINT}/loader/loader.conf" <<'LEOF'
default BOOTAA64.EFI
timeout 5
LEOF

  hdiutil detach "${MOUNT_POINT}" >/dev/null

  # Convert to raw (hdiutil adds .dmg extension automatically, then rename)
  hdiutil convert "${WORK_DMG}" -format UDRO -o "${USB_OUT}" -ov >/dev/null 2>&1 || true
  # hdiutil appends .dmg — rename if needed
  [[ -f "${USB_OUT}.dmg" ]] && mv "${USB_OUT}.dmg" "${USB_OUT}"
  rm -f "${WORK_DMG}"

else
  # ── Linux: use losetup + dosfstools ──────────────────────────────────────
  IMG="${USB_OUT}"
  dd if=/dev/zero of="${IMG}" bs=1M count="${USB_SIZE_MB}" status=none

  # MBR with single FAT32 partition
  parted -s "${IMG}" mklabel msdos
  parted -s "${IMG}" mkpart primary fat32 1MiB 100%
  parted -s "${IMG}" set 1 boot on

  LOOP=$(losetup -f --show -P "${IMG}")
  mkfs.fat -F 32 -n TALOSBOOT "${LOOP}p1"

  MNT=$(mktemp -d)
  mount "${LOOP}p1" "${MNT}"

  mkdir -p "${MNT}/EFI/BOOT" "${MNT}/loader"
  cp "${UKI_PATH}" "${MNT}/EFI/BOOT/BOOTAA64.EFI"
  cat > "${MNT}/loader/loader.conf" <<'LEOF'
default BOOTAA64.EFI
timeout 5
LEOF

  umount "${MNT}"
  losetup -d "${LOOP}"
  rm -rf "${MNT}"
fi

info "USB image built: $(ls -lh "${USB_OUT}" | awk '{print $5}') → ${USB_OUT}"
info ""
info "Flash to USB drive — identify your drive first:"
info "  macOS:  diskutil list   (find /dev/diskN)"
info "  Linux:  lsblk"
info ""
info "Flash command (macOS — replace N):"
info "  sudo dd if=${USB_OUT} of=/dev/rdiskN bs=4m && sync"
info "Flash command (Linux — replace X):"
info "  sudo dd if=${USB_OUT} of=/dev/sdX bs=4M status=progress && sync"
