variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
  default     = "sme-eks-cluster"
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "eu-central-1"
}

variable "domain_name" {
  type        = string
  description = "Application domain name (placeholder in manifests). Used by ExternalDNS if provided."
  default     = "example.com"
}

variable "node_instance_type" {
  type        = string
  description = "EC2 instance type for managed node group"
  default     = "t3.small"
}

variable "desired_node_count" {
  type        = number
  description = "Desired number of nodes in the managed node group"
  default     = 2
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for new VPC"
  default     = "10.0.0.0/16"
}

variable "public_subnets_count" {
  type    = number
  default = 2
}

variable "private_subnets_count" {
  type    = number
  default = 2
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes version for EKS cluster"
  default     = "1.32"
}
