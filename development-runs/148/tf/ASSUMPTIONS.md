# Assumptions and decisions

This file documents assumptions made while converting the provided Kubernetes manifests and the architecture agent output into a Terraform repository.

1. AZ and subnet counts
   - Architecture agent requested 2 public and 2 private subnets; we provision resources across 2 AZs (eu-central-1a and eu-central-1b). This differs from some upstream defaults that use 3 AZs.

2. Region
   - Fixed to eu-central-1 per hard requirement.

3. Cluster version
   - Kubernetes control plane version set to 1.32 as requested by the architecture agent.

4. Node group
   - A managed node group is created (not Fargate or Karpenter) with default instance type t3.small and desired node count 2.
   - Min and max counts are set conservatively (min = max(1, desired-1), max = desired+2). Adjust variables for production.

5. Network and NAT
   - NAT Gateways enabled to allow nodes in private subnets to reach the internet for image pulls and updates.

6. Endpoint access
   - EKS cluster endpoint is configured with both private and public access enabled. The public access CIDR is set to 0.0.0.0/0 for simplicity. In production you should restrict this to known admin IP ranges. This choice is recorded here and should be tightened.

7. Ingress and DNS
   - The manifests include an Ingress annotated for the AWS ALB Ingress Controller (alb). We install the AWS Load Balancer Controller via Helm and create an IAM policy for it.
   - The Ingress references `example.com`. `domain_name` defaults to this placeholder value. If you have a Route53 zone, provide `route53_zone_id` to allow ExternalDNS to manage DNS records automatically.
   - ExternalDNS is installed and given a limited IAM policy scoped to the provided Route53 zone when `route53_zone_id` is set; otherwise the policy allows listing and changes to hosted zones (hostedzone/*). Tighten this by providing the Zone ID.

8. Storage
   - No PersistentVolumeClaims were present in the supplied manifests; therefore we did not install the EBS CSI Driver nor create a default StorageClass. If you add PVCs later, install the EBS CSI Driver or enable the relevant add-on.

9. Add-ons and IAM
   - We create IAM policies for the Load Balancer Controller and ExternalDNS. The ALB controller policy in this repository is a reasonable scoped policy assembled for functionality; consult the official AWS docs for the canonical least-privilege policy if you require stricter control.
   - IAM roles for service accounts are created using the eks module's IRSA support.

10. Application deployment
   - Terraform does not apply the supplied Kubernetes manifests. The delivery model assumes GitOps or CI/CD will apply k8s resources to the cluster once it is available. This keeps infra and app deployment separated.

11. Default tags
   - Resources are tagged with CreatedBy=terraform and Environment=dev by default. Provide additional tags via the `tags` variable.

12. Resource naming
   - Names are prefixed with the cluster_name variable to keep resources identifiable.

If any of the above assumptions are not acceptable, update variables in variables.tf or modify the Terraform code accordingly.
