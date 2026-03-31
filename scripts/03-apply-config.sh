#!/usr/bin/env bash
# 03-apply-config.sh — Apply Talos machine config to the Jetson node.
#
# Use this for:
#   a) Fresh install (node in maintenance mode, NVMe STATE wiped)
#   b) Config update on running node (--mode=reboot)
#
# Usage:
#   # Fresh install (maintenance mode):
#   ./scripts/03-apply-config.sh --insecure
#
#   # Update running node:
#   ./scripts/03-apply-config.sh
#
# After a fresh install, run 04-fix-nvme-boot.sh to copy the full UKI to NVMe.
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE_IP="${NODE_IP:-10.0.10.38}"
CONFIG="${CONFIG:-${REPO_ROOT}/controlplane.yaml}"
TALOSCONFIG_PATH="${TALOSCONFIG_PATH:-${REPO_ROOT}/talosconfig}"
INSECURE="${1:-}"

check_talosctl
[[ -f "${CONFIG}" ]] || error "Config not found: ${CONFIG}"

if [[ "${INSECURE}" == "--insecure" ]]; then
  info "Applying config in MAINTENANCE MODE (insecure) to ${NODE_IP}"
  info "Node must be booted from USB with NVMe STATE wiped."
  talosctl --nodes "${NODE_IP}" --endpoints "${NODE_IP}" --insecure \
    apply-config --file "${CONFIG}"
else
  info "Applying config to running node ${NODE_IP} (mode: reboot)"
  [[ -f "${TALOSCONFIG_PATH}" ]] || error "talosconfig not found: ${TALOSCONFIG_PATH}"
  talosctl --talosconfig "${TALOSCONFIG_PATH}" \
    --nodes "${NODE_IP}" --endpoints "${NODE_IP}" \
    apply-config --file "${CONFIG}" --mode=reboot
fi

info "Config applied. Waiting for node to come back..."
until talosctl --talosconfig "${TALOSCONFIG_PATH}" \
  --nodes "${NODE_IP}" --endpoints "${NODE_IP}" version &>/dev/null; do
  printf "."
  sleep 5
done
echo ""
info "Node is back online."
