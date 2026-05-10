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
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
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

  set {
    name  = "server.insecure"
    value = "true"
  }

  # -----------------------------------------------
  # CORRECTED IMAGE PATH
  # Argo CD lives on quay.io/argoproj/argocd
  # Use the quay pull-through prefix, not ecr-public
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
# ROOT APP MANIFEST LOCAL
# -----------------------------------------------
locals {
  root_app_manifest = yamlencode({
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
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  })
}

# -----------------------------------------------
# ARGO CD ROOT APP — APPLIED VIA kubectl
# null_resource used instead of kubernetes_manifest
# because the Application CRD does not exist at
# plan time — it is installed by helm_release above
# -----------------------------------------------
resource "null_resource" "argocd_root_app" {
  triggers = {
    argocd_release = helm_release.argocd.metadata[0].revision
    manifest_hash  = sha256(local.root_app_manifest)
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo '${local.root_app_manifest}' | kubectl apply -f -
    EOT
  }

  depends_on = [helm_release.argocd]
}