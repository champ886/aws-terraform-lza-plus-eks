###############################################################################
# PROVIDERS & VERSION CONSTRAINTS
# --------------------------------
# Providers are plugins that let Terraform talk to external APIs.
# Pinning versions (~> 5.0 means ">=5.0, <6.0") prevents surprise breaking
# changes when Terraform downloads a newer provider automatically.
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }
}

###############################################################################
# AWS PROVIDER
# ------------
# Targets the dev account (435321828725) via the OrganizationAccountAccessRole.
# This matches how the EKS layer authenticates — consistent across both layers.
###############################################################################
provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn = "arn:aws:sts::435321828725:assumed-role/OrganizationAccountAccessRole/dev-session"
  }
}

###############################################################################
# REMOTE STATE DATA SOURCE
# ------------------------
# Reads outputs from the EKS infra layer (cluster endpoint, CA cert, name)
# without hardcoding them. Terraform pulls them from the S3 state file that
# the EKS layer wrote when it was last applied.
#
# This is the standard pattern for splitting infra into independent layers
# that can be deployed and destroyed separately.
###############################################################################
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = "tf-state-landing-zone-champ-001"
    key    = "aws-lza/dev/eks/terraform.tfstate" # The EKS layer's state key
    region = "ap-southeast-2"

    assume_role = {
      role_arn = "arn:aws:iam::501562869247:role/TerraformStateRole"
    }
  }
}

###############################################################################
# LOCAL VALUES
# ------------
# locals{} lets you define named expressions computed once and reused
# throughout the config. Here we give shorter names to deeply nested
# remote state output references.
###############################################################################
locals {
  cluster_endpoint       = data.terraform_remote_state.eks.outputs.cluster_endpoint
  cluster_ca_certificate = data.terraform_remote_state.eks.outputs.cluster_certificate_authority_data
  cluster_name           = data.terraform_remote_state.eks.outputs.cluster_name
}

###############################################################################
# KUBERNETES PROVIDER
# -------------------
# Authenticates to your EKS cluster using an exec block that runs
# `aws eks get-token` to obtain a short-lived token — the same mechanism
# kubectl uses. This is safer than storing a static long-lived token.
#
# base64decode() is needed because EKS returns the CA certificate
# in base64-encoded form.
###############################################################################
provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", "ap-southeast-2"]
  }
}

###############################################################################
# HELM PROVIDER
# -------------
# Helm is a Kubernetes package manager used here to install PostgreSQL from
# the Bitnami chart repository. It uses the same exec-based authentication
# as the kubernetes provider above.
###############################################################################
provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", "ap-southeast-2"]
    }
  }
}