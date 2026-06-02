#!/usr/bin/env bash
set -euo pipefail

# sudo
sudo -v
# Keep sudo alive in the background for the duration of the script
( while true; do sudo -n true; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# install xrdp

# prompt for VM name
read -p "VM name (run Get-VM in elevated PowerShell to list): " VMName

# update & install packages
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y hyperv-daemons xrdp xorgxrdp

#disabled wayland
echo -e "\n[daemon]\nWaylandEnable=false" | sudo tee -a /etc/gdm3/custom.conf >/dev/null

# backup xrdp config
sudo cp -p /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak 2>/dev/null || true

# stop services
sudo systemctl stop xrdp xrdp-sesman 2>/dev/null || true

# tweak xrdp.ini
sudo sed -i -e "s|^port=3389|port=3389 vsock://-1:3389|" \
            -e "s|^security_layer=negotiate|security_layer=rdp|" \
            -e "s|^crypt_level=high|crypt_level=non|" \
            -e "s|^autorun=.*|autorun=Xorg|" \
            -e "s|^bitmap_compression=true|bitmap_compression=false|" \
            -e "s|^username=ask|username=$(whoami)|" \
            /etc/xrdp/xrdp.ini

# enable & start xrdp
sudo systemctl enable --now xrdp

# load hv_sock
echo "hv_sock" | sudo tee /etc/modules-load.d/hv_sock.conf >/dev/null
sudo modprobe hv_sock 2>/dev/null || true

#sudo adduser xrdp ssl-cert
sudo adduser xrdp ssl-cert

echo "done"
echo
echo "Shut down the VM then, in elevated PowerShell, run:"
echo "  Set-VMHost -EnableEnhancedSessionMode \$true"
echo "  Set-VM -VMName \"$VMName\" -EnhancedSessionTransportType HvSocket"
echo
echo "To verify, run:"
echo "  Get-VM -Name \"$VMName\" | Select-Object -ExpandProperty EnhancedSessionTransportType"
echo
echo -n "Shut down? [y/N] "
read -r answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
    systemctl poweroff
else
    echo
fi
