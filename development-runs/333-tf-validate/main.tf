
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
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

locals {
  cluster_name = "sme-app-cluster" # inferred from plan
  namespace    = "sme-app"
  vpc_cidr     = "10.0.0.0/16"
  public_subnets = [
    cidrsubnet("10.0.0.0/16", 8, 0),
    cidrsubnet("10.0.0.0/16", 8, 1),
  ]
  private_subnets = [
    cidrsubnet("10.0.0.0/16", 8, 128),
    cidrsubnet("10.0.0.0/16", 8, 129),
  ]
}

# NOTE: cluster name was not provided in the planning JSON; 'sme-app-cluster' was inferred.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = local.cluster_name
  cidr = local.vpc_cidr

  azs             = data.aws_availability_zones.available.names
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

data "aws_availability_zones" "available" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                = local.cluster_name
  kubernetes_version  = "1.32"
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = concat(module.vpc.public_subnets, module.vpc.private_subnets)

  # enable OIDC provider for IRSA
  create_oidc_provider = true

  # managed node groups
  eks_managed_node_groups = {
    default = {
      desired_capacity = 2
      min_capacity     = 2
      max_capacity     = 2
      instance_types   = ["t3.medium"]
      subnet_ids       = module.vpc.private_subnets
    }
  }

  # ensure core AWS-managed addons are installed via the EKS Addons API
  addons = {
    coredns = {}
    kube_proxy = {}
    vpc_cni = {}
  }

  tags = {
    "Name" = local.cluster_name
  }
}

# IAM role & policy for AWS Load Balancer Controller (IRSA)
# official policy document (minimized to required actions) - keep as tight as practical
resource "aws_iam_policy" "alb_controller" {
  name        = "${local.cluster_name}-aws-load-balancer-controller"
  description = "Policy for AWS Load Balancer Controller (IRSA)"

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcs",
        "ec2:DescribeTags"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:*",
        "iam:CreateServiceLinkedRole"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "cognito-idp:DescribeUserPoolClient"
      ],
      "Resource": "*"
    }
  ]
}
POLICY
}

# Create IAM role for the controller and allow assumption by the EKS OIDC provider for the specific ServiceAccount
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
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_controller
