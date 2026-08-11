variable "region" {
  description = "AWS region (must match 01-vpn-setup)."
  type        = string
  default     = "ap-southeast-1"
}

variable "availability_zone" {
  description = "AZ for the two new subnets (keep in the same AZ as the VPN subnet)."
  type        = string
  default     = "ap-southeast-1a"
}

variable "project" {
  description = "Project name / resource prefix."
  type        = string
  default     = "dokandar"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "subnet_cidrs" {
  description = "CIDRs for the two platform subnets. Must be inside 01-vpn-setup's VPC CIDR and must NOT collide with its subnets (the VPN's public subnet is 10.0.1.0/24)."
  type = object({
    public  = string # gitlab-runner
    private = string # utilities
  })
  default = {
    public  = "10.0.2.0/24"
    private = "10.0.11.0/24"
  }
}

variable "instance_types" {
  description = <<-EOT
    Per-role instance types. RUNNER SIZING STRATEGY:
      build phase : c5.2xlarge (8 vCPU / 16 GiB) — all 20 images build concurrently
      steady state: m7i-flex.large (2 vCPU / 8 GiB) — plenty for occasional pushes
    Downsized AUTOMATICALLY by ansible/downsize-runner.yml (runs at the end of
    deploy.yml: ~20 min after pipelines are triggered), or manually:
      terraform apply -var 'instance_types={gitlab_runner="m7i-flex.large",utilities="m7i-flex.large"}'
    (in-place stop/resize/start; the registered runner + Docker survive)
  EOT
  type = object({
    gitlab_runner = string
    utilities     = string
  })
  default = {
    gitlab_runner = "c5.2xlarge"
    utilities     = "m7i-flex.large"
  }
}

variable "ecr_repositories" {
  description = "ECR repositories to create (one per image). Namespaced under <project>/."
  type        = list(string)
  default = [
    "frontend",
    "00-support", "01-auth", "02-profile", "03-seller", "04-catalog", "05-search",
    "06-cart", "07-coupon", "08-review", "09-payment", "10-wallet", "11-reporting",
    "12-media", "13-order", "14-notification", "15-api-gateway", "16-recommendation",
    "17-shipping", "18-risk-trust",
  ]
}
