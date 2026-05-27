terraform {
  required_version = "~> 1.14.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
    }
    helm = {
      source  = "hashicorp/helm"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

data "aws_availability_zones" "available" {}

locals {
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets = [
    cidrsubnet(local.vpc_cidr, 8, 1),
    cidrsubnet(local.vpc_cidr, 8, 2),
  ]

  private_subnets = [
    cidrsubnet(local.vpc_cidr, 8, 11),
    cidrsubnet(local.vpc_cidr, 8, 12),
  ]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "sme-app-vpc"
  cidr = local.vpc_cidr
  azs  = local.azs

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = {
    Terraform   = "true"
    Environment = "sme-app"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  name               = "sme-eks-cluster"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = concat(module.vpc.private_subnets, module.vpc.public_subnets)

  # Core EKS add-ons as a map (using EKS Addons API)
  addons = {
    "vpc-cni"    = {}
    "kube-proxy" = {}
    "coredns"    = {}
  }

  # Managed node group for application workload
  eks_managed_node_groups = {
    sme_nodes = {
      desired_capacity = 2
      min_capacity     = 2
      max_capacity     = 2

      instance_types = ["t3.medium"]
      subnet_ids     = module.vpc.private_subnets

      capacity_type = "ON_DEMAND"
    }
  }

  tags = {
    Environment = "sme-app"
  }
}

# Minimal, broad IAM policy for AWS Load Balancer Controller (recommended: replace with the official least-privilege policy)
resource "aws_iam_policy" "alb_policy" {
  name        = "sme-alb-controller-policy"
  description = "Policy for AWS Load Balancer Controller (broad for validation)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "elasticloadbalancing:*",
          "iam:CreateServiceLinkedRole",
          "iam:PassRole",
          "cognito-idp:DescribeUserPoolClient",
          "waf-regional:GetWebACL",
          "wafv2:GetWebACL"
        ]
        Resource = "*"
      }
    ]
  })
}

# Kubernetes provider config using EKS cluster created by module
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  host = data.aws_eks_cluster.cluster.endpoint

  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# Create OIDC provider for the cluster (IRSA)
resource "aws_iam_openid_connect_provider" "eks" {
  url             = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da0ecd3b47b"]
}

# Create IAM Role for the aws-load-balancer-controller service account (IRSA)
resource "aws_iam_role" "alb_irsa_role" {
  name = "eks-alb-controller-role"

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
            "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "alb_attach" {
  role       = aws_iam_role.alb_irsa_role.name
  policy_arn = aws_iam_policy.alb_policy.arn
}

# Kubernetes namespace for application
resource "kubernetes_namespace" "sme_app" {
  metadata {
    name = "sme-app"
  }
}

# Create the ServiceAccount annotation that links to the created IAM role
resource "kubernetes_service_account" "alb_sa" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      # The annotation key format is required by IRSA
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_irsa_role.arn
    }
  }
}

# Install AWS Load Balancer Controller via Helm and bind to the above ServiceAccount
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.6.4"

  values = [jsonencode({
    clusterName = module.eks.cluster_id
    region      = "eu-central-1"
    serviceAccount = {
      create = false
      name   = kubernetes_service_account.alb_sa.metadata[0].name
    }
  })]

  depends_on = [kubernetes_service_account.alb_sa]
}

# NOTE: Implementation follows the provided planning JSON exactly. The module input names were used per the eks module v21
# compatibility rules (name, kubernetes_version, addons as a map, eks_managed_node_groups). An OIDC provider and IRSA
# are created separately to support the AWS Load Balancer Controller. The aws-load-balancer-controller policy included
# here is intentionally broad for validation; replace with the official least-privilege policy from AWS for production.

