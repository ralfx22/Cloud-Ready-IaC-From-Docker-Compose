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
# - An IAM OIDC provider and an IRSA role for the AWS Load Balancer Controller are created. The Kubernetes ServiceAccount binding must be created in-cluster (e.g., via Helm deployment of the controller) to complete IRSA.
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

  tags = {
    "Environment" = "sme"
    "Name"        = "sme-eks-cluster"
  }
}

# Create OIDC provider based on the cluster issuer URL so we can create IRSA roles.
data "tls_certificate" "eks_oidc" {
  url = module.eks.cluster_oidc_issuer_url
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.sha1_fingerprint]
}

resource "aws_iam_role" "alb_irsa_role" {
  name = "sme-alb-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      }
    ]
  })

  tags = {
    Name = "sme-alb-irsa-role"
  }
}

resource "aws_iam_role_policy_attachment" "alb_attach" {
  role       = aws_iam_role.alb_irsa_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSLoadBalancerControllerIAMPolicy"
}

resource "aws_iam_policy" "alb_custom" {
  name        = "sme-alb-controller-policy"
  description = "Placeholder custom policy for ALB controller (no actions defined since AWS managed policy is attached)."

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = []
  })

  # This custom policy is intentionally empty; the AWS managed policy is attached above.
}

