# EKS Terraform Deployment (plan-ready)

This repository provisions an AWS VPC and a managed Amazon EKS cluster to run the provided Kubernetes workloads.

Primary choices made (see ASSUMPTIONS.md for details):
- Region: eu-central-1
- VPC: 10.0.0.0/16 with 2 public and 2 private subnets
- NAT Gateways: enabled (one per AZ)
- EKS: Managed cluster (Kubernetes v1.32)
- Worker nodes: Managed node group with 2 x t3.small in private subnets
- OIDC provider & IRSA: enabled
- Control plane logs: api, audit, authenticator enabled
- Ingress & add-ons: Not installed (no Ingress manifests detected and architecture intent disabled ALB)

Important notes:
- This repo provisions infrastructure only. Application manifests are not applied by Terraform by default.
- After terraform apply, a kubeconfig is available from the output (sensitive). You can write it to a file and use kubectl/helm to deploy your application manifests or configure a GitOps tool.

Quick start:
1. Initialize Terraform:
   terraform init

2. Validate:
   terraform validate

3. Plan:
   terraform plan -out plan.out

4. Apply:
   terraform apply "plan.out"

After apply:
- Retrieve the kubeconfig (sensitive output) and connect with kubectl. Example:

  terraform output -raw kubeconfig > kubeconfig
  export KUBECONFIG=$(pwd)/kubeconfig
  kubectl get nodes

Recommended next steps:
- Reconcile the Kubernetes manifests with the application intent described in ASSUMPTIONS.md (notably: add a ClusterIP Service for 'quotes' exposing port 5000, or update the API environment variable).
- Decide on an external exposure strategy (Ingress/ALB or change Service types). If you want GitOps, re-run with the appropriate variable flags and consider installing Argo CD/Flux via Helm.

Security & lifecycle:
- Control plane public access is disabled by default. Ensure your operator has connectivity (VPN/bastion) or enable temporary public access if needed.

