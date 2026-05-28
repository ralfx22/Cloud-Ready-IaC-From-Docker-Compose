# SME Regression Test Report
**Complexity tier:** Simple (regression baseline)
**Application:** ralfx22/simple-microservice-example - minimal three-service quote app
**Stack:** 3 services (api, frontend, quotes); no databases, no persistent volumes
**Notable constraint:** None - the compose is minimal and self-contained; all env vars are present and all images are pre-pushed.
**Functional test:** Manual only - open the frontend, click the button, verify a quote is returned (exercises all 3 services end-to-end).
**Consistency runs:** Not applicable

## Run index

| Run | Model           | Artifact ID | T1 (tf fmt) | T4 (tf apply) | K1 (K8s apply, EKS) | K4 (K8s WL ready, before fix) | P1 (E2E success) | Repair LOC |
| --- | --------------- | ----------- | ----------- | ------------- | ------------------- | ----------------------------- | ---------------- | ---------- |
| 1   | GPT-5.4         | 541         | PASS        | **FAIL**      | YES                 | 100% (3/3)                    | **PASS**         | ~1         |
| 2   | Claude Opus 4.6 | 543         | **FAIL**    | PASS          | YES                 | 100% (3/3)                    | **PASS**         | ~1         |
| 3   | Gemini 3.1 Pro  | 548         | PASS        | PASS          | YES                 | 100% (3/3)                    | **PASS**         | 0          |
3 of 3 runs reached a working deployment. P1 assessed after fix. All repairs are trivial (0–2 LOC).

## Goal 1: Kubernetes manifests
### Q1.1 Syntactic validity (K1, K2)

| Metric | GPT run 1 (541) | Claude run 2 (543) | Gemini run 3 (548) |
|--------|-----------------|--------------------|--------------------|
| **K1** `kubectl apply` succeeds (k3d + EKS) | YES | YES | YES |
| **K2** API/schema error count | 0 | 0 | 0 |
All 3 runs applied cleanly on both the k3d validation cluster and EKS. No schema errors on any run.

### Q1.2 Workload runtime (K4, K5)

| Metric | GPT run 1 (541) | Claude run 2 (543) | Gemini run 3 (548) |
|--------|-----------------|--------------------|--------------------|
| **K4** Workload ready rate | 100% (3/3) | 100% (3/3) | 100% (3/3) |
| **K5** Failure state counts | 0 | 0 | 0 |
All 3 pods (api, frontend, quotes) reached Running/Ready on all runs. No pod-level failures observed.

### Q1.3 Semantic alignment with source spec (K7–K10)
Source: 3 services (api, frontend, quotes); no named volumes; minimal env vars (inter-service addresses, ports).

| Metric                              | GPT 1 | Claude 2 | Gemini 3 |
| ----------------------------------- | ----- | -------- | -------- |
| **K7** Service precision            | 100%  | 100%     | 100%     |
| **K8** Port precision               | 100%  | 100%     | 100%     |
| **K9** Env var coverage             | 100%  | 100%     | 100%     |
| **K10** Volume/persistence coverage | N/A   | N/A      | N/A      |
**K10:** No named volumes in the compose spec; no PVCs expected or generated. N/A for all runs.

## Goal 2: Terraform
### Q2.1 Validation chain (T1–T4)

| Metric          | GPT-1 (541) | Claude-2 (543)       | Gemini-3 (548) |
| --------------- | ----------- | -------------------- | -------------- |
| **T1** fmt      | PASS        | **FAIL**             | PASS           |
| **T2** validate | PASS        | PASS (after fmt fix) | PASS           |
| **T3** plan     | PASS        | PASS                 | PASS           |
| **T4** apply    | **FAIL**    | PASS                 | PASS           |
**GPT run 1: T4 failure (missing `vpc_id` in EKS module):** The `module "eks"` block did not include `vpc_id = module.vpc.vpc_id`. The EKS module created the cluster security group in the AWS account's default VPC, while the subnets belonged to the newly created VPC from `module.vpc`. The EKS API rejected the apply with "Security group(s) are not in/associated to the same VPC as the subnets." Fix: add `vpc_id = module.vpc.vpc_id` to the `module "eks"` block (1 LOC).
**Claude run 2: T1 failure (validation text prefix):** `main.tf` was prefixed with `Validation passed. Here is the final main.tf:` before the HCL content, causing `terraform fmt` to fail with `Invalid block definition` and `Invalid character`. Fix: comment out the prefix line (~1 LOC). Same class of serialization error as the Markdown fence in MD/BSA, different form.

### Q2.2 EKS baseline sufficiency (E1–E3)

| Metric | GPT 1 | Claude 2 | Gemini 3 |
|--------|-------|----------|----------|
| **E1** Essentials coverage (0–5) | 5/5 | 5/5 | 5/5 |
| **E2** Capacity feasibility | YES | YES | YES |
| **E3** Add-on readiness | YES (after T4 fix) | YES | YES |
**E1 checklist: all runs pass all 5 items:**
- VPC + subnets in >=2 AZs + NAT/IGW ✓
- EKS cluster + cluster IAM role ✓
- Managed node group + node IAM role ✓
- Core add-ons declared (vpc-cni, kube-proxy, coredns) ✓
- kubectl auth configured (OIDC/IRSA) ✓

## Constraint compliance
Constraints extracted from `Architecture-agent.md`, `Kubernetes-agent.md`, `Terraform-agent.md`.

| Constraint | Source agent | GPT 1 | Claude 2 | Gemini 3 |
| ------------------------------------------------------------ | ------------ | ----- | -------- | -------- |
| IAM policy from upstream official JSON (no hand-crafting) | Terraform | ✓ | ✓ | ✓ |
| LBC via Helm only; no direct ALB in Terraform | Terraform | ✓ | ✓ | ✓ |
| Version pins (CLI ~>1.14.3, aws ~>6.28, vpc ~>6.6, eks ~>21.0) | Terraform | ✓ | ✓ | ✓ |
| `before_compute = true` for vpc-cni | Architecture | ✓ | ✓ | ✓ |
| t3.small + 1.4 GiB allocatable in node-sizing math | Architecture | ✓ | ✓ | ✓ |
| Dedicated non-default namespace | Architecture | ✓ (`sme-app`) | ✓ | ✓ |
| No speculative extras | Architecture | ✓ | ✓ | ✓ |
| IRSA for trigger-based add-ons (EBS CSI) | Terraform | ✓ | ✓ | ✓ |
| EBS `lost+found` subPath on DB volume mounts | K8s | N/A | N/A | N/A |
| Probes omitted unless evidenced in compose | K8s | ✓ | ✓ | ✓ |

## Goal 3: Pipeline
### Q3.1 E2E success and failure distribution (P1, P2)

| Run | P1 |
|-----|-----|
| GPT-1 (541) | PASS |
| Claude-2 (543) | PASS |
| Gemini-3 (548) | PASS |
**Functional test:** Manual frontend check: open the frontend, click the button, verify a quote is returned. This exercises all 3 services: frontend renders the UI, api handles the request, quotes returns a random quote. Passed on all 3 runs after respective fixes.

**P2: Failure distribution across stages:**

| Stage             | Runs with failures | Detail                                                        |
| ----------------- | ------------------ | ------------------------------------------------------------- |
| Planning          | 0                  | -                                                             |
| Terraform gen+val | 2                  | GPT (T4: missing vpc_id); Claude (T1: validation text prefix) |
| K8s gen+val       | 0                  | -                                                             |
| K8s deploy        | 0                  | -                                                             |
**Fixes applied:**
- **GPT-1 (541):** Added `vpc_id = module.vpc.vpc_id` to `module "eks"` block in `main.tf` (1 LOC).
- **Claude-2 (543):** Commented out `Validation passed. Here is the final \`main.tf\`:` prefix in `main.tf` (~2 LOC).
- **Gemini-3 (548):** No fixes required.

### Q3.2 Failure types (P3)

| Failure                                                                                      | Runs affected | Category           | LOC to fix |
| -------------------------------------------------------------------------------------------- | ------------- | ------------------ | ---------- |
| Missing `vpc_id` in EKS module, security group created in default VPC, subnets in custom VPC | GPT           | Terraform semantic | 1          |
| `main.tf` prefixed with validation summary text                                              | Claude        | Terraform syntax   | 1          |

### Q3.3 Consistency (P4)
Not applicable

## Observations
**3 of 3 runs pass P1.** SME is the cleanest result across all evaluated apps: 0-2 LOC repair per run, no K5 failures, no K1 failures on EKS, no shared systematic failures. Gemini passes with zero changes.
**Failure patterns are consistent with prior runs.** Claude's serialization error appears again, in MD/BSA it was a Markdown fence, here it is a validation summary text prepended to `main.tf`. Both are the same root cause: the model outputs human-readable prose before or around the HCL content instead of returning the file verbatim. GPT's missing `vpc_id` is a new instance of a Terraform semantic error (required parameter omitted), different from prior GPT failures but in the same category.
**The simple app confirms the pipeline's lower bound.** A 3-service stateless app with no databases, no shared volumes, and no service discovery produces near-zero failure surface. All complexity-driven failure modes observed in MD, wger, and BSA (EFS/EBS, IRSA, Consul, imagePullPolicy, InfluxDB tags) are absent here by construction. The regression test validates the pipeline baseline; the gap between SME (0-2 LOC repairs) and BSA (~22–29 LOC repairs) quantifies the additional repair cost introduced by application complexity.
