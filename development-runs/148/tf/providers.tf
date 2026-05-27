provider "aws" {
  region = var.region
  default_tags {
    tags = merge({
      "CreatedBy"   = "terraform",
      "Environment" = var.environment
    }, var.tags)
  }
}

# EKS / Kubernetes providers: these use the AWS EKS cluster endpoint and auth
# Data sources referenced here are declared in main.tf and will resolve during plan/apply.
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
