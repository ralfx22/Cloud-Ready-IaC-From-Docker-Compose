variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "sme-eks-cluster"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "domain_name" {
  description = "Primary domain name to use for Ingress/DNS (placeholder if Route53 zone not provided)"
  type        = string
  default     = "example.com"
}

variable "node_instance_type" {
  description = "EC2 instance type for managed node group"
  type        = string
  default     = "t3.small"
}

variable "desired_node_count" {
  description = "Desired number of nodes for the managed node group"
  type        = number
  default     = 2
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane"
  type        = string
  default     = "1.32"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_count" {
  description = "Number of public subnets to create"
  type        = number
  default     = 2
}

variable "private_subnet_count" {
  description = "Number of private subnets to create"
  type        = number
  default     = 2
}

variable "environment" {
  description = "Environment tag value"
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Additional tags applied to resources"
  type        = map(string)
  default     = {}
}

# Optional: Route53 zone id if available. If not provided ExternalDNS will be installed but cannot manage DNS without this.
variable "route53_zone_id" {
  description = "(Optional) Route53 Zone ID to allow ExternalDNS and cert-manager DNS01 to operate. Leave empty to manage DNS manually."
  type        = string
  default     = ""
}
