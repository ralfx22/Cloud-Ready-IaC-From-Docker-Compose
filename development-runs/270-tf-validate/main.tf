terraform {
  required_version = "~> 1.14.3"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.28" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.20" }
  }
}

provider "aws" {
  region = "eu-central-1"
}

# NOTE: Cluster name and some minor defaults were inferred from the planning JSON. No ingress controller or LoadBalancer services are provisioned (manifests use ClusterIP). OIDC provider for IRSA will be created.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "sme-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["eu-central-1a", "eu-central-1b"]

  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.2.0/24", "10.0.3.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  name               = "sme-eks"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  create_oidc = true

  enabled_log_types = ["api", "audit", "authenticator"]

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
      max_size         = 2

      instance_types = ["t3.small"]
      subnet_ids     = module.vpc.private_subnets

      tags = {
        Name = "eks-app-nodes"
      }
    }
  }

  manage_aws_auth = true
}

