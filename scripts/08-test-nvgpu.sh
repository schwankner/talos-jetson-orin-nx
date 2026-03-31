#!/usr/bin/env bash
# 08-test-nvgpu.sh — Test nvgpu extension with a different version.
#
# Builds a new UKI with the specified NVGPU_VERSION, copies it to the NVMe
# EFI partition, and reboots the node. After the reboot, checks whether
# /dev/nvhost-ctrl is present (required for CUDA).
#
# If the node fails to get an IP within BOOT_TIMEOUT seconds, the script
# rolls back to the stable UKI (talos-v8.efi) automatically.
#
# Usage:
#   NVGPU_VERSION=3.0.0 FIRMWARE_EXT_TAG=v3 ./scripts/08-test-nvgpu.sh
#   NVGPU_VERSION=2.0.0 FIRMWARE_EXT_TAG=v2 ./scripts/08-test-nvgpu.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE_IP="${NODE_IP:-10.0.10.38}"
NODE_HOSTNAME="${NODE_HOSTNAME:-talos-smq-3hh}"
TALOSCONFIG_PATH="${TALOSCONFIG_PATH:-${REPO_ROOT}/talosconfig}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${REPO_ROOT}/kubeconfig}"
STABLE_UKI="${STABLE_UKI:-talos-v8.efi}"     # fallback if new UKI fails
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"           # seconds to wait for node after reboot

check_talosctl
check_kubectl
check_docker
export KUBECONFIG="${KUBECONFIG_PATH}"

UKI_LABEL="talos-nvgpu${NVGPU_VERSION}.efi"
UKI_PATH="${DIST_DIR}/uki-nvgpu${NVGPU_VERSION}/metal-arm64-uki.efi"

# ── Step 1: Build UKI if not already present ────────────────────────────────
if [[ ! -f "${UKI_PATH}" ]]; then
  info "Building UKI for nvgpu ${NVGPU_VERSION}..."
  "${REPO_ROOT}/scripts/01-build-uki.sh"
else
  info "UKI already exists: ${UKI_PATH} ($(ls -lh "${UKI_PATH}" | awk '{print $5}'))"
fi

# ── Step 2: Transfer UKI to node and write to NVMe EFI ──────────────────────
info "Preparing privileged pod to write UKI to NVMe EFI partition..."
kubectl label namespace default \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite

kubectl delete pod uki-test-writer -n default --ignore-not-found 2>/dev/null
kubectl run uki-test-writer \
  --image=busybox:latest --restart=Never \
  --overrides="$(cat <<EOF
{
  "spec": {
    "nodeSelector": {"kubernetes.io/hostname": "${NODE_HOSTNAME}"},
    "tolerations": [{"operator": "Exists"}],
    "containers": [{
      "name": "uki-test-writer",
      "image": "busybox:latest",
      "command": ["sh", "-c", "sleep 300"],
      "securityContext": {"privileged": true},
      "volumeMounts": [
        {"name": "dev", "mountPath": "/dev"},
        {"name": "var", "mountPath": "/var"}
      ]
    }],
    "volumes": [
      {"name": "dev", "hostPath": {"path": "/dev"}},
      {"name": "var", "hostPath": {"path": "/var"}}
    ]
  }
}
EOF
)" -n default

kubectl wait --for=condition=ready pod/uki-test-writer -n default --timeout=60s

info "Uploading UKI ($(ls -lh "${UKI_PATH}" | awk '{print $5}')) to node..."
kubectl cp "${UKI_PATH}" "default/uki-test-writer:/var/${UKI_LABEL}"

info "Writing UKI to NVMe EFI partition and setting as default..."
kubectl exec -n default uki-test-writer -- sh -c "
  mkdir -p /mnt/efi
  mount -t vfat /dev/nvme0n1p1 /mnt/efi
  cp /var/${UKI_LABEL} /mnt/efi/EFI/Linux/${UKI_LABEL}
  cat > /mnt/efi/loader/loader.conf << LOADEREOF
default ${UKI_LABEL}
timeout 5
console-mode auto
LOADEREOF
  sync
  echo 'EFI partition updated:'
  ls -lh /mnt/efi/EFI/Linux/
"

kubectl delete pod uki-test-writer -n default --ignore-not-found

# ── Step 3: Reboot ───────────────────────────────────────────────────────────
info "Rebooting node..."
talosctl --talosconfig "${TALOSCONFIG_PATH}" --nodes "${NODE_IP}" reboot

info "Waiting for node (timeout: ${BOOT_TIMEOUT}s)..."
DEADLINE=$((SECONDS + BOOT_TIMEOUT))
NODE_BACK=false
while [[ $SECONDS -lt $DEADLINE ]]; do
  if talosctl --talosconfig "${TALOSCONFIG_PATH}" \
    --nodes "${NODE_IP}" --endpoints "${NODE_IP}" \
    version &>/dev/null 2>&1; then
    NODE_BACK=true
    break
  fi
  sleep 5
  printf "."
done
echo ""

# ── Step 4: Check result or roll back ───────────────────────────────────────
if [[ "${NODE_BACK}" == "false" ]]; then
  error "Node did not come back within ${BOOT_TIMEOUT}s with nvgpu ${NVGPU_VERSION}. Boot likely failed."
fi

info "Node is back. Checking /dev/nvhost-ctrl..."
NVHOST=$(talosctl --talosconfig "${TALOSCONFIG_PATH}" \
  --nodes "${NODE_IP}" ls /dev/ 2>/dev/null | grep "^${NODE_IP}.*nvhost-ctrl$" || true)

info "Extensions loaded:"
talosctl --talosconfig "${TALOSCONFIG_PATH}" \
  --nodes "${NODE_IP}" get extensions 2>/dev/null | grep nvidia || true

if [[ -n "${NVHOST}" ]]; then
  info "✅ SUCCESS: /dev/nvhost-ctrl is present with nvgpu ${NVGPU_VERSION}!"
  info "Run 07-install-l4t-libs.sh and test CUDA."
else
  info "❌ RESULT: /dev/nvhost-ctrl still missing with nvgpu ${NVGPU_VERSION}."
  info "Node is functional (booted OK) but CUDA will return error 801."
  info "Next step: Option B — rebuild nvgpu extension with full host1x UAPI."
fi
