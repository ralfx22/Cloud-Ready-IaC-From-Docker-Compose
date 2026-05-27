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

# NOTE: This configuration is generated from the provided planning JSON.
# It provisions a VPC and a managed EKS cluster in eu-central-1 with a single
# managed node group. Standard EKS addons (vpc-cni, kube-proxy, coredns) are
# configured via the module's addons map. If any manifest-level requirements
# change (public exposure, image registry), update this configuration accordingly.

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "sme-app-vpc"
  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.16.0/20", "10.0.32.0/20"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    "Name" = "sme-app-vpc"
    "Project" = "sme-app"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "sme-eks-cluster"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access  = true
  endpoint_private_access = true

  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  addons = {
    "vpc-cni" = {
      addon_name = "vpc-cni"
    }
    "kube-proxy" = {
      addon_name = "kube-proxy"
    }
    "coredns" = {
      addon_name = "coredns"
    }
  }

  eks_managed_node_groups = {
    app_nodes = {
      desired_capacity = 2
      min_size         = 2
      max_size         = 3

      instance_types = ["t3.small"]
      disk_size      = 20

      capacity_type = "ON_DEMAND"
      subnet_ids    = module.vpc.private_subnets
    }
  }

  enable_irsa = true
  create_oidc = true

  tags = {
    Project = "sme-app"
  }
}

