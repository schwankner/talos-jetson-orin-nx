#!/usr/bin/env bash
# 05-bootstrap-cluster.sh — Bootstrap etcd and retrieve credentials after
#                            a fresh Talos install.
#
# Run ONCE per fresh cluster install — after 03-apply-config.sh --insecure.
# Do NOT run on an existing cluster (corrupts etcd).
#
# Usage:
#   ./scripts/05-bootstrap-cluster.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE_IP="${NODE_IP:-10.0.10.38}"
TALOSCONFIG_PATH="${TALOSCONFIG_PATH:-${REPO_ROOT}/talosconfig}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${REPO_ROOT}/kubeconfig}"

check_talosctl

info "Waiting for Talos API to be available at ${NODE_IP}..."
until talosctl --talosconfig "${TALOSCONFIG_PATH}" \
  --nodes "${NODE_IP}" --endpoints "${NODE_IP}" version &>/dev/null; do
  printf "."
  sleep 5
done
echo ""

info "Bootstrapping etcd (run once only)..."
talosctl --talosconfig "${TALOSCONFIG_PATH}" \
  --nodes "${NODE_IP}" --endpoints "${NODE_IP}" \
  bootstrap 2>&1 | tee /tmp/bootstrap.log

if grep -q "AlreadyExists" /tmp/bootstrap.log 2>/dev/null; then
  info "etcd already bootstrapped — skipping."
fi

info "Waiting for Kubernetes API to be available..."
sleep 10
until talosctl --talosconfig "${TALOSCONFIG_PATH}" \
  --nodes "${NODE_IP}" --endpoints "${NODE_IP}" \
  kubeconfig "${KUBECONFIG_PATH}" 2>/dev/null; do
  printf "."
  sleep 5
done
echo ""

info "Kubeconfig saved to ${KUBECONFIG_PATH}"

info "Waiting for node to become Ready..."
export KUBECONFIG="${KUBECONFIG_PATH}"
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  printf "."
  sleep 5
done
echo ""

kubectl get nodes
info "Cluster is ready."
