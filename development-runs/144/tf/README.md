# Terraform repository: EKS baseline for 'sme-app'

This repository provisions an Amazon EKS cluster and minimal infra to run the provided Kubernetes manifests (namespace, deployments, services, ALB ingress).

What this repo creates
- VPC with public and private subnets (2 AZs)
- EKS cluster (Kubernetes 1.32) with a managed node group (private subnets)
- OIDC provider for the cluster (IRSA)
- IAM roles + Kubernetes service accounts + Helm charts for:
  - AWS Load Balancer Controller (ALB ingress)
  - ExternalDNS (Route53-backed DNS automation)

Design and assumptions are documented in ASSUMPTIONS.md.

Quick start (deterministic runbook)
1. Review and set variables in terraform.tfvars or pass via CLI. Defaults target eu-central-1.

2. Initialize and plan
   terraform init
   terraform plan -out plan.tfplan

3. Apply (this will create many resources and may incur charges)
   terraform apply "plan.tfplan"

4. Configure kubectl (after apply finishes)
   aws eks update-kubeconfig --name <cluster_name> --region <region>

5. Validate cluster
   kubectl get nodes -o wide
   kubectl get pods -A
   kubectl get svc -n kube-system

6. After ALB controller and ExternalDNS are ready, deploy your application manifests (we do not auto-apply app resources):
   kubectl apply -f k8s-extended-144/k8s-extended/

Notes
- This repo intentionally does not apply your application manifests. Use your CI/CD or GitOps to deploy resources into the cluster.
- The ALB Ingress in your manifests expects an internet-facing ALB and host example.com. Adjust domain_name variable and your DNS records or integrate with ExternalDNS/Route53.

Cleanup
- terraform destroy

Support
- Inspect Terraform plan and AWS console for created resources. See ASSUMPTIONS.md for important configuration choices and known limitations.
