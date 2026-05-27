terraform {
  # ensure provider meta is consistent
}

# VPC: use terraform-aws-modules/vpc/aws
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.17"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = ["${var.region}a", "${var.region}b"]
  public_subnets  = [cidrsubnet(var.vpc_cidr, 8, 1), cidrsubnet(var.vpc_cidr, 8, 2)]
  private_subnets = [cidrsubnet(var.vpc_cidr, 8, 11), cidrsubnet(var.vpc_cidr, 8, 12)]

  enable_nat_gateway = true
  single_nat_gateway = true

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

# EKS cluster using terraform-aws-modules/eks/aws v18.x
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 18.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.32"

  subnets = module.vpc.private_subnets
  vpc_id  = module.vpc.vpc_id

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  create_oidc_provider = true

  # Enable a minimal set of control plane logs for auditing and debugging.
  enable_irsa               = true
  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  tags = var.tags

  eks_managed_node_groups = {
    default_nodes = {
      desired_capacity = var.desired_node_count
      min_size         = 1
      max_size         = max(2, var.desired_node_count)
      instance_types   = [var.node_instance_type]
      subnet_ids       = module.vpc.private_subnets
      tags             = merge(var.tags, { "Name" = "${var.cluster_name}-node" })
    }
  }

  # Keep aws-auth configmap management via module
  manage_aws_auth_configmap = true
}

# Wait for the cluster data sources (data.aws_eks_cluster & auth) to be available.
# Create IAM roles and service accounts for ALB Controller and ExternalDNS using IRSA.

# Lookup the created OIDC provider
data "aws_iam_openid_connect_provider" "oidc" {
  url = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
  # depends_on to ensure OIDC provider is created by the EKS module
  depends_on = [module.eks]
}

# IAM role for AWS Load Balancer Controller (IRSA)
data "aws_iam_policy_document" "alb_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.oidc.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_sa_role" {
  name               = "${var.cluster_name}-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.alb_assume_role.json
  tags               = var.tags
}

# Attach commonly required managed policies for ALB controller. These are broad but
# keep the deployment simple and functional for a baseline environment.
resource "aws_iam_role_policy_attachment" "alb_elb" {
  role       = aws_iam_role.alb_sa_role.name
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
}

resource "aws_iam_role_policy_attachment" "alb_readonly_ec2" {
  role       = aws_iam_role.alb_sa_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
}

# IAM role for ExternalDNS
data "aws_iam_policy_document" "external_dns_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.oidc.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:default:external-dns"]
    }
  }
}

resource "aws_iam_role" "external_dns_role" {
  name               = "${var.cluster_name}-external-dns-role"
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "external_dns_route53" {
  role       = aws_iam_role.external_dns_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
}

# Create Kubernetes service accounts using kubernetes provider (IRSA)
resource "kubernetes_service_account" "alb_sa" {
  provider = kubernetes.eks
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_sa_role.arn
    }
  }
  depends_on = [module.eks]
}

resource "kubernetes_service_account" "external_dns_sa" {
  provider = kubernetes.eks
  metadata {
    name      = "external-dns"
    namespace = "default"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns_role.arn
    }
  }
  depends_on = [module.eks]
}

# Deploy AWS Load Balancer Controller via Helm
resource "helm_release" "aws_lb_controller" {
  provider   = helm.eks
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.9.4"

  namespace = "kube-system"

  create_namespace = false

  values = [
    yamlencode({
      clusterName = var.cluster_name
      serviceAccount = {
        create = false
        name   = kubernetes_service_account.alb_sa.metadata[0].name
      }
      region = var.region
      vpcId  = module.vpc.vpc_id
    })
  ]

  depends_on = [kubernetes_service_account.alb_sa]
}

# Deploy ExternalDNS via Helm
resource "helm_release" "external_dns" {
  provider   = helm.eks
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "6.9.4"

  namespace        = "default"
  create_namespace = false

  values = [
    yamlencode({
      provider = "aws"
      aws = {
        region = var.region
      }
      txtOwnerId = var.cluster_name
      serviceAccount = {
        create = false
        name   = kubernetes_service_account.external_dns_sa.metadata[0].name
      }
      domainFilters = [var.domain_name]
    })
  ]

  depends_on = [kubernetes_service_account.external_dns_sa]
}
