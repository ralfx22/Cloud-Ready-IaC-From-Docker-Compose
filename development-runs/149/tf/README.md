This Terraform repo provisions a minimal AWS EKS environment in eu-central-1 to run the provided Kubernetes manifests for the "sme-app" namespace.

What this repository creates
- VPC (10.0.0.0/16) with 2 AZs, 2 public and 2 private subnets
- 1 NAT Gateway (cost-minimizing)
- EKS cluster (Kubernetes 1.32) with a managed node group (default 2 nodes, t3.small)
- IAM role + policy + Helm installation for AWS Load Balancer Controller (Ingress is present in manifests)
- Subnet tags required by the Load Balancer Controller
- OIDC provider enabled (IRSA)

What this repository intentionally does NOT create
- Any Kubernetes manifests (apps): those should be deployed by your CI/CD or GitOps tooling. This repo only creates infra.
- ExternalDNS, cert-manager, EBS CSI (no PVCs found), metrics-server (no HPA found)

Quick start (example)
1. Review variables in variables.tf and set values via terraform.tfvars or environment variables. At minimum provide AWS credentials and optionally set cluster_name and domain_name.
2. terraform init
3. terraform plan
4. terraform apply

After apply
- The cluster kubeconfig information is printed as outputs. Use the AWS CLI or the kubeconfig details to apply your Kubernetes manifests.

Notes
- Region default: eu-central-1
- Terraform and provider version pins are in versions.tf. See ASSUMPTIONS.md for rationale and any deviations.

Security / cost
- A single NAT Gateway is created (cheaper but single-AZ). If you require HA, update az_count and NAT settings.
- IAM policy for the AWS Load Balancer Controller is scoped to needed AWS actions but uses resource: "*" for brevity; review and harden for production.

Files of interest
- main.tf: core modules and resources
- variables.tf: configurable values
- providers.tf: provider configuration
- versions.tf: Terraform + provider pins
- ASSUMPTIONS.md: decisions, triggers, and potential manual steps

