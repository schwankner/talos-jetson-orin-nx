# CLAUDE.md — Projekthinweise für Claude Code

## CI-Workflow-Regel: Loop bei GitHub Actions Builds

**Immer wenn ein GitHub Actions Build getriggert wird**, sofort einen `/loop` mit 5-Minuten-
Intervall erstellen. Der Loop prüft den Build-Status und arbeitet automatisch weiter wenn CI
fertig ist (Upgrade, Tests, Dokumentation). Loop löschen sobald alle Folge-Aufgaben erledigt sind.

```
/loop — alle 5 Minuten: gh run view <RUN_ID> --repo schwankner/talos-jetson-orin
         → wenn concluded: talosctl upgrade + Performance messen + Doku updaten
         → Loop löschen wenn alles fertig
```

## Git-Regeln

- Commits **immer** GPG-signiert: `git commit -S`
- **Kein** `Co-Authored-By:`-Trailer
- Git-Email: `mrmoor4@googlemail.com`
- Commit-Messages **immer auf Englisch** — keine deutschen Wörter, kein Gemisch
- **Conventional Commits — erlaubte Types (immer, für alle Repos):**
  `feat`, `fix`, `chore`, `docs`, `perf`, `refactor`, `style`, `test`, `release`
  **NIEMALS** andere Types verwenden (z.B. `fixup`, `wip`, `update`, `add` — alles verboten)

## Projektziel

**GPU mit voller Leistung für CUDA-Inferenz auf Talos Linux / Jetson Orin NX.**

Aktueller Stand: **~23 tok/s** Decode (qwen2.5:0.5b, Ollama, nvgpu 5.10.5). Ziel: 20–30 tok/s ✅ erreicht.

**Lösung (nvgpu 5.10.0)**: `nvhost-ctrl-shim` Kernelmodul liefert `/dev/nvhost-ctrl`
mit `NVHOST_IOCTL_CTRL_SYNC_FENCE_CREATE` + `SYNC_FILE_EXTRACT` → Hardware-Syncpoint-
Interrupts für `cudaStreamSynchronize` statt CPU-Semaphore-Polling.

## Node-Update-Workflow (Standard — kein USB nötig)

Nach jedem erfolgreichen CI-Build **immer** per `talosctl upgrade` updaten.
Der Installer-Tag enthält die nvgpu-Version: `custom-installer:v<talos>-<kernel>-nvgpu<nvgpu>`.

```bash
# Aktuellen Installer-Tag aus common.sh ableiten
source scripts/common.sh
echo "ghcr.io/schwankner/custom-installer:${TALOS_VERSION}-${KERNEL_VERSION}-nvgpu${NVGPU_VERSION}"

# Node upgraden (--preserve behält Machine-Config)
talosctl upgrade \
  --nodes 10.0.10.38 \
  --talosconfig ./talosconfig \
  --image "ghcr.io/schwankner/custom-installer:${TALOS_VERSION}-${KERNEL_VERSION}-nvgpu${NVGPU_VERSION}" \
  --preserve
```

**Aktuell (nvgpu 5.10.0)**:
```bash
talosctl upgrade \
  --nodes 10.0.10.38 \
  --talosconfig ./talosconfig \
  --image ghcr.io/schwankner/custom-installer:v1.12.6-6.18.18-nvgpu5.10.0 \
  --preserve
```

> Nach dem Upgrade: CDI-Spec prüfen (`kubectl apply -f manifests/gpu/cdi-setup.yaml`)
> und Shim-Load verifizieren (`talosctl dmesg | grep nvhost-ctrl-shim`).

## Registry-Regel

**Ausschließlich `ghcr.io/schwankner` verwenden — NIEMALS die lokale Registry `10.0.10.24:5001`.**

Die lokale Registry existiert nur als Überbleibsel früherer Experimente und wird nicht mehr genutzt.
Alle Images liegen auf `ghcr.io/schwankner/`.

## Build-Regel: Immer GitHub Actions, nie lokal

**Wir bauen grundsätzlich in GitHub Actions — lokal wird nach Möglichkeit NIE gebaut.**

Gründe:
- Reproduzierbarkeit: CI-Builds sind deterministisch und nachvollziehbar
- Kein Zustand auf dem Entwickler-Mac (kein Colima, kein BuildKit-Cache, kein Platzmangel)
- Alle Artifacts werden automatisch in `ghcr.io/schwankner` gepusht

Lokal bauen **nur im absoluten Notfall** (z.B. CI nicht erreichbar), und dann niemals committen
ohne anschließend einen sauberen CI-Build zu triggern.

## Build-Workflow (wenn nvgpu oder Talos-Version ändert)

1. `NVGPU_VERSION` in `scripts/common.sh` bumpen
2. `nvidia-tegra-nvgpu/pkg.yaml` anpassen
3. Commit + Push → CI läuft (YAML-Check, Shellcheck)
4. Build manuell triggern: `gh workflow run "Build USB Image" --repo schwankner/talos-jetson-orin --ref main`
5. Nach ~90 min: `talosctl upgrade` (siehe oben)

Installer-Image wird automatisch in `ghcr.io/schwankner/custom-installer:<tag>` gepusht.
Da der Tag die nvgpu-Version enthält, wird bei jedem Version-Bump neu gebaut.

## Flash-Befehle (USB — nur für Erstinstallation oder Recovery)

USB-Stick auf diesem Mac: **`/dev/disk8`** (15.5 GB, external)

```bash
# Artifact herunterladen (nach workflow_dispatch Build)
gh run download <RUN_ID> --repo schwankner/talos-jetson-orin --dir /tmp/nvgpu-build

# Disk unmounten + flashen
diskutil unmountDisk /dev/disk8
sudo dd if=/tmp/nvgpu-build/talos-jetson-usb-main/talos-usb-nvgpu<VERSION>.raw \
  of=/dev/rdisk8 bs=4m status=progress && sync
```

## Jetson Node

| Eigenschaft | Wert |
|-------------|------|
| IP-Adresse | `10.0.10.38` |
| talosconfig | `./talosconfig` |
| kubeconfig | `./kubeconfig` |

```bash
# dmesg
talosctl dmesg --nodes 10.0.10.38 --talosconfig ./talosconfig

# kubectl
kubectl --kubeconfig ./kubeconfig get pods -A
```

## Deployment-Checklist nach nvgpu-Update

1. `talosctl upgrade` mit neuem Installer-Tag (siehe oben)
2. Warten bis Node ready: `talosctl health --nodes 10.0.10.38 --talosconfig ./talosconfig`
3. Shim geladen: `talosctl dmesg --nodes 10.0.10.38 --talosconfig ./talosconfig | grep nvhost-ctrl-shim`
4. CDI-Spec updaten: `kubectl apply -f manifests/gpu/cdi-setup.yaml`
5. CDI-Pod neu starten: `kubectl rollout restart ds/nvidia-cdi-setup -n nvidia-system`
6. Inference testen: `ollama run qwen2.5:0.5b "test"` → tok/s messen
