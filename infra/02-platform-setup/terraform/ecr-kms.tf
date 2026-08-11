# --- ECR repositories (one per image) ---
resource "aws_ecr_repository" "this" {
  for_each = toset(var.ecr_repositories)

  name                 = "${var.project}/${each.value}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # dev: allow `terraform destroy` to remove non-empty repos

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.project}/${each.value}" }
}

# Expire untagged images after 14 days to control storage cost.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 14 }
      action       = { type = "expire" }
    }]
  })
}

# --- KMS key for application secrets (env vars retrieved before container start) ---
resource "aws_kms_key" "secrets" {
  description             = "${local.name} application secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "${local.name}-secrets" }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${local.name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}
