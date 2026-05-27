ASSUMPTIONS, DECISIONS, AND RATIONALE

1) Module versions
- terraform-aws-modules/vpc/aws version = "3.19.0"
  Rationale: stable v3 line with stable interface for public_subnets/private_subnets.
- terraform-aws-modules/eks/aws version = "18.29.0"
  Rationale: stable v18 line which supports create_oidc/enable_irsa and managed node_groups.
- Providers pinned in versions.tf: aws ~> 4.60, kubernetes ~> 2.14, helm ~> 2.7
  Rationale: stable provider lines at time of generation; pinned for reproducibility.

2) Region
- Fixed to eu-central-1 per hard requirement.

3) Networking
- VPC created with CIDR 10.0.0.0/16 (from architecture output).
- 2 public and 2 private subnets created across AZs (simplest deterministic mapping).
- NAT gateways enabled to allow nodes in private subnets to pull images and reach external services.

4) EKS cluster
- Managed EKS cluster (architecture requested managed EKS).
- Kubernetes version set to 1.32 per architecture.
- Node group: managed node group with instance type t3.small and desired_node_count default 2.
  Rationale: matches architecture desired node count and cost posture (small nodes).
- Control plane endpoint is set to private (endpoint_public_access = false, endpoint_private_access = true).
  Rationale: security posture preference for private access. This requires running kubectl from within the VPC or a host with network access (bastion/CloudShell with VPC access).

5) OIDC / IRSA
- Module creates an OIDC provider and IRSA support for service accounts.
  Rationale: required for least-privilege IAM for addons.

6) Add-ons (inferred from manifests)
- AWS Load Balancer Controller (Helm): installed to serve the ALB Ingress (Ingress annotations use "alb" and internet-facing scheme).
  - An IRSA role is created and annotated on a Kubernetes ServiceAccount 'aws-load-balancer-controller' in kube-system.
  - The role is attached to the managed policy ElasticLoadBalancingFullAccess for functionality.
  Rationale: Using a broad managed policy reduces initial friction. In production you should replace this with the official least-privilege policy document from AWS.

- ExternalDNS (Helm): installed and given an IRSA role attached to AmazonRoute53FullAccess.
  Rationale: ExternalDNS needs Route53 permissions to create records; AmazonRoute53FullAccess is broad but functional. Replace with narrower policy in production.

- metrics-server (Helm): installed to support any HorizontalPodAutoscaler in manifests.

- aws-ebs-csi-driver (Helm): installed to provide an EBS-backed StorageClass (gp3)
  Rationale: No PVCs are present in the provided manifests, but the CSI driver is included because the architecture required it where PVCs are detected or when storage may be needed. The chart is installed without a dedicated IRSA role; nodes' IAM role is commonly sufficient for EBS operations. For stricter security, convert this to an EKS addon or add a dedicated IRSA role.

7) Service "quotes"
- The architecture agent noted that a ClusterIP for quotes should exist for in-cluster DNS. Terraform creates a simple ClusterIP Service named 'quotes' in namespace 'sme-app'.

8) Ingress and DNS
- The provided Ingress uses host example.com; ExternalDNS is installed so if you supply a Route53 Hosted Zone matching var.domain_name and run ExternalDNS with correct permissions, DNS records will be created.
- TLS/cert-manager: not installed by default because manifests did not request TLS/cert-manager. If you need automatic certificates via DNS-01, add cert-manager and bind its ServiceAccount to a Route53-capable role.

9) IAM and least-privilege
- For development speed this repo attaches broad, AWS-managed policies to IRSA roles (ElasticLoadBalancingFullAccess, AmazonRoute53FullAccess). This is intentionally conservative to get the system working end-to-end and is documented here.
- Recommended follow-up: replace those attachments with least-privilege policy documents per each add-on's upstream documentation.

10) Manifest deployment model
- This repo does not apply the application manifests (default delivery model). Use GitOps or apply them manually after cluster is reachable. If you want Terraform to apply them, modify Terraform to read YAML and create kubernetes_resources.

11) Determinism and defaults
- If any details were missing (exact hosted zone ID, exact AWS Load Balancer Controller IAM policy), conservative defaults were chosen to keep the system runnable. See items above for security trade-offs.

12) What to change for production
- Replace broad IAM policies with least-privilege policy documents.
- Increase node counts and replicas; add autoscaling (Cluster Autoscaler or Karpenter) if desired.
- Enable public endpoint with restricted CIDR blocks for admin access if needed.
- Add proper TLS with cert-manager and Route53 DNS validation.

