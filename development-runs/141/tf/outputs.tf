# Additional convenience outputs
output "kubeconfig_instructions" {
  value = <<EOT
To configure kubectl, create a kubeconfig entry using these values:
- server: ${data.aws_eks_cluster.cluster.endpoint}
- certificate-authority-data: ${data.aws_eks_cluster.cluster.certificate_authority[0].data}
- token: use aws cli to get token: aws eks get-token --cluster-name ${module.eks.cluster_id}
Example:
  aws eks update-kubeconfig --name ${module.eks.cluster_id} --region ${var.region}
EOT
}
