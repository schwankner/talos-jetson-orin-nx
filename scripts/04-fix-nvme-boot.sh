#!/usr/bin/env bash
# 04-fix-nvme-boot.sh — Copy UKI to NVMe EFI partition so the Jetson boots
#                        without USB.
#
# MUST be run after every fresh install or talosctl upgrade, because the
# Talos installer writes an extension-free 18.8 MB UKI to NVMe that fails
# to boot on Jetson (missing kernel modules).
#
# This script:
#   1. Creates a privileged pod on the Jetson node
#   2. Copies the UKI from the USB EFI partition (sda1) to NVMe (nvme0n1p1)
#   3. Sets the UKI as the default boot entry in loader.conf
#
# Usage:
#   ./scripts/04-fix-nvme-boot.sh
#   NVGPU_VERSION=4.0.0 ./scripts/04-fix-nvme-boot.sh
#
# After this runs, the Jetson can cold-boot from NVMe without USB inserted.
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE_HOSTNAME="${NODE_HOSTNAME:-talos-smq-3hh}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${REPO_ROOT}/kubeconfig}"
UKI_FILENAME="${UKI_FILENAME:-talos-v8.efi}"   # name as stored on USB EFI partition

check_kubectl
[[ -f "${KUBECONFIG_PATH}" ]] || error "kubeconfig not found: ${KUBECONFIG_PATH}"

export KUBECONFIG="${KUBECONFIG_PATH}"

info "Labelling default namespace as privileged..."
kubectl label namespace default \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite

info "Creating privileged pod for EFI partition access..."
kubectl run efi-fix-job \
  --image=busybox:latest \
  --restart=Never \
  --overrides="$(cat <<EOF
{
  "spec": {
    "nodeSelector": {"kubernetes.io/hostname": "${NODE_HOSTNAME}"},
    "tolerations": [{"operator": "Exists"}],
    "containers": [{
      "name": "efi-fix-job",
      "image": "busybox:latest",
      "command": ["sh", "-c", "sleep 120"],
      "securityContext": {"privileged": true},
      "volumeMounts": [{"name": "dev", "mountPath": "/dev"}]
    }],
    "volumes": [{"name": "dev", "hostPath": {"path": "/dev"}}]
  }
}
EOF
)" \
  -n default 2>/dev/null || true

kubectl wait --for=condition=ready pod/efi-fix-job -n default --timeout=60s

info "Copying UKI from USB (sda1) to NVMe EFI (nvme0n1p1)..."
kubectl exec -n default efi-fix-job -- sh -c "
  mkdir -p /mnt/efi /mnt/usb
  mount -t vfat /dev/nvme0n1p1 /mnt/efi
  mount -t vfat /dev/sda1      /mnt/usb

  # Determine source UKI name on USB
  USB_UKI=\$(ls /mnt/usb/EFI/Linux/*.efi 2>/dev/null | head -1)
  [[ -z \"\${USB_UKI}\" ]] && USB_UKI=\$(ls /mnt/usb/EFI/BOOT/BOOTAA64.EFI 2>/dev/null | head -1)
  [[ -z \"\${USB_UKI}\" ]] && { echo 'ERROR: No UKI found on USB'; exit 1; }

  DEST_NAME=${UKI_FILENAME}
  echo \"Copying \$(basename \${USB_UKI}) (\$(du -sh \${USB_UKI} | cut -f1)) to NVMe /EFI/Linux/\${DEST_NAME}\"
  cp \"\${USB_UKI}\" \"/mnt/efi/EFI/Linux/\${DEST_NAME}\"

  # Set as default boot entry
  cat > /mnt/efi/loader/loader.conf << LOADEREOF
default ${UKI_FILENAME}
timeout 5
console-mode auto
LOADEREOF

  sync
  echo ''
  echo 'NVMe EFI partition contents:'
  ls -lh /mnt/efi/EFI/Linux/
  echo ''
  echo 'loader.conf:'
  cat /mnt/efi/loader/loader.conf
"

kubectl delete pod efi-fix-job -n default --ignore-not-found

info ""
info "Done. The Jetson will now boot from NVMe (${UKI_FILENAME}) without USB."
info "USB can be safely removed. Keep it as recovery medium."
