#!/bin/bash

# Set up logging
LOG_DIR="/var/log/docker-install"
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

LOG_FILE="$LOG_DIR/docker_install_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE"
chown root:adm "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_message "Starting Docker installation in cloud-init environment"

# Get the actual user running the script
ACTUAL_USER=$(who am i | awk '{print $1}')
log_message "Detected actual user running the script: $ACTUAL_USER"

# Get username from cloud-init nocloud data - try both locations
if DEFAULT_USER=$(grep -r "username:" /target/cdrom/nocloud/ 2>/dev/null | cut -d':' -f3 | xargs) || \
   DEFAULT_USER=$(grep -r "username:" /cdrom/nocloud/ 2>/dev/null | cut -d':' -f3 | xargs); then
    log_message "Detected username from cloud-init: $DEFAULT_USER"
else
    log_message "Warning: Could not detect username from cloud-init data"
fi

# Update package lists
log_message "Updating package lists..."
apt-get update 2>&1 | tee -a "$LOG_FILE"

# Install prerequisites
log_message "Installing prerequisites..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release 2>&1 | tee -a "$LOG_FILE"

# Add Docker's official GPG key
log_message "Adding Docker's GPG key..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>&1 | tee -a "$LOG_FILE"
chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository
log_message "Adding Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists again
log_message "Updating package lists with Docker repository..."
apt-get update 2>&1 | tee -a "$LOG_FILE"

# Install Docker Engine
log_message "Installing Docker Engine..."
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>&1 | tee -a "$LOG_FILE"

# Enable Docker service
log_message "Enabling Docker service..."
systemctl enable docker 2>&1 | tee -a "$LOG_FILE"
systemctl start docker 2>&1 | tee -a "$LOG_FILE"

# Create docker group and add users
groupadd -f docker
if [ -n "$DEFAULT_USER" ]; then
    log_message "Setting up docker group for cloud-init user: $DEFAULT_USER..."
    usermod -aG docker "$DEFAULT_USER"
fi
if [ -n "$ACTUAL_USER" ]; then
    log_message "Setting up docker group for actual user: $ACTUAL_USER..."
    usermod -aG docker "$ACTUAL_USER"
fi

# Set up Docker daemon configuration
log_message "Configuring Docker daemon..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m"
    }
}
EOF

# Check for NVIDIA GPU
log_message "Checking for NVIDIA GPU..."
if lspci | grep -i nvidia > /dev/null; then
    log_message "NVIDIA GPU detected. Installing NVIDIA Container Toolkit..."
    
    # Download and install CUDA keyring
    log_message "Installing CUDA keyring..."
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb 2>&1 | tee -a "$LOG_FILE"
    dpkg -i cuda-keyring_1.1-1_all.deb 2>&1 | tee -a "$LOG_FILE"
    rm cuda-keyring_1.1-1_all.deb 2>&1 | tee -a "$LOG_FILE"

    # Update package lists with CUDA repository
    apt-get update 2>&1 | tee -a "$LOG_FILE"

    # Install NVIDIA driver and CUDA toolkit
    log_message "Installing NVIDIA driver and CUDA toolkit..."
    apt-get install -y nvidia-driver-565 cuda-toolkit 2>&1 | tee -a "$LOG_FILE"

    # Add the NVIDIA Container Toolkit repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>&1 | tee -a "$LOG_FILE"
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list 2>&1 | tee -a "$LOG_FILE"

    # Update package lists
    apt-get update 2>&1 | tee -a "$LOG_FILE"

    # Install NVIDIA Container Toolkit
    apt-get install -y nvidia-container-toolkit 2>&1 | tee -a "$LOG_FILE"

    # Configure Docker daemon to use NVIDIA Container Toolkit
    nvidia-ctk runtime configure --runtime=docker 2>&1 | tee -a "$LOG_FILE"
fi

# Install git if not already installed
log_message "Installing git..."
apt-get install -y git 2>&1 | tee -a "$LOG_FILE"

# Clone the repository
log_message "Cloning AI toolbox deployment repository..."
git clone https://github.com/bmv234/ai-toolbox-container-deployment.git 2>&1 | tee -a "$LOG_FILE"

# Start dockge using docker compose
log_message "Starting dockge service..."
cd ai-toolbox-container-deployment/dockge && docker compose up -d 2>&1 | tee -a "$LOG_FILE"

# Set proper permissions for Docker socket
log_message "Setting Docker socket permissions..."
chmod 666 /var/run/docker.sock

log_message "Installation completed!"
log_message "The following has been set up:"
log_message "- Docker Engine installed and enabled"
if [ -n "$DEFAULT_USER" ]; then
    log_message "- Docker configured for cloud-init user: $DEFAULT_USER"
fi
if [ -n "$ACTUAL_USER" ]; then
    log_message "- Docker configured for actual user: $ACTUAL_USER"
fi
if lspci | grep -i nvidia > /dev/null; then
    log_message "- NVIDIA Container Toolkit installed and configured"
fi
log_message "- AI toolbox deployment repository cloned"
log_message "- Dockge service started"

log_message "Installation completed! System will now reboot to complete NVIDIA driver setup."
log_message "After reboot:"
log_message "- Dockge UI will be available at: http://localhost:5001"
log_message "- Use Dockge to manage other services like Ollama and Open WebUI"

log_message "Installation log has been saved to: $LOG_FILE"

# Reboot the system
log_message "Rebooting system..."
reboot
