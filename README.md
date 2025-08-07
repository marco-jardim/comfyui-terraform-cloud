# ComfyUI GPU Stack on AWS or Cudo Compute

ComfyUI is a powerful node‑based interface for image and video generation.  
This Terraform project provisions a complete GPU environment for ComfyUI on two
different cloud back‑ends:

* **AWS** — deploys a persistent GPU EC2 instance (defaulting to the G‑family)
  using cost‑efficient Spot pricing, with separate EBS volumes for model data and
  generated media.  
* **Cudo Compute** — provisions a virtual machine equipped with an **NVIDIA RTX A6000**
  GPU. Separate storage disks are created for models and media, and the VM is
  destroyed at the end of your work session while the disks persist for the next run.

Both stacks install and launch ComfyUI automatically via a small `userdata`
script. Volumes survive instance termination so you only pay for the storage
when the GPU is off.

## Table of contents

- [1. Overview](#1-overview)
- [2. AWS stack](#2-aws-stack)
- [3. Cudo stack](#3-cudo-stack)
- [4. Prerequisites](#4-prerequisites)
- [5. First‑time setup](#5-first-time-setup)
- [6. Everyday workflow](#6-everyday-workflow)
- [7. Cleaning up](#7-cleaning-up)
- [8. License](#8-license)

---

## 1. Overview

You now have two options to run ComfyUI in the cloud:

| Option         | GPU type                  | Persistent storage            | Notes |
|---------------:|:-------------------------:|:------------------------------|:----- |
| **AWS**        | AWS G‑family (e.g. g6.*) | EBS volumes for models/media | Uses Spot or on‑demand pricing |
| **Cudo Compute** | NVIDIA RTX A6000         | Storage disks for models/media | VM destroyed when done, disks persist |

Model checkpoints, LoRAs and VAEs are stored on one volume; generated images and
videos live on another. This separation makes it easy to grow one without
affecting the other and ensures data survives instance termination【545279181630475†L49-L83】.

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
containing a single **RTX A6000** GPU. Two storage disks are created — one for
models and one for media — and attached to the VM. When you destroy the VM the
disks remain, preserving your data for the next run.

Disks default to **100 GiB for models** and **10 GiB for media** when the Cudo
platform supports resizing; otherwise they grow to **200 GiB and 50 GiB** to
accommodate future growth without resizing【545279181630475†L49-L83】.

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
cudo_data_center_id = "gb-bournemouth-1"  # or whichever datacenter is closest

# Optional overrides
cudo_vcpus         = 8
cudo_memory_gib    = 32
cudo_gpu_count     = 1
cudo_resizable_disks = true
```

You can adjust `cudo_image_id` and disk sizes if needed. The GPU model defaults
to **RTX A6000** via the `cudo_gpu_model` variable, and Cudo Compute will
automatically choose an appropriate CPU and memory configuration. The base
image defaults to **Ubuntu 22.04** with preinstalled NVIDIA drivers and Docker
(image ID `ubuntu-2204-nvidia-550-docker-v20250303`)【291726256184474†L114-L118】.
Override `cudo_image_id` only if your data centre offers a different OS or
driver version. See `cudo/variables.tf` for all available options.

When running the Cudo stack the VM is terminated when you call
`terraform destroy`, but the `cudo_storage_disk` resources are retained by
default thanks to the `prevent_destroy` lifecycle rule. This behaviour mirrors
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
  `prevent_destroy`.
- **Restart later**:  
  *AWS*: start the instance again and reconnect.  
  *Cudo*: re‑apply the Terraform stack; it will reuse the existing disks.

---

## 7. Cleaning up
### Destroying only the compute resources

Both stacks are designed so that your model and media volumes survive instance
termination.  When you call `terraform destroy` without any extra flags,
Terraform will delete the compute instance and detach the disks/volumes but
will **not** remove the underlying storage:

| Provider | How it preserves storage |
|---------:|:-------------------------|
| **AWS**  | The volume attachments use `skip_destroy = true`, so destroying
  the instance simply detaches the EBS volumes and leaves them intact. |
| **Cudo** | The `cudo_storage_disk` resources include a `prevent_destroy`
  lifecycle rule【774582159873390†L27-L30】. Terraform detaches the disks
  automatically but refuses to delete them. |

To destroy **only** the compute resources, run:

```bash
terraform destroy
```

This will shut down the VM and detach the storage.  The next time you apply
the stack the existing volumes/disks will be reattached and your data will be
available again.

### Removing all resources

If you really want to delete the persistent volumes as well, you can either
remove the lifecycle hooks and attachments from the Terraform code or force
Terraform to target the volumes.  For example:

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