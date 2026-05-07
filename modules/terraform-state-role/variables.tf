variable "environment" {
  description = "Environment name"
  type        = string
}

variable "dev_account_id" {
  description = "Dev workload account ID"
  type        = string
}

variable "prod_account_id" {
  description = "Prod workload account ID"
  type        = string
}

variable "state_bucket_name" {
  description = "S3 bucket name for Terraform state"
  type        = string
}

variable "lock_table_name" {
  description = "DynamoDB table name for Terraform locks"
  type        = string
  default     = "tf-locks"
}