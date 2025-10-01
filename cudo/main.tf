terraform {
  required_version = ">= 1.6"

  required_providers {
    cudo = {
      source  = "CudoVentures/cudo"
      version = ">= 0.11.2"
    }
  }
}

# Configure the Cudo Compute provider. These values come from variables defined in
# variables.tf within this directory.
provider "cudo" {
  api_key    = var.cudo_api_key
  project_id = var.cudo_project_id
}

# Compute the appropriate sizes for model and media disks based on whether
# resizable volumes are available. When resizable volumes are supported, the
# models volume defaults to 100 GiB and the media volume defaults to 10 GiB.
# Otherwise, the sizes are doubled to 200 GiB and 50 GiB respectively to
# accommodate future growth without resizing.
locals {
  models_size_gib = var.cudo_resizable_disks ? 100 : 200
  media_size_gib  = var.cudo_resizable_disks ? 10 : 50
}

# Persistant disk for models (checkpoints, LoRAs, etc).
resource "cudo_storage_disk" "models" {
  id             = "comfy-models"
  data_center_id = var.cudo_data_center_id
  project_id     = var.cudo_project_id
  size_gib       = local.models_size_gib


}

# Persistant disk for generated media.
resource "cudo_storage_disk" "media" {
  id             = "comfy-media"
  data_center_id = var.cudo_data_center_id
  project_id     = var.cudo_project_id
  size_gib       = local.media_size_gib


}
#ddf7c83d55bb9eb4c3647caecd9a1654
# --- VM -------------------------------------------------------------------
resource "cudo_vm" "comfy" {
  id             = "comfyui-a100"
  data_center_id = var.cudo_data_center_id

  vcpus        = var.cudo_vcpus
  memory_gib   = var.cudo_memory_gib
  machine_type = var.cudo_machine_type
  gpus         = var.cudo_gpu_count

  boot_disk = {
    image_id = var.cudo_image_id
    size_gib = var.cudo_boot_disk_size_gib
  }

  storage_disks = [
    { disk_id = cudo_storage_disk.models.id },
    { disk_id = cudo_storage_disk.media.id }
  ]

  security_group_ids = [cudo_security_group.comfy_sg.id]
  start_script       = replace(file("${path.module}/userdata/install_comfyui.sh"), "__HF_TOKEN__", var.huggingface_token)

  # (se ainda precisar contornar o bug do provider)
  lifecycle {
    ignore_changes = [storage_disks]
  }
}


output "public_ip" {
  value = cudo_vm.comfy.external_ip_address
}

output "comfyui_url" {
  value       = "http://${cudo_vm.comfy.external_ip_address}:8188"
  description = "Endereço HTTP para acessar o ComfyUI"
}


# --- Security group que libera SSH e ComfyUI ------------------------------
resource "cudo_security_group" "comfy_sg" {
  id             = "comfy-a100-sg"         # nome legível no painel
  data_center_id = var.cudo_data_center_id # mesmo DC da VM

  description = "Ingress SSH 22 and ComfyUI 8188"

  rules = [
    # Inbound – SSH
    {
      rule_type = "inbound"
      protocol  = "tcp"
      ports     = "22"
      ip_range  = "0.0.0.0/0"
    },
    # Inbound – ComfyUI
    {
      rule_type = "inbound"
      protocol  = "tcp"
      ports     = "8188"
      ip_range  = "0.0.0.0/0"
    },
    # Outbound – tudo liberado
    {
      rule_type = "outbound"
      protocol  = "all"
    }
  ]
}
