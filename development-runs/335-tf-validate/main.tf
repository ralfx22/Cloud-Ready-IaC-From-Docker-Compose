
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.28"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

data "aws_availability_zones" "available" {}

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
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = "1.32"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = concat(module.vpc.public_subnets, module.vpc.private_subnets)

  # enable IRSA (module will create OIDC provider)
  enable_irsa = true

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
    coredns    = {}
    kube_proxy = {}
    vpc_cni    = {}
  }

  tags = {
    "Name" = local.cluster_name
  }
}

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

resource "aws_iam_role" "alb_controller" {
  name               = "${local.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_assume_role.json
}

resource "aws_iam_role_policy_attachment" "alb_attach" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# Kubernetes provider configuration to install Helm chart via Terraform
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# Create ServiceAccount in kube-system with IRSA annotation
resource "kubernetes_service_account" "alb" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
    }
  }
}

# Install AWS Load Balancer Controller via Helm using the IRSA-bound ServiceAccount
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  create_namespace = false

  values = [
    <<EOF
clusterName: "${local.cluster_name}"
serviceAccount:
  create: false
  name: "${kubernetes_service_account.alb.metadata[0].name}"
region: "eu-central-1"
vpcId: "${module.vpc.vpc_id}"
EOF
  ]
}

# Create the application namespace
resource "kubernetes_namespace" "app_ns" {
  metadata {
    name = local.namespace
  }
}

# Create internal ClusterIP Service for 'quotes' to fulfill inter-service DNS
resource "kubernetes_service" "quotes" {
  metadata {
    name      = "quotes"
    namespace = local.namespace
    labels = {
      app = "quotes"
    }
  }

  spec {
    selector = {
      app = "quotes"
    }
    port {
      port        = 5000
      target_port = 5000
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

# Create Ingress (ALB) manifest minimal - using AWS Load Balancer Controller annotations
resource "kubernetes_ingress_v1" "frontend_ingress" {
  metadata {
    name      = "frontend-ingress"
    namespace = local.namespace
    annotations = {
      "kubernetes.io/ingress.class"      = "alb"
      "alb.ingress.kubernetes.io/scheme" = "internet-facing"
    }
  }

  spec {
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "frontend"
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }
}

