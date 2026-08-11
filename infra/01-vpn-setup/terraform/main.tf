# main.tf
# -----------------------------------------------------------------------------
# All AWS infrastructure for the OpenVPN-over-SSM deployment.
# Terraform builds infrastructure ONLY. Ansible (connecting over AWS SSM) does
# all OpenVPN install/config/client work — see ../ansible/.
# -----------------------------------------------------------------------------

# Account id is used to name the (globally-unique) SSM transfer bucket.
data "aws_caller_identity" "current" {}

# Detect YOUR current public IP at apply time so SSH can be locked to just you.
# If your IP changes (new network/ISP/travel), re-run `terraform apply` to update it.
data "http" "my_public_ip" {
  url = "https://checkip.amazonaws.com"
}

# ------------------------------- VPC -----------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

# ------------------------------ Subnets --------------------------------------
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name_prefix}-public-subnet" }
}

resource "aws_subnet" "private" {
  count             = var.enable_private_networking ? 1 : 0
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${local.name_prefix}-private-subnet" }
}

# ---------------------------- NAT gateway ------------------------------------
# Outbound-only internet for the private subnet. Lives in the public subnet.
resource "aws_eip" "nat" {
  count  = var.enable_private_networking ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${local.name_prefix}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_private_networking ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${local.name_prefix}-nat" }
  depends_on    = [aws_internet_gateway.this]
}

# ---------------------------- Route tables -----------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = var.enable_private_networking ? 1 : 0
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[0].id
  }
  tags = { Name = "${local.name_prefix}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = var.enable_private_networking ? 1 : 0
  subnet_id      = aws_subnet.private[0].id
  route_table_id = aws_route_table.private[0].id
}

# --------------------------- Security groups ---------------------------------
resource "aws_security_group" "openvpn" {
  name        = "${local.name_prefix}-openvpn-sg"
  description = "OpenVPN host. Management is via AWS SSM (no inbound SSH required)."
  vpc_id      = aws_vpc.this.id

  # OpenVPN data channel (UDP 1194) from anywhere.
  ingress {
    description = "OpenVPN UDP 1194"
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Break-glass SSH, restricted to your auto-detected public IP only. SSM is primary.
  ingress {
    description = "SSH (break-glass) from your detected public IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.admin_ssh_cidr]
  }

  # Outbound all — the SSM agent needs HTTPS (443) to AWS; OpenVPN needs egress.
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-openvpn-sg" }
}

resource "aws_security_group" "private" {
  count       = var.enable_private_networking ? 1 : 0
  name        = "${local.name_prefix}-private-sg"
  description = "Private resources: reachable from the VPC and from VPN clients."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "From inside the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  ingress {
    description = "From VPN clients"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpn_client_cidr]
  }
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.name_prefix}-private-sg" }
}

# ----------------------------- Ubuntu AMI ------------------------------------
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

# -------------------- S3 bucket for Ansible SSM file transfer ----------------
# The aws_ssm connection plugin moves files to/from the host via this bucket
# (this is how admin_user.ovpn is fetched back without SSH/SCP).
resource "aws_s3_bucket" "ssm_transfer" {
  bucket        = local.ssm_transfer_bucket
  force_destroy = true # let `terraform destroy` remove it even if not empty
  tags          = { Name = "${local.name_prefix}-ssm-transfer" }
}

resource "aws_s3_bucket_public_access_block" "ssm_transfer" {
  bucket                  = aws_s3_bucket.ssm_transfer.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------- IAM role + instance profile for SSM ------------------------
data "aws_iam_policy_document" "ssm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm" {
  name               = "${local.name_prefix}-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.ssm_assume.json
  tags               = { Name = "${local.name_prefix}-ssm-role" }
}

# Core SSM permissions: lets the agent register and run commands.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Let the instance use the SSM file-transfer bucket (Ansible aws_ssm plugin).
data "aws_iam_policy_document" "ssm_s3" {
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.ssm_transfer.arn}/*"]
  }
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.ssm_transfer.arn]
  }
}

resource "aws_iam_role_policy" "ssm_s3" {
  name   = "${local.name_prefix}-ssm-s3"
  role   = aws_iam_role.ssm.id
  policy = data.aws_iam_policy_document.ssm_s3.json
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${local.name_prefix}-ssm-profile"
  role = aws_iam_role.ssm.name
}

# ------------------- SSH key pair (break-glass admin access) -----------------
# Terraform GENERATES the key pair and saves the private key (.pem) to the repo
# root as <ssh_key_name>.pem. AWS only ever stores the PUBLIC key. SSM is the
# primary path; SSH is for emergency / manual administration.
resource "tls_private_key" "ovpn_admin" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ovpn_admin" {
  key_name   = var.ssh_key_name
  public_key = tls_private_key.ovpn_admin.public_key_openssh
  tags       = { Name = "${local.name_prefix}-admin-key" }
}

# Save the private key to the repository root as ovpn-admin.pem (owner-only, 0600).
# Use it with:  ssh -i ovpn-admin.pem ubuntu@<server-ip>
# (.gitignore already excludes *.pem, so it is never committed.)
resource "local_sensitive_file" "ovpn_admin_pem" {
  content         = tls_private_key.ovpn_admin.private_key_pem
  filename        = "${path.module}/../${var.ssh_key_name}.pem"
  file_permission = "0600"
}

# --------------------------- OpenVPN EC2 host --------------------------------
resource "aws_instance" "openvpn" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.openvpn.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  key_name               = aws_key_pair.ovpn_admin.key_name # break-glass SSH (SSM is primary)

  # This host forwards/NATs VPN traffic, so AWS must stop dropping packets that
  # aren't addressed to/from the instance itself.
  source_dest_check = false

  # Terraform does NOT install OpenVPN. This only ensures the SSM agent
  # (preinstalled on Ubuntu via snap) is running so the host registers with SSM.
  user_data = <<EOT
#!/bin/bash
set -eux
snap start amazon-ssm-agent || systemctl restart amazon-ssm-agent || true
EOT

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
  }

  tags = { Name = "${local.name_prefix}-openvpn" }
}

resource "aws_eip" "openvpn" {
  domain     = "vpc"
  instance   = aws_instance.openvpn.id
  tags       = { Name = "${local.name_prefix}-openvpn-eip" }
  depends_on = [aws_internet_gateway.this]
}

# ---------------- Generated Ansible inventory (SSM, no SSH) ------------------
resource "local_file" "ansible_inventory" {
  filename             = "${path.module}/../ansible/inventory.ini"
  file_permission      = "0644"
  directory_permission = "0755"

  content = <<EOT
# AUTO-GENERATED by Terraform (local_file.ansible_inventory). Do not edit by hand.
[openvpn]
vpn ansible_host=${aws_instance.openvpn.id}

[openvpn:vars]
ansible_connection=community.aws.aws_ssm
ansible_aws_ssm_region=${var.region}
ansible_aws_ssm_bucket_name=${local.ssm_transfer_bucket}
ansible_aws_ssm_instance_id=${aws_instance.openvpn.id}
ansible_aws_ssm_s3_addressing_style=virtual
ansible_python_interpreter=/usr/bin/python3
openvpn_public_ip=${aws_eip.openvpn.public_ip}
EOT

  depends_on = [aws_s3_bucket.ssm_transfer]
}
