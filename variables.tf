variable "region" {
  type    = string
  default = "us-east-1"
}

variable "availability_zone" {
  type    = string
  default = "us-east-1a"
}

variable "subnet_id" {
  type = string
}

variable "key_name" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "aws_region" { type = string }

variable "instance_type" {
  type    = string
  default = "g6.12xlarge"
}