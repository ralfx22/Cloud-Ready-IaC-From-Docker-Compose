terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.15"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

# Obtain availability zones for subnet placement
data "aws_availability_zones" "available" {}

data "aws_caller_identity" "current" {}

# VPC: terraform-aws-modules/vpc/aws ~> 6.6
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false

  tags = {
    "Name" = "eks-vpc"
  }
}

# EKS: terraform-aws-modules/eks/aws ~> 21.0
# Implements the planning JSON: managed EKS cluster in eu-central-1, Kubernetes v1.32,
# OIDC enabled for IRSA, managed node group with desired 2 t3.small nodes,
# and core addons (vpc-cni, kube-proxy, coredns) configured via addons map.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  # Renamed inputs per EKS v21 module interface
  name               = "app-eks-cluster"
  kubernetes_version = "1.32"

  # VPC placement
  vpc_id     = module.vpc.vpc_id
  subnet_ids = concat(module.vpc.private_subnets, module.vpc.public_subnets)

  # Control plane access (use defaults reflecting public endpoint enabled)
  endpoint_public_access  = true
  endpoint_private_access = false

  # Enable OIDC provider for IRSA
  create_oidc_provider = true

  # Ensure standard add-ons are managed via the EKS Addons API.
  # The module expects a map of addon configuration objects; keep them minimal.
  addons = {
    "vpc-cni"    = {}
    "kube-proxy" = {}
    "coredns"    = {}
  }

  # Managed node groups (use eks_managed_node_groups map not legacy node_groups)
  eks_managed_node_groups = {
    app_nodes = {
      name           = "app-ng"
      desired_size   = 2
      min_size       = 2
      max_size       = 2
      instance_types = ["t3.small"]
      subnet_ids     = module.vpc.private_subnets
      key_name       = null
      additional_tags = {
        "Name" = "app-eks-node"
      }
    }
  }

  # Basic tagging
  tags = {
    Environment = "dev"
    Project     = "sme-app"
  }

  # Keep the module minimal and reproducible: do not manage kubeconfig here beyond outputs.
  manage_aws_auth = true
}

# Outputs useful for users/operators to connect to the created cluster
output "cluster_id" {
  description = "EKS cluster id"
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate-authority-data for the cluster"
  value       = module.eks.cluster_certificate_authority_data
}