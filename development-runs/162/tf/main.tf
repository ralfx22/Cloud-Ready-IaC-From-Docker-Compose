terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.16"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

# Query availability zones and use the first two for a minimal HA footprint
data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  # Use two AZs as requested
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # exactly two public and two private subnets
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  # NAT gateways are required per the plan
  enable_nat_gateway = true

  tags = {
    Name        = "eks-vpc"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  # Cluster basics from the planning contract
  cluster_name    = "app-eks-cluster"
  cluster_version = "1.32"

  # Network: use the VPC created above. Workers live in private subnets.
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  # Enable IRSA so workloads can use IAM via service accounts
  enable_irsa = true

  # Managed node group to satisfy desired_node_count = 2 and instance_type t3.small
  eks_managed_node_groups = {
    app = {
      desired_capacity = 2
      min_size         = 2
      max_size         = 2

      instance_types = ["t3.small"]

      # place nodes into the private subnets (module-level subnets are used by default)
      # subnet_ids can be set per node group if stricter placement is required.
    }
  }

  # Small set of tags to help identify resources
  tags = {
    Name        = "app-eks-cluster"
    Environment = "dev"
    ManagedBy   = "terraform"
  }

  # Keep configuration minimal and compatible with the v21 module defaults.
  # The module will create the IAM OIDC provider (IRSA) and other required resources
  # using its built-in behavior for v21.x. Addons and additional features are left
  # to follow-up changes if required by the Kubernetes manifests.
}
