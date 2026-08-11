# DOKANDAR platform — runner (public) + utilities (private).
# The VPC, internet gateway and VPN entry point are OWNED by ../../01-vpn-setup;
# this project reads them via terraform_remote_state and only adds its own
# subnets, NAT, security groups, IAM, ECR/KMS and two EC2 instances.
#
# Apply order: 01-vpn-setup first (creates VPC + exports outputs), then this.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    tls   = { source = "hashicorp/tls", version = "~> 4.0" }
    local = { source = "hashicorp/local", version = "~> 2.4" }
    http  = { source = "hashicorp/http", version = "~> 3.4" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# Admin public IP -> break-glass SSH ingress on the public runner.
data "http" "my_public_ip" {
  url = "https://checkip.amazonaws.com"
}

# Network facts from 01-vpn-setup (VPC, IGW, VPN client CIDR).
# 01-vpn-setup stores its state in S3 (see its backend.tf) — read the SAME
# bucket/key here. If 01's backend ever changes, mirror it here.
data "terraform_remote_state" "vpn" {
  backend = "s3"
  config = {
    bucket = "123456789123-terraform-s3-backend-for-dokandar"
    key    = "ovpn/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  name = "${var.project}-${var.environment}"

  vpc_id          = data.terraform_remote_state.vpn.outputs.vpc_id
  vpc_cidr        = data.terraform_remote_state.vpn.outputs.vpc_cidr
  igw_id          = data.terraform_remote_state.vpn.outputs.igw_id
  vpn_client_cidr = data.terraform_remote_state.vpn.outputs.vpn_client_cidr

  admin_cidr = "${chomp(data.http.my_public_ip.response_body)}/32"

  # The two platform instances.
  instances = {
    gitlab-runner = {
      subnet  = "public"
      type    = var.instance_types.gitlab_runner
      disk    = 50
      public  = true
      profile = "runner"
      desc    = "Self-hosted GitLab Runner — runs all pipelines, builds images, pushes to ECR"
    }
    utilities = {
      subnet  = "private"
      type    = var.instance_types.utilities
      disk    = 50
      public  = false
      profile = "utilities"
      desc    = "Utilities host — the 16 backing tools in Docker (reached over the VPN)"
    }
  }
}

# Ubuntu 24.04 LTS (same lookup as 01-vpn-setup).
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}
