#!/usr/bin/env bash
# 00-setup-keys.sh — Manage the kernel module signing key pair.
#
# The signing key is embedded into the Talos kernel at build time and used to
# sign all out-of-tree kernel modules (nvgpu, nvmap, mc-utils, host1x, …).
# Kernel and modules MUST share the same key — mismatches cause
# "module.sig_enforce=1" rejections that break NVMe and networking.
#
# Key lifecycle:
#   • First run  : generates a fresh RSA-4096 key pair → saved to keys/
#   • Later runs : loads existing keys from keys/ (no regeneration)
#   • New key    : rm keys/signing_key.pem && ./scripts/00-setup-keys.sh
#
# After running this script the keys are copied to the two places the
# BuildKit stages expect them:
#   1. talos-pkgs/kernel/build/certs/   → kernel embeds the public key
#   2. talos-pkgs/nvidia-tegra-nvgpu/   → nvgpu modules are signed with it
#
# Usage:
#   ./scripts/00-setup-keys.sh               # ensure keys exist, copy to build dirs
#   FORCE_NEW_KEY=1 ./scripts/00-setup-keys.sh   # regenerate key (breaking change!)
set -euo pipefail
source "$(dirname "$0")/common.sh"

KEYS_DIR="${REPO_ROOT}/keys"
KEY_PEM="${KEYS_DIR}/signing_key.pem"
KEY_X509="${KEYS_DIR}/signing_key.x509"

KERNEL_CERTS_DIR="/tmp/talos-pkgs/kernel/build/certs"
NVGPU_DIR="/tmp/talos-pkgs/nvidia-tegra-nvgpu"

# ── 1. Regenerate if explicitly requested ─────────────────────────────────────
if [[ "${FORCE_NEW_KEY:-0}" == "1" ]]; then
  warn "FORCE_NEW_KEY=1 — generating NEW signing key."
  warn "You MUST rebuild kernel + ALL extensions after this!"
  warn "The running Talos node will reject modules signed with the old key."
  rm -f "${KEY_PEM}" "${KEY_X509}"
fi

# ── 2. Generate key pair if not present ───────────────────────────────────────
if [[ ! -f "${KEY_PEM}" ]]; then
  info "No signing key found at ${KEY_PEM} — generating new RSA-4096 key pair..."
  mkdir -p "${KEYS_DIR}"

  # Generate private key
  openssl genrsa -out "${KEY_PEM}" 4096 2>/dev/null
  # Generate self-signed certificate (same subject as Talos uses)
  openssl req -new -x509 -key "${KEY_PEM}" \
    -out "${KEY_X509}" \
    -days 36500 \
    -subj "/O=Sidero Labs, Inc./CN=Build time throw-away kernel key" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" 2>/dev/null

  SERIAL=$(openssl x509 -in "${KEY_X509}" -noout -serial | cut -d= -f2)
  info "New signing key generated: serial=${SERIAL}"
  info "Keys saved to: ${KEYS_DIR}/"
  warn "Rebuild kernel + all extensions to embed the new key!"
else
  SERIAL=$(openssl x509 -in "${KEY_X509}" -noout -serial 2>/dev/null | cut -d= -f2)
  info "Using existing signing key: serial=${SERIAL}"
fi

# ── 3. Copy keys to talos-pkgs build directories ──────────────────────────────
if [[ -d "${KERNEL_CERTS_DIR}" ]]; then
  cp "${KEY_PEM}"  "${KERNEL_CERTS_DIR}/signing_key.pem"
  cp "${KEY_X509}" "${KERNEL_CERTS_DIR}/signing_key.x509"
  info "Keys copied to ${KERNEL_CERTS_DIR}/"
else
  warn "Kernel certs dir not found: ${KERNEL_CERTS_DIR}"
  warn "Clone talos-pkgs to /tmp/talos-pkgs and run this script again before building."
fi

if [[ -d "${NVGPU_DIR}" ]]; then
  cp "${KEY_PEM}"  "${NVGPU_DIR}/signing_key.pem"
  cp "${KEY_X509}" "${NVGPU_DIR}/signing_key.x509"
  info "Keys copied to ${NVGPU_DIR}/"
else
  warn "nvgpu dir not found: ${NVGPU_DIR}"
  warn "Clone talos-pkgs to /tmp/talos-pkgs and run this script again before building."
fi

info "Signing key setup complete. Serial: ${SERIAL}"
