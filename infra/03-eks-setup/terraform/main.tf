# DOKANDAR EKS — cluster + 3 node pools matching the k8s manifests' node scheduling.
# VPC/IGW come from 01-vpn-setup (S3 remote state); the NAT gateway is 02-platform-setup's
# (looked up by tag, so 02's state is never touched). EKS needs TWO AZs, so this project
# adds its own 2 public + 2 private subnets.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    local = { source = "hashicorp/local", version = "~> 2.4" }
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

# VPC + IGW facts from 01-vpn-setup (same S3 backend it uses).
data "terraform_remote_state" "vpn" {
  backend = "s3"
  config = {
    bucket = "123456789123-terraform-s3-backend-for-dokandar"
    key    = "ovpn/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# 02-platform-setup's NAT gateway, found by tag (no cross-state coupling).
data "aws_nat_gateway" "platform" {
  filter {
    name   = "tag:Name"
    values = ["${var.project}-${var.environment}-nat"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  name            = "${var.project}-${var.environment}"
  cluster_name    = "${local.name}-eks"
  vpc_id          = data.terraform_remote_state.vpn.outputs.vpc_id
  igw_id          = data.terraform_remote_state.vpn.outputs.igw_id
  vpn_client_cidr = data.terraform_remote_state.vpn.outputs.vpn_client_cidr
}
