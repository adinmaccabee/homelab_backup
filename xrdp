#!/usr/bin/env bash
# NOTE: -e removed on purpose. This script runs many independent setup steps
# (theming, wallpapers, docker, xrdp); one cosmetic failure (e.g. a wallpaper
# 404) should not abort the whole run. We keep -u and pipefail.
set -uo pipefail

# --- sudo ---------------------------------------------------------------
sudo -v
# Keep sudo alive in the background for the duration of the script
( while true; do sudo -n true; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# Ask interactive questions up front, not buried after a long install.
read -p "VM name (run Get-VM in elevated PowerShell to list): " VMName </dev/tty

# --- xrdp / Hyper-V Enhanced Session Mode -------------------------------
sudo apt update -y
sudo apt upgrade -y
sudo apt install -y xrdp xorgxrdp

# Hyper-V integration daemons are OPTIONAL for Enhanced Session Mode.
# "hyperv-daemons" is the Fedora/RHEL package name and does NOT exist on
# Ubuntu/Mint; the equivalent lives in linux-cloud-tools-*.
sudo apt install -y "linux-cloud-tools-$(uname -r)" 2>/dev/null \
    || sudo apt install -y linux-cloud-tools-virtual 2>/dev/null \
    || sudo apt install -y linux-cloud-tools-generic 2>/dev/null \
    || echo "Note: linux-cloud-tools not found; skipping (not required for ESM)."

# Disable Wayland in GDM only if GDM is actually installed. Mint Cinnamon uses
# LightDM + X11 by default, so this is normally a no-op (kept for safety).
if [ -f /etc/gdm3/custom.conf ] && ! grep -q "WaylandEnable=false" /etc/gdm3/custom.conf; then
    printf '\n[daemon]\nWaylandEnable=false\n' | sudo tee -a /etc/gdm3/custom.conf >/dev/null
fi

# backup xrdp config
sudo cp -p /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak 2>/dev/null || true

# stop services before editing
sudo systemctl stop xrdp xrdp-sesman 2>/dev/null || true

# tweak xrdp.ini (note: some keys may already differ on newer xrdp; verify after)
sudo sed -i -e "s|^port=3389|port=3389 vsock://-1:3389|" \
            -e "s|^security_layer=negotiate|security_layer=rdp|" \
            -e "s|^crypt_level=high|crypt_level=none|" \
            -e "s|^autorun=.*|autorun=Xorg|" \
            -e "s|^bitmap_compression=true|bitmap_compression=false|" \
            -e "s|^username=ask|username=$(whoami)|" \
            /etc/xrdp/xrdp.ini

# enable & start xrdp
sudo systemctl enable --now xrdp

# load hv_sock (may be built into the kernel on modern Mint -> modprobe no-ops)
echo "hv_sock" | sudo tee /etc/modules-load.d/hv_sock.conf >/dev/null
sudo modprobe hv_sock 2>/dev/null || true

# allow xrdp to read the TLS cert
sudo adduser xrdp ssl-cert

echo "done"
echo
echo "Shut down the VM then, in elevated PowerShell on the host, run:"
echo "  Set-VMHost -EnableEnhancedSessionMode \$true"
echo "  Set-VM -VMName \"$VMName\" -EnhancedSessionTransportType HvSocket"
echo
echo "To verify, run:"
echo "  Get-VM -Name \"$VMName\" | Select-Object -ExpandProperty EnhancedSessionTransportType"
echo
echo -n "Shut down? [y/N] "
read -r answer </dev/tty
if [[ "$answer" =~ ^[Yy]$ ]]; then
    sudo systemctl poweroff
fi
