terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.21"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "app-eks-cluster"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access  = true
  endpoint_private_access = false

  create_oidc = true

  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  addons = {
    "vpc-cni"    = { addon_name = "vpc-cni" }
    "coredns"    = { addon_name = "coredns" }
    "kube-proxy" = { addon_name = "kube-proxy" }
  }

  eks_managed_node_groups = {
    app_nodes = {
      desired_capacity = 2
      min_capacity     = 2
      max_capacity     = 2
      instance_types   = ["t3.small"]
      subnet_ids       = module.vpc.private_subnets
    }
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# Kubernetes provider configured to interact with the created EKS cluster
# This uses the cluster created by the module. The provider block is defined
# but actual usage of it is left to future resources (we do not apply k8s manifests here).
data "aws_eks_cluster" "cluster" {
  name       = module.eks.cluster_id
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "cluster" {
  name       = module.eks.cluster_id
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
}
