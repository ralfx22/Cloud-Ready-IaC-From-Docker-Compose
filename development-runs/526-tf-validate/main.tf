# NOTE:
# - The supporting manifests state that the AWS Load Balancer Controller is installed separately.
#   The planning JSON requires Terraform to provision it, so this configuration installs it via Helm with IRSA.

terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

locals {
  region                                  = "eu-central-1"
  name                                    = "sme-app"
  cluster_name                            = local.name
  vpc_cidr                                = "10.0.0.0/16"
  public_subnets                          = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets                         = ["10.0.101.0/24", "10.0.102.0/24"]
  aws_load_balancer_controller_version    = "1.13.3"
  aws_load_balancer_controller_policy_url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.3/docs/install/iam_policy.json"
  aws_load_balancer_controller_name       = "aws-load-balancer-controller"
  aws_load_balancer_controller_namespace  = "kube-system"

  tags = {
    Application = local.name
    ManagedBy   = "Terraform"
  }
}

provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = local.name
  cidr = local.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                                     = local.cluster_name
  kubernetes_version                       = "1.35"
  endpoint_public_access                   = true
  endpoint_private_access                  = true
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true
  bootstrap_self_managed_addons            = false

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }

    kube-proxy = {
      most_recent = true
    }

    coredns = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]
      capacity_type  = "ON_DEMAND"
      min_size       = 2
      max_size       = 2
      desired_size   = 2
    }
  }

  tags = local.tags
}

data "aws_eks_cluster" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_iam_openid_connect_provider" "this" {
  url        = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  depends_on = [module.eks]
}

data "http" "aws_load_balancer_controller_iam_policy" {
  url = local.aws_load_balancer_controller_policy_url
}

locals {
  eks_oidc_issuer_hostpath = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

data "aws_iam_policy_document" "aws_load_balancer_controller_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_issuer_hostpath}:sub"
      values = [
        "system:serviceaccount:${local.aws_load_balancer_controller_namespace}:${local.aws_load_balancer_controller_name}"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_issuer_hostpath}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${local.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.aws_load_balancer_controller_assume_role.json
  tags               = local.tags
}

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name   = "${local.cluster_name}-aws-load-balancer-controller"
  policy = data.http.aws_load_balancer_controller_iam_policy.response_body
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = local.aws_load_balancer_controller_name
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = local.aws_load_balancer_controller_version
  namespace  = local.aws_load_balancer_controller_namespace

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "region"
    value = local.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = local.aws_load_balancer_controller_name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.aws_load_balancer_controller.arn
  }

  set {
    name  = "ingressClass"
    value = "alb"
  }

  set {
    name  = "createIngressClassResource"
    value = "true"
  }

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.aws_load_balancer_controller,
  ]
}

