# backend.tf
# -----------------------------------------------------------------------------
# The "backend" decides WHERE Terraform stores its state file (terraform.tfstate).
# State is how Terraform remembers what it has already created.
#
# We start with the LOCAL backend: state is a file on your computer. This is the
# simplest option and is perfect for learning or a single person.
#
# When a TEAM shares the infrastructure, switch to a REMOTE backend (S3 + DynamoDB)
# so everyone uses the same state and two people cannot run apply at the same time.
# -----------------------------------------------------------------------------

# terraform {
#   backend "local" {
#     path = "terraform.tfstate"
#   }
# }

# -----------------------------------------------------------------------------
# OPTIONAL: remote backend on AWS.
#
# Use this when:
#   * More than one person manages this infrastructure.
#   * You want state stored safely off your laptop (encrypted and versioned).
#   * You want state LOCKING so two applies cannot run at the same time.
#
# How to switch:
#   1. Create an S3 bucket (stores the state file) and a DynamoDB table (for the
#      lock) ONCE, by hand or in a separate Terraform project. The DynamoDB table
#      must have a primary key named exactly "LockID" (type String).
#   2. Replace the `backend "local"` block above with the block below.
#   3. Run: terraform init -migrate-state
#

terraform {
  backend "s3" {
    bucket       = "123456789123-terraform-s3-backend-for-dokandar" # placeholder — replace with YOUR state bucket
    key          = "ovpn/terraform.tfstate"
    region       = "ap-southeast-1"
    use_lockfile = true # S3-native state locking (Terraform >= 1.10; no DynamoDB needed)
    encrypt      = true
  }
}

# -----------------------------------------------------------------------------
