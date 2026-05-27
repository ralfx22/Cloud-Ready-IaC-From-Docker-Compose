provider "aws" {
  region = var.region
  default_tags {
    tags = merge({
      Terraform = "true",
      ManagedBy = "terraform-eks-agent"
    }, var.tags)
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# The Kubernetes and Helm providers are configured to talk to the EKS cluster
# after it is created. We use the data sources to fetch the cluster info.
# These provider blocks will be populated dynamically via the data sources
# (see main.tf outputs & data references). They are declared here (no static
# config) so they can be referenced by resources/modules that depend on them.
provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
  # Keep the provider pinned / explicit for Terraform provider resolution
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
    load_config_file       = false
  }
}
