ASSUMPTIONS and Decisions

1) Availability Zones and Subnets
- Architecture output requested 2 public and 2 private subnets. This configuration is used (az_count = 2). The platform default of 3 AZs was overridden by the architecture intent.

2) Cluster flavor and version
- EKS managed cluster will be created, targeting Kubernetes version 1.32 as specified.

3) Node groups
- Managed node group(s) with instance type t3.small and desired_node_count=2 (both configurable) will be created in private subnets. This favors cost-conscious but non-production sizing. Adjust instance type and desired_node_count for production workloads.

4) Ingress and external exposure
- The manifests include an Ingress annotated for ALB and an internet-facing scheme. We provision the AWS Load Balancer Controller (ALB) and expose the frontend and API via ALB. Public subnets are tagged to allow ALB to discover them.

5) DNS and TLS
- Architecture requested domain placeholder "example.com". ExternalDNS is installed and given permissions to change Route53 records. You must provide an existing Route53 hosted zone that matches the domain_name variable or update DNS settings accordingly. cert-manager is NOT installed because the architecture did not request certificate management explicitly.

6) Storage and CSI
- The manifests contain no PersistentVolumeClaims. Therefore the EBS CSI Driver is NOT installed by default. If you later add PVCs, install the EBS CSI Driver and create a default StorageClass (gp3).

7) Autoscaling and replicas
- Manifests declare replicas=1. Architecture recommended allowing availability changes; this repository does not change application replica counts. Consider using HPA or adjust Deployment replicas via CI or manifests; enable metrics-server if you add HPAs.

8) Add-ons and IRSA
- An OIDC provider is created for the cluster to allow IRSA.
- Least-privilege IAM roles are created for ALB Controller and ExternalDNS and bound to Kubernetes serviceaccounts via annotations (IRSA).

9) GitOps / Application deployment
- Default delivery model is NOT to apply application manifests from Terraform. If GitOps is preferred, install ArgoCD or Flux outside of this repository. Instructions are in the README if requested later.

10) Defaults and missing values
- Where missing from inputs, safe defaults were chosen and exposed as variables. Key defaults:
  - region = us-east-1
  - cluster_name = sme-eks-cluster
  - domain_name = example.com
  - node_instance_type = t3.small
  - desired_node_count = 2

11) Module and provider versions
- Versions for Terraform and providers are pinned in versions.tf. These are conservative, known-good ranges but may be updated intentionally by operators.

If any of these assumptions conflict with your requirements, update variables.tf or the IaC and re-run terraform plan/apply.

