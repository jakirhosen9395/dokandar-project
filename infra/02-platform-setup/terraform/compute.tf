# SSH keys, IAM roles and the two EC2 instances.

# --- One SSH key pair per instance; private keys written to ../keys/*.pem ---
resource "tls_private_key" "instance" {
  for_each  = local.instances
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "instance" {
  for_each   = local.instances
  key_name   = "${local.name}-${each.key}"
  public_key = tls_private_key.instance[each.key].public_key_openssh
  tags       = { Name = "${local.name}-${each.key}-key" }
}

resource "local_sensitive_file" "pem" {
  for_each             = local.instances
  filename             = "${path.module}/../keys/${local.name}-${each.key}.pem"
  content              = tls_private_key.instance[each.key].private_key_pem
  file_permission      = "0600"
  directory_permission = "0700"
}

# --- IAM: EC2 assume-role trust ---
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Runner role: push+pull THIS project's ECR repos. SSM core for keyless admin.
resource "aws_iam_role" "runner" {
  name               = "${local.name}-runner-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name}-runner-role" }
}

resource "aws_iam_role_policy_attachment" "runner_ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "runner" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
      "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
    ]
    resources = [for r in aws_ecr_repository.this : r.arn]
  }
}

resource "aws_iam_role_policy" "runner" {
  name   = "${local.name}-runner-policy"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner.json
}

resource "aws_iam_instance_profile" "runner" {
  name = "${local.name}-runner-profile"
  role = aws_iam_role.runner.name
}

# Utilities role: SSM core only (managed shell without SSH; no AWS API needs).
resource "aws_iam_role" "utilities" {
  name               = "${local.name}-utilities-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name}-utilities-role" }
}

resource "aws_iam_role_policy_attachment" "utilities_ssm" {
  role       = aws_iam_role.utilities.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "utilities" {
  name = "${local.name}-utilities-profile"
  role = aws_iam_role.utilities.name
}

# --- The two EC2 instances ---
resource "aws_instance" "this" {
  for_each = local.instances

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = each.value.type
  subnet_id                   = each.value.subnet == "public" ? aws_subnet.public.id : aws_subnet.private.id
  key_name                    = aws_key_pair.instance[each.key].key_name
  vpc_security_group_ids      = [each.key == "gitlab-runner" ? aws_security_group.runner.id : aws_security_group.utilities.id]
  iam_instance_profile        = each.value.profile == "runner" ? aws_iam_instance_profile.runner.name : aws_iam_instance_profile.utilities.name
  associate_public_ip_address = each.value.public

  root_block_device {
    volume_size           = each.value.disk
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  tags = {
    Name = "${local.name}-${each.key}"
    Role = each.key
  }
}

# Stable public address for the runner.
resource "aws_eip" "runner" {
  instance = aws_instance.this["gitlab-runner"].id
  domain   = "vpc"
  tags     = { Name = "${local.name}-gitlab-runner-eip" }
}
