variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "profile" {
  description = "Optional AWS CLI profile name"
  type        = string
  default     = ""
}

provider "aws" {
  region = var.region

  # If a profile is supplied use it. Empty means default provider chain.
  profile = var.profile != "" ? var.profile : null
}

# EKS cluster data sources are used to configure the kubernetes and helm providers.
data "aws_caller_identity" "current" {}

# Kubernetes provider will be configured after EKS cluster is created using data sources in main.tf outputs.
provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
    load_config_file       = false
  }
}
