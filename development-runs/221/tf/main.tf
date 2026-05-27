terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.16"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

#############################
# VPC (terraform-aws-modules/vpc/aws ~> 6.6)
#############################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "sme-app-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b"]
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.100.0/24", "10.0.101.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "sme-app"
  }
}

#############################
# EKS cluster (terraform-aws-modules/eks/aws ~> 21.0)
# Implements: managed EKS control plane, OIDC provider, IRSA, managed node group(s), core addons
#############################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  # Planning JSON authoritative values
  name               = "sme-app-eks"
  kubernetes_version = "1.31"

  # Networking
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  # Node groups: use managed node groups per requirement
  eks_managed_node_groups = {
    app_nodes = {
      desired_capacity = 2
      min_capacity     = 2
      max_capacity     = 2

      # use the requested instance type
      instance_types = ["t3.small"]

      # schedule nodes into private subnets
      subnet_ids = module.vpc.private_subnets

      # standard on-demand capacity
      capacity_type = "ON_DEMAND"

      # minimal tags
      tags = {
        Name = "sme-app-eks-node"
      }
    }
  }

  # Core EKS add-ons configured via the module's addons map (map of objects)
  # Note: exact addon versions are omitted to allow the module/EKS to pick defaults suitable for the cluster.
  addons = {
    "vpc-cni"    = {}
    "coredns"    = {}
    "kube-proxy" = {}
  }

  tags = {
    Environment = "sme-app"
    ManagedBy   = "terraform"
  }
}

module "aws_lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.58"

  role_name                             = "sme-app-aws-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    eks = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}


#############################
# Minimal outputs for operator convenience
#############################
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_certificate_authority_data" {
  description = "Cluster CA data to construct kubeconfig"
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN created/used by the cluster (for IRSA)"
  value       = try(module.eks.oidc_provider_arn, null)
}
