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