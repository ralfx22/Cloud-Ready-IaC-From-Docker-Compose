terraform {
  required_version = "~> 1.14.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.19"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "sme-eks-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["eu-central-1a", "eu-central-1b"]

  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.2.0/24", "10.0.3.0/24"]

  enable_nat_gateway = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "sme-eks"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  create_oidc = true

  enabled_log_types = []

  addons = {
    vpc_cni    = { addon_name = "vpc-cni" }
    kube_proxy = { addon_name = "kube-proxy" }
    coredns    = { addon_name = "coredns" }
  }

  eks_managed_node_groups = {
    app_nodes = {
      desired_capacity = 2
      min_size         = 2
      max_size         = 2
      instance_types   = ["t3.small"]
      subnet_ids       = module.vpc.private_subnets
      disk_size        = 20
      tags = {
        Name = "sme-eks-app-node"
      }
    }
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}
