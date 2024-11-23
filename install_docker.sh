#!/bin/bash

# Exit on any error
set -e

# Check if we are in the docker group
if ! groups | grep -q docker; then
    echo "Adding current user to docker group and reinitializing shell session..."
    sudo usermod -aG docker $USER
    exec sg docker "$0"
fi

echo "Starting Docker installation for Ubuntu 24.04..."

# Update package lists
echo "Updating package lists..."
sudo apt-get update

# Install prerequisites
echo "Installing prerequisites..."
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Add Docker's official GPG key
echo "Adding Docker's GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo "Adding Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists again
echo "Updating package lists with Docker repository..."
sudo apt-get update

# Install Docker Engine
echo "Installing Docker Engine..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start and enable Docker service
echo "Starting and enabling Docker service..."
sudo systemctl start docker
sudo systemctl enable docker

# Check for NVIDIA GPU
echo "Checking for NVIDIA GPU..."
if lspci | grep -i nvidia > /dev/null; then
    echo "NVIDIA GPU detected. Installing NVIDIA Container Toolkit..."
    
    # Install required packages
    sudo apt-get install -y nvidia-driver-535

    # Add the NVIDIA Container Toolkit repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    # Update package lists
    sudo apt-get update

    # Install NVIDIA Container Toolkit
    sudo apt-get install -y nvidia-container-toolkit

    # Configure Docker daemon to use NVIDIA Container Toolkit
    sudo nvidia-ctk runtime configure --runtime=docker

    # Restart Docker daemon
    sudo systemctl restart docker

    echo "NVIDIA Container Toolkit installation completed!"
    echo "You can verify the installation by running: sudo docker run --rm --gpus all nvidia/cuda:11.0.3-base-ubuntu20.04 nvidia-smi"
else
    echo "No NVIDIA GPU detected. Skipping NVIDIA Container Toolkit installation."
fi

# Verify docker permissions
echo "Verifying Docker permissions..."
if ! docker info >/dev/null 2>&1; then
    echo "Error: Failed to connect to Docker daemon"
    exit 1
fi

# Install Ollama using Docker
echo "Installing Ollama using Docker..."

# Pull Ollama image
echo "Pulling Ollama Docker image..."
docker pull ollama/ollama

# Start Ollama container
echo "Starting Ollama container..."
docker run -d \
    --name ollama \
    -v ollama:/root/.ollama \
    -p 11434:11434 \
    --restart always \
    ollama/ollama

# Wait for Ollama to be ready
echo "Waiting for Ollama to be ready..."
sleep 10

# Install Open WebUI
echo "Installing Open WebUI..."

# Configuration for Open WebUI
WEBUI_PORT=${OPEN_WEBUI_PORT:-3000}
WEBUI_CONTAINER="open-webui"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:cuda"

# Check if docker is running
if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker is not running or you don't have permissions"
    exit 1
fi

# Check if ollama is running
if ! curl -s http://localhost:11434/api/version >/dev/null 2>&1; then
    echo "Error: Ollama is not running on localhost:11434"
    echo "Please ensure Ollama is running before continuing"
    exit 1
fi

# Check GPU support for Open WebUI
if ! command -v nvidia-smi &> /dev/null; then
    echo "Warning: NVIDIA drivers not found. Continuing without GPU support for Open WebUI..."
    GPU_ARGS=""
else
    echo "GPU support detected, enabling CUDA for Open WebUI..."
    GPU_ARGS="--gpus all"
fi

# Pull and start Open WebUI
echo "Pulling latest Open WebUI image..."
docker pull $WEBUI_IMAGE

echo "Starting Open WebUI container..."
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
    $WEBUI_IMAGE

echo "Waiting for Open WebUI to start..."
sleep 5

# Check if Open WebUI container is running
if docker ps | grep -q "$WEBUI_CONTAINER"; then
    echo "✅ Open WebUI started successfully!"
    if [ ! -z "$GPU_ARGS" ]; then
        echo "✅ GPU support enabled for Open WebUI"
    fi
    echo "✅ Connected to local Ollama service"
    echo "✅ Open WebUI is running at: http://localhost:$WEBUI_PORT"
else
    echo "❌ Error: Open WebUI container failed to start properly"
    echo "Please check docker logs for more information:"
    echo "docker logs $WEBUI_CONTAINER"
    exit 1
fi

echo "Installation completed!"
echo "- Docker has been installed and configured successfully"
echo "- Docker permissions have been set up for current session"
echo "- You can verify Docker installation by running: docker --version"
if lspci | grep -i nvidia > /dev/null; then
    echo "- NVIDIA Container Toolkit has been installed"
    echo "- You can verify NVIDIA toolkit by running: sudo docker run --rm --gpus all nvidia/cuda:11.0.3-base-ubuntu20.04 nvidia-smi"
fi
echo "- Ollama has been installed and is running in Docker at: http://localhost:11434"
echo "- Open WebUI is installed and running at: http://localhost:$WEBUI_PORT"
echo "- You can start using Ollama through the web interface at: http://localhost:$WEBUI_PORT"
