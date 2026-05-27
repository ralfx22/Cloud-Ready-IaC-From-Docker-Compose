terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "sme-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["eu-central-1a", "eu-central-1b"]

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = {
    Terraform   = "true"
    Environment = "sme"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  name               = "sme-eks-cluster"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    managed_nodes = {
      name             = "managed-workers"
      desired_capacity = 2
      min_capacity     = 2
      max_capacity     = 2
      instance_types   = ["t3.small"]
      capacity_type    = "ON_DEMAND"
      subnet_ids       = module.vpc.private_subnets
    }
  }

  addons = {
    vpc_cni    = { addon_name = "vpc-cni" }
    kube_proxy = { addon_name = "kube-proxy" }
    coredns    = { addon_name = "coredns" }
  }

  tags = {
    Terraform   = "true"
    Environment = "sme"
  }

  cluster_tags = {
    "kubernetes.io/cluster/sme-eks-cluster" = "owned"
  }
}
