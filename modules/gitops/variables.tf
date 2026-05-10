variable "environment" {
  description = "Environment name — used in labels"
  type        = string
  default     = "dev"
}

variable "aws_account_id" {
  description = "AWS account ID — used to build ECR pull-through image path"
  type        = string
  default     = "435321828725"
}

variable "aws_region" {
  description = "AWS region — used to build ECR pull-through image path"
  type        = string
  default     = "ap-southeast-2"
}

# -----------------------------------------------
# GITOPS REPO URL
# This is the GitHub repo Argo CD will watch
# Use SSH URL for private repos with deploy key
# Use HTTPS URL for public repos (no auth needed)
# -----------------------------------------------
variable "gitops_repo_url" {
  description = "GitHub repo URL that Argo CD monitors for app manifests"
  type        = string
  default     = "https://github.com/champ886/aws-terraform-lza-plus-eks"
}

variable "gitops_target_revision" {
  description = "Git branch Argo CD tracks — HEAD means default branch"
  type        = string
  default     = "HEAD"
}