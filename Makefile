# Makefile — Talos Linux on NVIDIA Jetson Orin NX
#
# All targets are thin wrappers around the scripts/ directory.
# Environment variables override defaults in scripts/common.sh:
#   REGISTRY         local OCI registry reachable from Jetson  (default: 192.168.1.100:5001)
#   TALOS_VERSION    Talos release                              (default: v1.12.6)
#   KERNEL_VERSION   Linux kernel version                       (default: 6.18.18)
#   NVGPU_VERSION    nvidia-tegra-nvgpu extension version       (default: 5.1.0)
#   NODE_IP          Jetson IP address                          (default: 192.168.1.50)

.PHONY: all keys build-extensions build-kernel uki usb help clean

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

# ── Clean build outputs (not committed anyway) ───────────────────────────────
clean:
	rm -rf dist/ imager-out-*/

# ── Help ─────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  Talos Linux — NVIDIA Jetson Orin NX (Seeed Studio reComputer J4012)"
	@echo ""
	@echo "  Build targets:"
	@echo "    make all              Build UKI + USB image (default)"
	@echo "    make build-extensions Full rebuild: nvgpu extension + kernel + installer (~90 min)"
	@echo "    make build-kernel     Kernel + installer only, skip nvgpu build (~30 min)"
	@echo "    make uki              Assemble UKI from registry images"
	@echo "    make usb              Create bootable USB disk image"
	@echo "    make keys             (Re-)generate kernel module signing key"
	@echo "    make clean            Remove dist/ and intermediate build output"
	@echo ""
	@echo "  Key overrides:"
	@echo "    REGISTRY=<host:port>  Local OCI registry (default: 192.168.1.100:5001)"
	@echo "    NVGPU_VERSION=<ver>   nvgpu extension version (default: 5.1.0)"
	@echo "    NODE_IP=<ip>          Jetson node IP (default: 192.168.1.50)"
	@echo ""
	@echo "  Alternative: use GitHub Actions (.github/workflows/build-usb.yaml)"
	@echo "    Push a tag → USB image built in the cloud, uploaded as release artifact"
	@echo ""
