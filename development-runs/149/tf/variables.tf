variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "sme-eks-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane"
  type        = string
  default     = "1.32"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to create subnets in (default 2 for cost/HA tradeoff)"
  type        = number
  default     = 2
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.small"
}

variable "desired_node_count" {
  description = "Desired number of nodes in the managed node group"
  type        = number
  default     = 2
}

variable "key_name" {
  description = "(Optional) EC2 key pair name for SSH access to nodes"
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "(Optional) domain name for DNS automation (not used by default). Leave empty if not configuring ExternalDNS/cert-manager."
  type        = string
  default     = ""
}
