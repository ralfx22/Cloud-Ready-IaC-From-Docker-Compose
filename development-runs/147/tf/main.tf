locals {
  # We will use two availability zones (architecture specified 2 public and 2 private subnets).
  azs = ["eu-central-1a", "eu-central-1b"]

  # deterministic subnet CIDRs for two AZs, two public and two private
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "4.0.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = merge(var.tags, { "Name" = "${var.cluster_name}-vpc" })
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.0.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.32"

  subnets = module.vpc.private_subnets
  vpc_id  = module.vpc.vpc_id

  # create OIDC provider for IRSA
  create_oidc = true

  # enable control plane logging
  cluster_log_types = ["api", "audit", "authenticator"]

  manage_aws_auth = true

  node_groups = {
    default = {
      desired_capacity = var.desired_node_count
      max_capacity     = var.desired_node_count + 1
      min_capacity     = 1
      instance_types   = [var.node_instance_type]
      name             = "${var.cluster_name}-ng"
    }
  }

  tags = merge(var.tags, { "Name" = var.cluster_name })
}

# Expose EKS cluster information via data sources for provider configuration and add-on setup
data "aws_eks_cluster" "cluster" {
  name       = module.eks.cluster_id
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "cluster" {
  name       = module.eks.cluster_id
  depends_on = [module.eks]
}

# Tag subnets for Kubernetes ALB usage and cluster discovery.
# Public subnets: tag with role/elb and cluster association
resource "aws_subnet_tag" "public_alb_tags" {
  for_each  = toset(module.vpc.public_subnets)
  key       = "kubernetes.io/cluster/${var.cluster_name}"
  value     = "shared"
  subnet_id = each.value
}

resource "aws_subnet_tag" "public_elb_role" {
  for_each  = toset(module.vpc.public_subnets)
  key       = "kubernetes.io/role/elb"
  value     = "1"
  subnet_id = each.value
}

# Private subnets: tag for internal load balancers (internal ALB if used)
resource "aws_subnet_tag" "private_internal_elb" {
  for_each  = toset(module.vpc.private_subnets)
  key       = "kubernetes.io/role/internal-elb"
  value     = "1"
  subnet_id = each.value
}

# IAM role and policy for AWS Load Balancer Controller (IRSA)
resource "aws_iam_policy" "aws_lb_controller_policy" {
  name   = "${var.cluster_name}-alb-controller-policy"
  policy = file("alb-controller-policy.json")
}

resource "aws_iam_role" "aws_lb_controller_role" {
  name = "${var.cluster_name}-alb-controller-sa-role"

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
            "${replace(module.eks.cluster_oidc_issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "attach_lb_controller" {
  role       = aws_iam_role.aws_lb_controller_role.name
  policy_arn = aws_iam_policy.aws_lb_controller_policy.arn
}

# IAM role and policy for ExternalDNS
resource "aws_iam_policy" "external_dns_policy" {
  name = "${var.cluster_name}-external-dns-policy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ],
        Resource = ["arn:aws:route53:::hostedzone/*"]
      },
      {
        Effect   = "Allow",
        Action   = ["route53:ListHostedZones"],
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_iam_role" "external_dns_role" {
  name = "${var.cluster_name}-external-dns-sa-role"

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
            "${replace(module.eks.cluster_oidc_issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:external-dns"
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "attach_external_dns" {
  role       = aws_iam_role.external_dns_role.name
  policy_arn = aws_iam_policy.external_dns_policy.arn
}

# Helm: install AWS Load Balancer Controller into kube-system using the IRSA role we created.
resource "kubernetes_service_account" "aws_lb_controller_sa" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.aws_lb_controller_role.arn
    }
  }
}

resource "helm_release" "aws_lb_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  namespace        = "kube-system"
  create_namespace = false

  values = [yamlencode({
    clusterName = var.cluster_name
    serviceAccount = {
      create = false
      name   = kubernetes_service_account.aws_lb_controller_sa.metadata[0].name
    }
    region = var.region
  })]

  depends_on = [kubernetes_service_account.aws_lb_controller_sa, aws_iam_role_policy_attachment.attach_lb_controller]
}

# Kubernetes ServiceAccount for ExternalDNS that uses the IRSA role
resource "kubernetes_service_account" "external_dns_sa" {
  metadata {
    name      = "external-dns"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns_role.arn
    }
  }
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  namespace        = "kube-system"
  create_namespace = false

  values = [yamlencode({
    provider = "aws"
    aws = {
      region = var.region
    }
    serviceAccount = {
      create = false
      name   = kubernetes_service_account.external_dns_sa.metadata[0].name
    }
    domainFilters = [var.domain_name]
    txtOwnerId    = var.cluster_name
  })]

  depends_on = [kubernetes_service_account.external_dns_sa, aws_iam_role_policy_attachment.attach_external_dns]
}
