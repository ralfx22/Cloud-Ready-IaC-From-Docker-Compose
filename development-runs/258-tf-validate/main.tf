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

data "aws_availability_zones" "available" {
  state = "available"
}

# NOTE: Addons configured via the EKS module 'addons' map to ensure vpc-cni, kube-proxy and coredns
# are managed through the EKS Addons API. IRSA (OIDC provider) is enabled.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "sme-vpc"
  cidr = "10.0.0.0/16"

  azs = data.aws_availability_zones.available.names[0:2]

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = {
    Terraform = "true"
    Environment = "sme"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  name                = "sme-eks-cluster"
  kubernetes_version  = "1.32"

  # Place EKS nodes in private subnets
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  # Core add-ons deployed via EKS Addons API
  addons = {
    vpc_cni = {
      addon_name = "vpc-cni"
    }
    kube_proxy = {
      addon_name = "kube-proxy"
    }
    coredns = {
      addon_name = "coredns"
    }
  }

  eks_managed_node_groups = {
    app_nodes = {
      desired_size     = 2
      min_size         = 2
      max_size         = 2
      instance_types   = ["t3.small"]
      subnet_ids       = module.vpc.private_subnets
      disk_size        = 20
      capacity_type    = "ON_DEMAND"
    }
  }

  tags = {
    Terraform   = "true"
    Environment = "sme"
  }

  manage_aws_auth = true
}
