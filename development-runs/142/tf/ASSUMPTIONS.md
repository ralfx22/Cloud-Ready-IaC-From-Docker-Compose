ASSUMPTIONS, DECISIONS, AND NOTES

This file records choices made by the Terraform Platform Agent to produce a plan-ready repo. If you want different behavior, modify variables.tf or adjust resources.

1) AZs and Subnets
- Architecture input requested 2 public and 2 private subnets. To satisfy this intent we provisioned 2 AZs (eu-central-1a and eu-central-1b) with one public and one private subnet in each AZ.
- This deviates from the platform default of 3 AZs; we prioritized the architecture agent output. If you want 3 AZs change locals.azs and subnet CIDRs.

2) VPC CIDR and subnet CIDRs
- VPC CIDR chosen from architecture output: 10.0.0.0/16.
- Public subnets: 10.0.1.0/24, 10.0.2.0/24
- Private subnets: 10.0.101.0/24, 10.0.102.0/24
- These are defaults and can be overridden via variables.tf or by editing locals in main.tf.

3) EKS module and versions
- We used terraform-aws-modules/eks/aws >= 18.0.0 and terraform-aws-modules/vpc/aws >= 4.0.0 per instructions.
- Terraform core is pinned to ~> 6.0 and providers are pinned in versions.tf.

4) Node groups and sizing
- A single managed node group named 'primary-ng' is created using var.node_instance_type (default t3.small) and desired_node_count (default 2).
- Min and max sizes are conservative: min 1, max = desired + 1.
- Architecture recommended higher availability/replicas; adjust node group sizing and deployment replica counts as needed.

5) Add-ons and IRSA
- Installed via Helm using IRSA service accounts created by the eks module.
- Add-ons installed:
  - aws-load-balancer-controller (ALB ingress)
  - external-dns (Route53 integration)
  - aws-ebs-csi-driver (EBS CSI driver for dynamic volumes)

6) IAM Policies
- IAM policies for the add-ons are created in this repo. They are intended to be least-approximate for the add-ons to function. Review them before using in production and tighten if required.
- The ALB controller policy is a condensed set of permissions commonly required; the full official policy from AWS can be used instead if you prefer.

7) Ingress and DNS
- Your Ingress manifest references host: example.com. You must replace example.com with your real domain and have a Route53 hosted zone created for ExternalDNS to manage records.
- ExternalDNS is configured to manage public hosted zones.

8) TLS / cert-manager
- The architecture output did not explicitly require cert-manager. We did not install cert-manager. If you require automatic TLS (e.g., via Let's Encrypt + DNS-01), install cert-manager and grant it Route53 permissions or use another ACM/managed certificate flow.

9) Application manifests
- Terraform does not deploy the Kubernetes manifests for the application by default. This repo provisions the infra only. Apply the manifests using kubectl or configure GitOps (ArgoCD/Flux). If you want Terraform to manage those resources, update the repo to use the kubernetes provider resources.

10) Control plane logging
- Enabled cluster control plane log types: api, audit, authenticator.

11) Assumed ARNs and policies
- The repo creates IAM policies and attaches them to IRSA-backed roles. It assumes the account has permissions to create IAM policies, roles, and attach them.

12) Route53 zone id
- A Route53 hosted zone id was not provided. ExternalDNS will attempt to find the hosted zone by domain name. Ensure a hosted zone exists matching var.domain_name.

If any of these assumptions are incorrect for your environment, update variables.tf/main.tf and re-run terraform plan/apply.
