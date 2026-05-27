# Terraform repo to provision AWS EKS cluster for the provided Kubernetes manifests

This repository provisions a baseline AWS EKS cluster with the minimal infra required to run the supplied manifests (namespace, deployments, services, ALB ingress). It does NOT apply your Kubernetes manifests (they should be applied by CI/CD or GitOps). Instead this prepares cluster, networking, IRSA roles, and Helm installs for the AWS Load Balancer Controller and ExternalDNS to satisfy the Ingress and DNS needs.

Quick start (assumes AWS credentials configured):

1. Initialize
   terraform init

2. Review plan
   terraform plan -var "cluster_name=sme-eks" -var "domain_name=example.com"

3. Apply (creates VPC, EKS, node group, IAM roles, installs ALB controller and ExternalDNS)
   terraform apply -var "cluster_name=sme-eks" -var "domain_name=example.com"

4. Configure kubectl
   $(terraform output -raw kubeconfig_command)

5. Validate cluster
   kubectl get nodes --context $(terraform output -raw cluster_id)
   kubectl get pods -n kube-system

6. Deploy app manifests (outside of Terraform)
   kubectl apply -f k8s-extended-147/k8s-extended

Notes / runbook / debug hooks:
- The module creates node groups with desired size default 2 (variable desired_node_count). Adjust as needed via variable.
- Control plane logs (api, audit, authenticator) are enabled. Check CloudWatch log group names in the AWS console.
- To inspect Helm releases:
  helm --kubeconfig <kubeconfig> list -n kube-system

- If ALB Controller fails to create ALBs check:
  - IAM role ARN: terraform output alb_controller_role_arn
  - kubectl -n kube-system logs deployment/aws-load-balancer-controller

- ExternalDNS will create records only if your Route53 hosted zone matches the provided domain_name variable. The Terraform setup gives ExternalDNS broad access to Route53 hosted zones in the account for simplicity; lock down post-deployment.

Files to review:
- main.tf: core infra
- variables.tf: inputs
- alb-controller-policy.json: IAM policy used for ALB controller
- ASSUMPTIONS.md: contains choices and rationale

Security notes:
- This repo creates IAM policies with the permissions required by the controllers. They are intentionally scoped for functionality; tighten to least-privilege after first deploy.

