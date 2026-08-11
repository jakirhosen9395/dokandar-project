# outputs.tf
# -----------------------------------------------------------------------------
# Values printed after `terraform apply`. Read any of them later with:
#   terraform output            (all)
#   terraform output -raw NAME  (one value, no quotes)
# -----------------------------------------------------------------------------

# ---- Who is allowed to SSH ----
output "detected_admin_ip" {
  description = "Your public IP that Terraform detected and allowed for SSH (port 22)."
  value       = local.detected_admin_ip
}

# ---- VPN server addresses ----
output "vpn_server_public_ip" {
  description = "Public/Elastic IP of the OpenVPN server (VPN clients connect here)."
  value       = aws_eip.openvpn.public_ip
}

output "vpn_server_private_ip" {
  description = "Private IP of the OpenVPN server inside the VPC."
  value       = aws_instance.openvpn.private_ip
}

output "vpn_server_instance_id" {
  description = "EC2 instance ID (used as the SSM target and inventory host)."
  value       = aws_instance.openvpn.id
}

# ---- Primary access: AWS SSM (works from anywhere, no open ports) ----
output "ssm_command" {
  description = "Open an interactive shell on the server over AWS SSM (no SSH needed)."
  value       = "aws ssm start-session --target ${aws_instance.openvpn.id} --region ${var.region}"
}

# ---- Secondary access: SSH (break-glass only, needs outbound TCP 22) ----
output "ssh_command" {
  description = "Break-glass SSH command using the Terraform-generated .pem in the repo root."
  value       = "ssh -i ${abspath("${path.module}/../${var.ssh_key_name}.pem")} ubuntu@${aws_eip.openvpn.public_ip}"
}

output "ssh_private_key_path" {
  description = "Path to the Terraform-generated SSH private key (.pem) saved in the repo root."
  value       = abspath("${path.module}/../${var.ssh_key_name}.pem")
}

# ---- Helpers for the Ansible workflow ----
output "ssm_transfer_bucket" {
  description = "S3 bucket Ansible's aws_ssm connection uses to move files (no SSH/SCP)."
  value       = local.ssm_transfer_bucket
}

output "ansible_inventory_entry" {
  description = "The SSM-based Ansible inventory host line (Terraform also writes ../ansible/inventory.ini)."
  value       = "openvpn ansible_host=${aws_instance.openvpn.id} ansible_connection=community.aws.aws_ssm ansible_aws_ssm_region=${var.region} ansible_aws_ssm_bucket_name=${local.ssm_transfer_bucket}"
}

# ---- Network facts consumed by ../../02-platform-setup (terraform_remote_state) ----
output "vpc_id" {
  description = "VPC id — 02-platform-setup creates its subnets inside this VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "igw_id" {
  description = "Internet gateway id (02-platform-setup routes its public subnet through it)."
  value       = aws_internet_gateway.this.id
}

output "public_subnet_id" {
  description = "The VPN public subnet id."
  value       = aws_subnet.public.id
}

output "vpn_client_cidr" {
  description = "CIDR handed to VPN clients (allowed into 02's private security groups)."
  value       = var.vpn_client_cidr
}

output "availability_zone" {
  description = "AZ used by this VPC's subnets."
  value       = var.availability_zone
}
