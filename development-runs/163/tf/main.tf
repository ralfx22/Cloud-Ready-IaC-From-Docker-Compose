terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.11"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "sme-vpc"
  cidr = "10.0.0.0/16"

  # Use first two AZs in the region to create 2 public + 2 private subnets
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.16.0/24", "10.0.17.0/24"]

  enable_nat_gateway = true

  tags = {
    Terraform   = "true"
    Environment = "sme"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  # Cluster identifiers
  name               = "sme-eks-cluster"
  kubernetes_version = "1.32"

  # Use the VPC created above
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Ensure IAM OIDC is available for IRSA (module will manage provider as appropriate)
  # Note: v21.x has subtle changes around identity providers - keep defaults and let module manage OIDC.

  # Ensure core EKS addons are managed so they reach healthy state
  addons = [
    { name = "vpc-cni" },
    { name = "kube-proxy" },
    { name = "coredns" }
  ]

  # Managed node group: match planning JSON (2 nodes, t3.small)
  eks_managed_node_groups = {
    default = {
      instance_types   = ["t3.small"]
      desired_capacity = 2
      min_size         = 2
      max_size         = 2

      # Place nodes in the private subnets
      subnet_ids = module.vpc.private_subnets

      # Basic tags
      tags = {
        Name = "sme-eks-ng"
      }
    }
  }

  # Basic cluster tags
  tags = {
    Environment = "sme"
    Terraform   = "true"
  }

  # Keep the configuration minimal and let the module supply sensible defaults for IAM, OIDC, and other resources.
}
