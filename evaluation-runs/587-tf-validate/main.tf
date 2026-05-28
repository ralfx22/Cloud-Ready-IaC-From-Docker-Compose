# NOTE:
# - The planning JSON is authoritative. The provided manifests include internal targetPorts 50051/50052/50053/50059 and a note that the AWS Load Balancer Controller/default StorageClass must already exist; this configuration provisions those cluster prerequisites and leaves workload manifests unmanaged.
# - EKS module v21 is used with renamed inputs and managed node groups. Core EKS add-ons are configured through the module; the EBS CSI add-on is created separately so its IRSA role can be bound to the cluster OIDC provider after cluster creation.

terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }
}

locals {
  region             = "eu-central-1"
  cluster_name       = "microservice-demo-eks"
  kubernetes_version = "1.35"
  vpc_cidr           = "10.0.0.0/16"
  az_count           = 2

  tags = {
    Environment = "prod"
    ManagedBy   = "Terraform"
    Project     = "microservice-demo"
  }
}

provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = local.cluster_name
  cidr = local.vpc_cidr

  azs = slice(sort(data.aws_availability_zones.available.names), 0, local.az_count)

  public_subnets = [
    for index in range(local.az_count) : cidrsubnet(local.vpc_cidr, 4, index)
  ]

  private_subnets = [
    for index in range(local.az_count) : cidrsubnet(local.vpc_cidr, 4, index + local.az_count)
  ]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                                 = "1"
    (format("kubernetes.io/cluster/%s", local.cluster_name)) = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                        = "1"
    (format("kubernetes.io/cluster/%s", local.cluster_name)) = "shared"
  }

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = local.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access                   = true
  endpoint_private_access                  = true
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns      = {}
    "kube-proxy" = {}
    "vpc-cni" = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]
      desired_size   = 3
      min_size       = 3
      max_size       = 3
      subnet_ids     = module.vpc.private_subnets
    }
  }

  tags = local.tags
}

data "aws_eks_cluster_auth" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

data "http" "aws_load_balancer_controller_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

data "aws_iam_policy_document" "aws_load_balancer_controller_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${local.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.aws_load_balancer_controller_assume_role.json
  tags               = local.tags
}

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name   = "${local.cluster_name}-AWSLoadBalancerController"
  policy = jsonencode(jsondecode(data.http.aws_load_balancer_controller_iam_policy.response_body))
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  name               = "${local.cluster_name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "aws_ebs_csi_driver" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.ebs_csi_driver,
  ]

  tags = local.tags
}

resource "kubernetes_service_account_v1" "aws_load_balancer_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.aws_load_balancer_controller.arn
    }
    labels = {
      "app.kubernetes.io/name" = "aws-load-balancer-controller"
    }
  }

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.aws_load_balancer_controller,
  ]
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.13.0"
  namespace  = "kube-system"

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    region      = local.region
    vpcId       = module.vpc.vpc_id
    serviceAccount = {
      create = false
      name   = kubernetes_service_account_v1.aws_load_balancer_controller.metadata[0].name
    }
  })]

  depends_on = [
    module.eks,
    kubernetes_service_account_v1.aws_load_balancer_controller,
  ]
}

resource "kubernetes_storage_class_v1" "gp3_default" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }

  depends_on = [aws_eks_addon.aws_ebs_csi_driver]
}

