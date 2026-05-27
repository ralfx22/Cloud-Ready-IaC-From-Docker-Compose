output "kubeconfig_command_hint" {
  description = "Hint to generate kubeconfig using aws cli"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "alb_service_account_role_arn" {
  value = aws_iam_role.alb.arn
}

output "externaldns_service_account_role_arn" {
  value = aws_iam_role.externaldns.arn
}
