#!/usr/bin/env bash
# gen-config.sh — Generate a fresh Talos machine config (controlplane.yaml + talosconfig).
#
# Run this once after a fresh Jetson flash (QSPI re-flash wipes Talos state).
# Output: controlplane.yaml + talosconfig in the repo root (both are gitignored).
#
# Usage:
#   ./scripts/gen-config.sh
#   NODE_IP=10.0.10.38 ./scripts/gen-config.sh
#   INSTALL_IMAGE=ghcr.io/schwankner/custom-installer:v1.12.6-6.18.18 ./scripts/gen-config.sh
#
# After generating:
#   1. Boot Jetson from USB stick (maintenance mode)
#   2. ./scripts/apply-config.sh --insecure
#   3. talosctl bootstrap --talosconfig talosconfig -n $NODE_IP
#   4. kubectl --kubeconfig kubeconfig get nodes
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE_IP="${NODE_IP:-10.0.10.38}"
# Installer from ghcr.io (CI-built, must be public — set visibility at github.com/schwankner/custom-installer → Package settings)
INSTALL_IMAGE="${INSTALL_IMAGE:-ghcr.io/schwankner/custom-installer:${TALOS_VERSION}-${KERNEL_VERSION}}"
INSTALL_DISK="${INSTALL_DISK:-/dev/nvme0n1}"
CLUSTER_NAME="${CLUSTER_NAME:-jetson-cluster}"
# Optional: local registry mirror for custom workload images (device-plugin, etc.)
# Leave empty to use only public registries.
REGISTRY_LOCAL="${REGISTRY_LOCAL:-}"

check_talosctl

info "Generating Talos config for cluster '${CLUSTER_NAME}'"
info "  Node IP:       ${NODE_IP}"
info "  Install image: ${INSTALL_IMAGE}"
info "  Install disk:  ${INSTALL_DISK}"

# ── 1. talosctl gen config ─────────────────────────────────────────────────────
talosctl gen config \
  "${CLUSTER_NAME}" \
  "https://${NODE_IP}:6443" \
  --install-disk "${INSTALL_DISK}" \
  --install-image "${INSTALL_IMAGE}" \
  --output-dir "${REPO_ROOT}" \
  --with-docs=false \
  --force

# talosctl gen config writes: controlplane.yaml, worker.yaml, talosconfig
# We only need controlplane.yaml + talosconfig for a single-node cluster.
rm -f "${REPO_ROOT}/worker.yaml"

info "Generated: controlplane.yaml + talosconfig"

# ── 2. Patch: node labels (+ optional local registry mirror) ──────────────────
# talosctl machineconfig patch uses strategic merge (not JSON6902) for machine configs.
PATCH_FILE=$(mktemp /tmp/talos-patch-XXXXXX.yaml)

if [[ -n "${REGISTRY_LOCAL}" ]]; then
  info "Patching: node labels + registry mirror ${REGISTRY_LOCAL}..."
  cat > "${PATCH_FILE}" <<EOF
machine:
  registries:
    mirrors:
      ${REGISTRY_LOCAL}:
        endpoints:
          - "http://${REGISTRY_LOCAL}"
  nodeLabels:
    node.kubernetes.io/exclude-from-external-load-balancers: ""
EOF
else
  info "Patching: node labels (no local registry mirror)..."
  cat > "${PATCH_FILE}" <<'EOF'
machine:
  nodeLabels:
    node.kubernetes.io/exclude-from-external-load-balancers: ""
EOF
fi

talosctl machineconfig patch "${REPO_ROOT}/controlplane.yaml" \
  --patch "@${PATCH_FILE}" \
  --output "${REPO_ROOT}/controlplane.yaml"
rm -f "${PATCH_FILE}"

# ── 3. Update talosconfig with node IP ─────────────────────────────────────────
talosctl --talosconfig "${REPO_ROOT}/talosconfig" \
  config endpoint "${NODE_IP}"
talosctl --talosconfig "${REPO_ROOT}/talosconfig" \
  config node "${NODE_IP}"

info ""
info "=== Config generated ==="
info "  controlplane.yaml  → apply with: ./scripts/apply-config.sh --insecure"
info "  talosconfig        → used by all talosctl commands"
info ""
info "Next steps:"
info "  1. Boot Jetson from USB stick (maintenance mode)"
info "  2. ./scripts/apply-config.sh --insecure"
info "  3. talosctl bootstrap --talosconfig talosconfig -n ${NODE_IP}"
info "  4. talosctl kubeconfig --talosconfig talosconfig -n ${NODE_IP} --force ."
info "  5. kubectl --kubeconfig kubeconfig get nodes"
