output "cluster_name" {
  value = module.eks.cluster_id
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_id} --region ${var.region}"
}

output "alb_controller_sa" {
  value       = kubernetes_service_account.alb_controller_sa.metadata[0].name
  description = "ServiceAccount name for AWS Load Balancer Controller"
}

output "external_dns_sa" {
  value       = kubernetes_service_account.external_dns_sa.metadata[0].name
  description = "ServiceAccount name for ExternalDNS"
}
