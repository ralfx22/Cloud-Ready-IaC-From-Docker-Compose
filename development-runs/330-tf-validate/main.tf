terraform {
  required_version = ">= 1.14.3, < 2.0.0"
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

# NOTE: This configuration implements the planning JSON exactly. The AWS Load Balancer Controller IAM policy document and some IRSA specifics are left intentionally minimal; implementer should review and harden IAM policies and service account names as needed.

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "sme-vpc"
  cidr = "10.0.0.0/16"

  azs             = [data.aws_availability_zones.available.names[0], data.aws_availability_zones.available.names[1]]
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.100.0/24", "10.0.101.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = {
    Terraform   = "true"
    Environment = "sme"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "sme-eks-cluster"
  kubernetes_version = "1.32"

  endpoint_public_access  = true
  endpoint_private_access = false

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enabled_log_types = ["api", "audit", "authenticator"]

  # Ensure core managed add-ons are created and managed by the EKS Addons API
  addons = {
    "vpc-cni" = {
      addon_name = "vpc-cni"
    }
    "coredns" = {
      addon_name = "coredns"
    }
    "kube-proxy" = {
      addon_name = "kube-proxy"
    }
  }

  # Managed node group in private subnets
  eks_managed_node_groups = {
    sme_nodes = {
      desired_capacity = 2
      min_size         = 2
      max_size         = 2

      instance_types = ["t3.medium"]
      subnet_ids     = module.vpc.private_subnets

      capacity_type = "ON_DEMAND"

      tags = {
        Name = "sme-node"
      }
    }
  }

  tags = {
    Environment = "sme"
    Terraform   = "true"
  }
}

# Create IAM role for the AWS Load Balancer Controller Service Account (IRSA)
# NOTE: The exact IAM policy required for the controller is not provided here; implementer should attach the managed policy or a custom policy matching AWS recommendations.

data "aws_iam_policy_document" "alb_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "sme-alb-controller-irsa"
  assume_role_policy = data.aws_iam_policy_document.alb_assume_role.json
  tags = {
    Terraform   = "true"
    Environment = "sme"
  }
}

# Attach a placeholder policy (empty) to allow role creation; implementer should replace with the full AWSLoadBalancerController policy.
resource "aws_iam_role_policy" "alb_controller_placeholder" {
  name = "sme-alb-controller-placeholder"
  role = aws_iam_role.alb_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["sts:AssumeRole"]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Output cluster name and kubeconfig information for operator convenience
output "cluster_name" {
  value = module.eks.cluster_name
}

output "kubeconfig_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

