# -----------------------------------------------
# PROVIDER REQUIREMENTS
# Must match the provider aliases declared in
# environments/dev/eks/providers.tf
# aws.workload  → dev account 435321828725
# helm          → points at lean-dev cluster
# kubernetes    → points at lean-dev cluster
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
# NAMESPACE
# Isolated namespace for the sample app
# Keeps app resources separate from kube-system
# and kubecost namespaces
# -----------------------------------------------
resource "kubernetes_namespace" "sample_app" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# -----------------------------------------------
# DEPLOYMENT
# Runs the sample app container on EKS nodes
# Image pulled via ECR pull-through cache
# (docker-hub prefix) — no internet required
# Requests/limits sized for t3.medium spot nodes
# Two replicas for basic availability
# -----------------------------------------------
resource "kubernetes_deployment" "sample_app" {
  metadata {
    name      = var.app_name
    namespace = kubernetes_namespace.sample_app.metadata[0].name
    labels = {
      app         = var.app_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }

  spec {
    replicas = var.replica_count

    selector {
      match_labels = {
        app = var.app_name
      }
    }

    template {
      metadata {
        labels = {
          app         = var.app_name
          Environment = var.environment
        }
      }

      spec {
        container {
          name = var.app_name

          # -----------------------------------------------
          # ECR PULL-THROUGH CACHE IMAGE PATH
          # docker-hub prefix routes the pull through the
          # private ECR endpoint established in
          # modules/ecr-pull-through/main.tf
          # Format: <account>.dkr.ecr.<region>.amazonaws.com/docker-hub/<image>:<tag>
          # Nodes never hit the public internet
          # -----------------------------------------------
          image             = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/docker-hub/${var.container_image}:${var.container_tag}"
          image_pull_policy = "IfNotPresent"

          port {
            # Port the container listens on internally
            container_port = var.container_port
          }

          # -----------------------------------------------
          # RESOURCE LIMITS
          # Sized to fit two replicas on a single t3.medium
          # node (2 vCPU, 4GB) leaving headroom for system pods
          # Cluster Autoscaler will add nodes if load grows
          # -----------------------------------------------
          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          # -----------------------------------------------
          # LIVENESS PROBE
          # Kubernetes restarts the container if this fails
          # Uses HTTP GET on the container port
          # 30s initial delay — app needs time to start
          # -----------------------------------------------
          liveness_probe {
            http_get {
              path = var.health_check_path
              port = var.container_port
            }
            initial_delay_seconds = 30
            period_seconds        = 15
            failure_threshold     = 3
          }

          # -----------------------------------------------
          # READINESS PROBE
          # Pod removed from Service endpoints until ready
          # ALB target group health check depends on this
          # -----------------------------------------------
          readiness_probe {
            http_get {
              path = var.health_check_path
              port = var.container_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 3
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.sample_app]
}

# -----------------------------------------------
# SERVICE
# ClusterIP — internal only
# The ALB Ingress below exposes it externally
# ALB controller reads the service name from
# the Ingress backend spec to register targets
# -----------------------------------------------
resource "kubernetes_service" "sample_app" {
  metadata {
    name      = var.app_name
    namespace = kubernetes_namespace.sample_app.metadata[0].name
    labels = {
      app         = var.app_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }

  spec {
    selector = {
      app = var.app_name
    }

    port {
      protocol    = "TCP"
      port        = 80
      target_port = var.container_port
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_deployment.sample_app]
}

# -----------------------------------------------
# INGRESS (ALB)
# aws-load-balancer-controller watches for
# Ingress objects with this class annotation and
# creates a real ALB in the public subnets
#
# Annotation notes:
#   scheme: internet-facing     → public ALB in public subnets
#   target-type: ip             → routes directly to pod IPs
#                                 (required for VPC-native CNI)
#   group.name: sample-app      → allows multiple Ingress objects
#                                 to share a single ALB if needed
#
# Do NOT use NodePort services with ip target type —
# ALB talks directly to pod IPs via VPC routing
# -----------------------------------------------
resource "kubernetes_ingress_v1" "sample_app" {
  metadata {
    name      = var.app_name
    namespace = kubernetes_namespace.sample_app.metadata[0].name
    labels = {
      app         = var.app_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
    annotations = {
      "kubernetes.io/ingress.class"                        = "alb"
      "alb.ingress.kubernetes.io/scheme"                   = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"              = "ip"
      "alb.ingress.kubernetes.io/group.name"               = var.app_name
      "alb.ingress.kubernetes.io/healthcheck-path"         = var.health_check_path
      "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = "15"
      "alb.ingress.kubernetes.io/healthcheck-timeout-seconds"  = "5"
      "alb.ingress.kubernetes.io/healthy-threshold-count"  = "2"
      "alb.ingress.kubernetes.io/unhealthy-threshold-count" = "3"
    }
  }

  spec {
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.sample_app.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_service.sample_app]
}

# -----------------------------------------------
# PUBLIC SUBNET TAG PATCH (via AWS provider)
# ALB controller requires subnets to carry:
#   kubernetes.io/role/elb = 1  (public subnets)
# This resource adds that tag without modifying
# the vpc module — keeps subnet tagging local
# to the app module that needs it
# -----------------------------------------------
resource "aws_ec2_tag" "public_subnet_elb" {
  provider    = aws.workload
  count       = length(var.public_subnet_ids)
  resource_id = var.public_subnet_ids[count.index]
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

# -----------------------------------------------
# PRIVATE SUBNET TAG PATCH
# Required for the ALB controller to recognise
# private subnets for internal ALBs if ever needed
# kubernetes.io/role/internal-elb = 1
# -----------------------------------------------
resource "aws_ec2_tag" "private_subnet_internal_elb" {
  provider    = aws.workload
  count       = length(var.private_subnet_ids)
  resource_id = var.private_subnet_ids[count.index]
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}

# -----------------------------------------------
# CLUSTER OWNERSHIP TAG ON SUBNETS
# ALB controller also requires this tag on subnets
# kubernetes.io/cluster/<cluster-name> = shared
# Without it the controller cannot discover subnets
# -----------------------------------------------
resource "aws_ec2_tag" "public_subnet_cluster" {
  provider    = aws.workload
  count       = length(var.public_subnet_ids)
  resource_id = var.public_subnet_ids[count.index]
  key         = "kubernetes.io/cluster/${var.cluster_name}"
  value       = "shared"
}