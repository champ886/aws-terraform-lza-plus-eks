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