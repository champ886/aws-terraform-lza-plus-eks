###############################################################################
# BACKEND CONFIGURATION
# ---------------------
# Terraform needs to store "state" — a record of what infrastructure it has
# created. Without remote state, it's stored locally and can't be shared with
# a team or CI/CD pipeline.
#
# We use:
#   S3         → stores the .tfstate file (same bucket as the EKS layer)
#   use_lockfile → native S3 locking (no DynamoDB needed — newer approach)
#
# Note: We store app state under a different key to keep it separate from
# the EKS layer so each can be destroyed independently.
###############################################################################

terraform {
  backend "s3" {
    bucket       = "tf-state-landing-zone-champ-001"
    key          = "aws-lza/dev/app/terraform.tfstate"
    region       = "ap-southeast-2"
    encrypt      = true
    use_lockfile = true

    assume_role = {
      role_arn = "arn:aws:iam::501562869247:role/TerraformStateRole"
    }
  }
}