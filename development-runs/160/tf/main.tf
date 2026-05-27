terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.18"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

###############################################################################
# VPC
# - Implements planning JSON exactly: 10.0.0.0/16, 2 public & 2 private
# - Enables NAT gateway(s) because plan requested needs_nat_gateway = true
###############################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  # Fixed AZs in eu-central-1 to ensure exactly 2 public/2 private subnets
  azs = ["eu-central-1a", "eu-central-1b"]

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway = true

  # Keep resource set minimal and reproducible
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
    Name        = "eks-vpc"
  }
}

###############################################################################
# EKS Cluster (managed control plane)
# - Uses terraform-aws-modules/eks/aws pinned to ~> 21.0
# - Follows planning JSON exactly:
#   * region: eu-central-1 (provider)
#   * kubernetes version: 1.32
#   * managed node group: minimum 2 nodes of t3.small
#   * enable OIDC/IAM roles for service accounts (IRSA) via provider flag
# - Minimal, conservative argument list to remain compatible with v21.x
###############################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  # cluster identity
  cluster_name       = "app-cluster"
  kubernetes_version = "1.32"

  # networking: use private subnets for worker nodes
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  # Create the OIDC provider so workloads can use IRSA
  create_oidc = true

  # Managed EKS node groups (one group with 2 nodes as requested)
  eks_managed_node_groups = {
    default = {
      desired_size   = 2
      min_size       = 2
      max_size       = 2
      instance_types = ["t3.small"]

      # Keep defaults for ami_type / monitoring etc. v21 defaults are used
    }
  }

  # Basic tags
  tags = {
    Environment = "dev"
    Terraform   = "true"
  }

  # Minimal timeouts / keep other advanced features at defaults so upgrade
  # compatibility with v21 is preserved.
}

###############################################################################
# Outputs
# - Expose primary cluster properties. These are the standard outputs
#   typically exposed by the community EKS module (cluster_name, id,
#   endpoint, kubeconfig). They are included here so consumers can use
#   the cluster after terraform apply.
###############################################################################
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_id" {
  description = "EKS cluster id (the AWS resource id)"
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "kubeconfig" {
  description = "Kubeconfig for the cluster (sensitive)"
  value       = module.eks.kubeconfig
  sensitive   = true
}
