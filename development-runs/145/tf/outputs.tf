output "cluster_name" {
  value = module.eks.cluster_id
}

output "kubeconfig" {
  description = "Raw kubeconfig content for the cluster (use with caution)."
  value       = module.eks.kubeconfig
  sensitive   = true
}

output "cluster_endpoint" {
  value = data.aws_eks_cluster.cluster.endpoint
}

output "cluster_certificate_authority_data" {
  value     = data.aws_eks_cluster.cluster.certificate_authority[0].data
  sensitive = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "alb_service_account_iam_role_arn" {
  value = aws_iam_role.alb_sa_role.arn
}

output "external_dns_service_account_iam_role_arn" {
  value = aws_iam_role.external_dns_role.arn
}
