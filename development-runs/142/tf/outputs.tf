output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = data.aws_eks_cluster.cluster.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded cluster CA"
  value       = data.aws_eks_cluster.cluster.certificate_authority[0].data
}

output "kubeconfig_note" {
  description = "Kubeconfig access"
  value       = "Use 'aws eks update-kubeconfig --name ${module.eks.cluster_id} --region ${var.region}' to configure kubectl. The Kubernetes provider and Helm provider are configured for Terraform operations in this repository."
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "public_subnets" {
  value = module.vpc.public_subnets
}
