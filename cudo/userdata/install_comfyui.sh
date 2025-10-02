#!/bin/bash
# Bootstrap para ComfyUI + plugins em Cudo Compute
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/comfy-bootstrap.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo "[$(date -Iseconds)] Starting ComfyUI bootstrap"

HF_TOKEN_SEED="__HF_TOKEN__"
if [ "$HF_TOKEN_SEED" != "__HF_TOKEN__" ] && [ -n "$HF_TOKEN_SEED" ]; then
  export HF_TOKEN="$HF_TOKEN_SEED"
  echo "[$(date -Iseconds)] Hugging Face token injected via Terraform variable"
fi

wait_for_device() {
  local dev="$1"
  local attempts="${2:-60}"
  local sleep_secs="${3:-2}"

  for ((i = 0; i < attempts; i++)); do
    if [ -b "$dev" ]; then
      return 0
    fi
    udevadm settle || true
    sleep "$sleep_secs"
  done

  echo "Device $dev not found after waiting" >&2
  return 1
}

################################################################################
# 1. Montagem dos discos persistentes
################################################################################
# Detecta os dois discos extras não montados
DISKS=()

# Inclui discos já montados (idempotência em reruns)
for mount_point in /mnt/models /mnt/media; do
  if src=$(findmnt -n -o SOURCE "$mount_point" 2>/dev/null); then
    DISKS+=("$src")
  fi
done

for dev in /dev/vd[b-z] /dev/sd[b-z] /dev/nvme[1-9]n1; do
  if [ -b "$dev" ] && ! lsblk -no MOUNTPOINT "$dev" | grep -q '^/'; then
    DISKS+=("$dev")
  fi
done

if [ "${#DISKS[@]}" -gt 0 ]; then
  readarray -t DISKS < <(printf '%s\n' "${DISKS[@]}" | awk '!seen[$0]++')
fi

# Pega os dois primeiros
D0="${DISKS[0]:-$(findmnt -n -o SOURCE /mnt/models 2>/dev/null || echo /dev/vdb)}"
D1="${DISKS[1]:-$(findmnt -n -o SOURCE /mnt/media 2>/dev/null || echo /dev/vdc)}"

wait_for_device "$D0"
wait_for_device "$D1"

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
# Tokens e diretórios auxiliares após montagem dos discos
################################################################################
mkdir -p /mnt/models/.secrets
mkdir -p /root/.cache/huggingface

if [ -n "${HF_TOKEN:-}" ] && [ "$HF_TOKEN_SEED" != "__HF_TOKEN__" ] && [ -n "$HF_TOKEN_SEED" ]; then
  install -m 600 /dev/null /mnt/models/.secrets/huggingface.token
  printf '%s' "$HF_TOKEN" > /mnt/models/.secrets/huggingface.token
  echo "[$(date -Iseconds)] Token persistido em /mnt/models/.secrets/huggingface.token"
fi

# Detecta token Hugging Face para downloads autenticados (opcional)
if [ -z "${HF_TOKEN:-}" ]; then
  for token_file in \
    /mnt/models/.secrets/huggingface.token \
    /root/.cache/huggingface/token \
    /root/.huggingface/token; do
    if [ -f "$token_file" ]; then
      HF_TOKEN=$(tr -d '\r\n' <"$token_file" | head -c 200)
      export HF_TOKEN
      echo "[$(date -Iseconds)] Hugging Face token carregado de $token_file"
      break
    fi
  done
fi

if [ -n "${HF_TOKEN:-}" ]; then
  echo "[$(date -Iseconds)] Downloads autenticados do Hugging Face habilitados"
else
  echo "[$(date -Iseconds)] Nenhum token Hugging Face detectado; modelos com licença restrita podem exigir download manual"
fi

################################################################################
# 2. Dependências de sistema
################################################################################
apt-get update -y
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get install -y git python3-venv build-essential python3-dev \
                   libgl1 libglib2.0-0 ffmpeg aria2
apt-get autoremove -y

################################################################################
# 3. ComfyUI + venv
################################################################################
COMFY_DIR=/opt/ComfyUI
COMFY_REPO="https://github.com/comfyanonymous/ComfyUI.git"
COMFY_BRANCH_DEFAULT="${COMFY_BRANCH:-nightly}"
COMFY_BRANCH_FALLBACK="master"
COMFY_PIP="$COMFY_DIR/venv/bin/pip"
PIP_RETRIES="${PIP_RETRIES:-5}"

pip_retry() {
  local attempt=1
  while ! "$COMFY_PIP" "$@"; do
    if [ "$attempt" -ge "$PIP_RETRIES" ]; then
      echo "pip command failed after $attempt attempts: $*" >&2
      return 1
    fi
    echo "pip command failed (attempt $attempt), retrying in 5s..." >&2
    attempt=$((attempt + 1))
    sleep 5
  done
}

resolve_remote_branch() {
  local repo="$1" desired="$2" fallback="$3"
  if git ls-remote --exit-code --heads "$repo" "$desired" >/dev/null 2>&1; then
    printf '%s' "$desired"
  else
    printf '%s' "$fallback"
  fi
}

ensure_safe_git_dir() {
  git config --global --add safe.directory "$1" >/dev/null 2>&1 || true
}

COMFY_BRANCH=$(resolve_remote_branch "$COMFY_REPO" "$COMFY_BRANCH_DEFAULT" "$COMFY_BRANCH_FALLBACK")

if [ -d "$COMFY_DIR/.git" ]; then
  ensure_safe_git_dir "$COMFY_DIR"
  git -C "$COMFY_DIR" fetch --depth 1 origin "$COMFY_BRANCH"
  git -C "$COMFY_DIR" checkout "$COMFY_BRANCH" 2>/dev/null || \
    git -C "$COMFY_DIR" checkout -b "$COMFY_BRANCH"
  git -C "$COMFY_DIR" reset --hard "origin/$COMFY_BRANCH"
  git -C "$COMFY_DIR" clean -fd
else
  git clone --depth 1 --branch "$COMFY_BRANCH" "$COMFY_REPO" "$COMFY_DIR"
  ensure_safe_git_dir "$COMFY_DIR"
fi

python3 -m venv "$COMFY_DIR/venv"
pip_retry install --upgrade wheel
pip_retry install -r "$COMFY_DIR/requirements.txt"
pip_retry install piexif hf_transfer natsort rapidfuzz

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
  local url=$1
  local name=$2
  local branch=${3:-}
  local target="$CUSTOM_NODES_DIR/$name"

  if [ -z "$branch" ]; then
    if [ -d "$target/.git" ]; then
      branch=$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\r' | head -n 1)
      if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
        branch=$(git -C "$target" remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
      fi
    fi
    branch=${branch:-main}
  fi

  if [ -d "$target/.git" ]; then
    ensure_safe_git_dir "$target"
    rm -f "$target/.git/ORIG_HEAD" || true
    git -C "$target" fetch --depth 1 origin "$branch"
    git -C "$target" checkout "$branch" 2>/dev/null || \
      git -C "$target" checkout -b "$branch"
    git -C "$target" reset --hard "origin/$branch"
    git -C "$target" clean -fd
  else
    git clone --depth 1 --branch "$branch" "$url" "$target"
    ensure_safe_git_dir "$target"
  fi

  # Se o repositório contiver um subdir chamado 'custom_nodes', move tudo p/ raiz
  if [ -d "$target/custom_nodes" ]; then
    mv "$target/custom_nodes"/* "$CUSTOM_NODES_DIR"/
    rm -rf "$target"                          # remove casulo
    target="$CUSTOM_NODES_DIR"                # ajusta para requirements
  fi

  # Instala requirements do plugin
  for req in "$target"/requirements*.txt; do
  [ -f "$req" ] && "$COMFY_DIR/venv/bin/pip" install -r "$req"
  done
}

# Plugins desejados
install_or_update_repo https://github.com/ltdrdata/ComfyUI-Manager.git              ComfyUI-Manager main
install_or_update_repo https://github.com/willmiao/ComfyUI-Lora-Manager.git         ComfyUI_Lora_Manager main
install_or_update_repo https://github.com/AIExplorer25/ComfyUI_AutoDownloadModels.git ComfyUI_AutoDownloadModels main
install_or_update_repo https://github.com/WASasquatch/was-node-suite-comfyui.git     was-node-suite-comfyui main


################################################################################
# 6. Ajustes do ComfyUI-Manager (paralelismo + cache registry)
################################################################################
REG_PY="$CUSTOM_NODES_DIR/ComfyUI-Manager/backend/nodes/registry.py"
if [ -f "$REG_PY" ]; then
  sed -i 's/MAX_PARALLEL_REQUESTS = 2/MAX_PARALLEL_REQUESTS = 8/' "$REG_PY"
fi
mkdir -p /mnt/models/.comfyregistry_cache

################################################################################
# 7. Diretórios padrão persistentes para modelos
################################################################################
mkdir -p /mnt/models/text_encoders
mkdir -p /mnt/models/loras
mkdir -p /mnt/models/checkpoints
mkdir -p /mnt/models/embeddings
mkdir -p /mnt/models/vae
mkdir -p /mnt/models/controlnet 
mkdir -p /mnt/models/diffusion_models
mkdir -p /mnt/models/upscale_models
mkdir -p /mnt/models/unet

# Symlink ComfyUI model folders to the persistent volume so downloads/installers
# always land on /mnt/models and survive VM re-creation.
link_model_dir() {
  local subdir="$1"
  local persistent="/mnt/models/$subdir"
  local comfy_path="/opt/ComfyUI/models/$subdir"

  mkdir -p "$persistent"
  rm -rf "$comfy_path"
  ln -snf "$persistent" "$comfy_path"
}

for dir in \
  checkpoints \
  clip \
  clip_vision \
  controlnet \
  diffusion_models \
  embeddings \
  hypernetworks \
  loras \
  text_encoders \
  upscale_models \
  vae \
  vae_approx \
  audio_encoders \
  configs \
  unet; do
  link_model_dir "$dir"
done

cat >/opt/ComfyUI/extra_model_paths.yaml <<'YAML'
checkpoints:
  - /mnt/models/checkpoints
diffusion_models:
  - /mnt/models/diffusion_models
text_encoders:
  - /mnt/models/text_encoders
loras:
  - /mnt/models/loras
vae:
  - /mnt/models/vae
vae_approx:
  - /mnt/models/vae_approx
controlnet:
  - /mnt/models/controlnet
embeddings:
  - /mnt/models/embeddings
unet:
  - /mnt/models/unet
upscale_models:
  - /mnt/models/upscale_models
hypernetworks:
  - /mnt/models/hypernetworks
audio_encoders:
  - /mnt/models/audio_encoders
clip:
  - /mnt/models/clip
clip_vision:
  - /mnt/models/clip_vision
configs:
  - /mnt/models/configs
YAML

################################################################################
# 8. Download automático de modelos base comuns
################################################################################
download_model() {
  local url="$1" dest="$2" sha="$3" label="$4"
  local attempts="${5:-4}"

  mkdir -p "$(dirname "$dest")"

  if [ -f "$dest" ]; then
    if [ -n "$sha" ]; then
      if printf '%s  %s\n' "$sha" "$dest" | sha256sum -c --status 2>/dev/null; then
        echo "[$(date -Iseconds)] Modelo $label já presente (checksum ok)"
        return 0
      fi
      echo "[$(date -Iseconds)] Checksum inválido detectado para $label, removendo antigo"
      rm -f "$dest"
    else
      echo "[$(date -Iseconds)] Modelo $label já presente"
      return 0
    fi
  fi

  local aria=(aria2c --continue=true --max-connection-per-server=8 --split=8 \
              --min-split-size=8M --dir "$(dirname "$dest")" \
              --out "$(basename "$dest")")

  if [ -n "${HF_TOKEN:-}" ]; then
    aria+=(--header "Authorization: Bearer $HF_TOKEN")
  fi

  aria+=("$url")

  for ((i = 1; i <= attempts; i++)); do
    if "${aria[@]}"; then
      if [ -n "$sha" ]; then
        if ! printf '%s  %s\n' "$sha" "$dest" | sha256sum -c --status; then
          echo "[$(date -Iseconds)] Checksum errado após download de $label (tentativa $i)" >&2
          rm -f "$dest"
          sleep $((i * 5))
          continue
        fi
      fi
      echo "[$(date -Iseconds)] Download do modelo $label concluído"
      return 0
    fi
    echo "[$(date -Iseconds)] Falha ao baixar $label (tentativa $i/$attempts)" >&2
    sleep $((i * 5))
  done

  echo "[$(date -Iseconds)] ERRO: não foi possível baixar $label automaticamente" >&2
  return 1
}

DEFAULT_MODELS=(
  "checkpoints|sd_xl_base_1.0.safetensors|https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors?download=1|"
  "checkpoints|sd_xl_refiner_1.0.safetensors|https://huggingface.co/stabilityai/stable-diffusion-xl-refiner-1.0/resolve/main/sd_xl_refiner_1.0.safetensors?download=1|"
)

FAILED_MODELS=()
for item in "${DEFAULT_MODELS[@]}"; do
  IFS='|' read -r subdir filename url sha <<<"$item"
  dest="/mnt/models/$subdir/$filename"
  label="$filename"
  if ! download_model "$url" "$dest" "$sha" "$label"; then
    FAILED_MODELS+=("$label")
  fi
done

if [ "${#FAILED_MODELS[@]}" -gt 0 ]; then
  echo "[$(date -Iseconds)] Aviso: modelos não baixados automaticamente: ${FAILED_MODELS[*]}" >&2
  echo "[$(date -Iseconds)] Use o ComfyUI-Manager ou execute manualmente: aria2c <URL> --dir /mnt/models/<subdir>" >&2
fi

################################################################################
# 9. Configuração default do LoRA Manager
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
# 10. Wrapper para exportar variáveis de cache na inicialização
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
# 11. Systemd unit
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

systemctl daemon-reload
systemctl enable comfyui
systemctl restart comfyui
