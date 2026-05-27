# EKS Terraform (plan-ready)

This repository provisions an AWS EKS cluster and the supporting infrastructure required to run the provided Kubernetes workloads (manifests provided separately). It provisions:

- VPC with public and private subnets (per architecture intent)
- EKS Cluster (managed) with a private node group
- OIDC provider for IRSA
- IAM roles for add-ons (ALB controller, ExternalDNS)
- AWS Load Balancer Controller (Helm) to satisfy Ingress (ALB)
- ExternalDNS (Helm) to sync DNS for the provided domain
- EBS CSI Driver as an EKS managed add-on
- metrics-server (Helm) for HPA support

Important: This Terraform repository does NOT apply your application manifests. The manifests you provided should be deployed via GitOps or CI/CD. If you want Terraform to install app manifests, modify the configuration intentionally.

Quickstart
----------
1. Edit terraform.tfvars or pass variables at the CLI. Required variables (no defaults):
   - cluster_name
   - region
   - domain_name (Route53 hosted zone name; used by ExternalDNS)

2. Initialize and plan:

   terraform init
   terraform plan

3. Apply:

   terraform apply

Outputs
-------
- cluster_name
- cluster_endpoint
- kubeconfig (base64-encoded kubeconfig)
- kubeconfig_command (helper command to configure kubectl)

Notes
-----
- You must ensure that the provided domain_name corresponds to a Route53 hosted zone in this AWS account or adjust ExternalDNS config in values.
- The ALB Ingress controller will expose the frontend as described in your manifests. Ensure the frontend Ingress host matches your DNS records.

