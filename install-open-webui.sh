#!/bin/bash

# Determine if running as root
if [ "$(id -u)" = "0" ]; then
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
if [ "$(id -u)" = "0" ]; then
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

# Get the actual username even if running as root
ACTUAL_USER=${SUDO_USER:-$USER}

log_message "Starting Docker installation..."

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

# Enable Docker service to start on boot
log_message "Enabling Docker service..."
systemctl enable docker 2>&1 | tee -a "$LOG_FILE"

# Add user to docker group
if ! groups $ACTUAL_USER | grep -q docker; then
    log_message "Adding user $ACTUAL_USER to docker group..."
    usermod -aG docker $ACTUAL_USER
fi

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

    log_message "NVIDIA Container Toolkit installation completed!"
fi

# Create systemd service file for Ollama
log_message "Creating Ollama systemd service..."
cat > /etc/systemd/system/ollama.service << EOF
[Unit]
Description=Ollama AI Service
After=docker.service
Requires=docker.service

[Service]
ExecStartPre=-/usr/bin/docker rm -f ollama
ExecStart=/usr/bin/docker run --rm --name ollama -v ollama:/root/.ollama -p 11434:11434 ollama/ollama
ExecStop=/usr/bin/docker stop ollama
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Create systemd service file for Open WebUI
log_message "Creating Open WebUI systemd service..."
cat > /etc/systemd/system/open-webui.service << EOF
[Unit]
Description=Open WebUI Service
After=ollama.service
Requires=ollama.service

[Service]
ExecStartPre=-/usr/bin/docker rm -f open-webui
ExecStart=/usr/bin/docker run --rm --name open-webui -p 3000:8080 --add-host=host.docker.internal:host-gateway -v open-webui:/app/backend/data -e OLLAMA_BASE_URL=http://host.docker.internal:11434 ghcr.io/open-webui/open-webui:cuda
ExecStop=/usr/bin/docker stop open-webui
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Pull Docker images
log_message "Pulling required Docker images..."
docker pull ollama/ollama 2>&1 | tee -a "$LOG_FILE"
docker pull ghcr.io/open-webui/open-webui:cuda 2>&1 | tee -a "$LOG_FILE"

# Enable services to start on boot
log_message "Enabling services to start on boot..."
systemctl enable ollama.service 2>&1 | tee -a "$LOG_FILE"
systemctl enable open-webui.service 2>&1 | tee -a "$LOG_FILE"

log_message "Installation completed!"
log_message "The following has been set up:"
log_message "- Docker Engine installed and enabled"
log_message "- Docker permissions configured for user $ACTUAL_USER"
if lspci | grep -i nvidia > /dev/null; then
    log_message "- NVIDIA Container Toolkit installed and configured"
fi
log_message "- Ollama service created and enabled"
log_message "- Open WebUI service created and enabled"
log_message "- All services will start automatically after reboot"
log_message "- After reboot, Ollama will be available at: http://localhost:11434"
log_message "- After reboot, Open WebUI will be available at: http://localhost:3000"

log_message "Installation log has been saved to: $LOG_FILE"
log_message "Please reboot the system to start all services."
