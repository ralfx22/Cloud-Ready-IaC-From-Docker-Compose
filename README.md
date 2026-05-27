# Generation of Cloud-Ready IaC From Docker Compose With LLMs

Artifact repository for the bachelor's thesis *"Generation of Cloud-Ready Infrastructure as Code From Docker Compose With LLMs"* (Ralf Gärtner, University of Stuttgart, 2026).

The thesis builds and evaluates a three-agent LLM pipeline that takes a Docker Compose file and outputs Kubernetes manifests plus Terraform (AWS/EKS) configurations. The pipeline runs as an [n8n](https://n8n.io) workflow and was tested with GPT-5.4, Claude Opus 4.6, and Gemini 3.1 Pro.

---

## Repository layout

```
.
├── development-runs/    # Execution artifacts from workflow development
├── evaluation-run/      # Execution artifacts from the formal evaluation
├── n8n-deployment/      # Docker Compose stack to run n8n locally
└── n8n-workflows/       # n8n workflow JSON files (import these into n8n)
```

### `development-runs/`

Every n8n execution triggered while the workflow was still being designed and hardened (SME phase with `kasvith/simple-microservice-example`, RRB phase with `zoltanvin/royal-reserve-bank`). Each numbered subdirectory corresponds to one n8n execution and contains:

| Path | Content |
|------|---------|
| `docker-compose.yml` | The input Compose file that was submitted |
| `kompose/` | Raw Kompose output (deterministic baseline) |
| `k8s/` | LLM-refined Kubernetes manifests |
| `tf/` | Terraform code (present once the Terraform agent was added) |
| `architecture-plan.json` | Architecture agent output (present in later runs) |
| `kompose-log.log` | Kompose stdout/stderr |

Directories suffixed with `-tf-validate` (e.g. `206-tf-validate`) are repair-loop iterations triggered by a failing `terraform validate`. Up to five iterations were allowed per execution. Because each iteration is a separate n8n execution, its number is always higher than the main run that spawned it.

### `evaluation-run/`

Executions from the formal evaluation (Chapter 7 of the thesis). All runs here used the same frozen final version of the workflow. The per-run directory structure is the same as `development-runs/`. Three microservice applications were evaluated, each submitted to every LLM backend multiple times.

### `n8n-deployment/`

Docker Compose stack for running n8n locally on macOS (ARM/Apple Silicon).

| File | Purpose |
| --- | --- |
| `Dockerfile` | Multi-stage build that adds `kubectl` (latest stable), `kompose` v1.34.0, and Terraform 1.14.3 to `n8n:2.18.5` |
| `docker-compose.yaml` | Starts the custom n8n image, mounts a shared filesystem at `/data/shared`, and exposes the UI on port 5678 |

The shared volume (`/data/shared/{executionId}/`) is where the workflow writes all intermediate files: the Compose input, Kompose output, manifests, and Terraform code.

> **Note:** Paths in `docker-compose.yaml` are hard-coded to the original development machine. Update the `volumes:` section to match your local paths before starting the stack.

### `n8n-workflows/`

| File | Workflow |
|------|---------|
| `GenerationOfCloudReadyIaCFromDockerCompose.json` | Main three-agent pipeline (Architecture Agent → Kubernetes Agent → Terraform Agent) |
| `terraform_validate.json` | Standalone `terraform validate` repair-loop sub-workflow |

---

## How to run the workflow

### 1. Start n8n

```bash
cd n8n-deployment
docker compose up --build -d
```

n8n will be available at `http://localhost:5678`.

### 2. Import the workflows

1. Open n8n in your browser.
2. Go to **Workflows → Import from file**.
3. Import `n8n-workflows/terraform_validate.json` first — it is called as a sub-workflow.
4. Import `n8n-workflows/GenerationOfCloudReadyIaCFromDockerCompose.json`.
5. Add your LLM credentials (OpenAI / Anthropic / Google) in the n8n credential store.
6. Publish both workflows (this makes the webhook URLs live).

### 3. Submit a Docker Compose file

Send a `multipart/form-data` POST to the webhook. The workflow expects the file in a field named `composeFile`:

```bash
curl -X POST http://localhost:5678/webhook/compose-to-k8s \
  -F "composeFile=@path/to/docker-compose.yml"
```

The pipeline then:

1. Runs Kompose to generate a baseline manifest set.
2. Calls the Architecture Agent to analyse the Compose services.
3. Calls the Kubernetes Agent to produce refined manifests.
4. Calls the Terraform Agent to generate AWS/EKS infrastructure code.
5. Runs `terraform validate` and loops up to five times to fix any errors.

All output lands in `/data/shared/{executionId}/` inside the container.

---

## Microservice applications used in the thesis

### Evaluation applications (Chapter 7)

| Application | Original repository | Fork used in thesis |
|-------------|--------------------|--------------------|
| Microservice Demo | [Joker666/microservice-demo](https://github.com/Joker666/microservice-demo) | [ralfx22/microservice-demo](https://github.com/ralfx22/microservice-demo) |
| BookStoreApp Distributed | [devdcores/BookStoreApp-Distributed-Application](https://github.com/devdcores/BookStoreApp-Distributed-Application) | [ralfx22/BookStoreApp-Distributed-Application](https://github.com/ralfx22/BookStoreApp-Distributed-Application) |

### Development / hardening applications

| Application | Original repository | Fork used in thesis |
| --- | --- | --- |
| Simple Microservice Example (SME) | [kasvith/simple-microservice-example](https://github.com/kasvith/simple-microservice-example) | [ralfx22/simple-microservice-example](https://github.com/ralfx22/simple-microservice-example) |
| Royal Reserve Bank (RRB) | [zoltanvin/royal-reserve-bank](https://github.com/zoltanvin/royal-reserve-bank) | [ralfx22/royal-reserve-bank](https://github.com/ralfx22/royal-reserve-bank) |
