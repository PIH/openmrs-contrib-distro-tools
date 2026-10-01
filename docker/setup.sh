#!/bin/bash
# Sets up Ubuntu (e.g. under WSL) for this tool: installs git and Docker, clones the tool into
# DISTRO_TOOLS_HOME (default: ~/openmrs-contrib-distro-tools), and puts its bin/ on PATH.
# Usage: curl -fsSL https://raw.githubusercontent.com/PIH/openmrs-contrib-distro-tools/main/docker/setup.sh | bash
set -euo pipefail
DISTRO_TOOLS_HOME="${DISTRO_TOOLS_HOME:-$HOME/openmrs-contrib-distro-tools}"
echo -e "Setting up environment...\n"

sudo apt-get update && sudo apt-get install -y git ca-certificates curl

if [ -d "$DISTRO_TOOLS_HOME/.git" ]; then
    git -C "$DISTRO_TOOLS_HOME" pull --ff-only
else
    git clone https://github.com/PIH/openmrs-contrib-distro-tools.git "$DISTRO_TOOLS_HOME"
fi

# Docker's apt repository and key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<SOURCES
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
SOURCES
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"

# bin/ holds openmrs-docker, openmrs-utils and openmrs-sdk.
line="export PATH=\"$DISTRO_TOOLS_HOME/bin:\$PATH\""
grep -qxF "$line" ~/.bashrc 2>/dev/null || echo "$line" >> ~/.bashrc

echo -e "\nDone! Please close this terminal window and start a new session."
