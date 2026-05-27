output "cluster_id" {
  description = "EKS cluster id"
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded cluster CA"
  value       = module.eks.cluster_certificate_authority_data
}

output "kubeconfig" {
  description = "Kubeconfig contents for the cluster (use with caution)"
  value       = module.eks.kubeconfig
  sensitive   = true
}

output "node_group_names" {
  description = "Names of created node groups"
  value       = keys(module.eks.node_groups)
}
