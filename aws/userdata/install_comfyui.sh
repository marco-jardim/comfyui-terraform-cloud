#!/bin/bash
set -euo pipefail

# Format and mount the external volume that will hold models and LoRAs
if ! file -s /dev/nvme1n1 | grep -q ext4; then
  mkfs.ext4 /dev/nvme1n1
fi
mkdir -p /mnt/models
mount /dev/nvme1n1 /mnt/models
echo '/dev/nvme1n1 /mnt/models ext4 defaults,nofail 0 2' >> /etc/fstab
chown ubuntu:ubuntu /mnt/models

# Format and mount the external volume that will store generated media
if ! file -s /dev/nvme2n1 | grep -q ext4; then
  mkfs.ext4 /dev/nvme2n1
fi
mkdir -p /mnt/media
mount /dev/nvme2n1 /mnt/media
echo '/dev/nvme2n1 /mnt/media ext4 defaults,nofail 0 2' >> /etc/fstab
chown ubuntu:ubuntu /mnt/media

# Diretório persistente para custom nodes
CUSTOM_NODES_DIR="/mnt/models/custom_nodes"
mkdir -p "$CUSTOM_NODES_DIR"

# Install basic dependencies
apt-get update
apt-get -y install \
    git python3-venv build-essential python3-dev \
    libgl1 libglib2.0-0 ffmpeg awscli

# Configure AWS CLI default region
export AWS_DEFAULT_REGION=us-east-1

# Clone ComfyUI and create Python virtual environment
git clone https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI
python3 -m venv /opt/ComfyUI/venv
/opt/ComfyUI/venv/bin/pip install --upgrade wheel
/opt/ComfyUI/venv/bin/pip install -r /opt/ComfyUI/requirements.txt

# Install the ComfyUI Manager plugin. This custom node adds a management
# interface that can download missing checkpoints, LoRAs and other assets
# directly to /mnt/models and its subdirectories. Without this plugin,
# clicking on download links will initiate a download on your local machine.
# Instala o ComfyUI‑Manager para gerenciar checkpoints, LoRAs, VAEs etc.
PLUGIN_DIR="/opt/ComfyUI/custom_nodes/ComfyUI-Manager"
if [ ! -d "$PLUGIN_DIR" ]; then
    mkdir -p "/opt/ComfyUI/custom_nodes"
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git "$PLUGIN_DIR"
fi

# Instala o AutoDownloadModels para baixar automaticamente modelos ausentes
AUTO_PLUGIN_DIR="/opt/ComfyUI/custom_nodes/ComfyUI_AutoDownloadModels"
if [ ! -d "$AUTO_PLUGIN_DIR" ]; then
    git clone https://github.com/AIExplorer25/ComfyUI_AutoDownloadModels.git "$AUTO_PLUGIN_DIR" || true
fi

# Instala o LoRA Manager para visualizar, baixar e organizar LoRAs via interface /loras
LORA_PLUGIN_DIR="/opt/ComfyUI/custom_nodes/ComfyUI-Lora-Manager"
if [ ! -d "$LORA_PLUGIN_DIR" ]; then
    git clone https://github.com/willmiao/ComfyUI-Lora-Manager.git "$LORA_PLUGIN_DIR" || true
fi

# Simple systemd service
cat <<'EOF' > /etc/systemd/system/comfyui.service
[Unit]
Description=ComfyUI server
After=network.target

[Service]
Type=simple
User=ubuntu
Environment=COMFYUI_MODEL_DIR=/mnt/models
WorkingDirectory=/opt/ComfyUI
ExecStart=/opt/ComfyUI/venv/bin/python main.py \
         --listen 0.0.0.0 --port 8188 \
         --output-directory /mnt/media
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl enable comfyui
systemctl start comfyui