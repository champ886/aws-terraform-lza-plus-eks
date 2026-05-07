# -----------------------------------------------
# PROVIDER REQUIREMENTS
# -----------------------------------------------
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

# -----------------------------------------------
# TERRAFORM STATE ROLE
# Centralised role in management account
# Allows all child accounts to access shared
# S3 state bucket and DynamoDB lock table
# -----------------------------------------------
resource "aws_iam_role" "terraform_state" {
  name        = "TerraformStateRole"
  description = "Allows child accounts to access centralised Terraform state"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = [
            "arn:aws:iam::${var.dev_account_id}:root",
            "arn:aws:iam::${var.prod_account_id}:root",
            "arn:aws:iam::501562869247:root"
          ]
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# -----------------------------------------------
# TERRAFORM STATE POLICY
# Scoped only to the state bucket and lock table
# -----------------------------------------------
resource "aws_iam_role_policy" "terraform_state" {
  name = "TerraformStatePolicy"
  role = aws_iam_role.terraform_state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.state_bucket_name}",
          "arn:aws:s3:::${var.state_bucket_name}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:aws:dynamodb:ap-southeast-2:501562869247:table/${var.lock_table_name}"
      }
    ]
  })
}

# -----------------------------------------------
# S3 BUCKET POLICY
# Allows TerraformStateRole to access state bucket
# cross-account from dev and prod
# -----------------------------------------------
resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = var.state_bucket_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowTerraformStateRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.terraform_state.arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.state_bucket_name}",
          "arn:aws:s3:::${var.state_bucket_name}/*"
        ]
      }
    ]
  })
}