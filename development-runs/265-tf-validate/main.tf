# NOTE:
# This configuration implements the provided planning JSON exactly.
# - EKS Kubernetes version set to 1.32 as requested by the plan. Verify that this exact version is available in eu-central-1 at apply time.
# - Addons for vpc-cni, coredns and kube-proxy are deployed via the module's addons map (EKS Addons API).
# - A managed node group with 2 t3.small nodes (desired=2) is created. IRSA/OIDC provider enabled.
# If any of the above are not supported in the target region/account, adjust accordingly before apply.

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

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "sme-app-vpc"
  cidr = "10.0.0.0/16"

  # restrict AZs to two for the requested two public and two private subnets
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Terraform   = "true"
    Environment = "sme-app"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  name               = "sme-app-cluster"
  kubernetes_version = "1.32"

  vpc_id = module.vpc.vpc_id

  # Endpoint access settings (public endpoint enabled by default)
  endpoint_public_access  = true
  endpoint_private_access = false

  # Enable IRSA for pods to assume IAM roles (module will create OIDC provider as needed)
  enable_irsa = true

  # Ensure standard EKS managed addons are installed via the Addons API
  addons = {
    "vpc-cni" = {
      addon_name        = "vpc-cni"
      resolve_conflicts = "NONE"
    }
    "coredns" = {
      addon_name        = "coredns"
      resolve_conflicts = "NONE"
    }
    "kube-proxy" = {
      addon_name        = "kube-proxy"
      resolve_conflicts = "NONE"
    }
  }

  # Managed Node Groups configuration (following plan: 2 nodes, t3.small)
  eks_managed_node_groups = {
    app_nodes = {
      desired_capacity = 2
      min_capacity     = 2
      max_capacity     = 2

      instance_types = ["t3.small"]
      subnet_ids     = module.vpc.private_subnets

      capacity_type = "ON_DEMAND"
      ami_type      = "AL2_x86_64"
      disk_size     = 20

      # no SSH access by default
      ssh = {
        allow = false
      }

      tags = {
        Name = "sme-app-ng"
      }
    }
  }

  tags = {
    "Environment" = "sme-app"
    "Terraform"   = "true"
  }
}
