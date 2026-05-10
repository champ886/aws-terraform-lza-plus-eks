variable "environment" {
  description = "Environment name — used in labels and ECR repo path"
  type        = string
  default     = "dev"
}

variable "aws_account_id" {
  description = "AWS account ID — used to build ECR registry URL"
  type        = string
  default     = "435321828725"
}

variable "aws_region" {
  description = "AWS region — used to build ECR registry URL"
  type        = string
  default     = "ap-southeast-2"
}

# -----------------------------------------------
# GITOPS REPO URL
# Kept for reference/documentation only —
# Argo CD no longer reads directly from GitHub.
# GitHub Actions pushes manifests to ECR OCI.
# Remove this variable entirely once the team
# is comfortable with the OCI-only flow.
# -----------------------------------------------
variable "gitops_repo_url" {
  description = "GitHub repo URL — used for documentation only, not by Argo CD"
  type        = string
  default     = "https://github.com/champ886/aws-terraform-lza-plus-eks"
}

variable "gitops_target_revision" {
  description = "Kept for backwards compat — not used in OCI source mode"
  type        = string
  default     = "HEAD"
}