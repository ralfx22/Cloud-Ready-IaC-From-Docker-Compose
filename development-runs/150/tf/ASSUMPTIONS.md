ASSUMPTIONS, DECISIONS, AND NOTES

This file records assumptions made by the Terraform Platform Agent when generating this repository.

1) General
- Target platform: Amazon EKS (managed). Per requirements, no ECS or self-managed Kubernetes.
- Terraform and provider versions pinned in versions.tf as required.
- All resources are deployed into eu-central-1 (Frankfurt).

2) Network
- VPC CIDR: 10.0.0.0/16 (from the architecture output).
- Public subnets (2): 10.0.0.0/24, 10.0.1.0/24.
- Private subnets (2): 10.0.100.0/24, 10.0.101.0/24.
- NAT Gateways: enabled (one per AZ); create_nat_gateway = true per architecture request.
- AZs: uses the first 2 available AZs in the region.

3) EKS Cluster
- Cluster version set to 1.32 per architecture output.
- Control plane endpoint: private-only (cluster_endpoint_public_access = false, cluster_endpoint_private_access = true) to follow security defaults preferring restricted access. If operators need public access for management, update variables or provider settings accordingly.
- Cluster logs: api, audit, authenticator enabled.
- OIDC provider: created and IRSA enabled (create_oidc = true, enable_irsa = true).

4) Nodes
- Managed node group used (named app_nodes) with desired/min/max capacity = 2 (per architecture desired_node_count) and instance_type = t3.small.
- Nodes placed in private subnets.
- If SSH access is required, set variable key_name to an existing EC2 keypair name. Default is empty (no SSH key).

5) Kubernetes add-ons
- No ALB Ingress controller installed: architecture.ingress.enabled=false. We do not install the AWS Load Balancer Controller or create ALB-related IAM/service accounts.
- No ExternalDNS/cert-manager: no DNS/TLS signals were present in manifests or architecture intent.
- No EBS CSI driver: manifests contained no PVCs.
- No metrics-server: no HPA detected.

6) Application manifests & workload-specific assumptions
- Namespace: The manifests include a dedicated namespace 'app'. We will not modify manifests; Terraform will create infra only. The architecture output also requested the dedicated namespace 'app'.
- Important discrepancy detected (per architecture notes): The 'quotes' Deployment in the provided manifests expects to be reachable at http://quotes:5000 (the api Deployment sets QUOTES_API accordingly). Kompose did NOT create a Service for 'quotes' because the source Compose had no ports for quotes. To ensure runtime connectivity inside the cluster, one of the following must be done before or as part of application deployment:
  a) Create a ClusterIP Service named 'quotes' in namespace 'app' with port 5000 (targetPort 5000) that selects app=quotes. Also ensure the quotes pod/container declares containerPort 5000 (recommended), or
  b) Update the API Deployment environment variable QUOTES_API to point to the actual reachable service/port for quotes.

- Decision: This Terraform repo provisions infra only and does NOT modify or apply the Kubernetes manifests. The operator must reconcile the above application-level gap. Suggested manifest to add (example - not applied by Terraform):

  apiVersion: v1
  kind: Service
  metadata:
    name: quotes
    namespace: app
  spec:
    type: ClusterIP
    selector:
      app: quotes
    ports:
      - port: 5000
        targetPort: 5000
        protocol: TCP

- The architecture output indicated potential intent for external exposure (original docker-compose had host ports). However the provided K8s manifests use ClusterIP for api and frontend. Per the interpretation rules we follow manifests as-provided and leave exposure as-is. If external access is required, operator should change Service types or add an Ingress and enable the AWS Load Balancer Controller.

7) GitOps / Application Delivery
- The architecture did not request GitOps. Therefore we do NOT install Argo CD or Flux by default. If you want GitOps, install Argo CD (via Helm) or Flux and point it at your manifests repository.

8) Least-privilege IAM
- IRSA is enabled so add-on/serviceAccount IAM roles can be created by maintainers when needed. No additional IRSA roles are created by default since no add-ons (ALB/ExternalDNS/cert-manager) were enabled.

9) Defaults chosen when missing
- If variables or exact values were not provided (e.g., Route53 zone IDs or TLS/Domain details), they were left out. Add DNS/TLS resources only when intent/details are provided.

10) Outputs and next steps
- After terraform apply, a kubeconfig is emitted in the sensitive output 'kubeconfig'. Use it to apply or reconcile your manifests (kubectl/helm/CI-GitOps).

If you need this repository to also install specific add-ons (ALB controller, ExternalDNS, cert-manager, metrics-server, EBS CSI), or to apply the application manifests via Terraform, re-run the agent with that request and the infra will be extended accordingly.
