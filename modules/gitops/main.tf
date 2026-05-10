# -----------------------------------------------
# PROVIDER REQUIREMENTS
# -----------------------------------------------
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.workload]
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

# -----------------------------------------------
# ECR OCI REPOSITORY FOR GITOPS MANIFESTS
# Argo CD reads manifests from this private ECR
# repo via the existing ECR VPC endpoint —
# no internet egress required, fully consistent
# with the pull-through cache architecture
#
# Naming convention matches your existing repos:
#   <account>.dkr.ecr.<region>.amazonaws.com/gitops/apps/dev
# -----------------------------------------------
resource "aws_ecr_repository" "gitops" {
  provider             = aws.workload
  name                 = "gitops/apps/${var.environment}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = {
    Name        = "gitops-apps-${var.environment}"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# -----------------------------------------------
# ECR LIFECYCLE POLICY
# Keep only the last 10 OCI artifact versions
# Prevents unbounded storage growth as CI pushes
# new versions on every commit
# -----------------------------------------------
resource "aws_ecr_lifecycle_policy" "gitops" {
  provider   = aws.workload
  repository = aws_ecr_repository.gitops.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 gitops artifact versions"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# -----------------------------------------------
# ECR REPOSITORY POLICY
# Grants the EKS node role read access so that
# Argo CD repo-server (running on nodes) can pull
# the OCI artifact via the ECR VPC endpoint
# -----------------------------------------------
resource "aws_ecr_repository_policy" "gitops" {
  provider   = aws.workload
  repository = aws_ecr_repository.gitops.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEKSNodePull"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.aws_account_id}:root"
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetAuthorizationToken",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
        ]
      }
    ]
  })
}

# -----------------------------------------------
# ARGO CD NAMESPACE
# -----------------------------------------------
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      name        = "argocd"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# -----------------------------------------------
# ARGO CD HELM RELEASE
# -----------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = kubernetes_namespace.argocd.metadata[0].name
  version          = "7.3.4"
  timeout          = 900
  wait             = true
  wait_for_jobs    = true
  create_namespace = false
  atomic           = false

  set {
    name  = "redis-ha.enabled"
    value = "false"
  }

  set {
    name  = "controller.replicas"
    value = "1"
  }

  set {
    name  = "server.replicas"
    value = "1"
  }

  set {
    name  = "repoServer.replicas"
    value = "1"
  }

  set {
    name  = "applicationSet.replicas"
    value = "1"
  }

  set {
    name  = "server.insecure"
    value = "true"
  }

  # -----------------------------------------------
  # DISABLE DEX — NOT NEEDED FOR SINGLE-USER DEV
  # Re-enable when you need SSO/OIDC integration
  # -----------------------------------------------
  set {
    name  = "dex.enabled"
    value = "false"
  }

  # -----------------------------------------------
  # REDIS IMAGE — docker-hub pull-through
  # -----------------------------------------------
  set {
    name  = "redis.image.repository"
    value = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/docker-hub/library/redis"
  }

  # -----------------------------------------------
  # ARGO CD IMAGE — quay pull-through
  # -----------------------------------------------
  set {
    name  = "global.image.repository"
    value = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/quay/argoproj/argocd"
  }

  set {
    name  = "server.resources.requests.cpu"
    value = "50m"
  }

  set {
    name  = "server.resources.requests.memory"
    value = "64Mi"
  }

  set {
    name  = "server.resources.limits.cpu"
    value = "200m"
  }

  set {
    name  = "server.resources.limits.memory"
    value = "128Mi"
  }

  set {
    name  = "controller.resources.requests.cpu"
    value = "100m"
  }

  set {
    name  = "controller.resources.requests.memory"
    value = "128Mi"
  }

  set {
    name  = "controller.resources.limits.cpu"
    value = "500m"
  }

  set {
    name  = "controller.resources.limits.memory"
    value = "512Mi"
  }

  depends_on = [kubernetes_namespace.argocd]
}

# -----------------------------------------------
# ARGO CD ROOT APP — OCI SOURCE
# Points at the private ECR OCI repo, not GitHub
# Argo CD pulls via ECR VPC endpoint — no internet
#
# The OCI artifact is pushed by GitHub Actions on
# every commit to main (see .github/workflows/)
#
# Tag "latest" is always the most recent push.
# Argo CD polls every 3 minutes by default.
#
# gavinbunney/kubectl defers CRD validation to
# apply time so this works in the same Terraform
# run that installs Argo CD via Helm above.
# Fully baked — destroy + reapply restores all.
# -----------------------------------------------
resource "kubectl_manifest" "argocd_root_app" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: root-app
      namespace: argocd
      labels:
        Environment: ${var.environment}
        ManagedBy: Terraform
    spec:
      project: default
      source:
        repoURL: ${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com
        chart: gitops/apps/${var.environment}
        targetRevision: latest
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
  YAML

  depends_on = [helm_release.argocd]
}