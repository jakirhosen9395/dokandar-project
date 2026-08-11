# variables.tf
# -----------------------------------------------------------------------------
# Every value a user can change lives here as an "input variable".
# Each variable has a type, a description, and a sensible default.
# Override any of them in terraform.tfvars (see that file for examples).
# -----------------------------------------------------------------------------

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-southeast-1" # Singapore
}

variable "project_name" {
  description = "Short project name, used as a prefix in resource names and tags."
  type        = string
  default     = "ovpn"
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod). Used in names and tags."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "IP range for the whole VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "IP range for the PUBLIC subnet (holds the OpenVPN server and the NAT Gateway)."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "IP range for the PRIVATE subnet (holds protected resources)."
  type        = string
  default     = "10.0.2.0/24"
}

variable "enable_private_networking" {
  description = "Create the private subnet + NAT gateway (and private route table/EIP/SG). Default false = lean VPN-only VPC: cheaper (~$32/mo less) and faster/cleaner to destroy. Set true to model a full public+private VPC."
  type        = bool
  default     = false
}

variable "vpn_client_cidr" {
  description = "IP range OpenVPN hands out to connected VPN clients (the tunnel subnet)."
  type        = string
  default     = "10.8.0.0/24"
}

variable "availability_zone" {
  description = "Availability Zone for both subnets (single-AZ design for simplicity)."
  type        = string
  default     = "ap-southeast-1a"
}

# NOTE: there is no admin_ip variable. Your public IP is detected automatically at
# apply time (see data "http" "my_public_ip" in main.tf and locals.tf). If your IP
# changes, just run `terraform apply` again to update the SSH firewall rule.

variable "instance_type" {
  description = "EC2 instance size for the OpenVPN server."
  type        = string
  default     = "t3.micro"
}

variable "ssh_key_name" {
  description = "Name of the EC2 key pair Terraform creates; also the .pem filename saved in the repo root."
  type        = string
  default     = "ovpn-admin"
}
