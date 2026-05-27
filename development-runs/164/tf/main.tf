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

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs = ["eu-central-1a", "eu-central-1b"]

  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  # Basic cluster identifiers
  name               = "sme-eks"
  kubernetes_version = "1.32"

  # Place the cluster into the VPC created above
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Control plane access (public/private). Defaults chosen to allow standard admin access.
  endpoint_public_access  = true
  endpoint_private_access = false

  # Enable standard control-plane logging
  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Ensure standard EKS add-ons are managed by the module so they are created and reconciled
  addons = [
    { name = "vpc-cni" },
    { name = "kube-proxy" },
    { name = "coredns" }
  ]

  # Managed node group matching the planning JSON
  eks_managed_node_groups = {
    default = {
      # friendly name for the node group
      name = "default-ng"

      # instance sizing per plan
      instance_types = ["t3.small"]

      # desired/resize settings (plan requested 2 nodes)
      desired_capacity = 2
      min_capacity     = 2
      max_capacity     = 2

      # Place nodes in the private subnets for the VPC
      subnet_ids = module.vpc.private_subnets
    }
  }

  # Minimal tags for resources created by the module
  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}
