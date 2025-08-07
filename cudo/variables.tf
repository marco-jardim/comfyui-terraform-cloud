# Variables for provisioning the Cudo Compute A6000 stack.

variable "cudo_api_key" {
  description = "API key for Cudo Compute."
  type        = string
}

variable "cudo_project_id" {
  description = "Project identifier within Cudo Compute."
  type        = string
}

variable "cudo_data_center_id" {
  description = "Cudo datacenter ID in which to deploy the VM and disks (e.g. \"gb-bournemouth-1\")."
  type        = string
}


variable "cudo_vcpus" {
  description = "Number of virtual CPUs for the Cudo VM."
  type        = number
  default     = 8
}

variable "cudo_memory_gib" {
  description = "Amount of RAM in GiB for the Cudo VM."
  type        = number
  default     = 32
}

variable "cudo_gpu_model" {
  description = "GPU model name. The default selects the NVIDIA RTX A6000. Use the exact case and spacing returned by the provider (\"RTX A6000\")."
  type        = string
  # The provider returns the model name in title case with a space ("RTX A6000").
  # Setting the default accordingly avoids an inconsistency error during apply.
  default     = "RTX A6000"
}

variable "cudo_gpu_count" {
  description = "Number of GPUs to attach to the VM."
  type        = number
  default     = 1
}

variable "cudo_image_id" {
  description = "Base OS image identifier for the boot disk. Defaults to a Ubuntu 22.04 image preinstalled with the latest NVIDIA drivers and Docker."
  type        = string
  # Cudo offers public images packaged with NVIDIA drivers and Docker for GPU workloads.
  # See the docs for a list of available images: for example
  # - ubuntu-2204-nvidia-535-docker-v20241017
  # - ubuntu-2204-nvidia-550-docker-v20250303【291726256184474†L114-L118】
  # The default below selects the most recent Ubuntu 22.04 + NVIDIA v550 drivers + Docker image.
  default = "ubuntu-2204-nvidia-550-docker-v20250303"
}

variable "cudo_boot_disk_size_gib" {
  description = "Size of the boot disk in GiB."
  type        = number
  default     = 50
}

variable "cudo_resizable_disks" {
  description = "If true the attached model and media disks can be resized. When true the models disk is set to 100 GiB and the media disk to 10 GiB. When false they are set to 200 GiB and 50 GiB respectively."
  type        = bool
  default     = true
}

variable "cudo_machine_type" {
  description = "Machine type to use for the Cudo VM. Defaults to a machine with an Intel Broadwell CPU and an RTX A6000 GPU."
  type        = string
  default     = "ice-lake-rtx-a6000"
}