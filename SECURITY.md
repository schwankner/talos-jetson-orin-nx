# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest `main` | ✅ |
| Older tags | ❌ (no backports) |

## Reporting a Vulnerability

Please **do not** open a public GitHub Issue for security vulnerabilities.

Instead, report security issues by emailing the maintainer directly (see GitHub profile).

We aim to acknowledge reports within 72 hours and provide a fix or mitigation within 14 days.

## Scope

This repository contains build tooling and documentation — no server-side code.
The primary security surface is:

- **Signing key** (`keys/signing_key.pem`) — excluded from git via `.gitignore`.
  Each fork must generate its own key (`./scripts/00-setup-keys.sh --force`).
- **OCI registry** — the local registry is assumed to be on a private network.
  Do not expose it to the internet without authentication.
- **Talos machine config** (`controlplane.yaml`) — excluded from git via `.gitignore`.
  Contains cluster certificates and should be treated as a secret.
