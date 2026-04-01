# Makefile — Talos Linux on NVIDIA Jetson Orin NX
#
# All targets are thin wrappers around the scripts/ directory.
# Environment variables override defaults in scripts/common.sh:
#   REGISTRY         local OCI registry reachable from Jetson  (default: 10.0.10.24:5001)
#   TALOS_VERSION    Talos release                              (default: v1.12.6)
#   KERNEL_VERSION   Linux kernel version                       (default: 6.18.18)
#   NVGPU_VERSION    nvidia-tegra-nvgpu extension version       (default: 5.1.0)
#   NODE_IP          Jetson IP address                          (default: 10.0.10.38)

.PHONY: all keys build-extensions build-kernel build-uki usb \
        cluster-apply cluster-bootstrap cluster-gpu-libs cluster-ollama \
        help clean

# ── Default: build UKI + USB image ──────────────────────────────────────────
all: uki usb

# ── Signing key (generate once, committed to repo) ───────────────────────────
keys:
	./scripts/00-setup-keys.sh

# ── Build system extensions + kernel (full rebuild, ~60–90 min) ──────────────
build-extensions:
	./scripts/09-build-nvgpu.sh

# ── Rebuild kernel only (skip nvgpu ~60 min) ────────────────────────────────
build-kernel:
	KERNEL_ONLY=1 ./scripts/09-build-nvgpu.sh

# ── Assemble UKI from registry images ────────────────────────────────────────
uki:
	./scripts/01-build-uki.sh

# ── Create bootable USB disk image ──────────────────────────────────────────
usb: uki
	./scripts/02-build-usb-image.sh

# ── Cluster lifecycle ────────────────────────────────────────────────────────
cluster-apply:
	./scripts/03-apply-config.sh

cluster-bootstrap:
	./scripts/05-bootstrap-cluster.sh

cluster-gpu-libs:
	./scripts/07-install-l4t-libs.sh

cluster-ollama:
	./scripts/06-deploy-ollama.sh

# ── Clean build outputs (not committed anyway) ───────────────────────────────
clean:
	rm -rf dist/ imager-out-*/

# ── Help ─────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  Talos Linux — NVIDIA Jetson Orin NX"
	@echo ""
	@echo "  Build targets:"
	@echo "    make all              Build UKI + USB image (default)"
	@echo "    make build-extensions Full rebuild: nvgpu extension + kernel + installer (~90 min)"
	@echo "    make build-kernel     Kernel + installer only, skip nvgpu build (~30 min)"
	@echo "    make uki              Assemble UKI from registry images"
	@echo "    make usb              Create bootable USB disk image"
	@echo "    make keys             (Re-)generate kernel module signing key"
	@echo ""
	@echo "  Cluster targets:"
	@echo "    make cluster-apply      Apply Talos machine config"
	@echo "    make cluster-bootstrap  Bootstrap etcd + retrieve credentials"
	@echo "    make cluster-gpu-libs   Install JetPack r36.5 userspace libraries"
	@echo "    make cluster-ollama     Deploy Ollama LLM server with GPU"
	@echo ""
	@echo "  Misc:"
	@echo "    make clean            Remove dist/ and intermediate build output"
	@echo ""
	@echo "  Key overrides:"
	@echo "    REGISTRY=<host:port>  Local OCI registry (default: 10.0.10.24:5001)"
	@echo "    NVGPU_VERSION=<ver>   nvgpu extension version (default: 5.1.0)"
	@echo "    NODE_IP=<ip>          Jetson node IP (default: 10.0.10.38)"
	@echo ""
