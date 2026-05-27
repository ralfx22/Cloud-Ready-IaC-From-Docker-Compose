locals {
  # We will target two AZs in eu-central-1 to satisfy architecture intent.
  azs = ["eu-central-1a", "eu-central-1b"]

  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.101.0/24", "10.0.102.0/24"]
}

# VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = ">= 4.0.0"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnet_cidrs
  private_subnets = local.private_subnet_cidrs

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = merge(var.tags, { Name = var.cluster_name })
}

# EKS cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = ">= 18.0.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Security posture: enable private access and keep public access enabled so operator access remains possible.
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  manage_aws_auth_configmap = true

  # Enable control plane logging for audit and troubleshooting (security default)
  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  enable_irsa = true

  # Managed node group for workloads
  eks_managed_node_groups = {
    default = {
      desired_capacity = var.desired_node_count
      min_size         = 1
      max_size         = max(1, var.desired_node_count + 1)
      instance_types   = [var.node_instance_type]
      name             = "primary-ng"
      additional_tags  = var.tags
    }
  }

  # Create IAM Service Accounts (IRSA) for the cluster add-ons and attach the least-privilege policies created below.
  iam_service_accounts = [
    {
      name              = "aws-load-balancer-controller"
      namespace         = "kube-system"
      attach_policy_arn = aws_iam_policy.alb.arn
      create            = true
      role_name         = "eks-sa-aws-load-balancer-controller"
    },
    {
      name              = "external-dns"
      namespace         = "kube-system"
      attach_policy_arn = aws_iam_policy.external_dns.arn
      create            = true
      role_name         = "eks-sa-external-dns"
    },
    {
      name              = "ebs-csi-controller-sa"
      namespace         = "kube-system"
      attach_policy_arn = aws_iam_policy.ebs_csi.arn
      create            = true
      role_name         = "eks-sa-ebs-csi"
    }
  ]

  tags = merge(var.tags, { Name = var.cluster_name })

  depends_on = [module.vpc]
}

# IAM policies required by the add-ons
resource "aws_iam_policy" "alb" {
  name        = "${var.cluster_name}-aws-load-balancer-controller-policy"
  description = "IAM policy for AWS Load Balancer Controller (least-approximate set of permissions)"

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "acm:DescribeCertificate",
        "acm:ListCertificates",
        "acm:GetCertificate",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:Describe*",
        "elasticloadbalancing:*",
        "iam:CreateServiceLinkedRole",
        "iam:GetServerCertificate",
        "iam:ListServerCertificates",
        "cognito-idp:DescribeUserPoolClient",
        "waf-regional:GetWebACLForResource",
        "waf-regional:AssociateWebACL",
        "waf-regional:DisassociateWebACL",
        "wafv2:GetWebACL",
        "shield:GetSubscriptionState",
        "shield:DescribeProtection",
        "shield:CreateProtection",
        "shield:DeleteProtection",
        "tag:GetResources",
        "tag:TagResources",
        "tag:UntagResources"
      ],
      "Resource": "*"
    }
  ]
}
POLICY
}

resource "aws_iam_policy" "external_dns" {
  name        = "${var.cluster_name}-external-dns-policy"
  description = "IAM policy for ExternalDNS to manage Route53 records for the cluster domain"

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListHostedZonesByName"
      ],
      "Resource": "*"
    }
  ]
}
POLICY
}

resource "aws_iam_policy" "ebs_csi" {
  name        = "${var.cluster_name}-ebs-csi-policy"
  description = "IAM policy for AWS EBS CSI Driver (allows attaching/detaching and managing volumes)"

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVolume",
        "ec2:DeleteVolume",
        "ec2:AttachVolume",
        "ec2:DetachVolume",
        "ec2:ModifyVolume",
        "ec2:DescribeVolumes",
        "ec2:DescribeInstances",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:DescribeTags"
      ],
      "Resource": "*"
    }
  ]
}
POLICY
}

# Install AWS Load Balancer Controller via Helm (uses IRSA service account created by the EKS module)
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.5"
  namespace  = "kube-system"

  create_namespace = false

  # Configure the chart to use the IRSA-created service account and the cluster/vpc info.
  values = [
    yamlencode({
      clusterName = module.eks.cluster_id,
      serviceAccount = {
        create = false,
        name   = "aws-load-balancer-controller"
      },
      region = var.region,
      vpcId  = module.vpc.vpc_id
    })
  ]

  depends_on = [module.eks, aws_iam_policy.alb]
}

# Install ExternalDNS via Helm (uses IRSA service account created by the EKS module)
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "external-dns"
  version    = "6.7.0"
  namespace  = "kube-system"

  create_namespace = false

  values = [
    yamlencode({
      provider = "aws",
      aws = {
        region = var.region
      },
      txtOwnerId = var.cluster_name,
      serviceAccount = {
        create = false,
        name   = "external-dns"
      },
      policy = "sync"
    })
  ]

  depends_on = [module.eks, aws_iam_policy.external_dns]
}

# Install AWS EBS CSI Driver via Helm (uses IRSA service account created by the EKS module)
resource "helm_release" "ebs_csi_driver" {
  name       = "aws-ebs-csi-driver"
  repository = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  chart      = "aws-ebs-csi-driver"
  version    = "4.11.0"
  namespace  = "kube-system"

  create_namespace = false

  values = [
    yamlencode({
      controller = {
        serviceAccount = {
          create = false,
          name   = "ebs-csi-controller-sa"
        }
      }
    })
  ]

  depends_on = [module.eks, aws_iam_policy.ebs_csi]
}

# Tag the private subnets for ALB so the controller can discover them if necessary
resource "aws_subnet_tag" "alb_private_subnets" {
  for_each = toset(module.vpc.private_subnets)

  subnet_id = each.value
  key       = "kubernetes.io/cluster/${var.cluster_name}"
  value     = "shared"
}

resource "aws_subnet_tag" "alb_public_subnets" {
  for_each = toset(module.vpc.public_subnets)

  subnet_id = each.value
  key       = "kubernetes.io/role/elb"
  value     = "1"
}
