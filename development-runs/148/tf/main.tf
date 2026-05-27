locals {
  # Two AZs in eu-central-1 by default to match architecture agent intent.
  azs = ["eu-central-1a", "eu-central-1b"]

  public_subnet_cidrs  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnet_cidrs = ["10.0.128.0/24", "10.0.129.0/24"]

  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]
}

# VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnet_cidrs
  private_subnets = local.private_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = merge({
    "Name"                                      = "${var.cluster_name}-vpc",
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }, var.tags)

  public_subnet_tags = merge({
    "kubernetes.io/role/elb"                    = "1",
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }, var.tags)

  private_subnet_tags = merge({
    "kubernetes.io/role/internal-elb"           = "1",
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }, var.tags)
}

# EKS cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.15"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  # nodes run in private subnets
  node_groups = {
    managed_nodes = {
      desired_capacity = var.desired_node_count
      min_capacity     = max(1, var.desired_node_count - 1)
      max_capacity     = var.desired_node_count + 2

      instance_type = var.node_instance_type
      key_name      = null

      additional_tags = {
        "kubernetes.io/cluster/${var.cluster_name}" = "shared"
      }
    }
  }

  enable_irsa = true

  manage_aws_auth = true

  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = local.cluster_endpoint_public_access_cidrs

  # Enable control plane logging (api, audit, authenticator)
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  tags = merge({
    "Name" = var.cluster_name
  }, var.tags)

  map_roles = []

  # Create IAM service accounts for add-ons (IRSA). Policies are created below and referenced here.
  create_iam_service_account = [
    {
      name              = "aws-load-balancer-controller"
      namespace         = "kube-system"
      attach_policy_arn = aws_iam_policy.alb_controller_policy.arn
      create_role       = true
    },
    {
      name              = "external-dns"
      namespace         = "kube-system"
      attach_policy_arn = aws_iam_policy.external_dns_policy.arn
      create_role       = true
    }
  ]
}

# Data sources to configure kubernetes/helm providers
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

# IAM policies for add-ons
resource "aws_iam_policy" "alb_controller_policy" {
  name        = "${var.cluster_name}-alb-controller-policy"
  description = "IAM policy for AWS Load Balancer Controller (scoped)."

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "acm:DescribeCertificate",
          "acm:ListCertificates",
          "acm:GetCertificate",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          "ec2:DeleteSecurityGroup",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
          "ec2:DescribeVpcs",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteRule",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:Describe*",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "iam:CreateServiceLinkedRole",
          "cognito-idp:DescribeUserPoolClient",
          "waf-regional:GetWebACLForResource",
          "waf-regional:GetWebACL",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection",
          "shield:DescribeSubscription",
          "tag:GetResources",
          "tag:TagResources",
          "tag:UntagResources"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_policy" "external_dns_policy" {
  name        = "${var.cluster_name}-external-dns-policy"
  description = "IAM policy for ExternalDNS to manage Route53 records (limited to the configured zone if provided)."

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "route53:ChangeResourceRecordSets"
        ],
        Resource = var.route53_zone_id != "" ? ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"] : ["arn:aws:route53:::hostedzone/*"]
      },
      {
        Effect = "Allow",
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets"
        ],
        Resource = "*"
      }
    ]
  })
}

# Helm releases for add-ons
resource "helm_release" "aws_load_balancer_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  namespace        = "kube-system"
  create_namespace = false

  values = [jsonencode({
    clusterName = module.eks.cluster_name,
    serviceAccount = {
      create = false,
      name   = "aws-load-balancer-controller",
    },
    region = var.region,
    vpcId  = module.vpc.vpc_id
  })]

  depends_on = [module.eks, aws_iam_policy.alb_controller_policy]
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  namespace        = "kube-system"
  create_namespace = false

  values = [jsonencode({
    serviceAccount = {
      create = false,
      name   = "external-dns",
    },
    provider = "aws",
    aws = {
      region = var.region
    },
    txtOwnerId    = var.cluster_name,
    domainFilters = [var.domain_name]
  })]

  depends_on = [module.eks, aws_iam_policy.external_dns_policy]
}

# NOTE: We do not apply application manifests. The cluster and add-ons are provisioned. The manifests in k8s-extended-148/ should be applied by GitOps or CI/CD.
