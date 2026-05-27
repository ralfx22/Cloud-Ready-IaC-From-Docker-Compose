# NOTE:
# - The planning JSON requested an AWS ALB Ingress (AWS Load Balancer Controller) and an OIDC provider for IRSA. Installing the ALB controller correctly requires IRSA (an IAM role bound to a Kubernetes service account). The eks module can create an OIDC provider, but exact IRSA role/policy ARNs were not specified in the plan. This configuration creates the EKS cluster, worker node group, and provisions core EKS add-ons (vpc-cni, coredns, kube-proxy) via the AWS Addons API. Installing the AWS Load Balancer Controller (helm) and creating its IRSA role are intentionally left out so an operator can supply ARNs/policies or run the controller installation after reviewing IAM permissions.

terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.22"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "sme-vpc"
  cidr = "10.0.0.0/16"

  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.100.0/24", "10.0.101.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = {
    Name    = "sme-vpc"
    Project = "sme-app"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  name               = "sme-eks"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Managed node groups (eks_managed_node_groups per EKS v21 input renames)
  eks_managed_node_groups = {
    sme_nodes = {
      desired_capacity = 2
      min_size         = 2
      max_size         = 2

      instance_types = ["t3.medium"]

      subnet_ids = module.vpc.private_subnets

      capacity_type = "ON_DEMAND"

      tags = {
        Name    = "sme-eks-nodes"
        Project = "sme-app"
      }
    }
  }

  # Basic tags
  tags = {
    Project = "sme-app"
  }
}

# Provision standard EKS managed add-ons via the AWS Addons API
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = module.eks.cluster_id
  addon_name   = "vpc-cni"
}

resource "aws_eks_addon" "coredns" {
  cluster_name = module.eks.cluster_id
  addon_name   = "coredns"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = module.eks.cluster_id
  addon_name   = "kube-proxy"
}

# Kubernetes provider configuration using the cluster created by the module
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  host = module.eks.cluster_endpoint

  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# Create the non-default namespace requested by the plan
resource "kubernetes_namespace" "sme_app" {
  metadata {
    name = "sme-app"
  }
}

