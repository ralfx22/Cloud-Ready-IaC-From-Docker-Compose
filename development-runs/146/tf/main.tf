locals {
  common_tags = {
    ManagedBy = "terraform"
    Project   = "sme-app"
    Cluster   = var.cluster_name
  }
}

# VPC: terraform-aws-modules/vpc/aws
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.19.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = data.aws_availability_zones.available.names[0:2]
  public_subnets  = [cidrsubnet(var.vpc_cidr, 8, 0), cidrsubnet(var.vpc_cidr, 8, 1)]
  private_subnets = [cidrsubnet(var.vpc_cidr, 8, 128), cidrsubnet(var.vpc_cidr, 8, 129)]

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = local.common_tags
}

# EKS cluster: terraform-aws-modules/eks/aws
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "18.29.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  subnets         = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id

  manage_aws_auth = true

  # Create OIDC provider for IRSA
  create_oidc        = true
  enable_irsa        = true

  node_groups = {
    default = {
      desired_capacity = var.desired_node_count
      min_capacity     = 1
      max_capacity     = var.desired_node_count
      instance_types   = [var.node_instance_type]
      tags             = local.common_tags
      subnet_ids       = module.vpc.private_subnets
    }
  }

  # Prefer private control plane endpoint access (security posture). Public access disabled.
  endpoint_public_access  = false
  endpoint_private_access = true

  # Enable control plane logs for debugging / security
  cluster_log_types = ["api", "audit", "authenticator"]

  tags = local.common_tags
}

# Data sources for Kubernetes provider
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

# Tag public subnets for ALB discovery by the controller
resource "aws_subnet" "public_tags" {
  count = length(module.vpc.public_subnets)
  # Use aws_subnet data source to get existing subnet IDs (vpc module created them)
  id = module.vpc.public_subnets[count.index]
  tags = merge(local.common_tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                   = "1"
  })
}

# IAM role for AWS Load Balancer Controller (IRSA)
# Minimal trust policy binds the role to the EKS OIDC provider and the service account 'aws-load-balancer-controller' in kube-system.
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
      variable = "${replace(module.eks.cluster_oidc_issuer, "https://", "")} :sub"
      # Note: terraform requires variable without spaces; keep format exact. See ASSUMPTIONS.md for details.
      values = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.cluster_name}-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.alb_assume_role.json
  description        = "IRSA role for AWS Load Balancer Controller"
  tags               = local.common_tags
}

# Attach a conservative-but-functional managed policy for ALB controller. See ASSUMPTIONS.md for rationale.
resource "aws_iam_role_policy_attachment" "alb_elb_attach" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
}

# Create a Kubernetes ServiceAccount annotated with the IRSA role so Helm install can reuse it.
resource "kubernetes_service_account" "alb_sa" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
    }
  }
}

# ExternalDNS IAM role and ServiceAccount (Route53 access)
data "aws_iam_policy_document" "externaldns_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer, "https://", "")} :sub"
      values = ["system:serviceaccount:kube-system:external-dns"]
    }
  }
}

resource "aws_iam_role" "externaldns" {
  name               = "${var.cluster_name}-externaldns-role"
  assume_role_policy = data.aws_iam_policy_document.externaldns_assume_role.json
  tags               = local.common_tags
}

# Route53 access (broad); documented in ASSUMPTIONS.
resource "aws_iam_role_policy_attachment" "externaldns_route53" {
  role       = aws_iam_role.externaldns.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
}

resource "kubernetes_service_account" "externaldns_sa" {
  metadata {
    name      = "external-dns"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.externaldns.arn
    }
  }
}

# Helm: AWS Load Balancer Controller
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.0"

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

# Helm: ExternalDNS
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  namespace  = "kube-system"
  version    = "1.12.0"

  values = [
    yamlencode({
      provider = "aws"
      aws = { region = var.region }
      serviceAccount = {
        create = false
        name   = kubernetes_service_account.externaldns_sa.metadata[0].name
      }
      txtOwnerId = var.cluster_name
    })
  ]

  depends_on = [kubernetes_service_account.externaldns_sa]
}

# Helm: metrics-server (for HPA support)
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "5.10.2"

  values = [
    yamlencode({
      args = ["--kubelet-insecure-tls"]
    })
  ]
}

# Helm: AWS EBS CSI Driver (to provide StorageClass)
resource "helm_release" "aws_ebs_csi_driver" {
  name       = "aws-ebs-csi-driver"
  repository = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  chart      = "aws-ebs-csi-driver"
  namespace  = "kube-system"
  version    = "3.0.0"

  values = [
    yamlencode({
      controller = { serviceAccount = { create = false } }
    })
  ]
}

# Create the application namespace referenced by the manifests
resource "kubernetes_namespace" "sme_app" {
  metadata {
    name = "sme-app"
    labels = {
      app = "sme-app"
    }
  }
}

# Create a small internal ClusterIP Service for 'quotes' to match architecture note: ensure in-cluster DNS resolves
resource "kubernetes_service" "quotes" {
  metadata {
    name      = "quotes"
    namespace = kubernetes_namespace.sme_app.metadata[0].name
  }

  spec {
    selector = {
      app = "quotes"
    }

    port {
      port        = 5000
      target_port = 5000
      protocol    = "TCP"
      name        = "http"
    }

    type = "ClusterIP"
  }
}
