locals {
  cluster_name = var.cluster_name
  tags = {
    "Project"   = local.cluster_name
    "ManagedBy" = "terraform"
  }
}

# VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.19"

  name = "${local.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs = slice(data.aws_availability_zones.available.names, 0, var.public_subnets_count)

  public_subnets  = [for i in range(var.public_subnets_count) : cidrsubnet(var.vpc_cidr, 8, i + 1)]
  private_subnets = [for i in range(var.private_subnets_count) : cidrsubnet(var.vpc_cidr, 8, i + 11)]

  enable_nat_gateway = true
  single_nat_gateway = false

  tags               = merge(local.tags, { "Name" = "${local.cluster_name}-vpc" })
  public_subnet_tags = merge(local.tags, { "kubernetes.io/role/elb" = "1" })
}

# Tag public subnets for AWS LoadBalancer Controller/alb usage and the cluster
resource "aws_tag" "public_subnet_k8s_cluster_tag" {
  for_each = toset(module.vpc.public_subnets)
  key      = "kubernetes.io/cluster/${local.cluster_name}"
  value    = "shared"
}

resource "aws_tag" "public_subnet_elb_role" {
  for_each = toset(module.vpc.public_subnets)
  key      = "kubernetes.io/role/elb"
  value    = "1"
}

# EKS cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 18.0"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version
  subnets         = module.vpc.private_subnets

  vpc_id = module.vpc.vpc_id

  manage_aws_auth = true

  node_groups = {
    default = {
      desired_capacity = var.desired_node_count
      max_capacity     = var.desired_node_count + 1
      min_capacity     = 1

      instance_types = [var.node_instance_type]

      subnet_ids = module.vpc.private_subnets
      disk_size  = 20

      tags = merge(local.tags, { Name = "${local.cluster_name}-node" })
    }
  }

  # Enable creation of OIDC provider for IRSA
  create_oidc = true

  enable_irsa = true

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  # Control plane logging
  cluster_log_types = ["api", "audit", "authenticator"]

  tags = local.tags
}

# Data sources for kube provider
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

# Create IAM roles for service accounts using OIDC provider
# ALB controller role
resource "aws_iam_role" "alb_controller" {
  name = "${local.cluster_name}-alb-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "alb_controller_policy" {
  name = "${local.cluster_name}-alb-controller-policy"
  role = aws_iam_role.alb_controller.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "elasticloadbalancing:*",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          "ec2:Describe*",
          "iam:CreateServiceLinkedRole",
          "iam:GetServerCertificate",
          "cognito-idp:DescribeUserPoolClient",
          "wafv2:*",
          "shield:GetSubscriptionState",
          "acm:ListCertificates",
          "acm:DescribeCertificate"
        ],
        Resource = "*"
      }
    ]
  })
}

# ExternalDNS role
resource "aws_iam_role" "external_dns" {
  name = "${local.cluster_name}-external-dns-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:external-dns"
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "external_dns_policy" {
  name = "${local.cluster_name}-external-dns-policy"
  role = aws_iam_role.external_dns.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
          "route53:ListHostedZones",
          "route53:GetChange",
          "route53:ListTagsForResource"
        ],
        Resource = "*"
      }
    ]
  })
}

# Kubernetes service accounts annotated with IAM role ARN (IRSA)
resource "kubernetes_namespace" "kube_system_ns" {
  metadata {
    name = "kube-system"
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_account" "alb_controller_sa" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = kubernetes_namespace.kube_system_ns.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_account" "external_dns_sa" {
  metadata {
    name      = "external-dns"
    namespace = kubernetes_namespace.kube_system_ns.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns.arn
    }
  }

  depends_on = [module.eks]
}

# Install AWS Load Balancer Controller via Helm into kube-system
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = kubernetes_namespace.kube_system_ns.metadata[0].name
  version    = "1.6.12"

  create_namespace = false

  values = [jsonencode({
    clusterName = local.cluster_name,
    serviceAccount = {
      create = false,
      name   = kubernetes_service_account.alb_controller_sa.metadata[0].name
    }
  })]

  depends_on = [kubernetes_service_account.alb_controller_sa]
}

# ExternalDNS Helm release
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "external-dns"
  namespace  = kubernetes_namespace.kube_system_ns.metadata[0].name
  version    = "6.9.5"

  create_namespace = false

  values = [jsonencode({
    provider      = "aws",
    aws           = { region = var.region },
    domainFilters = [var.domain_name],
    serviceAccount = {
      create = false,
      name   = kubernetes_service_account.external_dns_sa.metadata[0].name
    }
  })]

  depends_on = [kubernetes_service_account.external_dns_sa]
}

# metrics-server via Helm (HPA support)
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = kubernetes_namespace.kube_system_ns.metadata[0].name
  version    = "5.10.2"

  create_namespace = false

  values = [jsonencode({
    args = ["--kubelet-insecure-tls"]
  })]

  depends_on = [module.eks]
}

# Install EBS CSI driver as EKS managed addon
resource "aws_eks_addon" "ebs_csi" {
  cluster_name      = module.eks.cluster_id
  addon_name        = "aws-ebs-csi-driver"
  addon_version     = "v1.26.0-eksbuild.1"
  resolve_conflicts = "OVERWRITE"

  depends_on = [module.eks]
}
