#!/usr/bin/env bash
# 10-setup-cdi.sh — Set up Container Device Interface (CDI) for OOB CUDA access
#
# Implements the full CDI stack that allows any container to request
# GPU resources via:
#   resources:
#     limits:
#       nvidia.com/gpu: "1"
#
# without any manual device mounts, library mounts or initContainers.
#
# What this script does:
#   1. Applies the Talos machine config patch that enables CDI in containerd
#      (requires a staged node reboot — the script waits for the node to come back)
#   2. Deploys the nvidia-cdi-setup DaemonSet:
#        • Restores JetPack r36.5 libs (replaces gpu-libs-restore + install-l4t-libs)
#        • Copies GPU firmware to NVMe and fixes firmware_class.path
#        • Creates /dev/nvhost-ctrl symlink
#        • Writes /var/run/cdi/nvidia-jetson.yaml CDI spec
#   3. Deploys the nvidia-device-plugin DaemonSet (squat/generic-device-plugin)
#      that reports nvidia.com/gpu to kubelet and returns CDI device IDs on alloc
#   4. Removes the legacy nvidia-device-setup DaemonSet (kube-system) and the
#      standalone gpu-libs-restore DaemonSet if they exist
#   5. Deploys the CDI-based ollama-cdi.yaml (replaces ollama-deployment.yaml)
#   6. Pulls the default inference model and prints a test command
#
# Usage:
#   ./scripts/10-setup-cdi.sh
#   NODE_IP=10.0.10.38 OLLAMA_MODEL=qwen2.5:1.5b ./scripts/10-setup-cdi.sh
#
# Skip options (if already done):
#   SKIP_PATCH=1    ./scripts/10-setup-cdi.sh   # skip containerd config patch
#   SKIP_REBOOT=1   ./scripts/10-setup-cdi.sh   # skip waiting for node reboot
#   SKIP_OLLAMA=1   ./scripts/10-setup-cdi.sh   # skip Ollama deployment
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE_IP="${NODE_IP:-10.0.10.38}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${REPO_ROOT}/kubeconfig}"
TALOSCONFIG_PATH="${TALOSCONFIG_PATH:-${REPO_ROOT}/talosconfig}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:1.5b}"
OLLAMA_PORT="${OLLAMA_PORT:-31434}"

SKIP_PATCH="${SKIP_PATCH:-0}"
SKIP_REBOOT="${SKIP_REBOOT:-0}"
SKIP_OLLAMA="${SKIP_OLLAMA:-0}"

check_kubectl
export KUBECONFIG="${KUBECONFIG_PATH}"

# ── 1. Apply containerd CDI patch ──────────────────────────────────────────
if [[ "${SKIP_PATCH}" != "1" ]]; then
  check_talosctl
  export TALOSCONFIG="${TALOSCONFIG_PATH}"

  info "Applying containerd CDI config patch (staged — requires reboot)..."
  talosctl apply-config \
    --nodes "${NODE_IP}" \
    --patch "@${REPO_ROOT}/manifests/talos/machine-patch-cdi.yaml" \
    --mode staged

  if [[ "${SKIP_REBOOT}" != "1" ]]; then
    info "Rebooting node ${NODE_IP} to apply containerd CDI config..."
    talosctl reboot --nodes "${NODE_IP}"

    info "Waiting for node to go offline..."
    sleep 15

    info "Waiting for node to come back online (up to 3 min)..."
    DEADLINE=$(( $(date +%s) + 180 ))
    until talosctl version --nodes "${NODE_IP}" &>/dev/null; do
      if (( $(date +%s) > DEADLINE )); then
        error "Node ${NODE_IP} did not come back within 3 minutes"
      fi
      sleep 5
    done
    info "Node is back online"

    info "Waiting for Kubernetes node to be Ready (up to 3 min)..."
    kubectl wait node --all --for=condition=Ready --timeout=180s
  fi
else
  warn "SKIP_PATCH=1 — skipping containerd CDI patch and reboot"
fi

# ── 2. Remove legacy DaemonSets (replaced by nvidia-cdi-setup) ────────────
info "Removing legacy GPU setup DaemonSets (if present)..."
kubectl delete daemonset nvidia-device-setup \
  -n kube-system --ignore-not-found=true
kubectl delete daemonset gpu-libs-restore \
  -n ollama --ignore-not-found=true

# ── 3. Deploy nvidia-cdi-setup DaemonSet ──────────────────────────────────
info "Deploying nvidia-cdi-setup DaemonSet (firmware + libs + CDI spec)..."
kubectl apply -f "${REPO_ROOT}/manifests/gpu/cdi-setup.yaml"

info "Waiting for nvidia-cdi-setup DaemonSet to be ready..."
# Allow up to 5 minutes for the initContainer to download JetPack libs
kubectl rollout status daemonset/nvidia-cdi-setup \
  -n nvidia-system --timeout=300s

info "Verifying CDI spec was written..."
CDI_SPEC=$(kubectl exec -n nvidia-system \
  "$(kubectl get pod -n nvidia-system -l app=nvidia-cdi-setup \
     -o jsonpath='{.items[0].metadata.name}')" \
  -- cat /var/run/cdi/nvidia-jetson.yaml 2>/dev/null || true)

if echo "${CDI_SPEC}" | grep -q 'cdiVersion'; then
  DEVICE_COUNT=$(echo "${CDI_SPEC}" | grep -c 'path: /dev/' || true)
  info "CDI spec OK — ${DEVICE_COUNT} device node(s) registered"
else
  warn "CDI spec not found or empty — check nvidia-cdi-setup pod logs:"
  warn "  kubectl logs -n nvidia-system -l app=nvidia-cdi-setup -c cdi-writer"
fi

# ── 4. Deploy nvidia-device-plugin ────────────────────────────────────────
info "Deploying nvidia-device-plugin (squat/generic-device-plugin, nvidia.com/gpu)..."
kubectl apply -f "${REPO_ROOT}/manifests/gpu/device-plugin.yaml"

info "Waiting for nvidia-device-plugin DaemonSet to be ready..."
kubectl rollout status daemonset/nvidia-device-plugin \
  -n nvidia-system --timeout=60s

info "Verifying nvidia.com/gpu resource is visible on node..."
sleep 5   # give kubelet a moment to pick up the new resource
GPU_CAPACITY=$(kubectl get node -o jsonpath='{.items[0].status.capacity.nvidia\.com/gpu}' 2>/dev/null || echo "0")
if [[ "${GPU_CAPACITY}" == "1" ]]; then
  info "✓ nvidia.com/gpu: 1 visible on node"
else
  warn "nvidia.com/gpu not yet visible (capacity=${GPU_CAPACITY})"
  warn "Check plugin logs: kubectl logs -n nvidia-system -l app=nvidia-device-plugin"
  warn "Node may need a moment — continuing anyway"
fi

# ── 5. Deploy Ollama with CDI ──────────────────────────────────────────────
if [[ "${SKIP_OLLAMA}" != "1" ]]; then
  info "Deploying Ollama with CDI-based GPU access..."

  # Remove legacy ollama deployment if present (different resource structure)
  kubectl delete deployment ollama -n ollama --ignore-not-found=true

  kubectl apply -f "${REPO_ROOT}/manifests/ollama/ollama-cdi.yaml"

  info "Waiting for Ollama pod to be Running (up to 3 min)..."
  kubectl rollout status deployment/ollama -n ollama --timeout=180s

  # ── 6. Pull model + smoke test ──────────────────────────────────────────
  OLLAMA_URL="http://${NODE_IP}:${OLLAMA_PORT}"
  info "Ollama is running at ${OLLAMA_URL}"

  if [[ -n "${OLLAMA_MODEL}" ]]; then
    info "Pulling model ${OLLAMA_MODEL}..."
    curl -fsSL -X POST "${OLLAMA_URL}/api/pull" \
      -H 'Content-Type: application/json' \
      -d "{\"name\": \"${OLLAMA_MODEL}\"}" \
      | grep -E '"status"|"error"' | tail -5
  fi

  info ""
  info "Test GPU inference:"
  info "  curl http://${NODE_IP}:${OLLAMA_PORT}/api/generate \\"
  info "    -d '{\"model\":\"${OLLAMA_MODEL}\",\"prompt\":\"Hello!\",\"stream\":false}'"
  info ""
  info "Check GPU resource allocation:"
  info "  kubectl describe node | grep -A5 'nvidia.com/gpu'"
  info "  kubectl get pod -n ollama -o wide"
fi

info ""
info "CDI stack setup complete."
info ""
info "Useful diagnostics:"
info "  # CDI spec"
info "  kubectl exec -n nvidia-system \$(kubectl get pod -n nvidia-system -l app=nvidia-cdi-setup -o jsonpath='{.items[0].metadata.name}') -- cat /var/run/cdi/nvidia-jetson.yaml"
info ""
info "  # Device plugin logs"
info "  kubectl logs -n nvidia-system -l app=nvidia-device-plugin"
info ""
info "  # CDI setup logs"
info "  kubectl logs -n nvidia-system -l app=nvidia-cdi-setup -c cdi-writer"
info "  kubectl logs -n nvidia-system -l app=nvidia-cdi-setup -c restore-libs"
