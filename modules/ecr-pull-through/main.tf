# -----------------------------------------------
# PROVIDER REQUIREMENTS
# -----------------------------------------------
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.workload]
    }
  }
}

# -----------------------------------------------
# ECR PULL THROUGH CACHE RULES
# Automatically caches images from public
# registries into your private ECR on first pull
# Nodes never need internet access
# -----------------------------------------------

# registry.k8s.io — cluster-autoscaler
resource "aws_ecr_pull_through_cache_rule" "registry_k8s_io" {
  provider              = aws.workload
  ecr_repository_prefix = "registry-k8s-io"
  upstream_registry_url = "registry.k8s.io"
}

# public.ecr.aws — AWS public images
resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  provider              = aws.workload
  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
}

# docker.io — Docker Hub (grafana, prometheus etc)
resource "aws_ecr_pull_through_cache_rule" "docker_hub" {
  provider              = aws.workload
  ecr_repository_prefix = "docker-hub"
  upstream_registry_url = "registry-1.docker.io"
  credential_arn        = aws_secretsmanager_secret.docker_hub.arn
}

# quay.io — fallback for some charts
resource "aws_ecr_pull_through_cache_rule" "quay" {
  provider              = aws.workload
  ecr_repository_prefix = "quay"
  upstream_registry_url = "quay.io"
}

# -----------------------------------------------
# DOCKER HUB CREDENTIALS
# Docker Hub requires auth for pull through cache
# Using empty credentials for public images
# (unauthenticated — 100 pulls/6hrs per IP)
# -----------------------------------------------
resource "aws_secretsmanager_secret" "docker_hub" {
  provider                = aws.workload
  name                    = "ecr-pullthroughcache/docker-hub"
  recovery_window_in_days = 0

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_secretsmanager_secret_version" "docker_hub" {
  provider  = aws.workload
  secret_id = aws_secretsmanager_secret.docker_hub.id

  secret_string = jsonencode({
    username = var.docker_hub_username
    accessToken = var.docker_hub_token
  })
}

# -----------------------------------------------
# ECR LIFECYCLE POLICIES
# Keep only last 5 images per repo to control
# storage costs — old cached images auto-deleted
# -----------------------------------------------
resource "aws_ecr_lifecycle_policy" "pull_through_cleanup" {
  provider   = aws.workload
  for_each   = toset([
    "registry-k8s-io",
    "ecr-public",
    "docker-hub",
    "quay"
  ])
  repository = each.value

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })

  depends_on = [
    aws_ecr_pull_through_cache_rule.registry_k8s_io,
    aws_ecr_pull_through_cache_rule.ecr_public,
    aws_ecr_pull_through_cache_rule.docker_hub,
    aws_ecr_pull_through_cache_rule.quay
  ]
}