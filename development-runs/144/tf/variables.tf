variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "sme-eks"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "domain_name" {
  description = "Domain name used in ingress (placeholder if not available). Will tag Route53 records when ExternalDNS is enabled."
  type        = string
  default     = "example.com"
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.small"
}

variable "desired_node_count" {
  description = "Desired number of worker nodes in the managed node group"
  type        = number
  default     = 2
}

variable "vpc_cidr" {
  description = "CIDR block for new VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_azs" {
  description = "List of AZs to create subnets in (2 AZs chosen from eu-central-1)"
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]
}

variable "public_subnets" {
  description = "Public subnet CIDRs"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnets" {
  description = "Private subnet CIDRs"
  type        = list(string)
  default     = ["10.0.16.0/24", "10.0.17.0/24"]
}

variable "tags" {
  description = "Common tags applied to resources"
  type        = map(string)
  default = {
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}
