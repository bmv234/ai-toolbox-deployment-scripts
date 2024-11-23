#!/bin/bash

# Determine if running as root
if [ "$EUID" -eq 0 ]; then
    # If root, use /var/log
    LOG_DIR="/var/log/docker-install"
    # Create log directory with appropriate permissions
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"
else
    # If regular user, use current directory
    LOG_DIR="$(pwd)"
fi

LOG_FILE="$LOG_DIR/docker_install_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE"

# Set appropriate permissions for log file
if [ "$EUID" -eq 0 ]; then
    chown root:adm "$LOG_FILE"
    chmod 644 "$LOG_FILE"
fi

# Function to log messages to both console and log file
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_message "Starting Docker installation"
log_message "Installation directory: $(pwd)"
log_message "Log file location: $LOG_FILE"
log_message "Running as user: $(whoami)"

# Exit on any error
set -e

# Get the actual username even if running as root
ACTUAL_USER=${SUDO_USER:-$USER}

# Check docker group membership and add if needed
if ! groups $ACTUAL_USER | grep -q docker; then
    log_message "Adding user $ACTUAL_USER to docker group..."
    usermod -aG docker $ACTUAL_USER
    if [ "$EUID" -ne 0 ]; then
        # Only reinitialize shell session if not running as root
        log_message "Reinitializing shell session..."
        exec sg docker "$0"
    fi
fi

log_message "Starting Docker installation for Ubuntu 24.04..."

# Update package lists
log_message "Updating package lists..."
sudo apt-get update 2>&1 | tee -a "$LOG_FILE"

# Install prerequisites
log_message "Installing prerequisites..."
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release 2>&1 | tee -a "$LOG_FILE"

# Add Docker's official GPG key
log_message "Adding Docker's GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>&1 | tee -a "$LOG_FILE"
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository
log_message "Adding Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists again
log_message "Updating package lists with Docker repository..."
sudo apt-get update 2>&1 | tee -a "$LOG_FILE"

# Install Docker Engine
log_message "Installing Docker Engine..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>&1 | tee -a "$LOG_FILE"

# Start and enable Docker service
log_message "Starting and enabling Docker service..."
sudo systemctl start docker 2>&1 | tee -a "$LOG_FILE"
sudo systemctl enable docker 2>&1 | tee -a "$LOG_FILE"

# Check for NVIDIA GPU
log_message "Checking for NVIDIA GPU..."
if lspci | grep -i nvidia > /dev/null; then
    log_message "NVIDIA GPU detected. Installing NVIDIA Container Toolkit..."
    
    # Install required packages
    sudo apt-get install -y nvidia-driver-535 2>&1 | tee -a "$LOG_FILE"

    # Add the NVIDIA Container Toolkit repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>&1 | tee -a "$LOG_FILE"
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list 2>&1 | tee -a "$LOG_FILE"

    # Update package lists
    sudo apt-get update 2>&1 | tee -a "$LOG_FILE"

    # Install NVIDIA Container Toolkit
    sudo apt-get install -y nvidia-container-toolkit 2>&1 | tee -a "$LOG_FILE"

    # Configure Docker daemon to use NVIDIA Container Toolkit
    sudo nvidia-ctk runtime configure --runtime=docker 2>&1 | tee -a "$LOG_FILE"

    # Restart Docker daemon
    sudo systemctl restart docker 2>&1 | tee -a "$LOG_FILE"

    log_message "NVIDIA Container Toolkit installation completed!"
    log_message "You can verify the installation by running: sudo docker run --rm --gpus all nvidia/cuda:11.0.3-base-ubuntu20.04 nvidia-smi"
else
    log_message "No NVIDIA GPU detected. Skipping NVIDIA Container Toolkit installation."
fi

# Verify docker permissions
log_message "Verifying Docker permissions..."
if ! docker info >/dev/null 2>&1; then
    log_message "Error: Failed to connect to Docker daemon"
    exit 1
fi

# Install Ollama using Docker
log_message "Installing Ollama using Docker..."

# Pull Ollama image
log_message "Pulling Ollama Docker image..."
docker pull ollama/ollama 2>&1 | tee -a "$LOG_FILE"

# Start Ollama container
log_message "Starting Ollama container..."
docker run -d \
    --name ollama \
    -v ollama:/root/.ollama \
    -p 11434:11434 \
    --restart always \
    ollama/ollama 2>&1 | tee -a "$LOG_FILE"

# Wait for Ollama to be ready
log_message "Waiting for Ollama to be ready..."
sleep 10

# Install Open WebUI
log_message "Installing Open WebUI..."

# Configuration for Open WebUI
WEBUI_PORT=${OPEN_WEBUI_PORT:-3000}
WEBUI_CONTAINER="open-webui"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:cuda"

# Check if docker is running
if ! docker info >/dev/null 2>&1; then
    log_message "Error: Docker is not running or you don't have permissions"
    exit 1
fi

# Check if ollama is running
if ! curl -s http://localhost:11434/api/version >/dev/null 2>&1; then
    log_message "Error: Ollama is not running on localhost:11434"
    log_message "Please ensure Ollama is running before continuing"
    exit 1
fi

# Check GPU support for Open WebUI
if ! command -v nvidia-smi &> /dev/null; then
    log_message "Warning: NVIDIA drivers not found. Continuing without GPU support for Open WebUI..."
    GPU_ARGS=""
else
    log_message "GPU support detected, enabling CUDA for Open WebUI..."
    GPU_ARGS="--gpus all"
fi

# Pull and start Open WebUI
log_message "Pulling latest Open WebUI image..."
docker pull $WEBUI_IMAGE 2>&1 | tee -a "$LOG_FILE"

log_message "Starting Open WebUI container..."
# Remove existing container if it exists
docker rm -f $WEBUI_CONTAINER >/dev/null 2>&1 || true

docker run -d \
    $GPU_ARGS \
    -p $WEBUI_PORT:8080 \
    --add-host=host.docker.internal:host-gateway \
    -v open-webui:/app/backend/data \
    --name $WEBUI_CONTAINER \
    -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
    --restart always \
    $WEBUI_IMAGE 2>&1 | tee -a "$LOG_FILE"

log_message "Waiting for Open WebUI to start..."
sleep 5

# Check if Open WebUI container is running
if docker ps | grep -q "$WEBUI_CONTAINER"; then
    log_message "✅ Open WebUI started successfully!"
    if [ ! -z "$GPU_ARGS" ]; then
        log_message "✅ GPU support enabled for Open WebUI"
    fi
    log_message "✅ Connected to local Ollama service"
    log_message "✅ Open WebUI is running at: http://localhost:$WEBUI_PORT"
else
    log_message "❌ Error: Open WebUI container failed to start properly"
    log_message "Please check docker logs for more information:"
    log_message "docker logs $WEBUI_CONTAINER"
    exit 1
fi

log_message "Installation completed!"
log_message "- Docker has been installed and configured successfully"
log_message "- Docker permissions have been set up for current session"
log_message "- You can verify Docker installation by running: docker --version"
if lspci | grep -i nvidia > /dev/null; then
    log_message "- NVIDIA Container Toolkit has been installed"
    log_message "- You can verify NVIDIA toolkit by running: sudo docker run --rm --gpus all nvidia/cuda:11.0.3-base-ubuntu20.04 nvidia-smi"
fi
log_message "- Ollama has been installed and is running in Docker at: http://localhost:11434"
log_message "- Open WebUI is installed and running at: http://localhost:$WEBUI_PORT"
log_message "- You can start using Ollama through the web interface at: http://localhost:$WEBUI_PORT"

log_message "Installation log has been saved to: $LOG_FILE"
