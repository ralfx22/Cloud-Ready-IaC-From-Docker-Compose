variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "sme-eks-cluster"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Root domain name to manage (ExternalDNS will restrict to this domain)"
  type        = string
  default     = "example.com"
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

variable "az_count" {
  description = "Number of Availability Zones (AZs) to create subnets in"
  type        = number
  default     = 2
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default = {
    Owner = "terraform"
  }
}

