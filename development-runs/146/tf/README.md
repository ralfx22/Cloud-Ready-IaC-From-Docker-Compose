# EKS Terraform baseline for sme-app

This repository provisions a baseline AWS EKS cluster and minimal cluster add-ons needed to run the provided Kubernetes manifests for the `sme-app` application.

What this creates
- VPC with public and private subnets (2 each), NAT gateway(s)
- EKS managed cluster (Kubernetes v1.32) with a managed node group (default nodes: t3.small)
- OIDC provider enabled (IRSA)
- Helm installs (via the cluster's Helm provider):
  - AWS Load Balancer Controller (ALB) (uses IRSA role created in this repo)
  - ExternalDNS (Route53 integration; IRSA role created in this repo)
  - metrics-server (required for HPA)
  - aws-ebs-csi-driver (StorageClass available)
- Kubernetes namespace `sme-app` and a ClusterIP `quotes` Service to match in-cluster DNS used by the application manifests

Security posture / defaults
- Control plane endpoint: private only (endpoint_public_access = false). This reduces public exposure. You must run kubectl from a host inside the VPC (bastion or AWS CloudShell with appropriate network access).
- Control plane logs enabled for api, audit, and authenticator
- Tags applied consistently

Quick start / runbook
1. Initialize and preview:
   terraform init
   terraform plan -var "cluster_name=sme-eks" -var "desired_node_count=2" -var "node_instance_type=t3.small"

2. Apply (this will create VPC and EKS resources; expect ~10-15 minutes):
   terraform apply -var "cluster_name=sme-eks" -auto-approve

3. Configure kubectl (run from a host with access to the VPC/private endpoint):
   aws eks update-kubeconfig --region eu-central-1 --name <cluster-name-output-from-terraform>

4. Verify nodes and system pods:
   kubectl get nodes
   kubectl get pods -n kube-system

5. The manifests (YAML) you provided are not applied by Terraform by default. Recommended flow:
   - Install GitOps (ArgoCD/Flux) or run `kubectl apply -f k8s-extended-146/k8s-extended/` from a host with access to the cluster.

Debugging tips
- EKS control plane logs are enabled and viewable in CloudWatch under `/aws/eks/<cluster-name>/cluster`.
- To inspect Helm release states:
  kubectl get deployments -n kube-system
  kubectl logs deploy/aws-load-balancer-controller -n kube-system

Notes
- After cluster creation, the ALB Controller will reconcile Ingress resources annotated for "alb" and create an internet-facing ALB (Ingress manifest used host example.com). Map DNS in Route53 or update host file for testing.

