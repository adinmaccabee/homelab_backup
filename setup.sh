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

# --- Mint-Y-Yaru theme --------------------------------------------------
wget -O /tmp/Mint-Y-Yaru.zip https://raw.githubusercontent.com/adinmaccabee/Mint-Y-Yaru/main/Mint-Y-Yaru.zip
mkdir -p ~/.themes
unzip -o /tmp/Mint-Y-Yaru.zip -d ~/.themes/

# --- wallpapers ---------------------------------------------------------
mkdir -p ~/.local/share/backgrounds/yaru
for wallpaper in bloom.png bloom_lockscreen.png bloom_server.png bloom_vm.png frutiger_aero.png geometric.png sele_ring.png; do
    wget -q -P ~/.local/share/backgrounds/yaru https://raw.githubusercontent.com/adinmaccabee/Mint-Y-Yaru/main/yaru-wallpapers/$wallpaper
done

# --- register wallpapers in Cinnamon background settings ----------------
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

# --- apply themes -------------------------------------------------------
gsettings set org.cinnamon.desktop.interface cursor-theme "Yaru"
gsettings set org.cinnamon.desktop.interface gtk-theme "Mint-Y-Yaru"
gsettings set org.cinnamon.desktop.wm.preferences theme "Mint-Y-Yaru"
gsettings set org.cinnamon.desktop.interface icon-theme "Mint-Y-Yaru"
gsettings set org.cinnamon.theme name "Mint-Y-Yaru"

# dark mode (GTK / Firefox follow these)
gsettings set org.gnome.desktop.interface gtk-theme "Mint-Y-Yaru" 2>/dev/null || true
gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" 2>/dev/null || true

# --- Firefox dark mode --------------------------------------------------
if command -v firefox >/dev/null 2>&1; then
    firefox --headless --no-remote about:blank &
    sleep 3
    pkill -f "firefox --headless" 2>/dev/null || true
    sleep 1
    FIREFOX_PROFILE=$(find ~/.mozilla/firefox -maxdepth 1 -name "*default-release" -type d 2>/dev/null | head -1)
    if [ -n "$FIREFOX_PROFILE" ]; then
        echo 'user_pref("ui.systemUsesDarkTheme", 1);' > "$FIREFOX_PROFILE/user.js"
        echo "Firefox dark mode applied to $FIREFOX_PROFILE"
    fi
fi

# --- wallpaper & panel --------------------------------------------------
gsettings set org.cinnamon.desktop.background picture-uri "file://$HOME/.local/share/backgrounds/yaru/sele_ring.png"
gsettings set org.cinnamon panels-enabled "['1:0:left']"

# --- calendar custom date format ---------------------------------------
# The applet instance file is named <instance-id>.json (e.g. 13.json) and the
# number varies per machine, so we glob for it instead of hardcoding 13.json.
CALENDAR_DIR="$HOME/.config/cinnamon/spices/calendar@cinnamon.org"
if [ -d "$CALENDAR_DIR" ]; then
    python3 - "$CALENDAR_DIR" <<'PY'
import json, sys, glob, os
d = sys.argv[1]
updates = {
    'use-custom-format': True,
    'custom-format': '%H:%M',
    'custom-tooltip-format': '%A, %B %e, %H:%M',
}
for path in glob.glob(os.path.join(d, '*.json')):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        continue
    if not isinstance(data, dict):
        continue
    for k, v in updates.items():
        if isinstance(data.get(k), dict):
            data[k]['value'] = v
        else:
            data[k] = {'value': v}
    with open(path, 'w') as f:
        json.dump(data, f, indent=4)
    print('Updated calendar format in', path)
PY
else
    echo "Calendar applet config not found; skipping date format."
fi

# --- docker -------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sudo sh
fi
sudo usermod -aG docker "$USER"
# Do NOT run `newgrp docker` here: it execs a new shell and would halt the
# rest of this script. The docker group takes effect after you log out and
# back in (or run `newgrp docker` manually later).

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
