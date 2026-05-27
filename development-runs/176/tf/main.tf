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

// VPC: create a minimal 2 AZ VPC with public + private subnets and a NAT gateway
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "sme-app-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

// EKS managed cluster (AWS EKS managed control plane)
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "sme-eks-cluster"
  kubernetes_version = "1.32"

  # VPC configuration
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  # Endpoint access: allow public access by default (can be changed later)
  endpoint_public_access  = true
  endpoint_private_access = false

  # Ensure OIDC provider is created so IRSA can be used by workloads
  create_oidc                         = true
  create_iam_role_for_service_account = true

  # Use EKS Addons (map of objects). Ensure core addons are managed via the Addons API.
  bootstrap_self_managed_addons = false
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

  # Managed Node Groups: one node group sized per the architecture agent output
  eks_managed_node_groups = {
    app_nodes = {
      desired_capacity = 2
      min_size         = 2
      max_size         = 2

      instance_types = ["t3.small"]
      capacity_type  = "ON_DEMAND"

      # schedule nodes into private subnets
      subnet_ids = module.vpc.private_subnets

      tags = {
        Name = "sme-app-node"
      }
    }
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
    ManagedBy   = "terraform"
  }

  # Keep the module minimal and reproducible
  manage_aws_auth = true
}
