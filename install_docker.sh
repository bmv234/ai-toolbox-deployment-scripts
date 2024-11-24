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

# Detect the default user
# First try to get it from cloud-init
if [ -f /run/cloud-init/cloud-init-run-module-once.lock ]; then
    DEFAULT_USER=$(grep -oP 'default_username: \K.*' /etc/cloud/cloud.cfg 2>/dev/null || true)
fi

# If not found in cloud-init, try to find the first non-root user with home directory
if [ -z "$DEFAULT_USER" ]; then
    DEFAULT_USER=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd | head -n 1)
fi

# If still not found, look for any user with sudo privileges
if [ -z "$DEFAULT_USER" ]; then
    DEFAULT_USER=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | head -n 1)
fi

# Verify we found a user
if [ -z "$DEFAULT_USER" ]; then
    log_message "Error: Could not detect default user. Please specify user manually."
    exit 1
fi

log_message "Detected default user: $DEFAULT_USER"

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

# Create docker group and add default user
log_message "Setting up docker group for $DEFAULT_USER..."
groupadd -f docker
usermod -aG docker "$DEFAULT_USER"

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
    
    # Install required packages
    apt-get install -y nvidia-driver-535 2>&1 | tee -a "$LOG_FILE"

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

# Pull Docker images
log_message "Pulling required Docker images..."
docker pull ollama/ollama 2>&1 | tee -a "$LOG_FILE"
docker pull ghcr.io/open-webui/open-webui:cuda 2>&1 | tee -a "$LOG_FILE"

# Create containers (they will start automatically on boot due to --restart always)
log_message "Creating containers..."
docker create \
    --name ollama \
    --restart always \
    -v ollama:/root/.ollama \
    -p 11434:11434 \
    ollama/ollama 2>&1 | tee -a "$LOG_FILE"

docker create \
    --name open-webui \
    --restart always \
    -p 3000:8080 \
    --add-host=host.docker.internal:host-gateway \
    -v open-webui:/app/backend/data \
    -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
    ghcr.io/open-webui/open-webui:cuda 2>&1 | tee -a "$LOG_FILE"

# Set proper permissions for Docker socket
log_message "Setting Docker socket permissions..."
chmod 666 /var/run/docker.sock

log_message "Installation completed!"
log_message "The following has been set up:"
log_message "- Docker Engine installed and enabled"
log_message "- Docker configured for user: $DEFAULT_USER"
log_message "- Docker images pulled"
log_message "- Containers created with auto-restart policy"
if lspci | grep -i nvidia > /dev/null; then
    log_message "- NVIDIA Container Toolkit installed and configured"
fi

log_message "After system boot:"
log_message "- Containers will start automatically"
log_message "- Ollama will be available at: http://localhost:11434"
log_message "- Open WebUI will be available at: http://localhost:3000"
log_message "- User $DEFAULT_USER will have Docker permissions"

log_message "Installation log has been saved to: $LOG_FILE"
