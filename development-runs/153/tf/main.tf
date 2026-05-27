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

locals {
  cluster_name = "sme-eks"
  vpc_name     = "sme-vpc"
  azs          = ["eu-central-1a", "eu-central-1b"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 4.0"

  name = local.vpc_name
  cidr = "10.0.0.0/16"

  azs             = local.azs
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    "Name"      = local.vpc_name
    "CreatedBy" = "terraform"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = "1.32"

  # Networking
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Endpoint access
  endpoint_public_access  = true
  endpoint_private_access = false

  enabled_log_types = ["api", "audit", "authenticator"]

  # Managed node group per planning JSON
  eks_managed_node_groups = {
    default = {
      name             = "default"
      desired_capacity = 2
      min_capacity     = 1
      max_capacity     = 3
      instance_types   = ["t3.small"]
    }
  }

  tags = {
    "CreatedBy" = "terraform"
  }
}
