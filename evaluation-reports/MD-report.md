# MD Evaluation Report
**Complexity tier:** Intermediate
**Application:** Joker666's Microservice Demo - Go microservices with gRPC + REST gateway
**Stack:** 5 Go services (user, project, task, api, api-gateway) + MongoDB + MySQL 5.7 + PostgreSQL 16
**Notable constraint:** `pull_policy: never` on `api-gateway` in compose; Kompose translates this to `imagePullPolicy: Never`, which works locally but breaks on EKS where no local image cache exists.
**Consistency runs:** 3 runs per model (all models), extended from GPT-only per GQM scope.

## Run index

| Run | Model           | Artifact ID | T1 (tf fmt) | T4 (tf apply) | K1 (K8s apply, EKS) | K4 (K8s WL ready, before fix) | P1 (E2E success) | Repair LOC |
| --- | --------------- | ----------- | ----------- | ------------- | ------------------- | ----------------------------- | ---------------- | ---------- |
| 1   | GPT-5.4         | 580         | PASS        | **FAIL**      | **NO**              | 7/8                           | **PASS**         | ~3         |
| 2   | GPT-5.4         | 583         | PASS        | PASS          | **NO**              | 7/8                           | **PASS**         | ~1         |
| 3   | GPT-5.4         | 588         | PASS        | **FAIL**      | **NO**              | 7/8                           | **FAIL**         | ~20        |
| 4   | Claude Opus 4.6 | 591         | **FAIL**    | PASS          | YES                 | 7/8                           | **PASS**         | ~3         |
| 5   | Claude Opus 4.6 | 594         | **FAIL**    | PASS          | YES                 | 7/8                           | **PASS**         | ~3         |
| 6   | Claude Opus 4.6 | 598         | **FAIL**    | PASS          | YES                 | 7/8                           | **PASS**         | ~3         |
| 7   | Gemini 3.1 Pro  | 602         | PASS        | PASS          | YES                 | 7/8                           | **PASS**         | ~1         |
| 8   | Gemini 3.1 Pro  | 605         | PASS        | **FAIL**      | YES                 | 8/8                           | **PASS**         | ~1         |
| 9   | Gemini 3.1 Pro  | 608         | PASS        | PASS          | YES                 | 7/8                           | **PASS**         | ~1         |
8 of 9 runs reached a working deployment. P1 assessed after fix. GPT run 3 (588) also passed Postman after fix but is marked P1 FAIL, the required fix (~20 LOC, missing IRSA role from scratch) exceeded the trivial-fix threshold defined in the evaluation convention.

## Goal 1: Kubernetes manifests
### Q1.1 Syntactic validity (K1, K2)

| Metric | GPT run 1–3 | Claude run 4–6 | Gemini run 7–9 |
|--------|-------------|----------------|----------------|
| **K1** `kubectl apply` succeeds (EKS) | **NO** (all 3) | YES (all 3) | YES (all 3) |
| **K2** API/schema error count | 1 per run | 0 | 0 |
**GPT K1 failure: MongoDB probe YAML bug (all 3 runs):** The MongoDB healthcheck command `{ ping: 1 }` was written unquoted in the liveness/readiness probe exec field. YAML interprets `{ ping: 1 }` as an inline mapping, not as a string; kubectl rejects the manifest. Fix: quote the command. This is a consistent generation error across all three GPT runs. Same input, same bug, same fix (1 LOC).
**Claude/Gemini K1:** Apply succeeded. Runtime failures (MySQL crash, imagePullPolicy) are captured in K5, not K1.

### Q1.2 Workload runtime (K4, K5)

| Metric | GPT run 1 (580) | GPT runs 2–3 | Claude 4–6 | Gemini 7, 9 | Gemini 8 |
|--------|-----------------|-------------|-----------|------------|---------|
| **K4** Workload ready rate (before fix) | 87.5% (7/8) | 87.5% (7/8) | 87.5% (7/8) | 87.5% (7/8) | 100% (8/8) |
| **K5** Failure state counts | 1× CrashLoopBackOff (mysql StatefulSet, lost+found) | 0 after K1 fix | 1× CrashLoopBackOff (mysql StatefulSet, lost+found) | 1× ErrImageNeverPull (api-gateway Deployment) | 0 |
**GPT: MongoDB pod absent (K1, not a runtime crash):** The MongoDB StatefulSet manifest was rejected at apply time due to the probe YAML bug, no pod was ever created. The 7/8 K4 reflects the 7 workloads that applied cleanly; MongoDB simply did not exist as a pod. After quoting the probe command (`["mongosh", "--eval", "{ ping: 1 }"]`), kubectl apply succeeded and MongoDB came up without issues. Run 1 had an additional MySQL CrashLoop (see below); runs 2 and 3 were clean after the K1 fix.
**GPT run 1 + Claude 4–6: MySQL CrashLoopBackOff:** On a fresh EBS volume, ext4 places a `lost+found` directory at the mount root. MySQL 5.7's `--initialize` detects files in the data directory and aborts with "data directory has files in it". Fix: add `subPath: mysql-data` to the MySQL volumeMount so MySQL sees a clean subdirectory. The K8s agent prompt explicitly documents this pattern. 1 LOC fix. GPT generated the subPath correctly in runs 2 and 3; run 1 and all three Claude runs omitted it.
**Gemini runs 7, 9: api-gateway ErrImageNeverPull:** The compose sets `pull_policy: never` on `api-gateway`; Kompose translates this directly to `imagePullPolicy: Never`. Locally this is intentional (the image is built before compose runs); on EKS nodes have no local image cache, so `Never` causes immediate pull failure. Fix: change to `IfNotPresent`. 1 LOC, same fix in both runs.

### Q1.3 Semantic alignment with source spec (K7–K10)
Source: 8 services (user, project, task, api, api-gateway, postgresql, mysql, mongo); 4 named volumes (postgresdb, mysqldb, mongodb, mongodb_config); key env vars: DB_URI per service, inter-service addresses (USER_ADDRESS, PROJECT_ADDRESS, TASK_ADDRESS), gateway config (HOST, PORT, PROXY_PORT), DB credentials.

| Metric                              | GPT 1–3                    | Claude 4–6 | Gemini 7–9 |
| ----------------------------------- | -------------------------- | ---------- | ---------- |
| **K7** Service precision            | 100%                       | 100%       | 100%       |
| **K8** Port precision               | 100%                       | 100%       | 100%       |
| **K9** Env var coverage             | 100%                       | 100%       | 100%       |
| **K10** Volume/persistence coverage | 100% runs 2–3 / ~90% run 1 | ~90%       | 100%       |
**K10 note (GPT run 1, Claude 4–6):** The PVC is correctly created and mounted in all cases. The missing `subPath` is a mount-level issue. MySQL cannot initialize because ext4's `lost+found` directory at the EBS mount root is interpreted as a non-empty data directory. Scored ~90% for affected runs to reflect the functional impact.

## Goal 2 — Terraform

### Q2.1 Validation chain (T1–T4)

| Metric | GPT-1 (580) | GPT-2 (583) | GPT-3 (588) | Claude 4–6 | Gemini-7 (602) | Gemini-8 (605) | Gemini-9 (608) |
|--------|------------|------------|------------|-----------|----------------|----------------|----------------|
| **T1** fmt | PASS | PASS | PASS | **FAIL** all 3 | PASS | PASS | PASS |
| **T2** validate | PASS | PASS | PASS | PASS (after fmt fix) | PASS | PASS | PASS |
| **T3** plan | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| **T4** apply | **FAIL** | PASS | **FAIL** | PASS | PASS | **FAIL** | PASS |
**GPT run 1: T4 failure (name_prefix too long):** The EKS node group was named `microservice-demo-eks-default`, generating an IAM `name_prefix` of `microservice-demo-eks-default-eks-node-group-` which exceeds AWS's 38-character limit. Fix: shorten node group name to `default`. ~1 LOC.
**GPT run 3: T4 failure (EBS CSI addon timeout + missing IRSA role):** Two issues. (1) The EBS CSI driver addon was declared inside the EKS module's `addons` block alongside an external IRSA role dependency. The module cannot enforce ordering between internal addons and external resources, so the addon started before the IRSA role existed and timed out. Fix: move EBS CSI to a standalone `aws_eks_addon` resource with explicit `depends_on`. (2) The original output had no IRSA role for the EBS CSI driver at all. Without it, the CSI controller pods cannot make AWS API calls to provision EBS volumes. Fix: add `aws_iam_policy_document` trust policy, `aws_iam_role`, and `aws_iam_role_policy_attachment` for the CSI driver. Total: ~20 LOC added. Notably, runs 1 and 2 included the IRSA role correctly; run 3 omitted it. -> same model, same app, inconsistent output.
**Claude runs 4–6: T1 failure (fence, all 3 runs):** All three Claude runs wrapped `main.tf` in a Markdown fence, causing `terraform fmt` to fail identically (`Invalid block definition`, `Invalid character`). Fix: comment out the fence lines (2 LOC). This is 100% consistent across all 3 Claude runs, a systematic serialization issue with the model's output step.
**Gemini run 8: T4 failure (missing `before_compute`):** EKS nodes registered with the cluster before vpc-cni was installed, leaving all pods unable to start (`NetworkPluginNotReady`). Fix: add `before_compute = true` to the vpc-cni addon entry. 1 LOC. Runs 7 and 9 had `before_compute = true` correctly; run 8 omitted it -> same inconsistency pattern as GPT run 3.

### Q2.2 EKS baseline sufficiency (E1–E3)

| Metric | GPT 1–3 | Claude 4–6 | Gemini 7–9 |
|--------|---------|-----------|-----------|
| **E1** Essentials coverage (0–5) | 5/5 | 5/5 | 5/5 |
| **E2** Capacity feasibility | YES (3 nodes, 4.2 GiB allocatable) | YES (4 nodes, 5.6 GiB allocatable) | YES (4 nodes, 5.6 GiB allocatable) |
| **E3** Add-on readiness | YES (after fix for run 3) | YES | YES (after fix for run 8) |
**E1 checklist: all runs pass all 5 items:**
- VPC + subnets in >=2 AZs + NAT/IGW ✓ (IGW implicit via VPC module when public_subnets declared)
- EKS cluster + cluster IAM role ✓
- Managed node group + node IAM role ✓
- Core add-ons declared (vpc-cni, kube-proxy, coredns) ✓
- kubectl auth configured (OIDC/IRSA) ✓
**E2 note:** Claude and Gemini both planned 4 nodes vs GPT's 3. The app has 8 pods with ~3.8 GiB total estimated memory; 3 nodes (4.2 GiB allocatable) is sufficient, 4 nodes adds comfortable headroom. Both are valid.
**E3 note (GPT run 3, Gemini run 8):** Add-on readiness was not met in the initial apply but was reached after the respective fixes (EBS CSI ordering for GPT, before_compute for Gemini).

## Constraint compliance

| Constraint                                                     | Source agent | GPT 1–3                                                                                                   | Claude 4–6                               | Gemini 7–9                                 |
| -------------------------------------------------------------- | ------------ | --------------------------------------------------------------------------------------------------------- | ---------------------------------------- | ------------------------------------------ |
| IAM policy from upstream official JSON (no hand-crafting)      | Terraform    | ✓                                                                                                         | ✓                                        | ✓                                          |
| LBC via Helm only; no direct ALB in Terraform                  | Terraform    | ✓                                                                                                         | ✓                                        | ✓                                          |
| Version pins (CLI ~>1.14.3, aws ~>6.28, vpc ~>6.6, eks ~>21.0) | Terraform    | ✓                                                                                                         | ✓                                        | ✓                                          |
| `before_compute = true` for vpc-cni                            | Architecture | ✓ (all 3)                                                                                                 | ✓ (all 3)                                | ✓ run 7, 9 / **✗ run 8** (original output) |
| t3.small + 1.4 GiB allocatable in node-sizing math             | Architecture | ✓                                                                                                         | ✓                                        | ✓                                          |
| Dedicated non-default namespace                                | Architecture | ✓ (`microservice-demo`)                                                                                   | ✓                                        | ✓                                          |
| No speculative extras                                          | Architecture | ✓                                                                                                         | ✓                                        | ✓                                          |
| IRSA for trigger-based add-ons (EBS CSI)                       | Terraform    | ✓ runs 1–2 / **✗ run 3** (original output)                                                                | ✓                                        | ✓                                          |
| EBS `lost+found` subPath on DB volume mounts                   | K8s          | ✓ runs 2–3 / **✗ run 1** (missing subPath, MySQL CrashLoop)                                               | **✗** (all 3 runs, same missing subPath) | ✓                                          |
| Probes omitted unless evidenced in compose                     | K8s          | ✓ (probes on MongoDB, MySQL, PostgreSQL only, all 3 have compose healthchecks; no probes on app services) | ✓ (same pattern)                         | ✓ (same pattern)                           |
**Notes:**
- Claude's LBC IAM policy approach uses the `iam-role-for-service-accounts-eks` module's built-in `attach_load_balancer_controller_policy = true` flag, which sources the policy from the module's managed definitions rather than hand-crafting it. This satisfies the spirit of the constraint.
- GPT run 3 omitting the EBS CSI IRSA role entirely is the most significant constraint violation in this app. It means the CSI controller would have been permanently unable to provision EBS volumes even after the addon started. GPT runs 1 and 2 included it correctly, making this **a consistency failure, not a systematic one**.
- Gemini run 8 omitting `before_compute` for vpc-cni is a direct violation of an explicitly stated rule. The resulting `NetworkPluginNotReady` state effectively bricked the cluster until the fix was applied.
- The `lost+found` subPath rule is explicitly stated in the K8s agent prompt. Claude violated it consistently across all 3 runs. GPT violated it in run 1 (MySQL CrashLoop, same cause); runs 2 and 3 generated the subPath correctly. Gemini was compliant across all 3 runs.

## Goal 3. Pipeline
### Q3.1 E2E success and failure distribution (P1, P2)

| Run | P1 |
|-----|----|
| GPT-1 (580) | PASS |
| GPT-2 (583) | PASS |
| GPT-3 (588) | **FAIL** |
| Claude-4 (591) | PASS |
| Claude-5 (594) | PASS |
| Claude-6 (598) | PASS |
| Gemini-7 (602) | PASS |
| Gemini-8 (605) | PASS |
| Gemini-9 (608) | PASS |
**Postman suite (9 requests, 17 assertions):** Derived from the gRPC proto and auto-generated Swagger spec. Happy path: register user, login, create project, get project, create task, list tasks (6 requests, 14 assertions). Negative auth: create project with no auth header, create project with bad token, login as unknown user (3 requests, 3 assertions). Re-runnability: each run generates a fresh `alice_<timestamp>@test.com` email and `Project <timestamp>` via pre-request scripts; IDs and tokens chain through collection variables so the full flow runs top-to-bottom in one pass. 8 of 9 runs passed 17/17. GPT run 3 (588) also passed Postman after fix but is marked P1 FAIL.

**P2: Failure distribution across stages:**

| Stage             | Runs with failures | Detail                                                                                                                                                                                                                                                                     |
| ----------------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Planning          | 0                  | -                                                                                                                                                                                                                                                                          |
| Terraform gen+val | 6                  | GPT 1, 3 (T4); Claude 4-6 (T1); Gemini 8 (T4)                                                                                                                                                                                                                              |
| K8s gen+val       | 9                  | All runs: k3d smoketest env failure (ImagePullBackOff ARM images + EBS CSI absent in k3d, pipeline continued)<br>Gemini 7, 9: additionally ErrImageNeverPull api-gateway in smoketest (see K5)<br>GPT 1-3: additionally MongoDB probe YAML rejection in smoketest (see K1) |
| K8s deploy        | 6                  | GPT 1 (MySQL subPath); Claude 4-6 (MySQL subPath); Gemini 7, 9 (imagePullPolicy)                                                                                                                                                                                           |
**Fixes applied per run:**
- **GPT-1 (580):** Quoted MongoDB probe command `"{ ping: 1 }"` (1 LOC). Shortened node group name to drop below 38-char IAM prefix limit (1 LOC). Added `subPath: mysql-data` to MySQL volumeMount (1 LOC).
- **GPT-2 (583):** Quoted MongoDB probe command (1 LOC).
- **GPT-3 (588):** Quoted MongoDB probe command (1 LOC). Added standalone `aws_eks_addon` with `depends_on` for EBS CSI ordering and added missing IRSA role for CSI driver (~19 LOC).
- **Claude-4-6 (591/594/598):** Removed markdown fence from `main.tf` (2 LOC). Added `subPath: mysql-data` to MySQL volumeMount (1 LOC). Same fix applied identically across all three runs.
- **Gemini-7, 9 (602/608):** Changed `imagePullPolicy: Never` to `IfNotPresent` on api-gateway (1 LOC).
- **Gemini-8 (605):** Added `before_compute = true` to vpc-cni addon entry (1 LOC).

### Q3.2 Failure types (P3)

| Failure                                                   | Runs affected  | Category                | LOC to fix |
| --------------------------------------------------------- | -------------- | ----------------------- | ---------- |
| MongoDB probe `{ ping: 1 }` unquoted, YAML inline mapping | GPT 1, 2, 3    | K8s schema / Format     | 1          |
| TF node group name_prefix >38 chars                       | GPT 1          | Terraform semantic      | 1          |
| EBS CSI IRSA role missing entirely                        | GPT 3          | Terraform semantic      | ~15        |
| EBS CSI addon ordering (no depends_on)                    | GPT 3          | Terraform semantic      | ~5         |
| `main.tf` wrapped in Markdown fence                       | Claude 4, 5, 6 | Terraform syntax        | 2          |
| MySQL subPath missing on EBS volume mount                 | GPT 1, Claude 4, 5, 6 | Runtime failure         | 1          |
| `imagePullPolicy: Never` on api-gateway                   | Gemini 7, 9    | K8s schema / Spec drift | 1          |
| `before_compute = true` missing for vpc-cni               | Gemini 8       | Terraform semantic      | 1          |

### Q3.3 Consistency (P4)

| Model | T4 pass rate | K1 pass rate | K8s deploy pass rate | Final P1 pass rate | Dominant failure |
|-------|-------------|-------------|---------------------|-------------------|-----------------|
| GPT-5.4 | 1/3 | 0/3 | 0/3 | **2/3** | MongoDB probe (K1, 3/3); missing IRSA role (run 3, P1 FAIL) |
| Claude 4.6 | 3/3 | 3/3 | 0/3 | **3/3** | fmt fence (T1, 3/3) + MySQL subPath (K5, 3/3) |
| Gemini 3.1 | 2/3 | 3/3 | 1/3 | **3/3** | imagePullPolicy (K5, 2/3) |
**P4 analysis:**
Claude and Gemini achieve 3/3 P1; GPT is 2/3, with run 3 marked FAIL due to a non-trivial repair. Pre-fix failure patterns differ sharply across models:
**GPT** has 0/3 K1 passes. Every run fails at kubectl apply due to the same MongoDB probe YAML bug. The fix is 1 LOC and identical each time. TF failures are inconsistent (run 1: name_prefix; run 3: missing IRSA role entirely; run 2: clean). Run 3 crossed the P1 threshold.
**Claude** is perfectly deterministic: T1 fails in 3/3 runs with the same fence, K8s deploy fails in 3/3 runs with the same MySQL subPath issue. Every run needs the same 3 LOC fix. This is the most consistent failure pattern in the entire evaluation, same input produces identical output and identical bugs.
**Gemini** is the most variable: one run has a TF failure (missing before_compute), two have a K8s deploy failure (imagePullPolicy), one run (8) passes K8s deploy entirely. The failures are independent across runs rather than systematic.

## Observations
**8 of 9 runs pass P1.** GPT run 3 is the only FAIL. The ~20 LOC fix required to add a missing EBS CSI IRSA role from scratch exceeded the trivial-fix threshold. All other 8 runs reached a working deployment. Median repair cost across passing runs is 1-3 LOC.
**Claude's deterministic failures are the most interesting P4 finding.** The fmt fence appears in 3/3 runs and the MySQL subPath is missing in 3/3 runs. This means the model reliably generates the same output from the same input, including the same bugs. The subPath rule is explicitly documented in the K8s agent prompt ("account for the fact that freshly formatted EBS volumes contain a lost+found directory at the mount root"), Claude consistently ignored it.
**GPT's K1 failure (MongoDB probe) is also 100% consistent but trivially cheap.** A 1-LOC quoting fix resolves it every time. The more concerning finding is GPT's variable Terraform quality: run 2 was clean, run 1 had a naming issue, run 3 was missing an IRSA role entirely. Same model, same app, meaningfully different outputs.
**The imagePullPolicy: Never issue is a Kompose accuracy problem, not a model problem.** Kompose correctly translates `pull_policy: never` to `imagePullPolicy: Never`, that is semantically accurate. The model is expected to catch this and correct it (the compose note about pull_policy was added to compensate for an ARM compatibility issue, not as a permanent K8s policy). Neither Gemini run 7 nor 9 corrected it. This is a spec-drift case where the agent should have identified the compose flag as deployment-context-specific.
**Low repair LOC supports the near-miss hypothesis.** Excluding GPT run 3 (the outlier at ~20 LOC due to a missing IAM resource), all other fixes are 1-3 LOC. The gap between "generated" and "working" is consistently small across all 9 runs.
