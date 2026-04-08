#!/usr/bin/env bash
# gen-config.sh — Generate a fresh Talos machine config (controlplane.yaml + talosconfig).
#
# Run this once after a fresh Jetson flash (QSPI re-flash wipes Talos state).
# Output: controlplane.yaml + talosconfig in the repo root (both are gitignored).
#
# Usage:
#   ./scripts/gen-config.sh
#   NODE_IP=10.0.10.38 ./scripts/gen-config.sh
#   INSTALL_IMAGE=ghcr.io/mrmoor/custom-installer:v1.12.6-6.18.18 ./scripts/gen-config.sh
#
# After generating:
#   1. Boot Jetson from USB stick (maintenance mode)
#   2. ./scripts/apply-config.sh --insecure
#   3. talosctl bootstrap --talosconfig talosconfig -n $NODE_IP
#   4. kubectl --kubeconfig kubeconfig get nodes
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE_IP="${NODE_IP:-10.0.10.38}"
# Prefer ghcr.io installer (CI-built). Fall back to local registry if ghcr.io image not yet public.
INSTALL_IMAGE="${INSTALL_IMAGE:-ghcr.io/mrmoor/custom-installer:${TALOS_VERSION}-${KERNEL_VERSION}}"
INSTALL_DISK="${INSTALL_DISK:-/dev/nvme0n1}"
CLUSTER_NAME="${CLUSTER_NAME:-jetson-cluster}"
REGISTRY_LOCAL="${REGISTRY_LOCAL:-10.0.10.24:5001}"

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

# ── 2. Patch: local registry mirror (for device plugin etc.) ──────────────────
info "Patching: registry mirror ${REGISTRY_LOCAL}..."
talosctl machineconfig patch "${REPO_ROOT}/controlplane.yaml" \
  --patch "[{\"op\":\"add\",\"path\":\"/machine/registries\",\"value\":{\"mirrors\":{\"${REGISTRY_LOCAL}\":{\"endpoints\":[\"http://${REGISTRY_LOCAL}\"]}}}}]" \
  --output "${REPO_ROOT}/controlplane.yaml"

# ── 3. Patch: node labels ──────────────────────────────────────────────────────
info "Patching: node labels..."
talosctl machineconfig patch "${REPO_ROOT}/controlplane.yaml" \
  --patch '[{"op":"add","path":"/machine/nodeLabels","value":{"node.kubernetes.io/exclude-from-external-load-balancers":""}}]' \
  --output "${REPO_ROOT}/controlplane.yaml"

# ── 4. Update talosconfig with node IP ─────────────────────────────────────────
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
