locals {
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.100.0/24", "10.0.101.0/24"]
  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = var.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.15"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Prefer private endpoint exposure for the control plane per security defaults
  cluster_endpoint_public_access  = false
  cluster_endpoint_private_access = true

  # Enable selected control plane logs
  cluster_log_types = ["api", "audit", "authenticator"]

  # Create OIDC provider and enable IRSA for least-privilege service accounts
  create_eks      = true
  manage_aws_auth = true
  create_oidc     = true
  enable_irsa     = true

  node_groups = {
    app_nodes = {
      desired_capacity = var.desired_node_count
      max_capacity     = var.desired_node_count
      min_capacity     = var.desired_node_count

      instance_types = [var.instance_type]
      subnet_ids     = module.vpc.private_subnets

      # Optional SSH key (empty string = not set)
      key_name = length(trimspace(var.key_name)) > 0 ? var.key_name : null

      tags = merge(var.tags, { Name = "${var.cluster_name}-node" })
    }
  }

  tags = var.tags

  # Expose useful outputs for consumers
  depends_on = [module.vpc]
}

# Data sources for configuring the Kubernetes/Helm providers after cluster creation
data "aws_eks_cluster" "cluster" {
  name       = module.eks.cluster_id
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "cluster" {
  name       = module.eks.cluster_id
  depends_on = [module.eks]
}
