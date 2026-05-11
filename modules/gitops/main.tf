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
# -----------------------------------------------
resource "aws_ecr_repository" "gitops" {
  provider             = aws.workload
  name                 = "gitops-apps-${var.environment}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true   

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
# -----------------------------------------------
resource "aws_ecr_repository_policy" "gitops" {
  provider   = aws.workload
  repository = aws_ecr_repository.gitops.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.aws_account_id}:root"
        }
        Action = "ecr:*"
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

  set {
    name  = "dex.enabled"
    value = "false"
  }

  set {
    name  = "redis.image.repository"
    value = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/docker-hub/library/redis"
  }

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
        chart: gitops-apps-${var.environment}
        targetRevision: 0.0.1
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
} # <--- ADDED THIS MISSING BRACE

# -----------------------------------------------
# ECR AUTHORIZATION TOKEN
# -----------------------------------------------
data "aws_ecr_authorization_token" "token" {
  provider = aws.workload
}

# -----------------------------------------------
# ARGO CD ECR CREDENTIALS SECRET
# -----------------------------------------------
resource "kubernetes_secret" "argocd_ecr_creds" {
  metadata {
    name      = "ecr-credentials"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type                  = "helm"
    name                  = "ecr-gitops"
    url                   = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    enableOCI             = "true"
    username              = "AWS"
    password              = data.aws_ecr_authorization_token.token.password
  }

  depends_on = [helm_release.argocd]
}
