/*
Terraform repository to provision AWS EKS infrastructure for the provided application manifests.

Implementation notes (authoritative: follow the provided Planning JSON exactly):
- AWS region: eu-central-1
- EKS Kubernetes version: 1.32
- Managed node group: 2 nodes, instance type t3.small
- VPC: 10.0.0.0/16 with 2 public and 2 private subnets, NAT gateway(s) enabled
- Use community modules; pin versions per requirements.

Discrepancies / important manual actions (documented here because repository is code-only):
- Manifests converted by Kompose did NOT create a Service for "quotes". The application expects QUOTES_API=http://quotes:5000 (api Deployment). Either create a ClusterIP Service for "quotes" on port 5000 and ensure the quotes Deployment exposes containerPort 5000, or change the api environment to point to the actual Service/port. This Terraform repo does NOT deploy any Kubernetes manifests or fix that; it only provisions the infra required to run the cluster.
- The Kompose conversion produced ClusterIP Services for "api" and "frontend", which are not externally exposed. If external access is required, add an Ingress (ALB) or change Service types in your manifests. The Planning JSON declared ingress.enabled=false so no ALB controller or Ingress resources are provisioned.

Usage:
- terraform init
- terraform plan
- terraform apply

Hard requirements satisfied in this file:
- Target is Amazon EKS (managed control plane) only.
- terraform-aws-modules/eks/aws pinned to ~> 21.0 (exact pinned below).
- Terraform CLI required_version pinned to ~> 1.14.3.
- hashicorp/aws provider pinned to ~> 6.28.
- hashicorp/kubernetes provider version pinned in required_providers (no K8s resources are created by Terraform in this repo).

This single-file repository intentionally contains only main.tf as required by the task.
*/

terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      # pinned to a stable, compatible provider version; no k8s resources are created by this repo
      version = "~> 2.22"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

# VPC: terraform-aws-modules/vpc/aws
# Version pinned for module stability. This module creates:
# - VPC with the requested CIDR
# - 2 public subnets and 2 private subnets
# - NAT gateways enabled
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = "eks-app-vpc"
  cidr = "10.0.0.0/16"

  # eu-central-1 has 3 AZs (a,b,c). Use two AZs for the requested two publics/two privates.
  azs = ["eu-central-1a", "eu-central-1b"]

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]

  enable_nat_gateway = true
  # create a NAT gateway per AZ (not single) for redundancy
  single_nat_gateway = false

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# EKS cluster: terraform-aws-modules/eks/aws ~> 21.0
# Managed control plane per requirements. Create a managed node group with 2 t3.small nodes.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  cluster_name    = "app-eks-cluster"
  cluster_version = "1.32"

  # Use the private subnets for worker nodes and EKS networking
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  # Enable IRSA / OIDC provider required by the platform rules
  enable_irsa = true

  # managed node group(s) configuration
  node_groups = {
    default_nodes = {
      desired_capacity = 2
      min_capacity     = 2
      max_capacity     = 2

      instance_types = ["t3.small"]

      # common defaults; customize if you have a key pair or SSH needs
      capacity_type = "ON_DEMAND"
    }
  }

  # allow the module to manage aws-auth mapRoles/mapAccounts
  manage_aws_auth = true

  tags = {
    Environment = "dev"
    Application = "sme-app"
  }
}

# Outputs useful to operators (optional but helpful). These outputs are minimal and safe.
output "cluster_name" {
  value = module.eks.cluster_id
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "kubeconfig_command_hint" {
  value = "Run: aws eks update-kubeconfig --name ${module.eks.cluster_id} --region eu-central-1"
}
