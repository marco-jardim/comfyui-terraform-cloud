terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

############## Fetch the latest AMI ID ##############
data "aws_ssm_parameter" "dlami" {
  name = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id"
}

locals {
  dlami_id = data.aws_ssm_parameter.dlami.value
}

# Instance uses the subnet created below
resource "aws_instance" "comfy" {
  ami                                  = local.dlami_id
  instance_type                        = var.instance_type
  key_name                             = aws_key_pair.comfy.key_name
  subnet_id                            = aws_subnet.public_a.id
  vpc_security_group_ids               = [aws_security_group.comfy.id]
  user_data                            = file("${path.module}/userdata/install_comfyui.sh")
  instance_initiated_shutdown_behavior = "stop"

  # add the market options only when purchase_option == "spot"
  dynamic "instance_market_options" {
    for_each = var.purchase_option == "spot" ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
      }
    }
  }

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = false
  }

  tags = { Name = "comfyui" }
}

# Volumes stay in the same availability zone
resource "aws_ebs_volume" "models" {
  availability_zone = var.availability_zone
  size              = 500
  type              = "gp3"
  tags              = { Name = "comfy-models" }
}

resource "aws_ebs_volume" "media" {
  availability_zone = var.availability_zone
  size              = 1000
  type              = "gp3"
  tags              = { Name = "comfy-media" }
}

/* attach the models volume as /dev/sdf */
resource "aws_volume_attachment" "attach_models" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.models.id
  instance_id  = aws_instance.comfy.id
  skip_destroy = true # keeps the volume if the instance is destroyed
}

# attach as /dev/sdg
resource "aws_volume_attachment" "attach_media" {
  device_name  = "/dev/sdg"
  volume_id    = aws_ebs_volume.media.id
  instance_id  = aws_instance.comfy.id
  skip_destroy = true
}

# VPC
resource "aws_vpc" "main" {
  cidr_block = "172.31.0.0/16"
}

# Public subnet
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.31.0.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
}

# Security group now linked to the created VPC
resource "aws_security_group" "comfy" {
  name_prefix = "comfyui"
  description = "ssh and comfyui access"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ComfyUI"
    from_port   = 8188
    to_port     = 8188
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "comfy-sg" }
}

output "subnet_id" {
  value = aws_subnet.public_a.id
}

# create or import the public key automatically
resource "aws_key_pair" "comfy" {
  key_name   = "comfyui-aws" # name that will appear in the account
  public_key = file(pathexpand("~/.ssh/id_ed25519.pub"))
  #                           └── Terraform expands ~ to:
  #                               C:\\Users\\<you> on Windows
  #                               /home/<you>    on Linux
}