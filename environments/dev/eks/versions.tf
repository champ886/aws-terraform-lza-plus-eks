terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"    # ← pin to v2 — v3 broke kubernetes block syntax
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # -----------------------------------------------
    # KUBECTL PROVIDER
    # Used to apply the Argo CD root app manifest
    # after Argo CD installs its CRD
    # Defers validation to apply time — unlike
    # kubernetes_manifest which validates at plan
    # time and errors when CRD does not yet exist
    # -----------------------------------------------
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }    
  }
}