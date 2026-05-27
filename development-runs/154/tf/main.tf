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

# VPC: terraform-aws-modules/vpc/aws ~> 6.6
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "app-vpc"
  cidr = "10.0.0.0/16"

  # two AZs / two public + two private subnets as requested
  azs             = ["eu-central-1a", "eu-central-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]

  # NAT gateway(s) enabled per plan
  enable_nat_gateway = true
  # create one NAT per AZ (false -> one per AZ). Keeping multiple NAT gateways
  # to match availability across AZs
  single_nat_gateway = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# EKS: terraform-aws-modules/eks/aws ~> 21.0
# Respect v21 interface: use name, kubernetes_version, endpoint_public_access, endpoint_private_access,
# enabled_log_types, eks_managed_node_groups
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  name               = "app-eks-cluster"
  kubernetes_version = "1.32"

  # supply VPC information from the vpc module
  vpc_id     = module.vpc.vpc_id
  subnet_ids = concat(module.vpc.public_subnets, module.vpc.private_subnets)

  # endpoint accessibility
  endpoint_public_access  = true
  endpoint_private_access = false

  # enable essential control plane logs
  enabled_log_types = ["api", "audit", "authenticator"]

  # managed node group per plan: 2 x t3.small
  eks_managed_node_groups = {
    ng1 = {
      desired_size   = 2
      min_size       = 2
      max_size       = 2
      instance_types = ["t3.small"]
      capacity_type  = "ON_DEMAND"

      # place nodes in private subnets
      subnet_ids = module.vpc.private_subnets

      tags = {
        Name = "app-eks-ng1"
      }
    }
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}
