output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint (private)"
  value       = data.aws_eks_cluster.cluster.endpoint
}

output "kubeconfig_command" {
  description = "One-line command to populate kubeconfig (uses AWS CLI). Control plane is private; run this from a host with network access to the cluster (bastion/EC2 in VPC)."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_id}"
}

output "alb_controller_helm" {
  description = "Helm release name for AWS Load Balancer Controller"
  value       = helm_release.aws_load_balancer_controller.name
}

output "external_dns_helm" {
  description = "Helm release name for ExternalDNS"
  value       = helm_release.external_dns.name
}
