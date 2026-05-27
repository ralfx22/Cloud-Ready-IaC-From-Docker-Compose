locals {
  common_tags = merge({
    Name = var.cluster_name,
  }, var.tags)
}

# VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "4.0.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  public_subnets  = [for i in range(var.az_count) : cidrsubnet("10.0.0.0/16", 8, i)]
  private_subnets = [for i in range(var.az_count) : cidrsubnet("10.0.0.0/16", 8, i + var.az_count)]

  enable_nat_gateway = true
  single_nat_gateway = false

  public_subnet_tags = merge(local.common_tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  })

  private_subnet_tags = merge(local.common_tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/role/worker"                 = "1"
  })

  tags = local.common_tags
}

# Availability zones data
data "aws_availability_zones" "available" {
  state = "available"
}

# EKS cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "18.0.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.32"
  subnets         = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id

  # Managed node groups
  node_groups = {
    default = {
      desired_capacity = var.desired_node_count
      max_capacity     = var.desired_node_count + 1
      min_capacity     = max(1, var.desired_node_count - 1)

      instance_types = [var.node_instance_type]
      subnet_ids     = module.vpc.private_subnets
    }
  }

  manage_aws_auth           = true
  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  tags = local.common_tags
}

# Allow data sources to get cluster info for providers
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

# OIDC issuer host for IRSA condition
locals {
  cluster_oidc_issuer = module.eks.cluster_oidc_issuer
  oidc_issuer_host    = replace(local.cluster_oidc_issuer, "https://", "")
}

# Fetch AWS Load Balancer Controller IAM policy document
data "http" "alb_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "alb" {
  name   = "AWSLoadBalancerControllerIAMPolicy-${var.cluster_name}"
  policy = data.http.alb_policy.body
}

# IAM role for ALB Controller (IRSA)
data "aws_iam_policy_document" "alb_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb" {
  name               = "alb-controller-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.alb_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "alb_attach" {
  role       = aws_iam_role.alb.name
  policy_arn = aws_iam_policy.alb.arn
}

# Kubernetes ServiceAccount for ALB Controller annotated with IRSA role
resource "kubernetes_service_account" "alb" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb.arn
    }
  }
}

# Install AWS Load Balancer Controller via Helm
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  values = [jsonencode({
    clusterName = var.cluster_name
    region      = var.region
    serviceAccount = {
      create = false
      name   = kubernetes_service_account.alb.metadata[0].name
    }
  })]

  depends_on = [kubernetes_service_account.alb]
}

# IAM policy for ExternalDNS (least privilege for Route53)
data "aws_iam_policy_document" "external_dns_policy_doc" {
  statement {
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets"
    ]
    resources = ["arn:aws:route53:::hostedzone/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "external_dns" {
  name   = "ExternalDNSPolicy-${var.cluster_name}"
  policy = data.aws_iam_policy_document.external_dns_policy_doc.json
}

# IAM role for ExternalDNS (IRSA)
data "aws_iam_policy_document" "external_dns_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:kube-system:external-dns"]
    }
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "external-dns-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "external_dns_attach" {
  role       = aws_iam_role.external_dns.name
  policy_arn = aws_iam_policy.external_dns.arn
}

# Kubernetes ServiceAccount for ExternalDNS annotated with IRSA role
resource "kubernetes_service_account" "external_dns" {
  metadata {
    name      = "external-dns"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns.arn
    }
  }
}

# Install ExternalDNS via Helm
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  namespace  = "kube-system"

  values = [jsonencode({
    provider = "aws"
    aws = {
      region = var.region
    }
    policy        = "upsert-only"
    txtOwnerId    = var.cluster_name
    domainFilters = [var.domain_name]
    serviceAccount = {
      create = false
      name   = kubernetes_service_account.external_dns.metadata[0].name
    }
  })]

  depends_on = [kubernetes_service_account.external_dns]
}

# Output kubeconfig-related info and useful identifiers
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = data.aws_eks_cluster.cluster.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded CA cert"
  value       = data.aws_eks_cluster.cluster.certificate_authority[0].data
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "alb_iam_role_arn" {
  value = aws_iam_role.alb.arn
}

output "external_dns_iam_role_arn" {
  value = aws_iam_role.external_dns.arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "private_subnets" {
  value = module.vpc.private_subnets
}
