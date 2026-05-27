# EKS Terraform repository for 'sme-app'

This repository provisions an Amazon EKS cluster and the AWS infrastructure required to run the provided Kubernetes manifests (namespace, Deployments, Services, Ingress) for the "sme-app" workload.

What this repo creates
- VPC (custom CIDR), public and private subnets (2 AZs per architecture intent)
- NAT Gateways for private subnet egress
- Amazon EKS cluster (managed) with a managed nodegroup
- OIDC provider and IRSA-enabled IAM service accounts for add-ons
- IAM policies and IRSA bindings for:
  - AWS Load Balancer Controller (ALB ingress)
  - ExternalDNS (Route53 record management)
  - AWS EBS CSI Driver (dynamic EBS volumes)
- Helm releases installed into the cluster for the above add-ons

Design notes / operational model
- Region: eu-central-1
- Kubernetes version: 1.32 (configurable)
- Managed node group using instance type t3.small by default
- Ingress: AWS ALB (aws-load-balancer-controller) — manifests expect an ALB Ingress
- DNS: ExternalDNS is installed; configure a Route53 hosted zone matching your domain and ensure the IAM role has access to it (policy included)
- Cert-manager: not installed by default. If you want certificate automation via Route53/DNS-01, add cert-manager (Helm) and attach Route53 permissions to its service account or reuse ExternalDNS role with caution.

Usage
1. Set variables (recommended via terraform.tfvars):
   - cluster_name, region, domain_name, node_instance_type, desired_node_count

2. Initialize and apply:
   terraform init
   terraform apply

3. Configure kubectl for local use (after apply):
   aws eks update-kubeconfig --name <cluster_name> --region ${var.region}

4. Deploy application manifests:
   This Terraform repo does NOT apply your application manifests. The cluster is provisioned and configured with ALB and ExternalDNS; apply your Kubernetes manifests using kubectl or GitOps (e.g., ArgoCD/Flux). Example:

   kubectl apply -R -f k8s-extended-142/k8s-extended

Notes
- The ALB Ingress in your manifests references host: example.com. Replace this with your real domain and ensure a Route53 hosted zone exists and is authoritative for that domain. ExternalDNS will create records for the ALB when you have the correct hosted zone.
- The aws-load-balancer-controller service account is created using IRSA and a policy crafted for the controller. Review IAM policies in this repo before applying in production.

Security and assumptions are captured in ASSUMPTIONS.md.
