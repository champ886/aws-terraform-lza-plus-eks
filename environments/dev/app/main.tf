###############################################################################
# ROOT MODULE — APP LAYER
# -----------------------
# Entry point for the app layer. Composes two child modules in dependency
# order:
#
#   1. postgresql   → database must exist before the app can connect to it
#   2. sample_app   → nginx deployment + ALB ingress
#
# Deployment order is enforced by the depends_on argument on module.sample_app.
###############################################################################

###############################################################################
# MODULE: postgresql
# ------------------
# Deploys PostgreSQL inside the cluster using the Bitnami Helm chart.
# Data is persisted to an EBS volume via a PersistentVolumeClaim (PVC).
# In-cluster = no RDS cost, suitable for dev and non-critical workloads.
###############################################################################
module "postgresql" {
  source = "../../../modules/postgresql"

  namespace     = var.app_namespace
  db_name       = var.db_name
  db_username   = var.db_username
  db_password   = var.db_password
  storage_size  = var.db_storage_size
  storage_class = var.db_storage_class
}

###############################################################################
# MODULE: sample_app
# ------------------
# Deploys nginx with a custom HTML page, exposes it via a Kubernetes Service,
# and creates an internet-facing ALB through an Ingress resource.
#
# The AWS Load Balancer Controller (installed in the cluster) watches Ingress
# resources and automatically provisions real AWS ALBs in response.
###############################################################################
module "sample_app" {
  source = "../../../modules/sample-app"

  namespace   = var.app_namespace
  environment = var.environment
  image       = var.app_image
  replicas    = var.app_replicas

  ###########################################################################
  # Pass the in-cluster PostgreSQL DNS name as the DB host.
  # Kubernetes resolves this internally using CoreDNS.
  # Format: <service-name>.<namespace>.svc.cluster.local
  ###########################################################################
  db_host     = module.postgresql.service_name
  db_port     = module.postgresql.service_port
  db_name     = var.db_name
  db_username = var.db_username
  db_password = var.db_password

  ###########################################################################
  # Explicit dependency: do not create the app until PostgreSQL is fully
  # running. Terraform infers most dependencies from references, but this
  # makes the ordering unambiguous and ensures the namespace + PVC are
  # ready before any pods attempt to start.
  ###########################################################################
  depends_on = [module.postgresql]
}

###############################################################################
# OUTPUTS
# -------
# Printed after `terraform apply` completes and readable by other layers
# via terraform_remote_state.
###############################################################################

output "alb_dns_name" {
  description = "Open this URL in a browser ~2 minutes after apply (ALB provisioning takes time)"
  value       = module.sample_app.alb_dns_name
}

output "postgresql_service" {
  description = "In-cluster DNS name for PostgreSQL — reuse in any other app that needs the DB"
  value       = module.postgresql.service_name
}