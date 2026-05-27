provider "aws" {
  region = var.region
}

# The EKS module will create the cluster. We expose a kubernetes and helm provider
# configured against the created cluster using data sources referencing the created EKS cluster.
# These providers depend on the EKS module (via the data sources below) and allow installing
# Helm charts and service accounts into the cluster.

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
  # Keep a conservative request timeout for interactive operations
  client_timeout_seconds = 60
  # Ensure provider initialization waits for the cluster
  alias = "eks"
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
    load_config_file       = false
  }
  alias = "eks"
}
