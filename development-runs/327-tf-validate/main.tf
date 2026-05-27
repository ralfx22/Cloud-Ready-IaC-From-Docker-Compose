# NOTE: The planning JSON requires EKS add-ons (vpc-cni, kube-proxy, coredns) and an IRSA/OIDC role for the AWS Load Balancer Controller. For simplicity this configuration attaches AWS managed policies (ElasticLoadBalancingFullAccess, AmazonEC2FullAccess, AmazonEKS_CNI_Policy) to the aws-load-balancer-controller IAM role; in production you should replace these with the least-privilege policy recommended by AWS (AWSLoadBalancerControllerIAMPolicy JSON).

terraform {
  required_version = "~> 1.14.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
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
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "sme-app-vpc"
    Environment = "sme-app"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.0"

  # Module (v21) uses renamed inputs: 'name' (cluster_name → name), 'kubernetes_version', etc.
  name               = "sme-eks"
  kubernetes_version = "1.32"

  # VPC configuration
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Endpoint access - keep public access for external ALB / controller communication
  endpoint_public_access  = true
  endpoint_private_access = false

  # Enable core control-plane logging
  enabled_log_types = ["api", "audit", "authenticator"]

  # Ensure OIDC provider exists for IRSA usage
  create_oidc_provider = true
  manage_aws_auth      = true

  # EKS managed add-ons via the Addons API (map of objects)
  addons = {
    vpc_cni = {
      addon_name = "vpc-cni"
      enabled    = true
    }
    kube_proxy = {
      addon_name = "kube-proxy"
      enabled    = true
    }
    coredns = {
      addon_name = "coredns"
      enabled    = true
    }
  }

  # Managed node groups - use eks_managed_node_groups input
  eks_managed_node_groups = {
    sme_nodes = {
      name           = "sme-nodes"
      desired_size   = 2
      min_size       = 2
      max_size       = 2
      instance_types = ["t3.medium"]
      disk_size      = 20
      capacity_type  = "ON_DEMAND"
      subnet_ids     = module.vpc.private_subnets
    }
  }

  # Create IAM Service Account for AWS Load Balancer Controller using IRSA
  iam_service_accounts = [
    {
      name      = "aws-load-balancer-controller"
      namespace = "kube-system"
      attach_policy_arns = [
        "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess",
        "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
        "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
      ]
      create = true
    }
  ]

  tags = {
    Environment = "sme-app"
    Terraform   = "true"
  }
}

# End of configuration

