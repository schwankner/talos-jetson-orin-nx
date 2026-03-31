#!/usr/bin/env bash
# 07-install-l4t-libs.sh — Download real JetPack r36.5 userspace libraries
#                           onto the Jetson node via a Kubernetes Job.
#
# The dustynv/ollama image carries 0-byte stub libraries. This Job downloads
# the real libs from NVIDIA's public APT repo and stores them at:
#   /var/lib/nvidia-tegra-libs/tegra/  (on EPHEMERAL/NVMe)
#
# These libs persist across reboots but are LOST on a full cluster wipe.
# Re-run this script after every fresh install.
#
# Usage:
#   ./scripts/07-install-l4t-libs.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${REPO_ROOT}/kubeconfig}"
L4T_VERSION="${L4T_VERSION:-36.5.0-20260115194252}"
NAMESPACE="${NAMESPACE:-ollama}"
JOB_NAME="install-l4t-r365-libs"

check_kubectl
export KUBECONFIG="${KUBECONFIG_PATH}"

info "Installing JetPack r36.5 libs (version ${L4T_VERSION}) on Jetson node..."

# Delete any previous run
kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: install-libs
          image: ubuntu:22.04
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              apt-get update -qq && apt-get install -y -qq curl dpkg
              DEST=/nvidia-libs
              rm -rf \$DEST/tegra && mkdir -p \$DEST/tegra
              BASE="https://repo.download.nvidia.com/jetson/t234/pool/main/n"
              VER="${L4T_VERSION}"
              echo "Downloading JetPack packages (VER=\$VER)..."
              curl -fsSL -o /tmp/l4t-core.deb "\$BASE/nvidia-l4t-core/nvidia-l4t-core_\${VER}_arm64.deb"
              curl -fsSL -o /tmp/l4t-cuda.deb "\$BASE/nvidia-l4t-cuda/nvidia-l4t-cuda_\${VER}_arm64.deb"
              curl -fsSL -o /tmp/l4t-3d.deb   "\$BASE/nvidia-l4t-3d-core/nvidia-l4t-3d-core_\${VER}_arm64.deb"
              echo "Extracting libraries..."
              for pkg in l4t-core.deb l4t-cuda.deb l4t-3d.deb; do
                dpkg-deb -x /tmp/\$pkg /tmp/extract-\$pkg/
                find /tmp/extract-\$pkg -path '*/aarch64-linux-gnu/tegra/*' -type f \
                  -exec cp {} \$DEST/tegra/ \;
                find /tmp/extract-\$pkg -path '*/aarch64-linux-gnu/nvidia/*' -type f \
                  -exec cp {} \$DEST/tegra/ \;
              done
              echo "Installed \$(ls \$DEST/tegra/ | wc -l) libraries to \$DEST/tegra/"
              ls \$DEST/tegra/ | grep -E "libcuda|libnvrm" | head -10
          volumeMounts:
            - name: nvidia-libs
              mountPath: /nvidia-libs
      volumes:
        - name: nvidia-libs
          hostPath:
            path: /var/lib/nvidia-tegra-libs
            type: DirectoryOrCreate
EOF

info "Waiting for Job to complete (downloads ~50 MB)..."
kubectl wait --for=condition=complete job/"${JOB_NAME}" \
  -n "${NAMESPACE}" --timeout=300s

kubectl logs job/"${JOB_NAME}" -n "${NAMESPACE}" | tail -10
info "JetPack libs installed at /var/lib/nvidia-tegra-libs/tegra/ on the node."
info "Ollama mounts these at /usr/lib/aarch64-linux-gnu/nvidia/ in the container."
