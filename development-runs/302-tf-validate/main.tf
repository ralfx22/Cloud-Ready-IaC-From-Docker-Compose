# NOTE: No planning JSON was provided by the user; this main.tf implements a minimal, reproducible EKS setup in eu-central-1 following module and provider version pins from the task.

terraform {
  required_version = ">= 1.14.3, < 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.100.0/24", "10.0.101.0/24", "10.0.102.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/app-eks-cluster" = "shared"
    "kubernetes.io/role/elb"                = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/app-eks-cluster" = "shared"
    "kubernetes.io/role/internal-elb"       = "1"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                            = "app-eks-cluster"
  kubernetes_version              = "1.27"
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = false

  # Enable common control plane logging
  enabled_log_types = ["api", "audit", "authenticator"]

  # Use the VPC created above
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Core add-ons via EKS Addons API (map of objects as required)
  addons = {
    "vpc-cni" = {
      addon_name = "vpc-cni"
    }
    "coredns" = {
      addon_name = "coredns"
    }
    "kube-proxy" = {
      addon_name = "kube-proxy"
    }
  }

  # Managed node groups
  eks_managed_node_groups = {
    ng_default = {
      name             = "ng-default"
      instance_types   = ["t3.medium"]
      desired_capacity = 2
      min_size         = 1
      max_size         = 2
      subnet_ids       = module.vpc.private_subnets
    }
  }

  manage_aws_auth = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }

  node_groups_defaults = {
    additional_tags = {
      "Environment" = "dev"
    }
  }
}

