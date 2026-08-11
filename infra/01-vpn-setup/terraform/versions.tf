# versions.tf
# -----------------------------------------------------------------------------
# Pins the Terraform CLI version and the providers this project uses.
# Kept in its own file (separate from providers.tf) so version constraints are
# easy to find and review.
# -----------------------------------------------------------------------------

terraform {
  # use_lockfile (S3-native state locking) requires Terraform >= 1.10.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # any 5.x, never 6.0
    }
    # Used to write ../ansible/inventory.ini on the local disk after apply.
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    # Used to auto-detect your current public IP (for the SSH firewall rule).
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    # Used to generate the SSH key pair so Terraform can save the .pem locally.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
