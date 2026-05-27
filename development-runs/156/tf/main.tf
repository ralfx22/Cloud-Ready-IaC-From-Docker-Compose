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

##########################
# VPC - terraform-aws-modules/vpc/aws
##########################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "sme-app-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Project   = "sme-app"
    Terraform = "true"
  }
}

##########################
# EKS - terraform-aws-modules/eks/aws (v21.x interface)
# - Use only inputs compatible with v21 interface per plan
##########################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  # Cluster identity
  name               = "sme-app-eks"
  kubernetes_version = "1.32"

  # Control plane endpoint accessibility
  endpoint_public_access  = true
  endpoint_private_access = false

  # Core logs enabled
  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # VPC / networking
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Managed node groups (baseline: 2 x t3.small)
  eks_managed_node_groups = {
    app_nodes = {
      desired_size   = 2
      min_size       = 2
      max_size       = 2
      instance_types = ["t3.small"]

      # Ensure worker nodes are launched in private subnets
      subnet_ids = module.vpc.private_subnets

      # On-demand capacity
      capacity_type = "ON_DEMAND"

      tags = {
        Name = "sme-app-eks-node"
      }
    }
  }

  # Basic tags
  tags = {
    Project   = "sme-app"
    Terraform = "true"
  }

  # Keep the module minimal and let it create required IAM roles and OIDC provider
}

##########################
# Outputs
##########################
output "vpc_id" {
  description = "VPC id created for the EKS cluster"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private subnets used for the EKS cluster"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "Public subnets created for the VPC"
  value       = module.vpc.public_subnets
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "EKS cluster certificate authority data (base64)"
  value       = module.eks.cluster_certificate_authority_data
}

output "node_group_names" {
  description = "Managed node group names"
  value       = module.eks.node_groups
}
