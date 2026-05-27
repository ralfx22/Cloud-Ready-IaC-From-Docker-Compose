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
  description = "Primary DNS domain to use for Ingress / ExternalDNS (placeholder if not configured)"
  type        = string
  default     = "example.com"
}

variable "node_instance_type" {
  description = "EC2 instance type for managed node groups"
  type        = string
  default     = "t3.small"
}

variable "desired_node_count" {
  description = "Desired size for the managed node group"
  type        = number
  default     = 2
}

variable "vpc_cidr" {
  description = "CIDR block for the new VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets_count" {
  description = "Number of public subnets to create (per architecture intent)"
  type        = number
  default     = 2
}

variable "private_subnets_count" {
  description = "Number of private subnets to create (per architecture intent)"
  type        = number
  default     = 2
}

variable "cluster_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.32"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    Owner = "sme-team"
    Env   = "dev"
  }
}
