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

# -----------------------------------------------
# ARGO CD ROOT APP — APPLIED VIA kubectl PROVIDER
# Uses gavinbunney/kubectl which defers CRD
# validation to apply time, not plan time
# This means it works even though the Application
# CRD is installed by helm_release.argocd above
# in the same Terraform run
#
# No local-exec, no shell credential issues,
# no manual kubectl apply needed after destroy
# Fully baked into IaC — destroy and re-apply
# restores everything automatically
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
        repoURL: ${var.gitops_repo_url}
        targetRevision: ${var.gitops_target_revision}
        path: gitops/apps/dev
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