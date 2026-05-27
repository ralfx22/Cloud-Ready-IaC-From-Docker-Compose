ASSUMPTIONS and RATIONALE

1) AZs and subnets
- Assumption: architecture requested 2 public and 2 private subnets, so we create 2 AZs (eu-central-1a, eu-central-1b) with one public and one private subnet each.
  Rationale: Architecture output explicitly requested 2 public and 2 private subnets.

2) VPC CIDR and subnet CIDRs
- Default VPC CIDR: 10.0.0.0/16 (from architecture)
- Default public/private CIDRs are conservative /24s (10.0.0.0/24, 10.0.1.0/24, 10.0.16.0/24, 10.0.17.0/24).
  Rationale: Fixed CIDRs simplify the module inputs and create predictable subnets.

3) EKS module and versions
- Using terraform-aws-modules/eks/aws v18.0.0 per requirement; VPC module pinned to 4.0.0.
  Rationale: Complies with hard requirement to pin the eks module to v18.

4) Node group placement
- Managed node group(s) are placed in private subnets.
  Rationale: Security default prefers private nodes; ALB in public subnets will forward to node targets in private subnets.

5) ALB Controller and ExternalDNS installation
- We install the Helm charts for AWS Load Balancer Controller and ExternalDNS and create IRSA roles for each.
- The IAM roles attach broad AWS managed policies (ElasticLoadBalancingFullAccess, AmazonEC2FullAccess, AmazonRoute53FullAccess for ALB role; AmazonRoute53FullAccess for ExternalDNS role).
  Rationale: Creating the exact minimal inline IAM policy blob for ALB controller is verbose and brittle in this template; attaching managed policies produces a working baseline. Operators should tighten these policies in production.

6) IRSA / OIDC assumptions
- The EKS module is configured with create_oidc = true. The code assumes module outputs module.eks.cluster_oidc_issuer and module.eks.oidc_provider_arn are exported by the module and usable for the IRSA role trust relationship.
  Rationale: The eks module supports creating an OIDC provider; this template relies on its outputs to craft assume role policies for service accounts.

7) DNS / domain
- Default domain_name = example.com (from manifests). ExternalDNS is installed and constrained to this domain by default.
  Rationale: Manifests reference host example.com in Ingress; ExternalDNS will manage Route53 records if your account has a matching Hosted Zone.

8) App manifests
- This Terraform repo does NOT apply the provided Kubernetes manifests. Deploy them via your preferred GitOps/CI pipeline or using kubectl after cluster creation.
  Rationale: Delivery model default and separation of infra/app lifecycle.

9) Security defaults
- EKS control plane logs enabled (api, audit, authenticator).
- Cluster endpoint public access is enabled for initial operator access; private access is also enabled.
  Rationale: Provides operator access post-provisioning; in stricter environments, set cluster_endpoint_public_access = false.

10) Resource tags
- All resources receive tags from variable tags (default Environment=dev, ManagedBy=terraform).

KNOWN LIMITATIONS and ACTION ITEMS
- The IAM policies attached to ALB and ExternalDNS roles are broad; tighten them before production.
- If you have a specific Route53 Hosted Zone, provide appropriate permissions and ensure domain_name matches that hosted zone. ExternalDNS will create records only if a matching zone exists.
- If you require a different number of AZs (3), update variable public_azs and corresponding subnet CIDRs.

If anything is missing or you want stricter IAM, smaller scope for managed policies, or alternative deployment models (Fargate, Karpenter, GitOps), update the Terraform templates accordingly.
