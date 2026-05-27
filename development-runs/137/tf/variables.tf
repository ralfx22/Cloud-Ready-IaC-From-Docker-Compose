variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "sme-eks-cluster"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Primary DNS domain name (Route53 hosted zone name). Example: example.com"
  type        = string
  default     = "example.com"
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.small"
}

variable "desired_node_count" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "namespace_name" {
  description = "Application namespace"
  type        = string
  default     = "sme-app"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets_count" {
  description = "Number of public subnets / AZs to create"
  type        = number
  default     = 2
}

variable "private_subnets_count" {
  description = "Number of private subnets / AZs to create"
  type        = number
  default     = 2
}

variable "cluster_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.28"
}
