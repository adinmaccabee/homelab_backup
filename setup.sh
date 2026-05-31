#!/usr/bin/env bash
set -euo pipefail

if ! id -nG "$(whoami)" | grep -qw sudo; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "Root password required to add user $(whoami) to group sudo."
        exec su -c "bash '$0'"
    else
        sudo usermod -aG sudo $1
        echo "Done adding user $1 to group sudo."
        # restart script as user with a fresh login shell...
        exec su - $1 -c "bash '$0'"
    fi
fi

cat > 01_docker.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo 
echo "Installing:"
echo "  Docker"

# update & install packages
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update

# install Docker Engine
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# start Docker
sudo systemctl enable --now docker

# add user to groups
sudo usermod -aG docker $USER

echo -n "Run 'sudo docker run hello-world' to test Docker? [y/N] "
read -r answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
    sudo docker run hello-world
else
    echo
fi
EOF

cat > 02_xrdp.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

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
EOF

chmod +x ./*.sh 2>/dev/null || true

newgrp sudo << 'EOF'
bash "./01_docker.sh" < /dev/tty && bash "./02_xrdp.sh" < /dev/tty
EOF
