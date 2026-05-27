
# NOTE: This main.tf implements the planning JSON for an EKS cluster named "sme-app" in eu-central-1.
# NOTE: The planning JSON requested tagging subnets with kubernetes.io/cluster/<cluster-name>=shared|owned but did not choose; this configuration uses "shared".

terraform {
  required_version = "~> 1.14.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
    }
    helm = {
      source  = "hashicorp/helm"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

locals {
  cluster_name = "sme-app"
  sa_name      = "aws-load-balancer-controller"
  sa_namespace = "kube-system"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = local.cluster_name
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]

  enable_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb" = "1"
    "Name" = "${local.cluster_name}-public"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb" = "1"
    "Name" = "${local.cluster_name}-private"
  }

  tags = {
    "Environment" = "sme"
    "Name"        = local.cluster_name
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name = local.cluster_name
  kubernetes_version = "1.32"

  # Provide subnets where control plane & nodes will be placed (both public and private)
  vpc_id     = module.vpc.vpc_id
  subnet_ids = concat(module.vpc.private_subnets, module.vpc.public_subnets)

  # Ensure core add-ons are managed by the EKS Addons API
  addons = {
    "vpc-cni" = {}
    "coredns" = {}
    "kube-proxy" = {}
  }

  # Managed node groups
  eks_managed_node_groups = {
    default = {
      desired_capacity = 2
      min_capacity     = 2
      max_capacity     = 2

      instance_types = ["t3.medium"]
      subnet_ids     = module.vpc.private_subnets
      capacity_type  = "ON_DEMAND"
    }
  }

  tags = {
    "Name" = local.cluster_name
  }
}

# Wait for EKS outputs to be available for provider configuration
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host = data.aws_eks_cluster.cluster.endpoint

  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# Fetch the official AWS Load Balancer Controller IAM policy from upstream
# (this is the official policy JSON used by the controller)
data "http" "alb_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "alb_controller_policy" {
  name        = "alb-controller-policy-${local.cluster_name}"
  description = "IAM policy for AWS Load Balancer Controller - generated for ${local.cluster_name}"
  policy      = data.http.alb_iam_policy.body
}

# Build trust policy for IRSA using the cluster OIDC provider
data "aws_iam_policy_document" "alb_assume_role_policy" {
  statement {
    effect = "Allow"

    principals {
      identifiers = [module.eks.oidc_provider_arn]
      type        = "Federated"
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:${local.sa_namespace}:${local.sa_name}"]
    }
  }
}

resource "aws_iam_role" "alb_irsa_role" {
  name               = "alb-irsa-${local.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.alb_assume_role_policy.json
}

resource "aws_iam_role_policy_attachment" "alb_attach" {
  role       = aws_iam_role.alb_irsa_role.name
  policy_arn = aws_iam_policy.alb_controller_policy.arn
}

# Create the Kubernetes ServiceAccount with the eks.amazonaws.com/role-arn annotation
resource "kubernetes_service_account" "alb_sa" {
  metadata {
    name      = local.sa_name
    namespace = local.sa_namespace

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_irsa_role.arn
    }
  }
}

# Install the AWS Load Balancer Controller via Helm using the IRSA-bound ServiceAccount
resource "helm_release" "aws_load_balancer_controller" {
  name       = local.sa_name
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = local.sa_namespace

  create_namespace = false

  values = [
    yamlencode({
      clusterName = module.eks.cluster_name
      region      = "eu-central-1"
      vpcId       = module.vpc.vpc_id
      serviceAccount = {
        create = false
        name   = kubernetes_service_account.alb_sa.metadata[0].name
      }
    })
  ]

  depends_on = [kubernetes_service_account.alb_sa]
}

# NOTE: Application manifests are not deployed by Terraform per Delivery Model; this repo provisions
# the infrastructure, EKS cluster, node group(s), OIDC/IRSA, and installs the AWS Load Balancer Controller.


