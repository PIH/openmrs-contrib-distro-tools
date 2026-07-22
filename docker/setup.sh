echo -e "Setting up environment...\n"

# Install required tools
sudo apt-get update && sudo apt-get install -y git ca-certificates

# Clone this tool
git clone https://github.com/PIH/openmrs-contrib-distro-tools.git
cd openmrs-contrib-distro-tools

# Add Docker's official GPG key:
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# Install docker from newly added repo
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add user to the docker group
sudo usermod -aG docker $USER

# Add this tool's bin/ to PATH — holds only openmrs-docker/openmrs-sdk, not the whole checkout
echo 'export PATH="$HOME/openmrs-contrib-distro-tools/bin:$PATH"' >> ~/.bashrc

echo -e "\nDone! Please close this terminal window and start a new session."
