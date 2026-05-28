# wger Evaluation Report
**Complexity tier:** Simple
**Application:** wger fitness tracker, wger-project/docker, production compose
**Stack:** Django (gunicorn) + nginx + PostgreSQL 15 + Redis + 2x Celery (worker + beat)
**Notable constraint:** `./config/prod.env` is missing from the source repository; Kompose cannot execute and all three agents must infer the environment variables from the compose structure alone.
**Consistency runs:** none (wger is not the consistency-run scope)

## Run index

| Run | Model           | Artifact ID | T1 (tf fmt) | T4 (tf apply) | K1 (K8s apply, EKS) | K4 (K8s WL ready, before fix) | P1 (E2E success) | Repair LOC |
| --- | --------------- | ----------- | ----------- | ------------- | ------------------- | ----------------------------- | ---------------- | ---------- |
| 1   | GPT-5.4         | 571         | PASS        | PASS          | YES                 | ~50% (3/6)                    | **PASS**         | 2          |
| 2   | Claude Opus 4.6 | 574         | **FAIL**    | PASS          | YES                 | ~33% (2/6)                    | **FAIL**         | ~30        |
| 3   | Gemini 3.1 Pro  | 578         | PASS        | PASS          | YES                 | 100% (6/6)                    | **PASS**         | 0          |

2 of 3 runs reached a working deployment. P1 assessed after fix. Claude (574) is marked FAIL, repair cost (~30 LOC across 3 independent failure chains including a non-trivial init container rewrite) exceeded the trivial-fix threshold.

## Goal 1: Kubernetes manifests

### Q1.1 Syntactic validity (K1, K2)

| Metric | GPT-5.4 (571) | Claude 4.6 (574) | Gemini 3.1 (578) |
|--------|--------------|-----------------|-----------------|
| **K1** `kubectl apply` succeeds | YES | YES | YES |
| **K2** API/schema error count | 0 | 0 | 0 |
All three applied cleanly to the EKS cluster. The smoketest errors in the validate cluster (k3d) were a cluster-environment issue (EBS CSI / EFS CSI not present in k3d), not manifest schema errors, and are not counted here.

### Q1.2 Workload runtime (K4, K5)

| Metric                                  | GPT-5.4 (571)                                   | Claude 4.6 (574)                                                    | Gemini 3.1 (578) |
| --------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------------- | ---------------- |
| **K4** Workload ready rate (before fix) | ~50% (3/6)                                      | ~33% (2/6)                                                          | **100%** (6/6)   |
| **K5** Failure state counts             | 3x Pending (static + media PVCs, RWX not bound) | 3x Pending + 1x CrashLoopBackOff (affinity deadlock; only celery-beat schedules and crashes on env-var) | 0                |

**GPT:** `web`, `nginx`, `celery-worker` stayed Pending because their `static-data` and `media-data` PVCs requested `ReadWriteMany` with no `storageClassName` set, defaulting to `gp3`/EBS which does not support RWX and rejected the claims with `Volume capabilities not supported`. Terraform had already provisioned the EFS stack and an `efs-sc` StorageClass for exactly this case, but the PVCs never referenced it. Fix: add `storageClassName: efs-sc` to both PVCs.
**Claude:** Two independent failure chains. (1) Pod-affinity labels used the wrong key (`app.kubernetes.io/name-media: media-consumer` instead of `app.kubernetes.io/name: media-consumer`), so all three media-sharing pods matched nothing and stayed Pending; additionally the affinity was self-referential which would have deadlocked even with correct keys. Fix: anchor-on-nginx pattern (nginx schedules freely; web and celery-worker pin to wherever nginx landed). (2) The placeholder Secret invented `DJANGO_SETTINGS_MODULE=wger.settings`; that module does not exist, the image generates it during `wger bootstrap`. Fix: remove that line plus three other problematic placeholders (`MEDIA_URL`, `SITE_URL`, `CSRF_TRUSTED_ORIGINS`). Also: the `copy-static` init container ran `cp -a /home/wger/static/. /tmp/static/` but the image ships `/home/wger/static` empty; fix replaced the bare `cp` with a full `wger bootstrap` + `collectstatic` + `cp -r` sequence.
**Gemini:** No pod-level failures. A collectstatic call was needed post-deploy (`kubectl exec`) because the static PVC was empty (Docker volumes auto-populate on first mount; Kubernetes PVCs do not). This is a runtime operation with 0 manifest LOC changes.

### Q1.3 Semantic alignment with source spec (K7–K10)
Source: 6 services (web, nginx, db, cache, celery_worker, celery_beat); 5 named volumes (postgres-data, redis-data, celery-beat, media, static); 2 config mounts (nginx.conf, redis.conf); key env sources: `./config/prod.env` (missing), db explicit vars (POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, TZ).

| Metric                              | GPT-5.4 (571)                          | Claude 4.6 (574)                                     | Gemini 3.1 (578)                              |
| ----------------------------------- | -------------------------------------- | ---------------------------------------------------- | --------------------------------------------- |
| **K7** Service precision            | 100%                                   | ~92%                                                 | ~100%                                         |
| **K8** Port precision               | 100%                                   | 100%                                                 | 100%                                          |
| **K9** Env var coverage             | 100% (empty placeholder, no conflicts) | ~70% (4 spec-conflicting invented values)            | ~80% (SITE_URL placeholder conflict)          |
| **K10** Volume/persistence coverage | ~90% (celery-worker has extra static-data mount not in compose spec) | ~70% (media RWO instead of RWX; static via emptyDir) | ~90% (media + static both RWO instead of RWX) |
**K7 notes:**
- GPT: all 6 mapped; headless services for StatefulSets (db, cache) are appropriate extras.
- Claude: generates a ClusterIP Service for `celery-beat` which has no ports in compose (minor unneeded extra).
- Gemini: all 6 mapped.
**K9 notes:**
- GPT correctly left `wger-env` ConfigMap and Secret empty (`data: {}`), allowing the image's own bootstrap to run untouched. db vars (POSTGRES_USER, POSTGRES_DB, TZ) carried over correctly alongside POSTGRES_PASSWORD in a Secret.
- Claude invented ~21 values in a placeholder Secret; four were spec-conflicting and caused runtime failures: `DJANGO_SETTINGS_MODULE`, `MEDIA_URL`, `SITE_URL`, `CSRF_TRUSTED_ORIGINS`. All four were removed; 17 neutral values remain.
- Gemini filled a ConfigMap with plausible values including `SITE_URL: "http://localhost"` (conflicting with ALB hostname), but this did not cause visible failures during the test run.
**K10 notes:**
- The core challenge: `static` and `media` are named volumes shared across `web`, `nginx`, and `celery-worker` -> requires `ReadWriteMany`.
- GPT correctly identified the EFS requirement, provisioned EFS in Terraform, and created RWX PVCs with `storageClassName: efs-sc` for both volumes. Only a missing storageClass ref on deploy required fixing.
- Claude planned EBS RWO + pod-affinity as a cost-saving baseline (architecture plan explicitly acknowledged EFS as the alternative). The access mode choice is architecturally defensible but the affinity implementation was buggy, making the approach fail in practice.
- Gemini also used RWO for both shared volumes. Like Claude, Gemini explicitly enforced co-location via `requiredDuringSchedulingIgnoredDuringExecution` pod affinity (anchor-on-web pattern: nginx and celery-worker pinned to web's node). The access mode choice is architecturally defensible and the affinity implementation was correct, so all pods reached Running.

## Goal 2: Terraform
### Q2.1 Validation chain (T1–T4)

| Metric                        | GPT-5.4 (571)              | Claude 4.6 (574)     | Gemini 3.1 (578)                |
| ----------------------------- | -------------------------- | -------------------- | ------------------------------- |
| **T1** `terraform fmt -check` | PASS                       | **FAIL**             | PASS                            |
| **T2** `terraform validate`   | PASS                       | PASS (after fmt fix) | PASS (deprecation warning only) |
| **T3** `terraform plan`       | PASS (deprecation warning) | PASS                 | PASS                            |
| **T4** `terraform apply`      | PASS                       | PASS                 | PASS                            |
**T1 failure (Claude):** The agent wrapped the final `main.tf` output in a Markdown fence. The file began with `` The configuration validates successfully. Here is the final `main.tf`: ``, causing `terraform fmt` to fail with `Invalid block definition` and `Invalid character`. Fix: commented out the fence
**Deprecation warnings (all three runs):** `data.aws_region.current.name` attribute is deprecated in the `iam-role-for-service-accounts-eks` module. Not an error; no fix required. Not flagged as T2/T3 failures.

### Q2.2 EKS baseline sufficiency (E1–E3)

| Metric                           | GPT-5.4 (571)                      | Claude 4.6 (574)                   | Gemini 3.1 (578)                   |
| -------------------------------- | ---------------------------------- | ---------------------------------- | ---------------------------------- |
| **E1** Essentials coverage (0–5) | 5/5                                | 5/5                                | 5/5                                |
| **E2** Capacity feasibility      | YES (3 nodes, 4.2 GiB allocatable) | YES (3 nodes, 4.2 GiB allocatable) | YES (2 nodes, 2.8 GiB allocatable) |
| **E3** Add-on readiness          | YES                                | YES                                | YES                                |
**E1 checklist: all three pass all 5 items:**
- VPC + subnets in >=2 AZs + NAT/IGW ✓ (IGW implicit via VPC module default when public_subnets are declared)
- EKS cluster + cluster IAM role ✓
- Managed node group + node IAM role ✓
- Core add-ons declared (vpc-cni, kube-proxy, coredns) ✓
- kubectl auth configured (OIDC/IRSA) ✓
**E2 note (Gemini):** 2 nodes with 2.8 GiB total allocatable vs ~2.2 GiB pod requests. Tight but sufficient for this app; there is no headroom for a second replica or a pod restart surge.

## Constraint compliance
Constraints extracted from `Architecture-agent.md`, `Kubernetes-agent.md`, `Terraform-agent.md`.

| Constraint                                                     | Source agent       | GPT-5.4 (571)                            | Claude 4.6 (574)                                                       | Gemini 3.1 (578)                        |
| -------------------------------------------------------------- | ------------------ | ---------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------- |
| IAM policy from upstream official JSON (no hand-crafting)      | Terraform          | ✓                                        | ✓                                                                      | ✓                                       |
| LBC via Helm only; no direct ALB in Terraform                  | Terraform          | ✓                                        | ✓                                                                      | ✓                                       |
| Version pins (CLI ~>1.14.3, aws ~>6.28, vpc ~>6.6, eks ~>21.0) | Terraform          | ✓                                        | ✓                                                                      | ✓                                       |
| `before_compute = true` for vpc-cni                            | Architecture       | ✓                                        | ✓                                                                      | ✓                                       |
| t3.small + 1.4 GiB allocatable in node-sizing math             | Architecture       | ✓                                        | ✓                                                                      | ✓                                       |
| Dedicated non-default namespace                                | Architecture       | ✓ (`wger`)                               | ✓ (`wger`)                                                             | ✓ (`wger`)                              |
| No speculative extras                                          | Architecture       | ✓                                        | ✓                                                                      | ✓                                       |
| PVC forbidden for config paths                                 | Architecture / K8s | ✓ (ConfigMap for nginx.conf, redis.conf) | ✓                                                                      | ✓                                       |
| Exposed service as ClusterIP + Ingress (not NodePort)          | K8s                | ✓                                        | ✓                                                                      | **✗** (nginx Service: `NodePort`)       |
| Probes omitted unless evidenced in compose                     | K8s                | ✓ (0 probes; omits all, incl. evidenced) | ✓ (10 probes; liveness + readiness for all 5 evidenced services)       | ✓ (5 probes; liveness-only for all 5 evidenced services)               |
| Empty/placeholder env containers when source env file missing  | K8s                | ✓ (empty data: {})                       | **✗** (~21 invented values, 4 spec-conflicting)                        | **~** (plausible values, 1 conflicting) |
**Notes:**
- All three models sourced the LBC IAM policy from the official upstream GitHub URL rather than hand-crafting it, the primary constraint the user flagged. No manual policy violations observed.
- Gemini's architecture plan specified `NodePort` for nginx (plan-level deviation from the architecture-agent constraint "keep all other services internal ClusterIP unless explicitly required"); the K8s agent faithfully implemented what the plan said. Both agents deviated at the plan stage. The violation is a structural one (unnecessary NodePort exposure on the node level), not a functional one.
- The probe constraint is a restriction ("omit unless evidenced"), not a requirement to add probes when evidenced. GPT satisfies it by omitting everything: never a violation, but also no liveness/readiness coverage at all, which is a quality gap. Claude added 10 probes (liveness + readiness) for all 5 evidenced services; celery-beat has no compose healthcheck and no generated probe — full compliance. Gemini added liveness-only probes for all 5 evidenced services; celery-beat has no probe.

## Goal 3: Pipeline

### Q3.1 E2E success and failure distribution (P1, P2)

| Run | P1 |
| --- | -- |
| GPT-5.4 (571) | PASS |
| Claude 4.6 (574) | **FAIL** |
| Gemini 3.1 (578) | PASS |
**P2: Failure distribution across stages:**

| Stage             | Runs with failures | Detail                                                                                                                      |
| ----------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| Planning          | 0                  | -                                                                                                                           |
| K8s gen+val       | 3 (non-blocking)   | All runs: Kompose silent error (prod.env missing, pipeline continued); all runs: k3d smoketest env failure (EBS/EFS CSI absent in k3d, pipeline continued) |
| Terraform gen+val | 1                  | Claude (574): T1 fmt fence                                                                                                  |
| K8s deploy        | 2                  | GPT (571): RWX PVCs unbound; Claude (574): affinity + init container + env vars                                            |
**Fixes applied:**
**GPT (571):** Added `storageClassName: efs-sc` to both shared PVCs (2 LOC). Ran `collectstatic` via `kubectl exec` post-deploy (0 file changes, PVCs do not auto-populate unlike Docker volumes). Frontend PASS.
**Claude (574):** Removed markdown fence from `main.tf` (2 LOC). Corrected pod-affinity to anchor-on-nginx pattern and fixed label key (~10 LOC). Removed 4 conflicting env vars and replaced bare `cp` init container with full `wger bootstrap` + `collectstatic` sequence (~18 LOC). Total ~30 LOC. Frontend passed after fix but P1 marked FAIL, repair cost exceeded the trivial-fix threshold.
**Gemini (578):** No file changes. Ran `collectstatic` via `kubectl exec` post-deploy. Frontend PASS.

### Q3.2 Failure types (P3)

| Failure                                                        | Run                     | Category        | LOC to fix           |
| -------------------------------------------------------------- | ----------------------- | --------------- | -------------------- |
| fmt: markdown fence in TF output                               | Claude (574)            | Terraform syntax | 2                    |
| Affinity label key mismatch (wrong label key on pods)          | Claude (574)            | Runtime failure | ~10                  |
| Placeholder env var `DJANGO_SETTINGS_MODULE` crashes Django    | Claude (574)            | Runtime failure | 4                    |
| Init container `cp` against empty static dir                   | Claude (574)            | Runtime failure | ~14                  |
| RWX PVCs have no `storageClassName` set, defaulting to gp3/EBS which rejects RWX | GPT (571)               | Spec drift      | 2                    |
| Static PVC empty on first mount (no collectstatic on init)     | GPT (571), Gemini (578) | Runtime failure | 0 (kubectl exec fix) |

### Q3.3 Consistency (P4)
Not applicable, wger is not the consistency-run scope.

## Observations
**2 of 3 runs pass P1.** Gemini (578) passes cleanly with 0 file changes. GPT (571) passes after a 2 LOC fix. Claude (574) is the only FAIL: 3 independent failure chains totalling ~30 LOC, including a non-trivial init container rewrite that required domain knowledge of how wger bootstraps. The functional test passed after those fixes, but the repair cost exceeded the trivial-fix threshold.

**EFS vs EBS for shared volumes, the key architectural decision for wger.** The docker-compose shares `static` and `media` across three services, which requires RWX (ReadWriteMany: mounted by many nodes simultaneously, requires EFS) storage in Kubernetes. GPT correctly identified this and provisioned EFS. Claude and Gemini both used RWO (ReadWriteOnce: mounted by one node at a time, backed by EBS), both relying on explicit pod affinity for co-location. Gemini used the anchor-on-web pattern (nginx and celery-worker pinned to web's node via `required` affinity) correctly and all pods reached Running. Claude's architecture plan made the same choice but the K8s agent implemented the affinity with the wrong label key, causing all three co-location pods to stay Pending. This is an architecture-level decision where GPT's output was the most correct out-of-the-box.

**The missing `prod.env` file is a systematic challenge.** All three agents had to invent or omit the environment configuration for `web`, `celery_worker`, and `celery_beat`. GPT's strategy (leave empty, let the image bootstrap) was the safest. Claude's strategy (fill in plausible values) caused runtime failures. Gemini's strategy (fill in plausible values with less-problematic defaults) was intermediate. This is not a model capability difference but a prompt-strategy difference. The architecture plan notes for both Claude and Gemini flagged the missing file but still chose to invent values.

**Constraint compliance is high on the high-stakes rules.** All three models correctly sourced the LBC IAM policy from upstream, used Helm for the controller, and respected version pins. Gemini's NodePort deviation is lower-stakes and did not affect P1. Claude's invented env values contributed directly to the P1 FAIL — 4 of the ~21 invented values were spec-conflicting and caused runtime failures that formed part of the 30 LOC repair.
