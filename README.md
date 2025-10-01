# ComfyUI GPU Stack on AWS or Cudo Compute

ComfyUI is a powerful node-based interface for image and video generation.
This Terraform project provisions a complete GPU environment for ComfyUI on two
different cloud back-ends:

* **AWS** — deploys a persistent GPU EC2 instance (defaulting to the G-family)
  using cost-efficient Spot pricing, with separate EBS volumes for model data and
  generated media.
* **Cudo Compute** — provisions a virtual machine equipped with an **NVIDIA A100 PCIe**
  GPU. Separate storage disks are created for models and media, and the VM is
  destroyed at the end of your work session while the disks persist for the next run.

Both stacks install and launch ComfyUI automatically via a small `userdata`
script. Volumes survive instance termination so you only pay for the storage
when the GPU is off.

## Table of contents

- [ComfyUI GPU Stack on AWS or Cudo Compute](#comfyui-gpu-stack-on-aws-or-cudo-compute)
  - [Table of contents](#table-of-contents)
  - [1. Overview](#1-overview)
  - [2. AWS stack](#2-aws-stack)
  - [3. Cudo stack](#3-cudo-stack)
  - [4. Prerequisites](#4-prerequisites)
  - [5. First‑time setup](#5-firsttime-setup)
  - [6. Everyday workflow](#6-everyday-workflow)
  - [7. Cleaning up](#7-cleaning-up)
    - [Destroying only the compute resources](#destroying-only-the-compute-resources)
    - [Removing all resources](#removing-all-resources)
  - [8. License](#8-license)

---

## 1. Overview

You now have two options to run ComfyUI in the cloud:

| Option         | GPU type            | Persistent storage            | Notes |
|---------------:|:-------------------:|:------------------------------|:----- |
| **AWS**        | AWS G-family        | EBS volumes for models/media  | Uses Spot or on-demand pricing |
| **Cudo Compute** | NVIDIA A100 PCIe    | Storage disks for models/media | VM destroyed when done, disks persist |

Model checkpoints, LoRAs and VAEs are stored on one volume; generated images and
videos live on another. This separation makes it easy to grow one without
affecting the other and ensures data survives instance termination.

---
## 2. AWS stack

The original Terraform configuration for AWS lives in the `aws/` directory. It
creates:

* An EC2 instance using the latest Deep Learning AMI【206619876762535†L16-L31】.
* Two GP3 EBS volumes (500 GiB for `/mnt/models` and 1000 GiB for `/mnt/media`)【266417534711484†L54-L55】.
* A security group exposing SSH and the ComfyUI port 8188【206619876762535†L102-L123】.
* A tiny userdata script that formats and mounts the volumes, installs
  dependencies and starts ComfyUI as a systemd service【232503751736464†L0-L57】.

To deploy the AWS stack:

```bash
cd aws
cp secrets.auto.tfvars.example secrets.auto.tfvars  # create your secrets file
terraform init
terraform apply
```

Populate `secrets.auto.tfvars` with your AWS profile, region and instance type.
See the comments in that file for guidance.

Stopping and starting the instance via the AWS CLI or the EC2 console leaves
your volumes intact and avoids compute charges. When you no longer need the
stack, run `terraform destroy`.

---

## 3. Cudo stack

The Cudo configuration resides in the `cudo/` directory and provisions a VM
containing a single **A100 PCIe** GPU. Two storage disks are created — one for
models and one for media — and attached to the VM. When you destroy the VM the
disks remain, preserving your data for the next run.

The bootstrap script upgrades Ubuntu to the latest security patches, checks out
the nightly branch of ComfyUI, and refreshes the bundled plugins (ComfyUI
Manager, LoRA Manager, AutoDownloadModels and the WAS node suite) to their
latest releases. Beginning with the October 2025 build the bootstrap also tries
to fetch a small starter set of models (Stable Diffusion XL base and refiner)
directly onto the persistent `/mnt/models` volume so workflows open without
prompting for local downloads.

> **Remote Hugging Face token** — some models (including SDXL) require licence
> acceptance. Either set the `huggingface_token` variable in
> `cudo/secrets.auto.tfvars` **or** place a token file at
> `/mnt/models/.secrets/huggingface.token` (the directory lives on the
> persistent disk) before rerunning the bootstrap or the next `terraform
> apply`. The script automatically detects the value and uses it for
> authenticated downloads. You can create it over SSH with:
>
> ```bash
> mkdir -p /mnt/models/.secrets
> printf '%s' "hf_xxxxxxxxxxxxxxxxx" | sudo tee /mnt/models/.secrets/huggingface.token >/dev/null
> sudo chmod 600 /mnt/models/.secrets/huggingface.token
> ```
>
> If no token is present the bootstrap skips gated files and reminds you to
> download them inside the ComfyUI web UI via **ComfyUI Manager → Downloads**.

Disks default to **100 GiB for models** and **10 GiB for media** when the Cudo
platform supports resizing; otherwise they grow to **200 GiB and 50 GiB** to
accommodate future growth without resizing.

To deploy on Cudo:

```bash
cd cudo
cp secrets.auto.tfvars.example secrets.auto.tfvars
terraform init
terraform apply
```

Your `secrets.auto.tfvars` in `cudo/` should define:

```hcl
cudo_api_key       = "your-api-key"
cudo_project_id    = "project-uuid"
cudo_data_center_id = "us-carlsbad-1"  # or whichever datacentre suits you

# Optional overrides
cudo_vcpus         = 24
cudo_memory_gib    = 192
cudo_gpu_count     = 1
cudo_resizable_disks = true
```

You can adjust `cudo_image_id` and disk sizes if needed. The GPU model defaults
to **A100 PCIe** via the `cudo_gpu_model` variable, and the machine type pairs an
Ice Lake host with that accelerator. The base image defaults to
**Ubuntu 22.04** with preinstalled NVIDIA drivers and Docker (image ID
`ubuntu-2204-nvidia-550-docker-v20250303`). Override `cudo_image_id` only if
your data centre offers a different OS or driver version. See `cudo/variables.tf`
for all available options.

> **Tip:** Persistent disks stay in the region where they were created. If
> you've already applied the stack and need to change `cudo_data_center_id`, you
> must either keep the original value (to reuse the disks) or manually migrate
> the data before switching. Otherwise the plan will try to recreate the disks
> and be blocked by the `prevent_destroy` safeguard. Temporarily comment out the
> `lifecycle { prevent_destroy = true }` block if you intentionally need
> Terraform to replace the disks after backing up data.

When running the Cudo stack the VM is terminated when you call
`terraform destroy`, but the `cudo_storage_disk` resources are retained by
default thanks to the `prevent_destroy` safeguard. This behaviour mirrors
the AWS stack where volumes survive instance termination【545279181630475†L49-L83】.

---

## 4. Prerequisites

| Tool        | Minimum version | Install command              |
| :---------- | :-------------- | :--------------------------- |
| Terraform   | 1.6            |                             |
| AWS CLI     | 2.15           | `brew install awscli` or MSI |
| Cudo account | —             | [Create on Cudo Compute](https://www.cudocompute.com/) |
| Git         | any recent     |                             |
| SSH key     | ED25519 recommended | `ssh-keygen -t ed25519 -C "comfyui"` |

---

## 5. First‑time setup

1. **Configure providers**  
   *AWS*: run `aws configure --profile your_aws_profile_name` and import your
   public key into EC2.  
   *Cudo*: generate an API key and create a project via the Cudo web console.

2. **Prepare the repository**  
   Clone this repo and navigate into either the `aws` or `cudo` directory
   depending on your chosen platform.

3. **Create and edit `secrets.auto.tfvars`**  
   Copy the provided example file and fill in the variables for your chosen
   platform.

4. **Initialise and apply**  
   Run `terraform init` and `terraform apply`, confirming with `yes` when prompted.

The first run can take a few minutes while the VM is created, volumes are
provisioned and ComfyUI is installed.

---

## 6. Everyday workflow

Once deployed, access ComfyUI at `http://public-ip:8188` in your browser.

- **Resize the GPU** (AWS only): change `instance_type` in your variables file
  and run `terraform apply -var "instance_type=g6.4xlarge"`.
- **Stop billing**:  
  *AWS*: stop the instance via the AWS CLI or console; volumes remain attached.  
  *Cudo*: destroy the VM with `terraform destroy`; the disks persist thanks to
  the `prevent_destroy` lifecycle guard.
- **Restart later**:  
  *AWS*: start the instance again and reconnect.  
  *Cudo*: re-apply the Terraform stack; it will reuse the existing disks.
- **Server-side model downloads**: the bootstrap preloads SDXL base/refiner into
  `/mnt/models/checkpoints` whenever possible. Use **ComfyUI Manager →
  Downloads** to pull additional assets straight onto the VM, or edit
  `cudo/userdata/install_comfyui.sh` to extend the `DEFAULT_MODELS` list for
  future applies.

---

## 7. Cleaning up
### Destroying only the compute resources

Both stacks are designed so that your model and media volumes survive instance
termination. When you call `terraform destroy` without any extra flags,
Terraform will delete the compute instance and detach the disks/volumes but
will **not** remove the underlying storage:

| Provider | How it preserves storage |
|---------:|:-------------------------|
| **AWS**  | The volume attachments use `skip_destroy = true`, so destroying
  the instance simply detaches the EBS volumes and leaves them intact. |
| **Cudo** | The `cudo_storage_disk` resources include a `prevent_destroy`
  lifecycle rule. Terraform detaches the disks automatically but refuses to
  delete them. |

To destroy **only** the compute resources, run:

```bash
terraform destroy -target=cudo_vm.comfy -target=cudo_security_group.comfy_sg
```

This shuts down the VM and deletes the security group while leaving the
`cudo_storage_disk` resources intact (they're protected by `prevent_destroy`).
The next time you apply the stack the existing disks will be reattached and
your data will be available again.

### Removing all resources

If you really want to delete the persistent volumes as well, you can either
remove the lifecycle hooks and attachments from the Terraform code or force
Terraform to target the volumes. For example:

```bash
# Remove prevent_destroy in cudo/main.tf and/or skip_destroy in aws/main.tf,
# then run:
terraform destroy
```

Alternatively you can delete the disks manually in the AWS or Cudo web
consoles after running `terraform destroy`.

---

## 8. License

MIT License unless stated otherwise.
Feel free to fork and improve.