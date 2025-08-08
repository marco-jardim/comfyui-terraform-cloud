#!/bin/bash
# Bootstrap para ComfyUI + plugins em Cudo Compute
set -euo pipefail

################################################################################
# 1. Montagem dos discos persistentes
################################################################################
# Detecta os dois discos extras não montados
DISKS=()
for dev in /dev/vd[b-z] /dev/sd[b-z] /dev/nvme[1-9]n1; do
  if [ -b "$dev" ] && ! lsblk -no MOUNTPOINT "$dev" | grep -q '^/'; then
    DISKS+=("$dev")
  fi
done

# Pega os dois primeiros
D0="${DISKS[0]:-/dev/vdb}"
D1="${DISKS[1]:-/dev/vdc}"

# Escolhe o maior para MODELS
S0=$(blockdev --getsize64 "$D0")
S1=$(blockdev --getsize64 "$D1")
if (( S0 >= S1 )); then
  MODEL_DEV="$D0"; MEDIA_DEV="$D1"
else
  MODEL_DEV="$D1"; MEDIA_DEV="$D0"
fi

# Formata/rotula se necessário, garante LABELs estáveis
prep_ext4() {
  local DEV="$1" LABEL="$2"
  if ! file -s "$DEV" | grep -q ext4; then
    mkfs.ext4 -F -L "$LABEL" "$DEV"
  else
    e2label "$DEV" "$LABEL" || true
  fi
}
prep_ext4 "$MODEL_DEV" MODELS
prep_ext4 "$MEDIA_DEV" MEDIA

# Monta por LABEL (idempotente)
mkdir -p /mnt/models /mnt/media
sed -i '\| /mnt/models |d' /etc/fstab
sed -i '\| /mnt/media |d'  /etc/fstab
echo 'LABEL=MODELS /mnt/models ext4 defaults,nofail 0 2' >> /etc/fstab
echo 'LABEL=MEDIA  /mnt/media  ext4 defaults,nofail 0 2'  >> /etc/fstab

mount -a

################################################################################
# 2. Dependências de sistema
################################################################################
apt-get update -y
apt-get install -y git python3-venv build-essential python3-dev \
                   libgl1 libglib2.0-0 ffmpeg aria2

################################################################################
# 3. ComfyUI + venv
################################################################################
if [ ! -d /opt/ComfyUI ]; then
  git clone https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI
fi
python3 -m venv /opt/ComfyUI/venv
/opt/ComfyUI/venv/bin/pip install --upgrade wheel
/opt/ComfyUI/venv/bin/pip install -r /opt/ComfyUI/requirements.txt
/opt/ComfyUI/venv/bin/pip install piexif hf_transfer natsort rapidfuzz

################################################################################
# 4. Diretório persistente + symlink para custom_nodes
################################################################################
CUSTOM_NODES_DIR="/mnt/models/custom_nodes"
mkdir -p "$CUSTOM_NODES_DIR"
rm -rf /opt/ComfyUI/custom_nodes              # evita loops antigos
ln -snf "$CUSTOM_NODES_DIR" /opt/ComfyUI/custom_nodes

###############################################################################
# 5. Função utilitária — clone/pull + requirements + flatten
###############################################################################
install_or_update_repo() {
  local url=$1 name=$2 target="$CUSTOM_NODES_DIR/$name"

  if [ -d "$target/.git" ]; then
    git -C "$target" pull --ff-only
  else
    git clone --depth 1 "$url" "$target"
  fi

  # Se o repositório contiver um subdir chamado 'custom_nodes', move tudo p/ raiz
  if [ -d "$target/custom_nodes" ]; then
    mv "$target/custom_nodes"/* "$CUSTOM_NODES_DIR"/
    rm -rf "$target"                          # remove casulo
    target="$CUSTOM_NODES_DIR"                # ajusta para requirements
  fi

  # Instala requirements do plugin
  for req in "$target"/requirements*.txt; do
    [ -f "$req" ] && /opt/ComfyUI/venv/bin/pip install -r "$req"
  done
}

# Plugins desejados
install_or_update_repo https://github.com/ltdrdata/ComfyUI-Manager.git              ComfyUI-Manager
install_or_update_repo https://github.com/willmiao/ComfyUI-Lora-Manager.git         ComfyUI_Lora_Manager
install_or_update_repo https://github.com/AIExplorer25/ComfyUI_AutoDownloadModels.git ComfyUI_AutoDownloadModels
install_or_update_repo https://github.com/WASasquatch/was-node-suite-comfyui.git     was-node-suite-comfyui


################################################################################
# 6. Ajustes do ComfyUI-Manager (paralelismo + cache registry)
################################################################################
REG_PY="$CUSTOM_NODES_DIR/ComfyUI-Manager/backend/nodes/registry.py"
if [ -f "$REG_PY" ]; then
  sed -i 's/MAX_PARALLEL_REQUESTS = 2/MAX_PARALLEL_REQUESTS = 8/' "$REG_PY"
fi
mkdir -p /mnt/models/.comfyregistry_cache

################################################################################
# 7. Configuração default do LoRA Manager
################################################################################
LM_CONF="$CUSTOM_NODES_DIR/ComfyUI_Lora_Manager/settings.json"
if [ ! -f "$LM_CONF" ]; then
cat > "$LM_CONF" <<'JSON'
{
  "enable_api": true,
  "listen": "0.0.0.0",
  "port": 8188,
  "cors_allowed_origins": ["*"],
  "lora_root": "/mnt/models/loras",
  "checkpoint_root": "/mnt/models/checkpoints",
  "embedding_root": "/mnt/models/embeddings",
  "vae_root": "/mnt/models/vae",
  "controlnet_root": "/mnt/models/controlnet"
}
JSON
fi

################################################################################
# 8. Wrapper para exportar variáveis de cache na inicialização
################################################################################
cat >/opt/ComfyUI/run_with_env.sh <<'BASH'
#!/usr/bin/env bash
export COMFYUI_REGISTRY_CACHE_DIR=/mnt/models/.comfyregistry_cache
exec /opt/ComfyUI/venv/bin/python /opt/ComfyUI/main.py \
     --listen 0.0.0.0 --port 8188 \
     --output-directory /mnt/media
BASH
chmod +x /opt/ComfyUI/run_with_env.sh

################################################################################
# 9. Systemd unit
################################################################################
SERVICE_FILE=/etc/systemd/system/comfyui.service
if [ ! -f "$SERVICE_FILE" ]; then
cat >"$SERVICE_FILE" <<'EOF'
[Unit]
Description=ComfyUI server
After=network.target

[Service]
Type=simple
User=root
Environment=COMFYUI_MODEL_DIR=/mnt/models
WorkingDirectory=/opt/ComfyUI
ExecStart=/opt/ComfyUI/run_with_env.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
fi

mkdir -p /mnt/models/text_encoders
mkdir -p /mnt/models/loras
mkdir -p /mnt/models/checkpoints
mkdir -p /mnt/models/embeddings
mkdir -p /mnt/models/vae
mkdir -p /mnt/models/controlnet 
mkdir -p /mnt/models/diffusion_models

systemctl daemon-reload
systemctl enable comfyui
systemctl restart comfyui
