output "gitops_metadata" {
  description = "GitOps metadata for ArgoCD"
  value       = local.addons_metadata
}

output "argocd_namespace" {
  description = "ArgoCD namespace"
  value       = "argocd"
}