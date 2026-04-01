#!/usr/bin/env bash
# 04-fix-nvme-boot.sh — Fix NVMe EFI UKI signing-key mismatch and set correct UEFI boot order.
#
# MUST be run after every fresh install, apply-config, or talosctl upgrade.
#
# Background:
#   apply-config --mode no-reboot and talosctl upgrade silently replace the NVMe EFI UKI
#   with a new build that has a DIFFERENT random signing key than the installed extensions.
#   With module.sig_enforce=1, mismatched modules are rejected → NVMe PCIe driver fails →
#   STATE/META "missing" → maintenance mode (6× "Loading of module with unavailable key is rejected").
#
#   Additionally, UEFI Boot0009 ("Talos Linux UKI") must be first in the boot order, otherwise
#   the Jetson boots the USB DataTraveler (Boot0008) even if NVMe is correctly configured.
#
# This script:
#   1. Creates a privileged pod on the Jetson node
#   2. Copies the correct UKI from USB (sda1) to BOTH NVMe EFI locations:
#      - nvme0n1p1/EFI/Linux/talos-nvgpu<VERSION>.efi  (loaded by systemd-boot)
#      - nvme0n1p1/EFI/BOOT/BOOTAA64.efi               (loaded by UEFI Boot0009)
#   3. Verifies all three checksums match
#   4. Sets EFI boot order: Boot0009 (NVMe) first
#
# Usage:
#   ./scripts/04-fix-nvme-boot.sh
#   NVGPU_VERSION=5.0.0 ./scripts/04-fix-nvme-boot.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE_HOSTNAME="${NODE_HOSTNAME:-talos-smq-3hh}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${REPO_ROOT}/kubeconfig}"
UKI_FILENAME="${UKI_FILENAME:-talos-nvgpu${NVGPU_VERSION}.efi}"

check_kubectl
[[ -f "${KUBECONFIG_PATH}" ]] || error "kubeconfig not found: ${KUBECONFIG_PATH}"

export KUBECONFIG="${KUBECONFIG_PATH}"

info "Labelling default namespace as privileged..."
kubectl label namespace default \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite

# Clean up any leftover pod from a previous run
kubectl delete pod fix-nvme-uki -n default --ignore-not-found 2>/dev/null || true

info "Creating privileged pod to fix NVMe EFI UKI and boot order..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: fix-nvme-uki
  namespace: default
spec:
  restartPolicy: Never
  tolerations:
  - operator: Exists
  nodeSelector:
    kubernetes.io/hostname: "${NODE_HOSTNAME}"
  containers:
  - name: worker
    image: alpine:3.19
    securityContext:
      privileged: true
    command:
    - sh
    - -c
    - |
      set -e
      apk add -q efibootmgr

      mkdir -p /mnt/nvme-efi /mnt/usb-efi
      mount /dev/nvme0n1p1 /mnt/nvme-efi
      mount /dev/sda1      /mnt/usb-efi

      USB_UKI=/mnt/usb-efi/EFI/BOOT/BOOTAA64.EFI
      [ -f "\${USB_UKI}" ] || { echo "ERROR: USB UKI not found at \${USB_UKI}"; exit 1; }
      USB_MD5=\$(md5sum "\${USB_UKI}" | cut -d' ' -f1)
      echo "USB UKI MD5: \${USB_MD5}"

      # Copy to BOTH NVMe EFI locations
      echo "Copying USB UKI → nvme0n1p1/EFI/Linux/${UKI_FILENAME}"
      mkdir -p /mnt/nvme-efi/EFI/Linux
      cp "\${USB_UKI}" "/mnt/nvme-efi/EFI/Linux/${UKI_FILENAME}"

      echo "Copying USB UKI → nvme0n1p1/EFI/BOOT/BOOTAA64.efi"
      mkdir -p /mnt/nvme-efi/EFI/BOOT
      cp "\${USB_UKI}" "/mnt/nvme-efi/EFI/BOOT/BOOTAA64.efi"
      sync

      # Verify all checksums match
      MD5_LINUX=\$(md5sum "/mnt/nvme-efi/EFI/Linux/${UKI_FILENAME}" | cut -d' ' -f1)
      MD5_BOOT=\$(md5sum "/mnt/nvme-efi/EFI/BOOT/BOOTAA64.efi" | cut -d' ' -f1)
      echo "Checksums (must all match):"
      echo "  USB:              \${USB_MD5}"
      echo "  NVMe EFI/Linux:   \${MD5_LINUX}"
      echo "  NVMe EFI/BOOT:    \${MD5_BOOT}"
      [ "\${USB_MD5}" = "\${MD5_LINUX}" ] && [ "\${USB_MD5}" = "\${MD5_BOOT}" ] \
        || { echo "ERROR: checksum mismatch!"; exit 1; }
      echo "All checksums match ✓"

      umount /mnt/nvme-efi /mnt/usb-efi

      # Fix EFI boot order: Boot0009 = "Talos Linux UKI" (NVMe) must be first.
      # Boot0009 points to nvme0n1p1 by GPT UUID 9215e99a-2dc1-49dd-821c-36781d7a0c78
      mkdir -p /sys/firmware/efi/efivars
      mount -t efivarfs efivarfs /sys/firmware/efi/efivars
      echo "Setting UEFI boot order: Boot0009 (NVMe) first..."
      efibootmgr --bootorder 0009,0001,0008,0004,0003,0002,0005,0007,0006
      echo "New boot order: \$(efibootmgr | grep BootOrder)"
      echo ""
      echo "DONE. Jetson will boot NVMe (Boot0009) on next restart."
    volumeMounts:
    - name: dev
      mountPath: /dev
  volumes:
  - name: dev
    hostPath:
      path: /dev
EOF

info "Waiting for fix pod to complete..."
kubectl wait --for=condition=ready pod/fix-nvme-uki -n default --timeout=60s
kubectl logs -f fix-nvme-uki -n default

POD_STATUS=$(kubectl get pod fix-nvme-uki -n default -o jsonpath='{.status.phase}')
kubectl delete pod fix-nvme-uki -n default --ignore-not-found

if [[ "${POD_STATUS}" != "Succeeded" ]]; then
  error "Fix pod failed (status: ${POD_STATUS}). Check logs above."
fi

info ""
info "NVMe EFI fix complete. Boot0009 (NVMe 'Talos Linux UKI') is now first."
info "USB remains plugged in as fallback — Jetson will boot NVMe next restart."
