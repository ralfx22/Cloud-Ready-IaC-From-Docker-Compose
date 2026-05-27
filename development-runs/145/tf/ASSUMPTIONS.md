Assumptions, decisions, and rationale

1) AZ and subnet sizing
- Architecture specified 2 public and 2 private subnets. I created 2 AZs (region eu-central-1: a & b) with 1 public and 1 private subnet per AZ.
  Rationale: Follow architecture agent output exactly (2 public, 2 private).

2) Terraform/module versions
- terraform required_version = ">= 1.4.0, < 2.0.0".
- aws provider pinned to "~> 6.0" (per hard requirement).
- terraform-aws-modules/vpc/aws pinned to "~> 3.17" and terraform-aws-modules/eks/aws pinned to "~> 18.0".
  Rationale: Pinned minor/major versions provide deterministic behavior while using module versions compatible with the EKS module interface v18.

3) Public vs private endpoint access
- EKS cluster has both private and public API access enabled; cluster_endpoint_private_access = true and cluster_endpoint_public_access = true.
  Rationale: Security default prefers private access, but keeping public access enables typical operations and CI/CD interactions in simple baseline environments. If you require strict private-only control plane, set cluster_endpoint_public_access = false in the module block.

4) ALB Controller IAM permissions
- For simplicity and to provide a working baseline, the ALB controller IAM role is attached to AWS managed policies (ElasticLoadBalancingFullAccess and AmazonEC2ReadOnlyAccess).
  Rationale: The exact least-privilege JSON policy for the ALB controller is non-trivial. Using managed policies keeps the setup simpler and debuggable. For production, replace attachments with the narrowly scoped IAM policy provided by AWS for the controller.

5) ExternalDNS IAM permissions
- ExternalDNS role is attached to AmazonRoute53FullAccess.
  Rationale: Simplifies integration with Route53. For production, create a scoped policy limited to the specific hosted zone.

6) OIDC/IRSA
- The EKS module creates the OIDC provider. We look it up via data.aws_iam_openid_connect_provider and create IAM roles that trust it for specific service accounts.
  Rationale: Follow best-practice IRSA approach to avoid long-lived Kubernetes secrets for AWS credentials.

7) Subnet tagging
- Public and private subnets are tagged from the VPC module inputs (public_subnet_tags & private_subnet_tags) to allow the ALB controller to discover subnets.
  Rationale: Required for automatic ALB provisioning.

8) Add-ons and CSI drivers
- No PersistentVolumeClaims were present in the manifests, so EBS CSI driver and StorageClass were not installed. If you add PVCs, install the AWS EBS CSI driver and create a gp3 StorageClass.

9) Application deployment
- This Terraform repo does NOT deploy the application manifests. The architecture specified GitOps as a possible future step but did not request automatic app deployment, so manifests should be applied by your CI/CD or GitOps pipeline (ArgoCD/Flux).

10) Domain and Route53
- The ingress host is set to example.com in the provided manifests. ExternalDNS is configured to manage records for var.domain_name. You must create/own a Route53 hosted zone for the domain or allow ExternalDNS permission to manage it.

If any of these assumptions should be changed (e.g., stricter IAM, different AZs, or private-only control plane), edit variables/main.tf and modules accordingly.
