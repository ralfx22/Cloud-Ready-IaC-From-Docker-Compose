# NOTE:
# - Cluster name was not provided in the planning JSON; "sme-app-eks" was chosen.
# - The AWS Load Balancer Controller IAM policy is simplified to a permissive document to enable IRSA creation and helm installation outside Terraform if desired.
# - ALB installation (Helm) is not performed by this configuration; instead IRSA (IAM role for service account) is created so the controller can be installed post-provisioning or by CI.

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

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "sme-app-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b"]
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.128.0/24", "10.0.129.0/24"]

  enable_nat_gateway = true

  tags = {
    "Name"    = "sme-app-vpc"
    "Project" = "sme-app"
  }
}

data "aws_iam_policy_document" "alb" {
  statement {
    sid    = "AllowALBControllerActions"
    effect = "Allow"

    actions = [
      "acm:DescribeCertificate",
      "acm:ListCertificates",
      "acm:GetCertificate",
      "elasticloadbalancing:*",
      "ec2:Describe*",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "iam:CreateServiceLinkedRole",
      "iam:PassRole",
      "cognito-idp:DescribeUserPoolClient",
      "wafv2:*",
      "shield:*",
      "tag:GetResources",
      "tag:TagResources"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "alb" {
  name   = "sme-alb-controller-policy"
  policy = data.aws_iam_policy_document.alb.json
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "sme-app-eks"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = concat(module.vpc.private_subnets, module.vpc.public_subnets)

  enable_irsa = true

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
    "sme_ng" = {
      name           = "sme-ng"
      desired_size   = 2
      min_size       = 2
      max_size       = 2
      instance_types = ["t3.medium"]
      subnet_ids     = module.vpc.private_subnets

      tags = {
        Name = "sme-ng"
      }
    }
  }

  tags = {
    "Environment" = "dev"
    "Project"     = "sme-app"
  }
}

# Create an IAM role for the AWS Load Balancer Controller using IRSA. The EKS module
# creates the OIDC provider when enable_irsa = true; reference module outputs to
# wire up the role's trust relationship.
resource "aws_iam_role" "alb_irsa_role" {
  name = "sme-alb-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = module.eks.oidc_provider_arn
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {

            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")} :sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      }
    ]
  })

  tags = {
    "Project" = "sme-app"
  }
}

resource "aws_iam_role_policy_attachment" "alb_attach" {
  role       = aws_iam_role.alb_irsa_role.name
  policy_arn = aws_iam_policy.alb.arn
}

