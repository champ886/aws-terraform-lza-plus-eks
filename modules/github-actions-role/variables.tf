variable "environment" {
  description = "Environment name — used in tags"
  type        = string
}

variable "role_name" {
  description = "Name of the IAM role GitHub Actions will assume"
  type        = string
  default     = "GitHubActionsRole"
}

# -----------------------------------------------
# GITHUB REPO
# Format: owner/repo-name
# Trust is scoped to this repo only
# -----------------------------------------------
variable "github_repo" {
  description = "GitHub repo in owner/repo format — trust is scoped to this repo only"
  type        = string
  default     = "champ886/aws-terraform-lza-plus-eks"
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository GitHub Actions is allowed to push to"
  type        = string
}