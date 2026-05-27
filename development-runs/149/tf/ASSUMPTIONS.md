ASSUMPTIONS, DECISIONS, AND NOTES

Ground truth used
- The supplied Kubernetes manifests (namespace, deployments, services, ingress) are authoritative for workload shape.
- Architecture intent output from the agent was followed (EKS, VPC CIDR 10.0.0.0/16, 2 AZs, NAT, ALB Ingress present, cluster version 1.32, desired node count 2, instance_type t3.small).

Decisions made
- VPC: created via terraform-aws-modules/vpc/aws (pinned in versions.tf). Public and private subnets = 2 (across 2 AZs). Single NAT Gateway to minimize cost.
- EKS: created via terraform-aws-modules/eks/aws (pinned). IRSA (OIDC provider) enabled.
- Nodes: a single managed node group created with desired_node_count default 2 and default instance type t3.small. Min set to 1 to allow scale-down; adjust for production.
- Load Balancer Controller: installed because the manifests include an Ingress with ALB annotations and internet-facing scheme. The Helm chart and an IAM role + policy are created. The role uses the EKS cluster OIDC provider (IRSA).
- Subnet tagging: the VPC module tags public subnets with kubernetes.io/role/elb=1 and kubernetes.io/cluster/${cluster_name}=shared so the ALB controller can discover public subnets.

Omitted because not required by manifests/intent
- EBS CSI Driver: no PVCs were found, so no storage CSI installed.
- metrics-server: no HPAs found.
- ExternalDNS / cert-manager: not installed. The Ingress references host example.com; if you want automated DNS or automatic TLS, enable ExternalDNS and/or cert-manager and provide domain/Route53 details.

Inputs you must provide
- AWS credentials in environment or shared config for Terraform to use.
- Optional: key_name if you want SSH access to nodes. Leave blank to avoid creating or referencing a key.
- Optional: domain_name if you want to use a real DNS name; otherwise the manifest's example.com is left as-is (Ingress will be created in Kubernetes after you deploy the manifests).

Notes about IAM policy
- The AWSLoadBalancerController policy included is sufficient for ALB controller operation but uses resource: "*" in some statements for functionality. For production, review and scope further.

Notes about provider/module outputs
- The terraform-aws-modules/eks/aws module outputs and data lookups are used to configure the Kubernetes/Helm providers. The configuration pattern relies on reading the EKS cluster and its OIDC provider after the cluster is created.

Potential mismatches (manifest vs. intent)
- The manifests create ClusterIP services only. The architecture intent wants frontend & api exposed; we satisfy this by installing the AWS Load Balancer Controller and relying on the provided Ingress. No changes were made to the manifests; you should apply the manifests to the cluster (they reference host example.com). If you want DNS automation, enable ExternalDNS and provide a Route53 zone id and domain name.

If something must be different
- To enable HA NAT (3 AZs): set az_count = 3 and adjust public_subnet_count/private_subnet_count accordingly.
- To change node sizing/count: set node_instance_type and desired_node_count variables.

