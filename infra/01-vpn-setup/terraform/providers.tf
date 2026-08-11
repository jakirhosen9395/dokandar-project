# providers.tf
# -----------------------------------------------------------------------------
# Configures the AWS provider. Version pins live in versions.tf.
# Credentials come from your environment (aws configure / env vars / IAM role) —
# never hard-code AWS keys here.
# -----------------------------------------------------------------------------

provider "aws" {
  region = var.region

  # Applied automatically to every taggable resource (no need to repeat them).
  default_tags {
    tags = local.common_tags
  }
}
