# Contributing

Contributions are welcome — especially:

- Support for other Jetson modules (AGX Orin, Orin Nano, Xavier NX)
- Updated component versions (newer Talos, nvgpu, firmware)
- Bug reports via GitHub Issues
- Fixes for known limitations (see [Known Limitations](README.md#15-known-limitations--future-work))

## Guidelines

- Follow the [Conventional Commits](https://www.conventionalcommits.org/) spec
- Test changes with at least one full boot cycle (UART log encouraged)
- For kernel/module builds: verify key serial matches before submitting
  (`openssl x509 -in keys/signing_key.x509 -noout -serial`)
- License: all contributions are subject to the [Mozilla Public License v2.0](LICENSE)

## Generating your own signing key

If you fork this repo, generate a new key pair so your builds are independent:

```bash
./scripts/00-setup-keys.sh --force   # regenerates keys/signing_key.{pem,x509}
# Then rebuild the kernel and all extensions:
make build-extensions
```

## Development Setup

See [README — Quick Start](README.md#3-quick-start) for full prerequisites.
Minimum: Docker (with BuildKit), `talosctl`, `kubectl`, a local OCI registry, and a Jetson Orin NX.

## Reporting Bugs

Open a [GitHub Issue](https://github.com/schwankner/talos-jetson-orin-nx/issues) with:
- Talos version, nvgpu extension version
- Full UART boot log (or relevant dmesg excerpt)
- Steps to reproduce
