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
#   # → After bootstrap, run: ./scripts/04-fix-nvme-boot.sh
#
#   # Update running node:
#   ./scripts/03-apply-config.sh
#   # → 04-fix-nvme-boot.sh runs AUTOMATICALLY after config is applied.
#
# WHY: apply-config silently replaces the NVMe EFI UKI with a build that has
# a different signing key than our extensions (module.sig_enforce=1 → maintenance mode).
# 04-fix-nvme-boot.sh restores the correct USB UKI to both NVMe EFI locations.
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE_IP="${NODE_IP:-192.168.1.50}"
CONFIG="${CONFIG:-${REPO_ROOT}/controlplane.yaml}"
TALOSCONFIG_PATH="${TALOSCONFIG_PATH:-${REPO_ROOT}/talosconfig}"
INSECURE="${1:-}"

check_talosctl
[[ -f "${CONFIG}" ]] || error "Config not found: ${CONFIG}"

CDI_PATCH="${REPO_ROOT}/manifests/talos/machine-patch-cdi.yaml"
[[ -f "${CDI_PATCH}" ]] || error "CDI patch not found: ${CDI_PATCH}"

if [[ "${INSECURE}" == "--insecure" ]]; then
  info "Applying config in MAINTENANCE MODE (insecure) to ${NODE_IP}"
  info "Node must be booted from USB with NVMe STATE wiped."
  info "Including CDI machine patch (enables CDI in containerd)..."
  talosctl --nodes "${NODE_IP}" --endpoints "${NODE_IP}" --insecure \
    apply-config --file "${CONFIG}" \
    --config-patch "@${CDI_PATCH}"
else
  info "Applying config to running node ${NODE_IP} (mode: reboot)"
  info "Including CDI machine patch (enables CDI in containerd)..."
  [[ -f "${TALOSCONFIG_PATH}" ]] || error "talosconfig not found: ${TALOSCONFIG_PATH}"
  talosctl --talosconfig "${TALOSCONFIG_PATH}" \
    --nodes "${NODE_IP}" --endpoints "${NODE_IP}" \
    apply-config --file "${CONFIG}" --mode=reboot \
    --config-patch "@${CDI_PATCH}"
fi

info "Config applied. Waiting for node to come back..."
until talosctl --talosconfig "${TALOSCONFIG_PATH}" \
  --nodes "${NODE_IP}" --endpoints "${NODE_IP}" version &>/dev/null; do
  printf "."
  sleep 5
done
echo ""
info "Node is back online."

# ── Auto-fix NVMe boot after config update ────────────────────────────────────
# apply-config replaces the NVMe EFI UKI with a fresh random-signing-key build.
# Restore the correct UKI and EFI boot order automatically.
if [[ "${INSECURE}" != "--insecure" ]]; then
  info "Auto-running 04-fix-nvme-boot.sh to restore correct NVMe UKI..."
  bash "$(dirname "$0")/04-fix-nvme-boot.sh"
else
  warn "Fresh install mode: run './scripts/04-fix-nvme-boot.sh' AFTER bootstrapping the cluster."
fi
