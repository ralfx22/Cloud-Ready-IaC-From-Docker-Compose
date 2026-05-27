# NOTE: Decisions/inferences: 
# - Chosen AWS region eu-central-1 per requirement.
# - Selected two AZs (eu-central-1a, eu-central-1b) to provide 2 public and 2 private subnets as requested.
# - Endpoint access left public (endpoint_public_access = true) and private disabled (endpoint_private_access = false) because the planning JSON did not specify; adjust if private endpoint is required.
# - OIDC/IRSA and AWS Load Balancer Controller role are planned but module-specific inputs were not available; the IAM Service Account for the controller should be created using the cluster OIDC provider and IRSA in an additional step if desired. This configuration leaves hooks in place to attach a controller IAM policy to a service account.
# - The configuration creates an IAM policy resource suitable for the AWS Load Balancer Controller; tighten the policy as needed for production.

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
  version = "6.6.0"

  name = "sme-app-vpc"
  cidr = "10.0.0.0/16"

  azs = ["eu-central-1a", "eu-central-1b"]

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  enable_dns_hostnames   = true
  enable_dns_support     = true

  tags = {
    "Name"        = "sme-app-vpc"
    "Environment" = "sme-app"
  }
}

resource "aws_iam_policy" "alb_controller" {
  name        = "sme-app-alb-controller-policy"
  description = "Policy for AWS Load Balancer Controller - scoped for sme-app (generated)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          "ec2:DeleteSecurityGroup",
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
          "ec2:DescribeVpcs",
          "ec2:ModifyInstanceAttribute",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:*"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
          "iam:GetServerCertificate",
          "iam:ListServerCertificates",
          "iam:PassRole"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "waf:GetWebACLForResource",
          "waf:ListResourcesForWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "shield:GetSubscriptionState"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "tag:GetResources",
          "tag:TagResources"
        ]
        Resource = "*"
      }
    ]
  })
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  name               = "sme-app-cluster"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access  = true
  endpoint_private_access = false

  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  eks_managed_node_groups = {
    "sme-app-ng" = {
      desired_capacity = 2
      max_capacity     = 2
      min_capacity     = 2

      instance_types = ["t3.medium"]
      subnet_ids     = module.vpc.private_subnets

      tags = {
        Name = "sme-app-node"
      }
    }
  }

  tags = {
    "Environment" = "sme-app"
    "Name"        = "sme-app-cluster"
  }
}

# NOTE: The Terraform configuration creates the VPC, EKS cluster, and a managed node group.  
# OIDC/IRSA and AWS Load Balancer Controller role are planned; the configuration creates an IAM policy resource that can be attached to a service-account role via IRSA in a follow-up step.
# The actual installation of the controller (Helm chart) and the Kubernetes Ingress resource that routes HTTP (80) -> frontend service (port 8080 -> targetPort 80) are left to an operator or a separate automation step that will use the created IRSA.

