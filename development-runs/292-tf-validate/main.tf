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

data "aws_caller_identity" "current" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true

  tags = {
    "Environment" = "dev"
    "Name"        = "eks-vpc"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  # cluster basics (mapped to v21 input renames)
  name               = "sme-eks-cluster"
  kubernetes_version = "1.32"

  # network
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # enable OIDC/IRSA
  create_oidc = true
  enable_irsa = true

  # managed node groups configuration
  eks_managed_node_groups = {
    default = {
      desired_capacity = 2
      min_size         = 2
      max_size         = 2
      instance_types   = ["t3.small"]
      name             = "managed-1"
    }
  }

  # ensure EKS managed core add-ons are installed via the Addons API
  addons = {
    coredns   = { addon_name = "coredns" }
    kubeproxy = { addon_name = "kube-proxy" }
    vpc_cni   = { addon_name = "vpc-cni" }
  }

  # basic tags
  cluster_tags = {
    "Name" = "sme-eks-cluster"
  }

  node_groups_tags = {
    "Name" = "sme-eks-node"
  }

  # do not bootstrap self-managed add-ons
  bootstrap_self_managed_addons = false

  depends_on = [module.vpc]
}

# NOTE: The manifests expect an ALB ingress to expose the frontend. This configuration
# provisions EKS, VPC, and a managed node group with OIDC/IRSA enabled. Installation
# of the AWS Load Balancer Controller (ALB ingress controller) and application
# Kubernetes manifests are intentionally left out (do not apply application manifests
# via Terraform by default). Create the IAM service account and Helm chart for the
# controller as a separate step or extend this module if you want the controller
# provisioned by Terraform.

