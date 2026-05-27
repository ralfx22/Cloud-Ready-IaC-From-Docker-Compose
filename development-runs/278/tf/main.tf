# NOTE:
# - The planning JSON did not specify cluster endpoint access configuration. This
#   configuration sets endpoint_public_access = true and endpoint_private_access = false by inference. If you need private
#   endpoint access, update these values.
# - The module will provision a single NAT gateway (single_nat_gateway = true)
#   to satisfy "needs_nat_gateway": true while keeping cost minimal. Adjust if
#   you require NAT in each AZ.

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

data "aws_availability_zones" "available" {}

locals {
  vpc_cidr = "10.0.0.0/16"

  public_subnets = [
    cidrsubnet(local.vpc_cidr, 8, 0),
    cidrsubnet(local.vpc_cidr, 8, 1),
  ]

  private_subnets = [
    cidrsubnet(local.vpc_cidr, 8, 10),
    cidrsubnet(local.vpc_cidr, 8, 11),
  ]

  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "eks-vpc"
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    "Name" = "eks-vpc"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name    = "app-eks-cluster"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access  = true
  endpoint_private_access = false

  # Enable creation of the IAM OIDC provider for IRSA via the module defaults.
  # The module typically creates the provider; if your environment requires a
  # different setting, adjust the module inputs accordingly.

  # Managed node groups (eks_managed_node_groups) as a map of objects.
  eks_managed_node_groups = {
    app_nodes = {
      name          = "app-ng"
      desired_size  = 2
      min_size      = 2
      max_size      = 2

      instance_types = ["t3.small"]

      # Let the module create the IAM role and attach required policies.
    }
  }

  # Core EKS addons via the Addons API. Map keys are arbitrary identifiers.
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

  tags = {
    "Name" = "app-eks-cluster"
  }
}

