# NOTE:
# This Terraform configuration was generated to implement the provided planning JSON exactly.
# Important implementation notes / documented discrepancies (from the planning JSON):
# - The Kubernetes manifests indicate the 'quotes' Deployment expects QUOTES_API=http://quotes:5000 but Kompose did not generate a Service for 'quotes'. The planner recommends creating a ClusterIP Service for 'quotes' on port 5000 or updating QUOTES_API. This repo creates only infra and a Kubernetes namespace as requested; it does NOT apply application manifests or add the missing Service. Reconcile application manifests before deploying the app.
# - The original Compose file suggested exposing ports on the host for 'api' (3000) and 'frontend' (8080). The converted Kubernetes manifests use ClusterIP Services (no external exposure). No Ingress/ALB controller is enabled by default here. If external access is required, add an ALB controller / LoadBalancer Service or change the Services accordingly.
# - The infrastructure created: VPC with NAT (eu-central-1), managed EKS control plane (Kubernetes 1.32), and a managed node group of 2 t3.small instances, matching the planning JSON.

terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.8"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

# VPC module (pinned to ~> 6.6)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "app-vpc"
  cidr = "10.0.0.0/16"

  # Use two AZs in eu-central-1
  azs = ["eu-central-1a", "eu-central-1b"]

  # Minimal, explicit subnet CIDRs (2 public, 2 private) as required by the plan
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  # NAT gateway required per plan
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# EKS module (pinned to ~> 21.15)
# This provisions a managed control plane and a managed node group of 2 t3.small nodes per the plan.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.15"

  cluster_name    = "app-eks-cluster"
  cluster_version = "1.32"

  # Use the private subnets for worker nodes
  subnets = module.vpc.private_subnets
  vpc_id  = module.vpc.vpc_id

  # Ensure aws-auth is managed and create OIDC provider for IRSA
  manage_aws_auth = true
  create_oidc     = true

  # Managed node group configuration matching desired_node_count and instance_type
  node_groups = {
    app_nodes = {
      desired_capacity = 2
      min_capacity     = 2
      max_capacity     = 2

      instance_type = "t3.small"
      # Use default AMI mapping from module
    }
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }

  # Keep default settings for other optional add-ons (no ALB controller, no metrics-server by default)
}

# Read cluster data to configure the Kubernetes provider
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id

  # Ensure data is read only after the cluster exists
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id

  depends_on = [module.eks]
}

# Kubernetes provider configured from the created EKS cluster
provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token

  # Do not load local kubeconfig
  load_config_file = false
}

# Create the 'app' namespace as required by the plan (do not deploy application workloads here)
resource "kubernetes_namespace" "app" {
  metadata {
    name = "app"
    labels = {
      name = "app"
    }
  }
}
