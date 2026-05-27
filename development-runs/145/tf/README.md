# EKS Terraform baseline for sme-app

This repository provisions an AWS EKS cluster and basic infra to run the provided Kubernetes manifests (namespace, deployments, services, ingress). It installs the AWS Load Balancer Controller and ExternalDNS to support the ALB Ingress and domain-driven DNS.

Quick facts / decisions (deterministic defaults):
- Region: eu-central-1
- Terraform: >=1.4.0, <2.0.0
- AWS provider: ~> 6.0
- VPC: new VPC 10.0.0.0/16 with 2 public and 2 private subnets, 1 NAT gateway
- EKS: managed EKS cluster (Kubernetes 1.32) with managed node group (default t3.small, desired_count 2)
- ALB Ingress Controller: installed via Helm (aws-load-balancer-controller)
- ExternalDNS: installed via Helm (Route53 integration)
- IRSA: OIDC provider + IAM roles created for ALB & ExternalDNS

Important files:
- main.tf — module wiring: VPC, EKS, IAM roles and Helm releases for ALB and ExternalDNS
- variables.tf — configurable inputs (cluster_name, region, domain_name, node_instance_type, desired_node_count, etc.)
- providers.tf — terraform provider configuration and Kubernetes/Helm providers configured against the created cluster
- outputs.tf — useful outputs including kubeconfig (sensitive), cluster endpoint, subnet ids, IAM role ARNs

Runbook
1. Initialize
   terraform init

2. Plan
   terraform plan -var "cluster_name=sme-eks-cluster" -var "domain_name=example.com"

3. Apply
   terraform apply -var "cluster_name=sme-eks-cluster" -var "domain_name=example.com"

Validation & troubleshooting
- After apply, retrieve the kubeconfig from the output and test access:
  terraform output -raw kubeconfig > kubeconfig
  KUBECONFIG=kubeconfig kubectl get nodes

- Confirm ALB Controller and ExternalDNS are running:
  KUBECONFIG=kubeconfig kubectl -n kube-system get deploy aws-load-balancer-controller
  KUBECONFIG=kubeconfig kubectl -n default get deploy external-dns

- Check ServiceAccount mappings:
  KUBECONFIG=kubeconfig kubectl -n kube-system describe sa aws-load-balancer-controller
  KUBECONFIG=kubeconfig kubectl -n default describe sa external-dns

Notes & next steps
- This repo does NOT apply your application Kubernetes manifests. It provisions the platform to run them. Deploy the provided manifests via your preferred GitOps/CD pipeline or run kubectl apply -f <manifests> using the kubeconfig output.
- The provided manifests reference host "example.com" in the Ingress. Configure a Route53 hosted zone (matching domain_name) and point DNS to the ALB created by the controller, or allow ExternalDNS to create records if it has permissions for the hosted zone.

Security & assumptions are recorded in ASSUMPTIONS.md.
