# BSA Evaluation Report
**Complexity tier:** Complex
**Application:** devdcores BookStoreApp - Spring Boot microservices with Consul service discovery and Zuul API gateway
**Stack:** 6 Spring Boot services (account, billing, catalog, order, payment, zuul) + React frontend + Consul + MySQL 5.7 + InfluxDB (untagged) + Kapacitor (untagged) + Telegraf + Zipkin + Prometheus + Grafana + Chronograf (16 services total)
**Notable constraints:** Spring Cloud Consul registers services using pod hostname by default; in Kubernetes, pod hostnames are not resolvable via Kubernetes DNS (unlike Docker Compose where the hostname resolves to the container name), requiring `SPRING_CLOUD_CONSUL_DISCOVERY_PREFER_IP_ADDRESS=true` on all Spring Boot services. InfluxDB and Kapacitor must be pinned to v1.x image tags; pulling `latest` lands on InfluxDB 2.x, breaking Kapacitor and Telegraf which target the 1.x line protocol API. Telegraf docker.sock-based monitoring is structurally incompatible with EKS (no Docker socket on nodes); left unresolved as a known baseline limitation.
**Consistency runs:** Not applicable

## Run index

| Run | Model           | Artifact ID | T1 (tf fmt) | T4 (tf apply) | K1 (K8s apply, EKS) | K3 (K8s WL ready, before fix) | P1 (E2E success) | Repair LOC |
| --- | --------------- | ----------- | ----------- | ------------- | ------------------- | ----------------------------- | ---------------- | ---------- |
| 1   | GPT-5.4         | 610         | PASS        | **FAIL**      | YES                 | 81.25% (13/16)                | **PASS***        | ~29        |
| 2   | Claude Opus 4.6 | 613         | **FAIL**    | PASS          | YES                 | 81.25% (13/16)                | **PASS***        | ~23        |
| 3   | Gemini 3.1 Pro  | 616         | PASS        | **FAIL**      | YES                 | 81.25% (13/16)                | **PASS***        | ~22        |
3 of 3 runs reached a working deployment after fix. P1 assessed after fix. All 3 runs required ~22–29 LOC repairs, placing them at or above the threshold where prior runs were marked FAIL. The dominant shared fix, `SPRING_CLOUD_CONSUL_DISCOVERY_PREFER_IP_ADDRESS=true` on all 6 Spring Boot deployments (~6 LOC), is a systematic miss not addressed in the K8s agent prompt; it is treated here as a baseline complexity cost for this tier rather than a per-run failure. ==**-> need supervisor review**==

## Goal 1: Kubernetes manifests
### Q1.1 Syntactic validity (K1, K2)

| Metric | GPT run 1 (610) | Claude run 2 (613) | Gemini run 3 (616) |
|--------|-----------------|--------------------|--------------------|
| **K1** `kubectl apply` succeeds (EKS) | YES | YES | YES |
| **K2** API/schema error count | 0 | 0 | 0 |
**Smoketest (k3d):** All 3 runs produced errors at the k3d smoketest stage: ImagePullBackOff (linux/amd64 images on ARM host) and StatefulSets Pending (EBS CSI provisioner absent in k3d). Both are cluster-environment mismatches, not schema errors; kubectl apply succeeded in both cases and the pipeline continued. On EKS, kubectl apply succeeded for all 3 runs with 0 schema errors. Runtime failures are captured in K5, not K1.

### Q1.2 Workload runtime (K3, K4)

| Metric | GPT run 1 (610) | Claude run 2 (613) | Gemini run 3 (616) |
|--------|-----------------|--------------------|--------------------|
| **K3** Workload ready rate (before fix) | 81.25% (13/16) | 81.25% (13/16) | 81.25% (13/16) |
| **K4** Failure state counts | 3× CrashLoopBackOff (influxdb, kapacitor, telegraf) | 3× CrashLoopBackOff (influxdb, kapacitor, telegraf) | 3× CrashLoopBackOff (influxdb, kapacitor, telegraf) |
**K4 shared: InfluxDB/Kapacitor latest tag -> InfluxDB 2.x incompatibility (all 3 runs):** InfluxDB and Kapacitor had no version tags in `05-observability.yaml`; both pulled `latest`, which resolved to InfluxDB 2.x. Kapacitor and Telegraf target the InfluxDB 1.x line protocol API and fail on connect with InfluxDB 2.x. Fix: pin `influxdb:1.8` and `kapacitor:1.7` (2 LOC). After fix, InfluxDB and Kapacitor reach Ready state.
**K4 shared: Telegraf crash-loop (all 3 runs, unresolved):** `ralfx22/bsa-telegraf:latest` pulls a newer Telegraf base (v1.38+) which removed `perdevice`, `total`, and `container_names` from `inputs.docker`; config fails strict validation on load. Additionally, `/var/run/docker.sock` is not available on EKS nodes. Fixing requires rebuilding the image with a Kubernetes-native metrics source. **Left unresolved as a known baseline limitation.** After applying influxdb + kapacitor pins, K3 = 93.75% (15/16); Telegraf remains at 1× CrashLoopBackOff. The 10 core business workloads are unaffected.

### Q1.3 Semantic alignment with source spec (K5-K8)
Source: 16 services (account, billing, catalog, order, payment, zuul, frontend, consul, mysql, influxdb, kapacitor, telegraf, zipkin, prometheus, grafana, chronograf); 4 named volumes (MySQL, Grafana, InfluxDB, Chronograf; a fifth `booksture-telegraph-volume` is declared but unmounted); key env vars: DB credentials, OAuth client config, service-to-service addresses, `BACKEND_API_GATEWAY_URL` (frontend).

| Metric                              | GPT 1 | Claude 2 | Gemini 3 |
| ----------------------------------- | ----- | -------- | -------- |
| **K5** Service precision            | 100%  | 100%     | 100%     |
| **K6** Port precision               | 100%  | 100%     | 100%     |
| **K7** Env var coverage             | 100%  | 100%     | 100%     |
| **K8** Volume/persistence coverage  | 100%  | 100%     | 100%     |
**K9 note:** All compose env vars are correctly preserved. `SPRING_CLOUD_CONSUL_DISCOVERY_PREFER_IP_ADDRESS=true` is not in the compose spec, it is a K8s-specific adaptation required because Spring Cloud Consul's default registration uses the pod hostname, which is not DNS-resolvable in Kubernetes (unlike Docker Compose where service names resolve to containers). All 3 models omitted it; this is captured in K4 and P3, not K7, since it is a new env var absent from the source spec rather than a preservation failure. `BACKEND_API_GATEWAY_URL` is correctly carried over; its value must be updated after `terraform apply` to the ALB hostname, which is an expected post-deploy step.
**K10 note:** No volume/persistence failures were reported across any run across all four PVC-backed services (MySQL, Grafana, InfluxDB, Chronograf). No lost+found CrashLoop was observed for MySQL, indicating the subPath constraint was either correctly applied or not triggered by this MySQL configuration.

## Goal 2: Terraform
### Q2.1 Validation chain (T1-T4)

| Metric | GPT-1 (610) | Claude-2 (613) | Gemini-3 (616) |
|--------|-------------|----------------|----------------|
| **T1** fmt | PASS | **FAIL** | PASS |
| **T2** validate | PASS | PASS (after fmt fix) | PASS |
| **T3** plan | PASS | PASS | PASS |
| **T4** apply | **FAIL** | PASS | **FAIL** |
**GPT run 1: T4 failure (duplicate IngressClass):** The AWS Load Balancer Controller Helm chart automatically creates an `alb` IngressClass as part of its installation. GPT's `main.tf` additionally declared a `kubernetes_ingress_class_v1 "alb"` resource. Terraform applied the Helm release first (IngressClass now exists), then tried to create the duplicate resource, which Kubernetes rejected with "ingressclasses.networking.k8s.io `alb` already exists". Fix: remove the `kubernetes_ingress_class_v1.alb` resource, the Helm chart owns and manages that object (~8 LOC removed).
**Claude run 2: T1 failure (fence):** `main.tf` was wrapped in a Markdown code fence, causing `terraform fmt` to fail with `Invalid block definition`. Fix: comment out the fence (2 LOC). Same systematic pattern as Claude runs 4–6 in MD.
**Gemini run 3: T4 failure (missing `before_compute`):** EKS nodes registered with the cluster before vpc-cni was installed, leaving all pods unable to start (`NetworkPluginNotReady`). Fix: add `before_compute = true` to the vpc-cni addon entry (1 LOC). Same pattern as Gemini run 8 in MD.

### Q2.2 EKS baseline sufficiency (E1–E3)

| Metric | GPT 1 | Claude 2 | Gemini 3 |
|--------|-------|----------|----------|
| **E1** Essentials coverage (0–5) | 5/5 | 5/5 | 5/5 |
| **E2** Capacity feasibility | YES | YES | YES |
| **E3** Add-on readiness | YES (after T4 fix) | YES | YES (after T4 fix) |
**E1 checklist: all runs pass all 5 items:**
- VPC + subnets in >=2 AZs + NAT/IGW ✓
- EKS cluster + cluster IAM role ✓
- Managed node group + node IAM role ✓
- Core add-ons declared (vpc-cni, kube-proxy, coredns) ✓
- kubectl auth configured (OIDC/IRSA) ✓
**E3 note (GPT run 1, Gemini run 3):** Add-on readiness was reached after the respective T4 fixes (IngressClass removal for GPT, before_compute for Gemini).

## Constraint compliance
Constraints extracted from `Architecture-agent.md`, `Kubernetes-agent.md`, `Terraform-agent.md`.

| Constraint                                                      | Source agent | GPT 1                                                              | Claude 2       | Gemini 3                |
| --------------------------------------------------------------- | ------------ | ------------------------------------------------------------------ | -------------- | ----------------------- |
| IAM policy from upstream official JSON (no hand-crafting)       | Terraform    | ✓                                                                  | ✓              | ✓                       |
| LBC via Helm only; no direct ALB in Terraform                   | Terraform    | ✓                                                                  | ✓              | ✓                       |
| Version pins (CLI ~>1.14.3, aws ~>6.28, vpc ~>6.6, eks ~>21.0)  | Terraform    | ✓                                                                  | ✓              | ✓                       |
| `before_compute = true` for vpc-cni                             | Architecture | ✓                                                                  | ✓              | **✗** (original output) |
| t3.small + 1.4 GiB allocatable in node-sizing math              | Architecture | ✓                                                                  | ✓              | ✓                       |
| Dedicated non-default namespace                                 | Architecture | ✓ (`bookstore`)                                                    | ✓              | ✓                       |
| No speculative extras                                           | Architecture | **✗** (`kubernetes_ingress_class_v1`, LBC Helm already creates it) | ✓              | ✓                       |
| IRSA for trigger-based add-ons (EBS CSI)                        | Terraform    | ✓                                                                  | ✓              | ✓                       |
| EBS `lost+found` subPath on DB volume mounts                    | K8s          | ✓                                                                  | ✓              | ✓                       |
| Probes omitted unless evidenced in compose                      | K8s          | ✓                                                                  | ✓              | ✓                       |
**Notes:**
- GPT's `kubernetes_ingress_class_v1` resource is the most structurally disruptive constraint violation across all BSA runs, it created a direct conflict with the LBC Helm chart's built-in object and blocked T4 entirely. This is the only instance across all 9 base runs (MD + wger + BSA) of a speculative extra causing a T4 failure.

## Goal 3. Pipeline
### Q3.1 E2E success and failure distribution (P1, P2)

| Run | P1 |
|-----|-----|
| GPT-1 (610) | PASS* |
| Claude-2 (613) | PASS* |
| Gemini-3 (616) | PASS* |
*See run index note: flagged for supervisor review.
**Functional tests:**
- **Postman (52 assertions):** Covers account (register, login, refresh token, role management), product catalog (CRUD), cart, billing (address), payment (Stripe test card), order (create, preview, list, admin view), and negative auth cases. All 52 assertions passed after fixes in all 3 runs.
- **Manual frontend test (8-step happy path):** Browse catalog, register, add to cart, enter shipping address, add payment card, place order, view order history, admin product/user management. Passed after fixes in all 3 runs.

**P2: Failure distribution across stages:**

| Stage             | Runs with failures | Detail                                                                                                                             |
| ----------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| Planning          | 0                  | -                                                                                                                                  |
| Terraform gen+val | 2                  | GPT (T4: IngressClass conflict); Gemini (T4: before_compute)                                                                       |
| K8s gen+val       | 3 (non-blocking)   | All runs: smoketest env failure (ARM images + EBS CSI absent in k3d, pipeline continued)                                           |
| K8s deploy        | 3                  | All runs: influxdb/kapacitor latest tag + Consul PREFER_IP_ADDRESS + second ingress missing (each model generated 1 of 2 required) |
**Note on ingresses:** Every run generated exactly one ingress, GPT the gateway ingress only; Claude and Gemini the frontend ingress only. Both are required: gateway for Postman, frontend for the manual test. The second ingress was added manually; `BACKEND_API_GATEWAY_URL` was updated at the same time once the gateway ALB hostname was known.
**Fixes applied:**
- **GPT-1 (610):** Removed `kubernetes_ingress_class_v1.alb` resource from `main.tf` (~8 LOC). Pinned `influxdb:1.8` and `kapacitor:1.7` in `05-observability.yaml` (2 LOC). Added `SPRING_CLOUD_CONSUL_DISCOVERY_PREFER_IP_ADDRESS=true` to 6 Spring Boot deployments in `04-application-services.yaml` (6 LOC). Added missing frontend Ingress + updated `BACKEND_API_GATEWAY_URL` (~13 LOC). Total ~29 LOC.
- **Claude-2 (613):** Commented out Markdown fence in `main.tf` (2 LOC). Pinned `influxdb:1.8` and `kapacitor:1.7` (2 LOC). Added missing gateway Ingress as `bookstore-zuul-api-gateway-server-ingress.yaml` + updated `BACKEND_API_GATEWAY_URL` (~13 LOC). Added `SPRING_CLOUD_CONSUL_DISCOVERY_PREFER_IP_ADDRESS=true` to 6 deployments (6 LOC). Total ~23 LOC.
- **Gemini-3 (616):** Added `before_compute = true` to vpc-cni addon entry (1 LOC). Pinned `influxdb:1.8` and `kapacitor:1.7` (2 LOC). Added missing gateway Ingress + updated `BACKEND_API_GATEWAY_URL` (~13 LOC). Added `SPRING_CLOUD_CONSUL_DISCOVERY_PREFER_IP_ADDRESS=true` to 6 deployments (6 LOC). Total ~22 LOC.

### Q3.2 Failure types (P3)

| Failure                                                                             | Runs affected       | Category                     | LOC to fix           |
| ----------------------------------------------------------------------------------- | ------------------- | ---------------------------- | -------------------- |
| InfluxDB/Kapacitor no image tag (latest → InfluxDB 2.x, 1.x API incompatible)       | GPT, Claude, Gemini | Runtime failure              | 2                    |
| Consul PREFER_IP_ADDRESS missing, pod hostname not DNS-resolvable in K8s            | GPT, Claude, Gemini | Runtime failure / Spec drift | 6                    |
| Telegraf docker.sock + deprecated config fields (unresolved)                        | GPT, Claude, Gemini | Runtime failure              | - (known limitation) |
| BACKEND_API_GATEWAY_URL set to cluster-internal DNS instead of ALB hostname         | GPT, Claude, Gemini | Runtime failure              | 1                    |
| Missing ingress: frontend (GPT) / API gateway (Claude, Gemini)                      | GPT, Claude, Gemini | Spec drift                   | ~12                  |
| `kubernetes_ingress_class_v1` duplicate resource; LBC Helm chart already creates it | GPT                 | Terraform semantic           | ~8                   |
| `main.tf` wrapped in Markdown fence                                                 | Claude              | Terraform syntax             | 2                    |
| `before_compute = true` missing for vpc-cni                                         | Gemini              | Terraform semantic           | 1                    |

### Q3.3 Consistency (P4)
Not applicable

## Observations
**3 of 3 runs pass P1 (decision flagged for supervisor review).** Repair costs ranged from ~22 to ~29 LOC across 4–5 chains per run. The dominant shared failure, Consul PREFER_IP_ADDRESS (~6 LOC, non-trivial domain knowledge), is not addressed in the K8s agent prompt. If treated as a per-run failure consistent with the ~20 LOC threshold applied in MD and wger, all 3 runs would be FAIL. The current PASS reflects the view that a systematic prompt gap affecting all 3 models equally is a baseline complexity cost for this tier, not a per-run model failure.
**The Consul PREFER_IP_ADDRESS failure is the highest-impact single finding in this evaluation.** One missing env var silenced all 6 Spring Boot services from Consul's perspective, making the Zuul gateway return no available upstream for every request. The root cause is a Compose-to-Kubernetes translation gap that none of the 3 models handled: Spring Cloud Consul registering pod hostnames rather than pod IPs, where pod hostnames are not DNS-resolvable in Kubernetes unlike Docker Compose service names. This is a candidate for explicit documentation in the K8s agent prompt. The same root cause appeared during WP2 workflow development with the Royal Reserve Bank app (Eureka also defaults to pod hostname registration and requires `eureka.instance.prefer-ip-address=true` in Kubernetes); it was not captured as a prompt rule at that time either, making this a recurring gap across Spring service discovery frameworks rather than a BSA-specific surprise.
**The InfluxDB/Kapacitor latest-tag failure is the most surprising systematic omission.** The source compose uses `image: influxdb` and `image: kapacitor` with no version tags; all 3 models faithfully preserved these untagged references into the K8s manifests. The problem is that neither the source nor any model added a 1.x pin, and the current `latest` image for both resolves to the 2.x line, which breaks the 1.x API that Kapacitor and Telegraf depend on. A more capable migration step would recognise untagged TICK stack images as a version-pinning risk and add `influxdb:1.8` / `kapacitor:1.7` proactively. The root cause is non-obvious from the crash logs alone, which show only a connection error rather than an API version mismatch. Chronograf, notably, was pinned in the source compose (`chronograf:1.7.3`) and had no issues.
**Model-specific failure patterns are consistent with prior runs.** Claude generates the Markdown fence in `main.tf` in every run where it appeared, MD runs 4–6 and BSA run 2 (4 of 4 total). Gemini omits `before_compute = true` for vpc-cni in 2 of 4 runs across both apps (MD run 8, BSA run 3). These are systematic serialization and generation-time errors. GPT's duplicate IngressClass resource is a new failure type not seen in MD or wger: creating infrastructure that a Helm chart already manages, then colliding with it at apply time.
**Telegraf is permanently broken across all 3 runs.** Docker-socket-based metrics collection (`inputs.docker`) is structurally incompatible with EKS, the Docker socket is not available on Kubernetes nodes. Fixing requires rebuilding `ralfx22/bsa-telegraf` with a Kubernetes-native metrics input. The 10 core business workloads and the Postman/frontend tests are unaffected; only the observability data pipeline is absent from this baseline deployment.
**The complex tier surfaces a new failure mode absent from MD and wger.** In simpler apps, inter-service addressing used env vars that models carried over mechanically (e.g., `USER_ADDRESS`, `DB_URI`). BSA's Consul-mediated discovery added an implicit registration behavior that differs between Compose and Kubernetes. No model identified or corrected it. This pattern, implicit framework behavior that works in Compose but breaks in K8s, is likely to recur in other service-mesh or discovery-dependent applications and warrants consideration in the prompt design.
