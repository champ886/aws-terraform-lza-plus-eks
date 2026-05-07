# -----------------------------------------------
# AWS REGION
# Region where management resources are deployed
# -----------------------------------------------
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

# -----------------------------------------------
# ENVIRONMENT
# Fixed as management to identify this environment
# -----------------------------------------------
variable "environment" {
  description = "Environment name"
  type        = string
  default     = "management"
}

# -----------------------------------------------
# ORGANIZATION ID
# Get from AWS console or CLI
# aws organizations describe-organization
# -----------------------------------------------
variable "org_id" {
  description = "AWS Organization ID"
  type        = string
  default     = "o-mrik3s6w85"
}

# -----------------------------------------------
# LOG RETENTION
# Days before CloudWatch logs are auto deleted
# -----------------------------------------------
variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 90
}

# -----------------------------------------------
# APPROVED REGIONS
# SCP blocks all other regions automatically
# -----------------------------------------------
variable "approved_regions" {
  description = "List of approved AWS regions"
  type        = list(string)
  default     = ["ap-southeast-2"]
}

# -----------------------------------------------
# DEV WORKLOAD ACCOUNT
# Email must be globally unique across all AWS
# -----------------------------------------------
variable "workload_dev_account_name" {
  description = "Name of the workload dev account"
  type        = string
  default     = "dev-workload-account"
}

variable "workload_dev_account_email" {
  description = "Email for the workload dev account"
  type        = string
  default = "aws-dev-workload@algorhythm.au"
}

# -----------------------------------------------
# PROD WORKLOAD ACCOUNT
# Must use a different email from dev account
# -----------------------------------------------
variable "workload_prod_account_name" {
  description = "Name of the workload prod account"
  type        = string
  default     = "prod-workload-account"
}

variable "workload_prod_account_email" {
  description = "Email for the workload prod account"
  type        = string
  default     = "aws-prod-workload@algorhythm.au"
}

# -----------------------------------------------
# SECURITY ACCOUNT
# Hosts centralised security tooling
# -----------------------------------------------
variable "security_account_name" {
  description = "Name of the security account"
  type        = string
  default     = "security-account"
}

variable "security_account_email" {
  description = "Email for the security account"
  type        = string
  default     = "aws-security@algorhythm.au"
}

# -----------------------------------------------
# IAM ANALYZER TYPE
# ORGANIZATION scans all accounts in the org
# -----------------------------------------------
variable "analyzer_type" {
  description = "IAM Access Analyzer type — ACCOUNT or ORGANIZATION"
  type        = string
  default     = "ORGANIZATION"
}

variable "workload_dev_account_id" {
  description = "Dev workload account ID"
  type        = string
  default     = "435321828725"
}

variable "workload_prod_account_id" {
  description = "Prod workload account ID"
  type        = string
  default     = "774386608951"
}

variable "state_bucket_name" {
  description = "S3 bucket for Terraform state"
  type        = string
  default     = "tf-state-landing-zone-champ-001"
}