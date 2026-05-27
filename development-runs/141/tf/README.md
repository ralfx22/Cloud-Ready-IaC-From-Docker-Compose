Terraform repository to provision AWS EKS infrastructure for the provided Kubernetes workloads.

This repository provisions:
- VPC with public and private subnets (2 AZs as configured)
- EKS managed control plane (Kubernetes v1.32) and managed nodegroup(s)
- OIDC provider for the cluster (IRSA)
- IAM roles and Helm deployments for:
  - AWS Load Balancer Controller (ALB ingress controller)
  - ExternalDNS (Route53 integration)

Notes:
- Application Kubernetes manifests from the user are NOT applied by this Terraform. Use your CI/CD or GitOps system to apply them (kubectl / ArgoCD / Flux).
- The ALB Controller will create an internet-facing ALB per the Ingress manifest and route traffic to the frontend and api services. Public subnets are tagged to allow ALB to discover them.
- ExternalDNS will manage Route53 records. Provide a hosted zone for domain_name or ensure the AWS account has the zone.

Quickstart
1. Install Terraform >= 1.4.6
2. Configure AWS credentials in your environment (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION) or via a profile.
3. Edit variables.tf or pass -var arguments (cluster_name, region, domain_name, desired_node_count, node_instance_type).
4. terraform init
5. terraform plan
6. terraform apply

After apply
- Outputs include cluster kubeconfig data and instructions where to apply your Kubernetes manifests.
- Deploy the application manifests (the repository that produced the k8s YAMLs) to the cluster. Example:
  - Save kubeconfig from the output to ~/.kube/config or use the printed values to configure kubectl.
  - kubectl apply -f path/to/manifests

Security and operations
- Nodes run in private subnets. NAT Gateway enabled for egress.
- EKS control plane logs enabled (API, audit, authenticator)
- Resources are tagged with "Owner = terraform" and cluster name tag.

Files of interest
- main.tf: wires modules and add-on resources
- variables.tf: configurable inputs
- outputs.tf: exported values
- ASSUMPTIONS.md: design decisions and assumptions made

