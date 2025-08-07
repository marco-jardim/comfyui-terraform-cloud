#!/bin/bash
# This userdata script is used by the Cudo Compute configuration to bootstrap
# a fresh VM with ComfyUI. It formats and mounts the two attached data
# disks for models and generated media, installs the required packages,
# clones the ComfyUI repository, and sets up a systemd service to run it
# automatically. The script is idempotent and safe to re-run.
set -euo pipefail

# Identify the extra block devices. On most Cudo VMs the root disk is vda and
# additional attached volumes appear as vdb, vdc and so on. We exclude the
# root disk and select the next two devices for models and media.
DISKS=()
for dev in /dev/vd[b-z] /dev/sd[b-z] /dev/nvme[1-9]n1; do
  if [ -b "$dev" ] && ! lsblk -no MOUNTPOINT "$dev" | grep -q '^/'; then
    DISKS+=("$dev")
  fi
done

MODEL_DEV="${DISKS[0]:-/dev/vdb}"
MEDIA_DEV="${DISKS[1]:-/dev/vdc}"

# Format and mount the models disk if it doesn't already contain an ext4 filesystem
if ! file -s "$MODEL_DEV" | grep -q ext4; then
  mkfs.ext4 -F "$MODEL_DEV"
fi
mkdir -p /mnt/models
mount "$MODEL_DEV" /mnt/models
if ! grep -q "$MODEL_DEV" /etc/fstab; then
  echo "$MODEL_DEV /mnt/models ext4 defaults,nofail 0 2" >> /etc/fstab
fi
chown root:root /mnt/models

# Format and mount the media disk
if ! file -s "$MEDIA_DEV" | grep -q ext4; then
  mkfs.ext4 -F "$MEDIA_DEV"
fi
mkdir -p /mnt/media
mount "$MEDIA_DEV" /mnt/media
if ! grep -q "$MEDIA_DEV" /etc/fstab; then
  echo "$MEDIA_DEV /mnt/media ext4 defaults,nofail 0 2" >> /etc/fstab
fi
chown root:root /mnt/media

# Install basic dependencies
apt-get update -y
apt-get install -y git python3-venv build-essential python3-dev \
    libgl1 libglib2.0-0 ffmpeg

# Clone ComfyUI and create Python virtual environment if not already present
if [ ! -d /opt/ComfyUI ]; then
  git clone https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI
fi
python3 -m venv /opt/ComfyUI/venv
/opt/ComfyUI/venv/bin/pip install --upgrade wheel
/opt/ComfyUI/venv/bin/pip install -r /opt/ComfyUI/requirements.txt

# Install the ComfyUI Manager plugin. This custom node adds a management
# interface that can download missing checkpoints, LoRAs and other assets
# directly to /mnt/models and its subdirectories. Without this plugin,
# clicking on download links will initiate a download on your local machine.
PLUGIN_DIR="/opt/ComfyUI/custom_nodes/ComfyUI-Manager"
if [ ! -d "$PLUGIN_DIR" ]; then
  mkdir -p "/opt/ComfyUI/custom_nodes"
  git clone https://github.com/ltdrdata/ComfyUI-Manager.git "$PLUGIN_DIR"
fi

# Simple systemd service to start ComfyUI on boot. Only write the unit file if
# it doesn't already exist to avoid overwriting customisations.
SERVICE_FILE=/etc/systemd/system/comfyui.service
if [ ! -f "$SERVICE_FILE" ]; then
  cat <<'EOF' > "$SERVICE_FILE"
[Unit]
Description=ComfyUI server
After=network.target

[Service]
Type=simple
User=root
Environment=COMFYUI_MODEL_DIR=/mnt/models
WorkingDirectory=/opt/ComfyUI
ExecStart=/opt/ComfyUI/venv/bin/python main.py \
         --listen 0.0.0.0 --port 8188 \
         --output-directory /mnt/media
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
fi

# Enable and start the service
systemctl daemon-reload
systemctl enable comfyui
systemctl restart comfyui

# Open ports in UFW if it is enabled later
if command -v ufw >/dev/null && ufw status | grep -q active; then
  ufw allow 22/tcp
  ufw allow 8188/tcp
fi