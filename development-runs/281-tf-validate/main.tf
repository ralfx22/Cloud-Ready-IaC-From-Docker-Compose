# NOTE: This configuration provisions a minimal, reproducible AWS EKS cluster per the planning JSON.
# NOTE: The manifests request an ALB Ingress (alb controller). This Terraform configuration enables OIDC/IRSA
# NOTE: via the EKS module but does not install the AWS Load Balancer Controller Helm chart or create the
# NOTE: controller IAM policy. Install the controller and associated IAM policy (or enable it via another
# NOTE: automation) before applying the Ingress manifest.

terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.19"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "app-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b"]
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.100.0/24", "10.0.101.0/24"]

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

  # VPC configuration
  vpc_id     = module.vpc.vpc_id
  subnet_ids = concat(module.vpc.private_subnets, module.vpc.public_subnets)

  # Access
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = false

  # Enable OIDC provider for IRSA
  create_oidc = true

  # Ensure core EKS add-ons are managed through the Addons API
  addons = {
    "vpc-cni"    = {}
    "kube-proxy" = {}
    "coredns"    = {}
  }

  # Managed node groups
  eks_managed_node_groups = {
    workers = {
      desired_capacity = 2
      min_size         = 2
      max_size         = 2

      instance_types = ["t3.small"]
      subnet_ids     = module.vpc.private_subnets

      capacity_type = "ON_DEMAND"
      tags = {
        Name = "app-eks-node"
      }
    }
  }

  manage_aws_auth = true

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

output "cluster_id" {
  value = module.eks.cluster_id
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}

output "kubeconfig_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

