#!/usr/bin/env bash
# 06-deploy-ollama.sh — Deploy Ollama LLM server on the Jetson cluster.
#
# Deploys dustynv/ollama:r36.4.0 with:
#   - Real JetPack r36.5 libs mounted from /var/lib/nvidia-tegra-libs/tegra/
#   - /dev hostPath for GPU device access
#   - NodePort 31434 for external access
#
# Prerequisite: JetPack libs must be installed (run 07-install-l4t-libs.sh first).
#
# Usage:
#   ./scripts/06-deploy-ollama.sh
#   OLLAMA_MODEL=qwen2.5:1.5b ./scripts/06-deploy-ollama.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE_IP="${NODE_IP:-192.168.1.50}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${REPO_ROOT}/kubeconfig}"
OLLAMA_MANIFEST="${REPO_ROOT}/manifests/ollama/ollama-deployment.yaml"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:1.5b}"
OLLAMA_PORT="${OLLAMA_PORT:-31434}"

check_kubectl
export KUBECONFIG="${KUBECONFIG_PATH}"

[[ -f "${OLLAMA_MANIFEST}" ]] || error "Ollama manifest not found: ${OLLAMA_MANIFEST}"

info "Creating ollama namespace with privileged pod-security..."
kubectl create namespace ollama --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace ollama \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite

info "Applying Ollama deployment..."
kubectl apply -f "${OLLAMA_MANIFEST}"

info "Waiting for Ollama pod to be Running..."
kubectl rollout status deployment/ollama -n ollama --timeout=120s

OLLAMA_URL="http://${NODE_IP}:${OLLAMA_PORT}"
info "Ollama is running at ${OLLAMA_URL}"

if [[ -n "${OLLAMA_MODEL}" ]]; then
  info "Pulling model ${OLLAMA_MODEL} (this may take a while)..."
  curl -fsSL -X POST "${OLLAMA_URL}/api/pull" \
    -H 'Content-Type: application/json' \
    -d "{\"name\": \"${OLLAMA_MODEL}\"}" \
    | grep -E '"status"|"error"' | tail -5
fi

info ""
info "Test inference:"
info "  curl http://${NODE_IP}:${OLLAMA_PORT}/api/generate \\"
info "    -d '{\"model\":\"${OLLAMA_MODEL}\",\"prompt\":\"Hello!\",\"stream\":false}'"
