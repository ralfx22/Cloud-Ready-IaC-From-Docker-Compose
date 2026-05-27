ASSUMPTIONS and Decisions

1. AZ / Subnets
   - Architecture requested 2 public and 2 private subnets. This repo uses 2 availability zones (AZs) and creates 2 public and 2 private subnets. The module defaults often recommend 3 AZs; per the architecture output we honored the 2-AZ design.

2. Cluster size and instance type
   - Architecture requested a small managed EKS cluster with desired_node_count=2 and instance_type=t3.small. Node group will be created in private subnets with that configuration.

3. Exposure and Ingress
   - Manifests include an ALB ingress annotation and host example.com. We provision the AWS Load Balancer Controller (ALB) using Helm and create the necessary IAM role for it. Public subnets are tagged for ALB usage.

4. DNS / ExternalDNS
   - ExternalDNS is installed and given a Route53 policy to manage DNS for the provided domain_name. We assume the hosted zone exists in the same account. If it does not, either create it or remove ExternalDNS.

5. EBS CSI Driver
   - The EBS CSI driver is installed as an EKS managed add-on.

6. ServiceAccount roles and IRSA
   - We create IAM roles with trust policies tied to the EKS OIDC provider and annotate Kubernetes service accounts (kube-system namespace) for the ALB controller and ExternalDNS. We deploy controller service accounts into kube-system.

7. Namespace
   - Your manifests target the namespace 'sme-app'. Terraform does not deploy those manifests. The controllers are created in 'kube-system'. This separation follows common patterns.

8. Route53 hosted zone id
   - The architecture output did not include a hosted zone ID. ExternalDNS is configured to discover the zone by name (domain_name). If you prefer to pin a specific hosted zone ID, update helm values for ExternalDNS or provide a terraform variable to set it.

9. IAM policies
   - For add-ons we provide concise, practical IAM inline policies that grant the permissions typically required. They are not the exhaustive least-privilege policies published in the upstream docs; if you require exact upstream IAM policy documents, replace the inline policies with the provider-managed policies or the exact JSON from AWS docs.

10. Application manifests
   - We do NOT apply your provided Kubernetes manifests. They are considered input for architecture and to infer add-ons. Deploy them using your GitOps/CI pipeline; README.md includes direction.

11. kube-system vs dedicated namespace for controllers
   - Controllers (ALB, ExternalDNS, metrics-server) are installed into the kube-system namespace by default. This is a common operational pattern and eases role scoping in the trust policy. If you prefer a different namespace, update the variables and role trust conditions accordingly.

If any of these assumptions should be changed, edit variables.tf or the relevant resources and re-run terraform plan.
