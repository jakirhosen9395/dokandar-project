# Jump server — a plain EC2 in the PRIVATE subnet. SSH with its .pem over the VPN.
# This is the machine that holds dokandar-k8s-cluster-setup/jump-server (config/secrets)
# AND is the sole control host: it runs kubectl/helm/argocd against the cluster.
# It authenticates to EKS via its instance profile (below) + the EKS access entry
# in eks.tf — no AWS keys ever live on the box.

resource "tls_private_key" "jump" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ---- IAM: lets the jump server run `aws eks update-kubeconfig` + kubectl -------
data "aws_iam_policy_document" "jump_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jump" {
  name               = "${local.name}-jump-role"
  assume_role_policy = data.aws_iam_policy_document.jump_assume.json
}

# update-kubeconfig needs eks:DescribeCluster; the rest of the cluster authz comes
# from the EKS access entry (eks.tf), not from IAM.
resource "aws_iam_role_policy" "jump_eks" {
  name = "${local.name}-jump-eks"
  role = aws_iam_role.jump.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }]
  })
}

# SSM core = break-glass shell without SSH; ECR read = optional image-pull debugging.
resource "aws_iam_role_policy_attachment" "jump_ssm" {
  role       = aws_iam_role.jump.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "jump_ecr" {
  role       = aws_iam_role.jump.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "jump" {
  name = "${local.name}-jump-profile"
  role = aws_iam_role.jump.name
}

resource "aws_key_pair" "jump" {
  key_name   = "${local.name}-jump-server"
  public_key = tls_private_key.jump.public_key_openssh
}

resource "local_sensitive_file" "jump_pem" {
  filename             = "${path.module}/../keys/${local.name}-jump-server.pem"
  content              = tls_private_key.jump.private_key_pem
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "aws_security_group" "jump" {
  name                   = "${local.name}-jump-sg"
  description            = "Jump server - SSH from VPN clients and inside the VPC"
  vpc_id                 = local.vpc_id
  revoke_rules_on_delete = true

  ingress {
    description = "SSH from VPN clients"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.vpn_client_cidr]
  }
  ingress {
    description = "SSH from inside the VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.vpn.outputs.vpc_cidr]
  }
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.name}-jump-sg" }
}

data "aws_ami" "ubuntu_jump" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "jump" {
  ami                    = data.aws_ami.ubuntu_jump.id
  instance_type          = var.jump_instance_type
  subnet_id              = aws_subnet.private["a"].id
  key_name               = aws_key_pair.jump.key_name
  vpc_security_group_ids = [aws_security_group.jump.id]
  iam_instance_profile   = aws_iam_instance_profile.jump.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }
  tags = {
    Name = "${local.name}-jump-server"
    Role = "jump-server"
  }
}
