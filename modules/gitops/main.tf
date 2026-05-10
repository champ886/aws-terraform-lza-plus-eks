
# -----------------------------------------------
# QUICK FIX: MANUALLY CREATE ECR REPO
# This bypasses the need for nodes to have ecr:CreateRepository
# permissions for the pull-through cache to work.
# -----------------------------------------------
resource "aws_ecr_repository" "argocd_cache" {
  provider = aws.workload # Use the alias that manages your ECR/Workload resources
  name     = "ecr-public/argoproj/argocd"
}

# -----------------------------------------------
# PROVIDER REQUIREMENTS
# Helm provider points at lean-dev cluster
# aws.workload used to tag any AWS resources
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
# Installs Argo CD into the argocd namespace
# via the official Argo CD Helm chart
#
# Image routed via ECR pull-through cache
# (ecr-public prefix → public.ecr.aws)
# No internet access required from nodes
#
# server.insecure = true — disables TLS on the
# Argo CD server pod itself; TLS is terminated
# at the ALB. Do not set to false without also
# configuring a certificate on the Ingress.
#
# HA is disabled (ha.enabled = false) — this is
# dev. Single replica of each component is fine
# and saves ~2 t3.medium node slots
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
  

  # -----------------------------------------------
  # DISABLE HA — SINGLE REPLICA PER COMPONENT
  # Cuts resource usage by ~60% vs HA mode
  # Appropriate for dev; flip to true for prod
  # -----------------------------------------------
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
  # Argo CD server listens on plain HTTP
  # ALB Ingress below handles HTTPS if you add ACM
  # -----------------------------------------------
  set {
    name  = "server.insecure"
    value = "true"
  }

  # -----------------------------------------------
  # ECR PULL-THROUGH IMAGE OVERRIDE
  # Routes argocd image via ecr-public pull-through
  # (public.ecr.aws → ecr-public prefix)
  # Full path: <account>.dkr.ecr.<region>.amazonaws.com/ecr-public/argoproj/argocd
  # -----------------------------------------------
  set {
    name  = "global.image.repository"
    value = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/ecr-public/argoproj/argocd"
  }

  # -----------------------------------------------
  # LEAN RESOURCE LIMITS
  # Argo CD server + controller fit on 1 t3.medium
  # when not actively syncing many apps
  # -----------------------------------------------
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

  depends_on = [
    kubernetes_namespace.argocd,
    aws_ecr_repository.argocd_cache # Add this line
  ]
}

# -----------------------------------------------
# ARGO CD APP-OF-APPS — "ROOT APP"
# This single Argo CD Application resource points
# at gitops/apps/dev/ in your GitHub repo
# Argo CD then discovers and manages every YAML
# file under that path automatically
#
# This is the "App of Apps" pattern:
# - One root Application in Terraform
# - That root Application reads the gitops/ folder
# - Each sub-folder becomes an Argo CD Application
# - Argo CD reconciles all of them continuously
#
# sync_policy automated + prune + selfHeal means:
#   - Any git push auto-deploys within ~3 minutes
#   - Deleted files auto-delete k8s resources
#   - Manual kubectl changes get reverted by Argo CD
# -----------------------------------------------
resource "kubernetes_manifest" "argocd_root_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"

    metadata = {
      name      = "root-app"
      namespace = "argocd"
      labels = {
        Environment = var.environment
        ManagedBy   = "Terraform"
      }
    }

    spec = {
      project = "default"

      source = {
        # -----------------------------------------------
        # YOUR GITHUB REPO — UPDATE THIS URL
        # Points at the gitops/apps/dev/ directory
        # Argo CD reads all Application YAMLs under
        # this path and creates them in the cluster
        # -----------------------------------------------
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_target_revision
        path           = "gitops/apps/dev"
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }

      syncPolicy = {
        automated = {
          prune    = true   # deletes k8s resources when YAML is removed from git
          selfHeal = true   # reverts manual kubectl changes
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }

  depends_on = [helm_release.argocd]
}