# -----------------------------------------------
# PROVIDER REQUIREMENTS
# Must be at the top of the file
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
  }
}

# -----------------------------------------------
# ARGO CD NAMESPACE
# Standard namespace — do not change the name
# Argo CD's own manifests hard-reference
# argocd as the namespace
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
# Image pulled via quay pull-through cache
# quay prefix → quay.io (already configured in
# modules/ecr-pull-through/main.tf)
# Argo CD is published on quay.io/argoproj/argocd
# NOT on public.ecr.aws — ecr-public prefix will
# not find this image
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

  # -----------------------------------------------
  # INSECURE MODE — TLS TERMINATED AT ALB
  # -----------------------------------------------
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
    value = "256Mi"
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