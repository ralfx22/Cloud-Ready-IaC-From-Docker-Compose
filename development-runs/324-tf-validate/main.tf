terraform {
  required_version = "~> 1.14.3"

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

# NOTE:
# Planning JSON is authoritative. Defaults/inferences made:
# - EKS endpoint_public_access set to true and private access left false (no explicit requirement provided).
# - OIDC provider will be created to support IRSA for the AWS Load Balancer Controller.
# - An IAM managed policy arn:aws:iam::aws:policy/AWSLoadBalancerControllerIAMPolicy is attached to the aws-load-balancer-controller service account.
# - Subnet CIDRs were chosen minimally to satisfy the VPC module; 2 public and 2 private subnets were created across eu-central-1a and eu-central-1b.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "sme-app-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b"]
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway = true

  tags = {
    "Name" = "sme-app-vpc"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  name               = "sme-eks-cluster"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access  = true
  endpoint_private_access = false

  create_iam_oidc_provider = true

  # Ensure core managed addons are enabled
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

  # Managed node groups
  eks_managed_node_groups = {
    worker_group = {
      desired_capacity = 2
      min_size         = 2
      max_size         = 2
      instance_types   = ["t3.medium"]
      subnet_ids       = module.vpc.private_subnets
      tags = {
        Name = "sme-eks-node"
      }
    }
  }

  iam_service_accounts = [
    {
      name              = "aws-load-balancer-controller"
      namespace         = "kube-system"
      attach_policy_arn = "arn:aws:iam::aws:policy/AWSLoadBalancerControllerIAMPolicy"
      create            = true
    }
  ]

  tags = {
    "Environment" = "sme"
    "Name"        = "sme-eks-cluster"
  }
}

resource "aws_iam_policy" "alb_custom" {
  name        = "sme-alb-controller-policy"
  description = "Placeholder custom policy for ALB controller (no actions defined since module uses AWS managed policy by default)."

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = []
  })

  # This custom policy is intentionally empty; we attach the AWS managed policy to the service account above.
}

