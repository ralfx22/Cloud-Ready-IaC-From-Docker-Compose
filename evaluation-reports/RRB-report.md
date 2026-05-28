# RRB Regression Test Report
**Complexity tier:** Intermediate (regression baseline)
**Application:** ralfx22/royal-reserve-bank - Spring Boot microservices with Eureka service discovery
**Stack:** 15 workloads - account-api, account-api-mongo, api-gateway, asset-management-api, asset-management-api-mysql, config-server, discovery-server, grafana, notification-api, notification-api-kafka, prometheus, redis, transaction-api, transaction-api-postgres, zipkin
**Notable constraint:** MySQL 8.x on fresh EBS volume; `--ignore-db-dir=lost+found` was removed in MySQL 8.0.0; the K8s agent prompt requires `subPath: mysql-data` on the volume mount instead.
**Functional test:** Postman suite: 26 assertions covering account, asset management, and transaction flows end-to-end through the API gateway.
**Consistency runs:** Not applicable

## Run index

| Run | Model           | Artifact ID | T1 (tf fmt) | T4 (tf apply) | K1 (K8s apply, EKS) | K4 (K8s WL ready, before fix) | P1 (E2E success) | Repair LOC |
| --- | --------------- | ----------- | ----------- | ------------- | ------------------- | ----------------------------- | ---------------- | ---------- |
| 1   | GPT-5.4         | 551         | PASS        | PASS          | YES                 | 100% (15/15)                  | **PASS**         | ~0         |
| 2   | Claude Opus 4.6 | 564         | **FAIL**    | **FAIL**      | YES                 | 87% (13/15)                   | **PASS**         | ~5         |
| 3   | Gemini 3.1 Pro  | 568         | PASS        | PASS          | YES                 | 53% (8/15)                    | **PASS**         | ~8         |
3 of 3 runs reached a working deployment. P1 assessed after fix.

## Goal 1: Kubernetes manifests
### Q1.1 Syntactic validity (K1, K2)

| Metric | GPT run 1 (551) | Claude run 2 (564) | Gemini run 3 (568) |
|--------|-----------------|--------------------|--------------------|
| **K1** `kubectl apply` succeeds (k3d + EKS) | YES | YES | YES |
| **K2** API/schema error count | 0 | 0 | 0 |
All 3 runs applied cleanly on both the k3d validation cluster and EKS. No schema errors on any run.
**k3d smoketest note (Claude, Gemini):** PVCs for MySQL and PostgreSQL remained Pending in k3d because the `ebs.csi.aws.com` StorageClass does not exist in k3d. The pipeline continued; PVCs provisioned correctly on EKS where the EBS CSI driver was installed. This is an expected k3d limitation, not a manifest error.

### Q1.2 Workload runtime (K4, K5)

| Metric | GPT run 1 (551) | Claude run 2 (564) | Gemini run 3 (568) |
|--------|-----------------|--------------------|--------------------|
| **K4** Workload ready rate (before fix) | 100% (15/15) | 87% (13/15) | 53% (8/15) |
| **K5** Failure state counts | 0 | 2× Error (asset-management-api, asset-management-api-mysql) | 1× CrashLoopBackOff (config-server) + 6× crash (dependent Spring services) |
**Claude: MySQL Error (`--ignore-db-dir=lost+found` removed in MySQL 8.0.0):** On a fresh EBS volume, ext4 places a `lost+found` directory at the mount root. The K8s agent prompt requires a `subPath: mysql-data` volumeMount so MySQL sees a clean subdirectory. Claude instead added `--ignore-db-dir=lost+found` as a MySQL command arg. This arg was removed in MySQL 8.0.0; the pod fails with `unknown variable 'ignore-db-dir=lost+found'`. The dependent `asset-management-api` Spring service also crashed with a connection-refused error. Fix: remove the deprecated arg and add `subPath: mysql-data` to the volumeMount (~2 LOC).
**Gemini: config-server CrashLoopBackOff on EKS.** config-server repeatedly crashed because a `config-server-files` ConfigMap was mounted at `/app/resources/config-files`, shadowing the actual config files baked into the Docker image. With config-server unavailable, all 6 downstream Spring services (account-api, api-gateway, asset-management-api, discovery-server, notification-api, transaction-api) failed to resolve their properties and crashed too. Fix: remove the `volumes` and `volumeMounts` block from the config-server Deployment (~8 LOC). Infrastructure services (MongoDB, MySQL, PostgreSQL, Kafka, Redis, Prometheus, Grafana, Zipkin) were unaffected.

### Q1.3 Semantic alignment with source spec (K7–K10)
Source: 15 services across Deployments and StatefulSets; named volumes for MongoDB, MySQL, and PostgreSQL; key env vars: Eureka endpoints, DB URIs, inter-service addresses.

| Metric                              | GPT 1 | Claude 2 | Gemini 3 |
| ----------------------------------- | ----- | -------- | -------- |
| **K7** Service precision            | 100%  | 100%     | 100%     |
| **K8** Port precision               | 100%  | 100%     | 100%     |
| **K9** Env var coverage             | 100%  | 100%     | 100%     |
| **K10** Volume/persistence coverage | 100%  | ~90%     | 100%     |
**K10 note (Claude):** The PVC was correctly created and mounted in all cases. The missing `subPath` is a mount-level issue; without it, MySQL sees the `lost+found` directory at the volume root and fails to initialize. Scored ~90% to reflect the functional impact.

## Goal 2: Terraform
### Q2.1 Validation chain (T1–T4)

| Metric          | GPT-1 (551) | Claude-2 (564)       | Gemini-3 (568) |
| --------------- | ----------- | -------------------- | -------------- |
| **T1** fmt      | PASS        | **FAIL**             | PASS           |
| **T2** validate | PASS        | PASS (after fmt fix) | PASS           |
| **T3** plan     | PASS        | PASS                 | PASS           |
| **T4** apply    | PASS        | **FAIL**             | PASS           |
**Claude run 2: T1 failure (validation text prefix):** `main.tf` was prefixed with `Validation passed successfully. The only remaining warnings are inside the community IAM module itself (deprecated data.aws_region.current.name) which is outside our control. Here is the final main.tf:`, causing `terraform fmt` to fail with `Invalid block definition` and `Invalid character`. Fix: comment out the prefix line (1 LOC). This is the same serialization failure class as the Markdown fence seen in MD, wger, BSA, and SME, the model consistently outputs human-readable prose before HCL content instead of returning the file verbatim.
**Claude run 2: T4 failure (missing `enable_irsa = true`):** The EKS module block omitted `enable_irsa = true`. Without it, no OIDC provider is created; the `ebs_csi_irsa` module has no OIDC endpoint to bind to, so `terraform apply` aborts. With no add-ons installed (including `vpc-cni`), nodes came up without CNI → `NetworkPluginNotReady` on all nodes. Fix: add `enable_irsa = true` to the `module "eks"` block (~1 LOC).

### Q2.2 EKS baseline sufficiency (E1–E3)

| Metric | GPT 1 | Claude 2 | Gemini 3 |
|--------|-------|----------|----------|
| **E1** Essentials coverage (0–5) | 5/5 | 5/5 | 5/5 |
| **E2** Capacity feasibility | YES | YES | YES |
| **E3** Add-on readiness | YES | YES (after T4 fix) | YES |
**E1 checklist: all runs pass all 5 items:**
- VPC + subnets in >=2 AZs + NAT/IGW ✓
- EKS cluster + cluster IAM role ✓
- Managed node group + node IAM role ✓
- Core add-ons declared (vpc-cni, kube-proxy, coredns) ✓
- kubectl auth configured (OIDC/IRSA) ✓
**E3 note (Claude):** Add-on readiness was not met before the T4 fix (no CNI → NetworkPluginNotReady). After adding `enable_irsa = true` and re-running apply, all core add-ons came up normally.

## Constraint compliance
Constraints extracted from `Architecture-agent.md`, `Kubernetes-agent.md`, `Terraform-agent.md`.

| Constraint | Source agent | GPT 1 | Claude 2 | Gemini 3 |
| ------------------------------------------------------------ | ------------ | ----- | -------- | -------- |
| IAM policy from upstream official JSON (no hand-crafting) | Terraform | ✓ | ✓ | ✓ |
| LBC via Helm only; no direct ALB in Terraform | Terraform | ✓ | ✓ | ✓ |
| Version pins (CLI ~>1.14.3, aws ~>6.28, vpc ~>6.6, eks ~>21.0) | Terraform | ✓ | ✓ | ✓ |
| `before_compute = true` for vpc-cni | Architecture | ✓ | ✓ | ✓ |
| t3.small + 1.4 GiB allocatable in node-sizing math | Architecture | ✓ | ✓ | ✓ |
| Dedicated non-default namespace | Architecture | ✓ (`rrb-app`) | ✓ | ✓ |
| No speculative extras | Architecture | ✓ | ✓ | **✗** |
| IRSA for trigger-based add-ons (EBS CSI) | Terraform | ✓ | **✗** | ✓ |
| EBS `lost+found` subPath on DB volume mounts | K8s | ✓ | **✗** | ✓ |
| Probes omitted unless evidenced in compose | K8s | ✓ | ✓ | ✓ |
**Notes:**
- **Claude - IRSA (`enable_irsa`):** The Terraform agent prompt requires OIDC/IRSA to be enabled via the EKS module. Claude omitted `enable_irsa = true`, preventing OIDC provider creation and causing the T4 failure and a NetworkPluginNotReady cluster state.
- **Claude - EBS subPath:** The K8s agent prompt explicitly requires `subPath: mysql-data` for MySQL volume mounts on fresh EBS. Claude added `--ignore-db-dir=lost+found` as a MySQL command arg instead, both the wrong approach and a deprecated one (arg removed in MySQL 8.0.0).
- **Gemini - No speculative extras:** Gemini added a `config-server-files` ConfigMap volume mount on the config-server Deployment. The actual config files are baked into the `ralfx22/rrb-config-server` Docker image; the mounted ConfigMap contained only a placeholder README. This shadowed the real config files and caused every downstream Spring service to crash with unresolvable properties. Fix: remove the `volumes` and `volumeMounts` block from the config-server Deployment (~8 LOC).

## Goal 3: Pipeline
### Q3.1 E2E success and failure distribution (P1, P2)

| Run | P1 |
|-----|-----|
| GPT-1 (551) | PASS |
| Claude-2 (564) | PASS |
| Gemini-3 (568) | PASS |
**Postman suite (26 assertions):** Tests cover account registration and login, asset management operations, and transaction flows through the API gateway. All 26 assertions passed on all 3 runs after respective fixes.

**P2: Failure distribution across stages:**

| Stage             | Runs with failures | Detail                                                                                                                                  |
| ----------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| Planning          | 0                  | -                                                                                                                                       |
| Terraform gen+val | 1                  | Claude (T1: validation text prefix; T4: missing `enable_irsa = true`)                                                                   |
| K8s gen+val       | 2                  | Claude, Gemini: PVCs Pending in k3d (StorageClass `ebs.csi.aws.com` absent, pipeline continued)                                         |
| K8s deploy        | 2                  | Claude: MySQL Error (`--ignore-db-dir=lost+found` removed in MySQL 8.0.0); Gemini: config-server CrashLoop + 6 Spring services cascade |
**Fixes applied:**
- **Claude-2 (564):** Commented out validation text prefix in `main.tf` (~2 LOC). Added `enable_irsa = true` to the `module "eks"` block (~1 LOC). Replaced `--ignore-db-dir=lost+found` command arg with `subPath: mysql-data` on MySQL volumeMount (~2 LOC). Total ~5 LOC.
- **Gemini-3 (568):** Removed `volumes` and `volumeMounts` block from config-server Deployment (~8 LOC).

### Q3.2 Failure types (P3)

| Failure                                                      | Runs affected | Category                     | LOC to fix |
| ------------------------------------------------------------ | ------------- | ---------------------------- | ---------- |
| `main.tf` prefixed with validation summary text              | Claude        | Terraform syntax             | 1          |
| `enable_irsa = true` missing from EKS module                 | Claude        | Terraform semantic           | 1          |
| `--ignore-db-dir=lost+found` (removed in MySQL 8.0.0)        | Claude        | Runtime failure              | ~2         |
| config-server ConfigMap volume shadowing Docker image config | Gemini        | Runtime failure / Spec drift | ~8         |

### Q3.3 Consistency (P4)
Not applicable.

## Observations
**3 of 3 runs pass P1.** GPT is clean with zero LOC changes to manifests or TF; Claude and Gemini each require targeted fixes but both reach a fully working deployment.
**Claude's serialization error occurs for the fifth time.** Across wger, MD, BSA, SME, and now RRB, Claude has consistently prefixed `main.tf` with human-readable output. The specific form varies (Markdown fence in MD/wger/BSA; "Validation passed..." prose in SME and RRB) but the root cause is identical: the model emits prose before HCL content instead of returning the file verbatim. This is the most consistent cross-app failure pattern in the entire evaluation.
**Claude's missing `enable_irsa = true` is a direct constraint violation.** The flag is the single mechanism that enables OIDC provider creation in the EKS module; omitting it leaves the cluster without an OIDC provider, silently breaks all IRSA bindings, and prevents the CSI add-on from starting. The result is NetworkPluginNotReady on every node, a cluster that is structurally correct but operationally unusable until the 1-LOC fix is applied.
**Claude's MySQL workaround is wrong in two independent ways.** Using `--ignore-db-dir=lost+found` instead of `subPath` violates an explicitly stated K8s agent prompt rule; it would also have failed at runtime even without that rule, because the arg was removed in MySQL 8.0.0. The violation is both a spec-drift failure and a deprecated-API failure simultaneously.
**Gemini's config-server volume is the most disruptive speculative extra in the evaluation.** The volume mount looks intentional but the ConfigMap contained only a placeholder, so it silently shadowed all config files baked into the Docker image and cascaded into a startup failure across every Spring service. The constraint "no speculative extras" is explicitly stated; the failure illustrates why: a well-formed addition with no harmful intent can still brick the application at runtime.
**The RRB confirms the intermediate-tier pattern.** Repair costs (0, ~5, ~8 LOC) are higher than SME (0–2 LOC) but well below BSA (~22–29 LOC), consistent with RRB sitting at the intermediate complexity tier. The nature of the failures also matches: a 15-service stateful app with databases introduces subPath and IRSA surface not present in SME, and a speculative volume can only cascade when there are downstream services to crash.
