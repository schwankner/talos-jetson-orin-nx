# CLAUDE.md — Projekthinweise für Claude Code

## Flash-Befehle (USB-Image auf Stick schreiben)

Aktuelles Release: **v1.12.6-nvgpu5.9.5**
USB-Stick auf diesem Mac: **`/dev/disk8`** (15.5 GB, external)

### macOS

```bash
# 1. Image herunterladen
curl -L -o /tmp/talos-usb-nvgpu5.9.5.raw \
  https://github.com/schwankner/talos-jetson-orin-nx/releases/download/v1.12.6-nvgpu5.9.5/talos-usb-nvgpu5.9.5.raw

# 2. Disk unmounten (N = Disk-Nummer, aktuell 8)
diskutil unmountDisk /dev/disk8

# 3. Flashen mit Fortschrittsanzeige
sudo dd if=/tmp/talos-usb-nvgpu5.9.5.raw of=/dev/rdisk8 bs=4m status=progress && sync
```

### Linux

```bash
# 1. Image herunterladen
curl -L -o /tmp/talos-usb-nvgpu5.9.5.raw \
  https://github.com/schwankner/talos-jetson-orin-nx/releases/download/v1.12.6-nvgpu5.9.5/talos-usb-nvgpu5.9.5.raw

# 2. USB-Gerät prüfen
lsblk

# 3. Flashen (X = Gerät, z.B. sda)
sudo dd if=/tmp/talos-usb-nvgpu5.9.5.raw of=/dev/sdX bs=4M status=progress && sync
```

> **Hinweis:** Auf macOS `rdisk` statt `disk` verwenden (raw device, deutlich schneller).
> Disk-Nummer per `diskutil list` prüfen — USB-Stick erscheint als `external, physical`.

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
