terraform {
  # nothing here; versions defined in versions.tf
}

##########################
# VPC (terraform-aws-modules/vpc/aws)
##########################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "4.0.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = var.public_azs

  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets

  enable_nat_gateway = true
  single_nat_gateway = false

  public_subnet_tags = merge(var.tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  })

  private_subnet_tags = merge(var.tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  })

  tags = var.tags
}

##########################
# EKS Cluster (terraform-aws-modules/eks/aws v18)
##########################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "18.0.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # node groups in private subnets
  eks_managed_node_groups = {
    default = {
      desired_capacity = var.desired_node_count
      max_capacity     = max(2, var.desired_node_count)
      min_capacity     = 1
      instance_types   = [var.node_instance_type]
      capacity_type    = "ON_DEMAND"
      subnet_ids       = module.vpc.private_subnets
    }
  }

  manage_aws_auth_configmap = true

  create_oidc = true

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  tags = var.tags

  node_groups_defaults = {
    additional_tags = {
      "k8s.eks.amazonaws.com/cluster" = var.cluster_name
    }
  }
}

##########################
# Data sources referencing EKS for provider configuration
##########################
# data.aws_eks_cluster_auth.cluster is declared in providers.tf

##########################
# IAM for add-ons using IRSA (OIDC) - create 2 IAM roles: alb and external-dns
##########################
# NOTE: The module "eks" creates an OIDC provider when create_oidc = true.
# We rely on outputs module.eks.cluster_oidc_issuer and module.eks.oidc_provider_arn

data "aws_iam_policy_document" "alb_assume_role_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb" {
  name               = "${var.cluster_name}-alb-sa-role"
  assume_role_policy = data.aws_iam_policy_document.alb_assume_role_policy.json
  tags               = var.tags
}

# Attach a set of managed policies to the ALB role. These are broad so the operator
# should review and narrow in production.
resource "aws_iam_role_policy_attachment" "alb_elb_attach" {
  role       = aws_iam_role.alb.name
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
}
resource "aws_iam_role_policy_attachment" "alb_ec2_attach" {
  role       = aws_iam_role.alb.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}
resource "aws_iam_role_policy_attachment" "alb_route53_attach" {
  role       = aws_iam_role.alb.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
}

# ExternalDNS IAM role
data "aws_iam_policy_document" "externaldns_assume_role_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:external-dns"]
    }
  }
}

resource "aws_iam_role" "externaldns" {
  name               = "${var.cluster_name}-externaldns-sa-role"
  assume_role_policy = data.aws_iam_policy_document.externaldns_assume_role_policy.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "externaldns_route53" {
  role       = aws_iam_role.externaldns.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
}

##########################
# Kubernetes service accounts annotated with IAM role ARN for IRSA
##########################
resource "kubernetes_service_account" "alb_sa" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb.arn
    }
  }
  depends_on = [module.eks]
}

resource "kubernetes_service_account" "externaldns_sa" {
  metadata {
    name      = "external-dns"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.externaldns.arn
    }
  }
  depends_on = [module.eks]
}

##########################
# Helm charts for AWS Load Balancer Controller and ExternalDNS
##########################
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  create_namespace = false

  values = [
    yamlencode({
      clusterName = var.cluster_name
      region      = var.region
      vpcId       = module.vpc.vpc_id
      serviceAccount = {
        create = false
        name   = kubernetes_service_account.alb_sa.metadata[0].name
      }
    })
  ]

  depends_on = [kubernetes_service_account.alb_sa]
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  namespace  = "kube-system"

  create_namespace = false

  values = [
    yamlencode({
      provider = "aws"
      serviceAccount = {
        create = false
        name   = kubernetes_service_account.externaldns_sa.metadata[0].name
      }
      domainFilters = [var.domain_name]
      txtOwnerId    = var.cluster_name
    })
  ]

  depends_on = [kubernetes_service_account.externaldns_sa]
}

##########################
# Subnet tag outputs for troubleshooting
##########################
output "vpc_id" {
  description = "VPC id"
  value       = module.vpc.vpc_id
}

output "public_subnets" {
  description = "Public subnet ids"
  value       = module.vpc.public_subnets
}

output "private_subnets" {
  description = "Private subnet ids"
  value       = module.vpc.private_subnets
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN created for the cluster (for IRSA)"
  value       = module.eks.oidc_provider_arn
}
