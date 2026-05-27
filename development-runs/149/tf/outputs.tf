output "cluster_name" {
  value = module.eks.cluster_id
}

output "cluster_endpoint" {
  value = data.aws_eks_cluster.cluster.endpoint
}

output "kubeconfig_certificate_authority_data" {
  value = data.aws_eks_cluster.cluster.certificate_authority[0].data
}

output "node_group_names" {
  value       = try(module.eks.node_groups_names, module.eks.node_group_names)
  description = "Names of created node groups (module output name differs between module versions; try both)."
}

output "alb_controller_iam_role_arn" {
  value = aws_iam_role.alb_controller.arn
}
