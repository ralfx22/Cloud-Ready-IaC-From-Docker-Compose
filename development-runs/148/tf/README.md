# EKS Terraform provisioning for SME App

This repository provisions an Amazon EKS cluster and required AWS resources to run the provided Kubernetes manifests (located in k8s-extended-148/). The Terraform code creates:

- VPC (10.0.0.0/16) with public and private subnets across 2 AZs
- NAT Gateways for private subnet egress
- EKS cluster (Kubernetes 1.32) with a managed node group in private subnets
- OIDC provider / IRSA
- IAM Policies and IAM service accounts for AWS Load Balancer Controller and ExternalDNS
- Helm charts to install AWS Load Balancer Controller and ExternalDNS

Important notes:
- Application manifests are not applied by Terraform. Use your CI/CD or GitOps (ArgoCD/Flux) to apply k8s manifests. The add-ons that integrate with AWS (ALB, ExternalDNS) are installed so the Ingress and DNS should work once the manifests are applied.
- Region: eu-central-1
- Default cluster name: "sme-eks-cluster"

Quickstart

1. Configure your AWS credentials (e.g., via AWS CLI environment variables).
2. Initialize Terraform:

   terraform init

3. Review plan:

   terraform plan -var "cluster_name=sme-eks-cluster"

4. Apply:

   terraform apply -var "cluster_name=sme-eks-cluster"

After apply, set up kubectl for the cluster:

  aws eks update-kubeconfig --name <cluster_name> --region eu-central-1

Then apply your Kubernetes manifests (k8s-extended-148/) using kubectl, or configure a GitOps tool to sync the manifests into the cluster.

If you want Automatic DNS management, provide a Route53 hosted zone id to the variable `route53_zone_id`.

Security considerations and assumptions are documented in ASSUMPTIONS.md.
