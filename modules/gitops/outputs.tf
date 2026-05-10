# -----------------------------------------------
# ARGO CD SERVER URL
# Access the Argo CD UI by port-forwarding:
#   kubectl port-forward svc/argocd-server -n argocd 8080:80
#   open http://localhost:8080
#
# Default admin password:
#   kubectl get secret argocd-initial-admin-secret \
#     -n argocd -o jsonpath='{.data.password}' | base64 -d
# -----------------------------------------------
output "argocd_namespace" {
  description = "Namespace where Argo CD is deployed"
  value       = kubernetes_namespace.argocd.metadata[0].name
}

output "argocd_access_instructions" {
  description = "How to access the Argo CD UI"
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:80 then open http://localhost:8080"
}

output "argocd_initial_password_command" {
  description = "Command to retrieve the initial Argo CD admin password"
  value       = "kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
}

output "root_app_name" {
  description = "Name of the root Argo CD Application resource"
  value       = "root-app"
}

# -----------------------------------------------
# ECR OCI REPO URL
# Use this in GitHub Actions to push manifests:
#   helm push gitops-apps-dev-<ver>.tgz oci://<this value>
# -----------------------------------------------
output "gitops_ecr_repo_url" {
  description = "ECR OCI repository URL — push manifests here from CI"
  value       = aws_ecr_repository.gitops.repository_url
}

output "gitops_ecr_registry" {
  description = "ECR registry hostname — used for docker login in CI"
  value       = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "gitops_ecr_repo_arn" {
  description = "ARN of the ECR OCI repository — passed to github-actions-role module"
  value       = aws_ecr_repository.gitops.arn
}