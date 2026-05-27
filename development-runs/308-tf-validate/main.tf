# NOTE: The Kompose manifests omitted a Service or containerPort for 'quotes'. The plan provisions the EKS cluster, VPC, managed node group, EKS managed add-ons (vpc-cni, kube-proxy, coredns), and an IAM role for the AWS Load Balancer Controller (IRSA). You must reconcile the runtime gap for 'quotes' (create a ClusterIP Service on port 5000 or add containerPort to the quotes Deployment) and deploy the AWS Load Balancer Controller Helm release (not created here).

terraform {
  required_version = "~> 1.14.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.13"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "sme-app-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b"]
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Name = "sme-app-vpc"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  name               = "sme-app-eks"
  kubernetes_version = "1.32"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  endpoint_public_access  = true
  endpoint_private_access = false

  create_oidc_provider = true

  addons = {
    vpc_cni = {
      addon_name = "vpc-cni"
    }
    kube_proxy = {
      addon_name = "kube-proxy"
    }
    coredns = {
      addon_name = "coredns"
    }
  }

  eks_managed_node_groups = {
    sme = {
      desired_capacity = 2
      min_size         = 2
      max_size         = 2
      instance_types   = ["t3.medium"]
      subnet_ids       = module.vpc.private_subnets
      capacity_type    = "ON_DEMAND"
    }
  }

  tags = {
    Project = "sme-app"
  }
}

# IAM role and policy for AWS Load Balancer Controller (IRSA)
# The OIDC provider is created by the eks module (create_oidc_provider = true)

data "http" "alb_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

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
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb" {
  name               = "sme-app-aws-load-balancer-controller-role"
  assume_role_policy = data.aws_iam_policy_document.alb_assume_role.json
  tags = {
    Project = "sme-app"
  }
}

resource "aws_iam_policy" "alb" {
  name   = "sme-app-aws-load-balancer-controller-policy"
  policy = data.http.alb_policy.body
}

resource "aws_iam_policy_attachment" "alb_attach" {
  name       = "sme-app-alb-attach"
  roles      = [aws_iam_role.alb.name]
  policy_arn = aws_iam_policy.alb.arn
}

# Create the application namespace in the cluster
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_id]
  }
}

resource "kubernetes_namespace" "sme_app" {
  metadata {
    name = "sme-app"
  }
}

