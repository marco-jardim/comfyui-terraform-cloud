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

variable "aws_region" {
  type = string
}

# "spot" = persistent Spot instance
# "on-demand" (or empty) = normal billing
variable "purchase_option" {
  description = "Instance billing model: spot or on-demand"
  type        = string
  default     = "on-demand"

  validation {
    condition     = can(regex("^(spot|on-demand)$", var.purchase_option))
    error_message = "purchase_option must be \"spot\" or \"on-demand\"."
  }
}

variable "instance_type" {
  type    = string
  default = "g6.12xlarge"
}