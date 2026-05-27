# NOTE:
# - The planning JSON is authoritative; Kubernetes manifests were used only as supporting data.
# - Application manifests are intentionally not applied by Terraform. This configuration provisions only the AWS/EKS infrastructure,
#   cluster add-ons, storage backends, namespace, storage classes, and AWS Load Balancer Controller prerequisites.

terraform {
  required_version = "~> 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "aws" {
  region = local.region
}

locals {
  region                            = "eu-central-1"
  cluster_name                      = "wger-eks"
  workload_namespace                = "wger"
  vpc_cidr                          = "10.0.0.0/16"
  availability_zone_count           = 3
  desired_node_count                = 3
  node_instance_type                = "t3.small"
  ebs_default_storage_class_name    = "gp3"
  efs_storage_class_name            = "efs-sc"
  aws_lb_controller_chart_version   = "1.11.0"
  aws_lb_controller_policy_version  = "v2.11.0"
  aws_lb_controller_namespace       = "kube-system"
  aws_lb_controller_service_account = "aws-load-balancer-controller"
  public_subnet_count               = 3
  private_subnet_count              = 3
  cluster_subnet_tag_key            = "kubernetes.io/cluster/${local.cluster_name}"

  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
    Project     = "wger"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_partition" "current" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = local.cluster_name
  cidr = local.vpc_cidr

  azs = slice(data.aws_availability_zones.available.names, 0, local.availability_zone_count)

  public_subnets = [
    for i in range(local.public_subnet_count) : cidrsubnet(local.vpc_cidr, 4, i)
  ]

  private_subnets = [
    for i in range(local.private_subnet_count) : cidrsubnet(local.vpc_cidr, 4, i + local.public_subnet_count)
  ]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"       = "1"
    (local.cluster_subnet_tag_key) = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    (local.cluster_subnet_tag_key)    = "shared"
  }

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                                     = local.cluster_name
  kubernetes_version                       = "1.35"
  authentication_mode                      = "API_AND_CONFIG_MAP"
  endpoint_public_access                   = true
  endpoint_private_access                  = true
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  addons = {
    vpc-cni = {
      before_compute = true
    }
    coredns    = {}
    kube-proxy = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      name           = "default"
      instance_types = [local.node_instance_type]
      capacity_type  = "ON_DEMAND"
      min_size       = local.desired_node_count
      max_size       = local.desired_node_count
      desired_size   = local.desired_node_count
    }
  }

  tags = local.tags
}

data "aws_eks_cluster" "this" {
  name       = local.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "this" {
  name       = local.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

data "http" "aws_load_balancer_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${local.aws_lb_controller_policy_version}/docs/install/iam_policy.json"
}

data "aws_iam_policy_document" "aws_load_balancer_controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:${local.aws_lb_controller_namespace}:${local.aws_lb_controller_service_account}"]
    }
  }
}

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name   = "${local.cluster_name}-aws-load-balancer-controller"
  policy = data.http.aws_load_balancer_controller_policy.response_body

  tags = local.tags
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${local.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.aws_load_balancer_controller_assume_role.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

data "aws_iam_policy_document" "efs_csi_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:efs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "efs_csi" {
  name               = "${local.cluster_name}-efs-csi"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_assume_role.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = local.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags

  depends_on = [module.eks]
}

resource "aws_eks_addon" "efs_csi" {
  cluster_name                = local.cluster_name
  addon_name                  = "aws-efs-csi-driver"
  service_account_role_arn    = aws_iam_role.efs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags

  depends_on = [module.eks]
}

resource "aws_security_group" "efs" {
  name        = "${local.cluster_name}-efs"
  description = "Allow NFS from EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "NFS from EKS worker nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-efs"
  })
}

resource "aws_efs_file_system" "this" {
  encrypted = true

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-shared"
  })
}

resource "aws_efs_mount_target" "this" {
  count = length(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

resource "kubernetes_namespace_v1" "wger" {
  metadata {
    name = local.workload_namespace

    labels = {
      "app.kubernetes.io/part-of" = "wger"
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_account_v1" "aws_load_balancer_controller" {
  metadata {
    name      = local.aws_lb_controller_service_account
    namespace = local.aws_lb_controller_namespace

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.aws_load_balancer_controller.arn
    }

    labels = {
      "app.kubernetes.io/name" = "aws-load-balancer-controller"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = local.aws_lb_controller_chart_version
  namespace  = local.aws_lb_controller_namespace

  values = [
    yamlencode({
      clusterName = local.cluster_name
      region      = local.region
      vpcId       = module.vpc.vpc_id
      serviceAccount = {
        create = false
        name   = local.aws_lb_controller_service_account
      }
      ingressClass               = "alb"
      createIngressClassResource = true
    })
  ]

  depends_on = [
    module.eks,
    kubernetes_service_account_v1.aws_load_balancer_controller,
    aws_iam_role_policy_attachment.aws_load_balancer_controller,
  ]
}

resource "kubernetes_storage_class_v1" "ebs_default" {
  metadata {
    name = local.ebs_default_storage_class_name

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}

resource "kubernetes_storage_class_v1" "efs" {
  metadata {
    name = local.efs_storage_class_name
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Delete"
  volume_binding_mode = "Immediate"
  mount_options       = ["tls"]

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.this.id
    directoryPerms   = "700"
    basePath         = "/dynamic_provisioning"
  }

  depends_on = [
    aws_eks_addon.efs_csi,
    aws_efs_mount_target.this,
  ]
}

output "cluster_name" {
  value = local.cluster_name
}

output "cluster_endpoint" {
  value = data.aws_eks_cluster.this.endpoint
}

output "region" {
  value = local.region
}

output "workload_namespace" {
  value = kubernetes_namespace_v1.wger.metadata[0].name
}

output "ebs_default_storage_class_name" {
  value = kubernetes_storage_class_v1.ebs_default.metadata[0].name
}

output "efs_storage_class_name" {
  value = kubernetes_storage_class_v1.efs.metadata[0].name
}

output "efs_file_system_id" {
  value = aws_efs_file_system.this.id
}

