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
# GITHUB OIDC PROVIDER
# Created once per AWS account — allows GitHub
# Actions to authenticate via OIDC federation
# so no long-lived AWS keys are needed
#
# Thumbprint is GitHub's OIDC cert thumbprint —
# stable, but can be verified at:
# https://token.actions.githubusercontent.com
# -----------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name        = "github-actions-oidc"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# -----------------------------------------------
# GITHUB ACTIONS IAM ROLE
# Assumed by GitHub Actions via OIDC
# Trust is scoped to a specific repo only —
# no other repo can assume this role
# -----------------------------------------------
resource "aws_iam_role" "github_actions" {
  name = var.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
          }
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name        = var.role_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# -----------------------------------------------
# ECR PUSH POLICY
# Scoped to the specific ECR repo passed in
# GetAuthorizationToken is account-wide —
# required by all ECR clients, cannot be
# restricted to a single repo by AWS design
# -----------------------------------------------
resource "aws_iam_role_policy" "ecr_push" {
  name = "${var.role_name}-ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
        ]
        Resource = var.ecr_repository_arn
      }
    ]
  })
}