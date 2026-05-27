output "cluster_id" {
  description = "EKS cluster id"
  value       = module.eks.cluster_id
}

output "kubeconfig_command" {
  description = "kubectl configuration command to fetch cluster credentials using awscli"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_id} --region ${var.region}"
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = data.aws_eks_cluster.cluster.endpoint
}

output "alb_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller (IRSA)"
  value       = aws_iam_role.aws_lb_controller_role.arn
}

output "external_dns_role_arn" {
  description = "IAM role ARN for ExternalDNS (IRSA)"
  value       = aws_iam_role.external_dns_role.arn
}
