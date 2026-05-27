# NOTE: Cluster name and some networking details were inferred from the plan. Name chosen: "app-eks-cluster". Subnet CIDR blocks and AZ selection were also inferred to satisfy the requested public/private subnet counts.

terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "app-vpc"
  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  # core cluster settings (renamed inputs per EKS v21 compatibility requirements)
  name               = "app-eks-cluster"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # endpoint accessibility (inferred defaults)
  endpoint_public_access  = true
  endpoint_private_access = false

  # enable OIDC provider for IRSA (controller/service account IAM)
  create_oidc_provider = true

  # Enable cluster control-plane logs
  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Ensure core EKS add-ons are managed via the Addons API
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

  # Managed node groups
  eks_managed_node_groups = {
    default = {
      desired_capacity = 2
      min_size         = 2
      max_size         = 2

      instance_types = ["t3.small"]
      subnet_ids     = module.vpc.private_subnets

      tags = {
        Name = "eks-ng-default"
      }
    }
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

# Configure the Kubernetes provider to talk to the created EKS cluster
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# Minimal outputs
output "cluster_name" {
  value = module.eks.cluster_id
}

