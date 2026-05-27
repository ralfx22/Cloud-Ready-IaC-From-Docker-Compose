variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "sme-eks-cluster"
}

variable "domain_name" {
  description = "Domain name for Ingress (placeholder). Provide your hosted zone domain (e.g. example.com)."
  type        = string
  default     = "example.com"
}

variable "node_instance_type" {
  description = "EC2 instance type for node group"
  type        = string
  default     = "t3.small"
}

variable "desired_node_count" {
  description = "Desired number of nodes in the managed node group"
  type        = number
  default     = 2
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets_count" {
  description = "Number of public subnets to create (architecture asked for 2)."
  type        = number
  default     = 2
}

variable "private_subnets_count" {
  description = "Number of private subnets to create (architecture asked for 2)."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = { "Environment" = "dev", "ManagedBy" = "terraform" }
}
