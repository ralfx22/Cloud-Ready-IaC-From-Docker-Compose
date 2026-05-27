terraform {
  required_version = "~> 1.14.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.11"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = [for i in range(2) : cidrsubnet("10.0.0.0/16", 8, i)]
  private_subnets = [for i in range(2) : cidrsubnet("10.0.0.0/16", 8, i + 10)]

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

  name = "sme-eks-cluster"

  kubernetes_version = "1.32"

  # Endpoint access: public by default, private access disabled
  endpoint_public_access  = true
  endpoint_private_access = false

  # VPC
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Enable IAM Roles for Service Accounts
  enable_irsa = true

  # EKS add-ons via the Addons API
  addons = {
    vpc_cni = {
      addon_name        = "vpc-cni"
      resolve_conflicts = "OVERWRITE"
    }
    kube_proxy = {
      addon_name        = "kube-proxy"
      resolve_conflicts = "OVERWRITE"
    }
    coredns = {
      addon_name        = "coredns"
      resolve_conflicts = "OVERWRITE"
    }
  }

  # Managed node groups
  eks_managed_node_groups = {
    app_nodes = {
      name             = "app-nodes"
      desired_capacity = 2
      min_size         = 2
      max_size         = 2
      instance_types   = ["t3.small"]
      subnet_ids       = module.vpc.private_subnets
      capacity_type    = "ON_DEMAND"
    }
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# Data sources to configure the Kubernetes provider (populated after cluster creation)
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
