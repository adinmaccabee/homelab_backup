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

# sudo
sudo -v
# Keep sudo alive in the background for the duration of the script
( while true; do sudo -n true; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
echo "Installing:"
echo "  Docker"
echo ""


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

newgrp sudo << 'EOF'
bash "./01_docker.sh" < /dev/tty
EOF
