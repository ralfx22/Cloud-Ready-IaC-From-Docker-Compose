Assumptions and rationales (explicit):

- Region: eu-central-1 (requested in hard requirements).
  Rationale: Hard requirement.

- Terraform and provider/module versions pinned:
  - terraform = 1.5.7
  - provider.aws = 5.17.0
  - provider.kubernetes = 2.18.0
  - provider.helm = 2.9.0
  - module vpc = terraform-aws-modules/vpc/aws version 4.0.0
  - module eks = terraform-aws-modules/eks/aws version 19.0.0
  Rationale: Pin to stable, reproducible versions. These specific versions are chosen to be recent and stable as of the time of generation. (If your environment requires different pinned versions, change them consistently in versions.tf and module blocks.)

- AZ and subnet counts: Architecture requested 2 public and 2 private subnets; we used two AZs (eu-central-1a, eu-central-1b) and created 2 public and 2 private subnets accordingly.
  Rationale: Respect architecture agent output which is "ground truth" for network shape.

- VPC CIDR: 10.0.0.0/16 (from architecture output).

- Node group: Managed Node Group using instance type t3.small and desired_node_count = 2 by default.
  Rationale: Architecture requested managed EKS and instance type/desired count.

- OIDC / IRSA: The eks module is asked to create OIDC provider. We create IAM roles for the AWS Load Balancer Controller and ExternalDNS and annotate Kubernetes ServiceAccounts so they use IRSA.
  Rationale: Hard requirement: create OIDC provider and IRSA support.

- AWS Load Balancer Controller: Installed via Helm into kube-system. Public subnets are tagged for ELB/ALB usage.
  Rationale: Ingress manifest uses ALB annotations and internet-facing; controller + subnet tags + IAM required per hard requirements.

- ExternalDNS: Installed via Helm and given permissions to manage Route53 hosted zones. domain_name variable used to scope domain filters.
  Rationale: Ingress references host example.com; architecture intent includes domain placeholder. Route53 id not provided; ExternalDNS is given permission to operate account-wide for hosted zones.

- EBS CSI Driver / StorageClass: Not installed. No PVCs found in manifests.
  Rationale: Hard requirement: only install CSI if PVCs present.

- HPA / metrics-server: Not installed. No HPAs present in manifests.

- Cert-manager: Not installed. No explicit cert-manager intent present.

- Subnet tagging: Public subnets are given kubernetes.io/role/elb and cluster association tags. Private subnets are tagged for internal ELB.
  Rationale: Required for ALB controller to pick subnets.

- Minimal manifest deployment: This repo does NOT apply app manifests. Use GitOps or kubectl after cluster creation.
  Rationale: Delivery model default per instructions.

- IAM policies: The alb-controller-policy.json contains the commonly required permissions for the AWS Load Balancer Controller. The ExternalDNS policy has Route53 permissions across hosted zones. These policies are slightly broad for initial functionality; tighten post-deployment.

- Module argument compatibility: The module arguments used are intentionally conservative and minimal to remain compatible with pinned versions. If terraform validate returns an error due to a module interface mismatch in your environment, update the module version or argument names consistently and re-run terraform init.


If any of these assumptions are unacceptable for your environment (e.g., different AZ layout, strict IAM boundaries, or a specific Route53 hosted zone ID), adjust the variables or replace the policy documents before applying.
