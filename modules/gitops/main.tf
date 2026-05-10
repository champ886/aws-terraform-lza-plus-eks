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
  # ALB handles HTTPS if you add ACM later
  # -----------------------------------------------
  set {
    name  = "server.insecure"
    value = "true"
  }

  # -----------------------------------------------
  # DISABLE DEX — NOT NEEDED FOR SINGLE-USER DEV
  # Dex provides SSO/OIDC federation — unnecessary
  # when you are the only user accessing the cluster
  # Dex pulls from ghcr.io which has no pull-through
  # cache rule — disabling avoids ImagePullBackOff
  # Re-enable and add ghcr pull-through rule when
  # you need team SSO or OIDC login integration
  # -----------------------------------------------
  set {
    name  = "dex.enabled"
    value = "false"
  }

  # -----------------------------------------------
  # REDIS IMAGE OVERRIDE
  # Redis pulls from docker.io/library/redis
  # Route via docker-hub pull-through prefix
  # -----------------------------------------------
  set {
    name  = "redis.image.repository"
    value = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/docker-hub/library/redis"
  }

  # -----------------------------------------------
  # ARGO CD IMAGE — quay pull-through
  # Argo CD is published on quay.io/argoproj/argocd
  # quay pull-through rule already exists in
  # modules/ecr-pull-through/main.tf
  # -----------------------------------------------
  set {
    name  = "global.image.repository"
    value = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/quay/argoproj/argocd"
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

  depends_on = [kubernetes_namespace.argocd]
}

# -----------------------------------------------
# ROOT APP MANIFEST
# Written as a plain YAML heredoc — not yamlencode
# yamlencode wraps keys in double quotes which
# Kubernetes rejects and shell echo corrupts
# Heredoc passes content through the shell safely
# without interpreting special characters
# -----------------------------------------------
locals {
  root_app_manifest = <<-YAML
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
}

# -----------------------------------------------
# ARGO CD ROOT APP — APPLIED VIA kubectl
# Cannot use kubernetes_manifest because the
# Application CRD does not exist at plan time —
# it is installed by helm_release.argocd above
#
# kubernetes_manifest validates against the live
# cluster API at plan time and errors if the CRD
# is not yet registered
#
# null_resource + local-exec runs only at apply
# time, after helm_release.argocd completes, so
# the CRD is guaranteed to exist
#
# update-kubeconfig run without --role-arn so it
# uses whatever credentials the shell has directly
# avoids double-assumption if shell is already in
# the dev account, works from management account
# credentials if not
#
# Pre-requisite: ensure your shell can reach the
# dev account before running terraform apply:
#   aws sts get-caller-identity  ← verify account
#   aws eks update-kubeconfig \
#     --name lean-dev \
#     --region ap-southeast-2   ← run if needed
#
# cat heredoc used instead of echo to safely pass
# YAML through the shell without corruption
# --validate=false skips client-side schema check
# and relies on server-side validation instead
# -----------------------------------------------
resource "null_resource" "argocd_root_app" {
  triggers = {
    argocd_release = helm_release.argocd.metadata[0].revision
    manifest_hash  = sha256(local.root_app_manifest)
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --name lean-dev \
        --region ap-southeast-2

      cat <<'MANIFEST' | kubectl apply --validate=false -f -
${local.root_app_manifest}
MANIFEST
    EOT

    # -----------------------------------------------
    # AWS_DEFAULT_REGION ensures the AWS CLI uses
    # the correct region regardless of shell config
    # Do NOT set ACCESS_KEY/SECRET/TOKEN here —
    # empty strings would clear inherited credentials
    # The shell inherits valid creds from the
    # Terraform process environment automatically
    # -----------------------------------------------
    environment = {
      AWS_DEFAULT_REGION = "ap-southeast-2"
    }
  }

  depends_on = [helm_release.argocd]
}