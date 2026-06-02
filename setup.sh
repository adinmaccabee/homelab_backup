#!/usr/bin/env bash
set -euo pipefail

# sudo
sudo -v
# Keep sudo alive in the background for the duration of the script
( while true; do sudo -n true; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
echo "Installing:"
echo "  Docker"
echo ""






# download and install Mint-Y-Yaru theme
wget -O /tmp/Mint-Y-Yaru.zip https://raw.githubusercontent.com/adinmaccabee/Mint-Y-Yaru/main/Mint-Y-Yaru.zip
mkdir -p ~/.themes
unzip -o /tmp/Mint-Y-Yaru.zip -d ~/.themes/

# download wallpapers
mkdir -p ~/.local/share/backgrounds/yaru
for wallpaper in bloom.png bloom_lockscreen.png bloom_server.png bloom_vm.png frutiger_aero.png geometric.png sele_ring.png; do
    wget -q -P ~/.local/share/backgrounds/yaru https://raw.githubusercontent.com/adinmaccabee/Mint-Y-Yaru/main/yaru-wallpapers/$wallpaper
done

# register wallpapers in Cinnamon background settings
sudo mkdir -p /usr/share/cinnamon-background-properties
sudo bash -c "cat > /usr/share/cinnamon-background-properties/Yaru.xml << XML
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE wallpapers SYSTEM \"gnome-wp-list.dtd\">
<wallpapers>
  <wallpaper deleted=\"false\">
    <name>Yaru</name>
    <filename>$HOME/.local/share/backgrounds/yaru/sele_ring.png</filename>
    <options>zoom</options>
  </wallpaper>
  <wallpaper deleted=\"false\">
    <name>Yaru</name>
    <filename>$HOME/.local/share/backgrounds/yaru/bloom.png</filename>
    <options>zoom</options>
  </wallpaper>
  <wallpaper deleted=\"false\">
    <name>Yaru</name>
    <filename>$HOME/.local/share/backgrounds/yaru/bloom_lockscreen.png</filename>
    <options>zoom</options>
  </wallpaper>
  <wallpaper deleted=\"false\">
    <name>Yaru</name>
    <filename>$HOME/.local/share/backgrounds/yaru/bloom_server.png</filename>
    <options>zoom</options>
  </wallpaper>
  <wallpaper deleted=\"false\">
    <name>Yaru</name>
    <filename>$HOME/.local/share/backgrounds/yaru/bloom_vm.png</filename>
    <options>zoom</options>
  </wallpaper>
  <wallpaper deleted=\"false\">
    <name>Yaru</name>
    <filename>$HOME/.local/share/backgrounds/yaru/frutiger_aero.png</filename>
    <options>zoom</options>
  </wallpaper>
  <wallpaper deleted=\"false\">
    <name>Yaru</name>
    <filename>$HOME/.local/share/backgrounds/yaru/geometric.png</filename>
    <options>zoom</options>
  </wallpaper>
</wallpapers>
XML"

# apply themes
gsettings set org.cinnamon.desktop.interface cursor-theme "Yaru"
gsettings set org.cinnamon.desktop.interface gtk-theme "Mint-Y-Yaru"
gsettings set org.cinnamon.desktop.wm.preferences theme "Mint-Y-Yaru"
gsettings set org.cinnamon.desktop.interface icon-theme "Mint-Y-Yaru"
gsettings set org.cinnamon.theme name "Mint-Y-Yaru"

# dark mode for Firefox
gsettings set org.gnome.desktop.interface gtk-theme "Mint-Y-Yaru"
gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" 2>/dev/null || true

# create Firefox profile if it doesn't exist, then set dark mode
firefox --headless --no-remote about:blank &
sleep 3
pkill -f "firefox --headless" 2>/dev/null
sleep 1
FIREFOX_PROFILE=$(find ~/.mozilla/firefox -maxdepth 1 -name "*default-release" -type d 2>/dev/null | head -1)
if [ -n "$FIREFOX_PROFILE" ]; then
    echo 'user_pref("ui.systemUsesDarkTheme", 1);' > "$FIREFOX_PROFILE/user.js"
    echo "Firefox dark mode applied to $FIREFOX_PROFILE"
fi

# set wallpaper
gsettings set org.cinnamon.desktop.background picture-uri "file://$HOME/.local/share/backgrounds/yaru/sele_ring.png"

# move panel to left
gsettings set org.cinnamon panels-enabled "['1:0:left']"

# calendar custom date format
CALENDAR_DIR="$HOME/.config/cinnamon/spices/calendar@cinnamon.org"
mkdir -p "$CALENDAR_DIR"
python3 -c "
import json, os
path = os.path.expanduser('$CALENDAR_DIR/13.json')
with open(path, 'r') as f:
    data = json.load(f)
data['use-custom-format']['value'] = True
data['custom-format']['value'] = '%H:%M'
data['custom-tooltip-format']['value'] = '%A, %B %e, %H:%M'
with open(path, 'w') as f:
    json.dump(data, f, indent=4)
"



# install docker
curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER && newgrp docker







# xrdp

echo "Installing:"
echo "  xrdp"

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
