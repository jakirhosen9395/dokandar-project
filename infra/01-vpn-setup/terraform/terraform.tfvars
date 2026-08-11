# terraform.tfvars
# -----------------------------------------------------------------------------
# Your actual values. Terraform loads this file automatically on plan/apply.
# Edit these to match your environment.
#
# This file may contain environment-specific values but NO secrets.
# Do not commit real production values to a public repository.
# -----------------------------------------------------------------------------

region       = "ap-southeast-1"
project_name = "ovpn"
environment  = "dev"

vpc_cidr            = "10.0.0.0/16"
public_subnet_cidr  = "10.0.1.0/24"
private_subnet_cidr = "10.0.2.0/24"
vpn_client_cidr     = "10.8.0.0/24"
availability_zone   = "ap-southeast-1a"

# enable_private_networking = false  # true = also build private subnet + NAT gateway (adds ~$32/mo)

instance_type = "t3.micro"

# SSH key pair is created/managed by Terraform from ~/.ssh/ovpn-admin.pub
# (see ssh_key_name / ssh_public_key_path in variables.tf).
