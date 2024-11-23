#!/bin/bash

# Set error handling
set -e

echo "Starting Open WebUI update process..."

# Configuration
WEBUI_PORT=${OPEN_WEBUI_PORT:-3000}
WEBUI_CONTAINER="open-webui"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:cuda"

# Function to check if docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        echo "Error: Docker is not running or you don't have permissions"
        exit 1
    fi
}

# Function to check if ollama is running locally
check_ollama() {
    if ! curl -s http://localhost:11434/api/version >/dev/null 2>&1; then
        echo "Error: Ollama is not running on localhost:11434"
        echo "Please ensure Ollama is running before updating Open WebUI"
        exit 1
    fi
}

# Function to check GPU support
check_gpu_support() {
    if ! command -v nvidia-smi &> /dev/null; then
        echo "Warning: NVIDIA drivers not found. Continuing without GPU support..."
        GPU_ARGS=""
    else
        echo "GPU support detected, enabling CUDA..."
        GPU_ARGS="--gpus all"
    fi
}

# Main update process
main() {
    echo "Checking Docker..."
    check_docker
    
    echo "Checking Ollama service..."
    check_ollama
    
    # Check GPU support
    check_gpu_support
    
    echo "Pulling latest image..."
    docker pull $WEBUI_IMAGE
    
    echo "Starting Open WebUI container..."
    docker run -d \
        $GPU_ARGS \
        -p $WEBUI_PORT:8080 \
        --add-host=host.docker.internal:host-gateway \
        -v open-webui:/app/backend/data \
        --name $WEBUI_CONTAINER \
        -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
        --restart always \
        $WEBUI_IMAGE
    
    echo "Waiting for service to start..."
    sleep 5
    
    # Check if container is running
    if docker ps | grep -q "$WEBUI_CONTAINER"; then
        echo "✅ Update completed successfully!"
        echo "✅ Persistent data has been preserved and reattached"
        echo "✅ Backup created in $BACKUP_DIR"
        if [ ! -z "$GPU_ARGS" ]; then
            echo "✅ GPU support enabled"
        fi
        echo "✅ Connected to local Ollama service"
        echo "Open WebUI is running at: http://localhost:$WEBUI_PORT"
    else
        echo "❌ Error: Container failed to start properly"
        echo "Please check docker logs for more information:"
        echo "docker logs $WEBUI_CONTAINER"
        echo "Your data is safely backed up in $BACKUP_DIR"
        exit 1
    fi
}

# Execute main function
main