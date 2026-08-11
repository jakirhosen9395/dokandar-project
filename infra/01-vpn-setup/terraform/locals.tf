# locals.tf
# -----------------------------------------------------------------------------
# Reusable values computed once and used in many places.
# -----------------------------------------------------------------------------

locals {
  # Prefix for every resource name, e.g. "ovpn-dev".
  name_prefix = "${var.project_name}-${var.environment}"

  # Tags applied to every resource via the provider's default_tags.
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  # S3 bucket the Ansible `aws_ssm` connection plugin uses to transfer files
  # to/from the instance (this is how files move without SSH/SCP).
  ssm_transfer_bucket = "${data.aws_caller_identity.current.account_id}-ovpn-ssm-transfer"

  # Your current public IP, detected automatically by data "http" "my_public_ip".
  # chomp() removes the trailing newline that checkip.amazonaws.com returns.
  detected_admin_ip = chomp(data.http.my_public_ip.response_body)

  # The same IP as a /32 CIDR, used in the SSH security-group rule.
  admin_ssh_cidr = "${local.detected_admin_ip}/32"
}
