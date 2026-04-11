# AX Ripple Network

[![CI](https://img.shields.io/badge/CI-passing-brightgreen)](../../actions/workflows/ci.yml)
[![Bootstrap](https://img.shields.io/badge/Bootstrap-manual-blue)](../../actions/workflows/bootstrap.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> Enterprise-grade XRP Ledger infrastructure on AWS using a hybrid IaC architecture (Terraform → CloudFormation) with HAProxy load balancing, ECS-based rippled nodes, and full observability.

---

## 🧠 Architecture

```
Terraform is used as the orchestration layer for infrastructure lifecycle
and team workflows (via Atlantis), while CloudFormation is used for
AWS-native resource provisioning to align with AWS best practices
and enable modular stack reuse.
```

### End-to-End Architecture Flow: Engineering, User, and Failover Perspectives

> The following diagram covers **three perspectives**: the software engineer's CI/CD & infra flow, the end-user's runtime traffic flow, and the HA failover testing flow — the most critical proof point for this architecture.

![End-to-End Architecture Flow](docs/images/e2e-flow.png)

### High-Level Infrastructure Overview

```mermaid
graph TB
    subgraph "Developer Workflow"
        DEV[Developer] --> |PR| GH[GitHub]
        GH --> |webhook| ATL[Atlantis]
        GH --> |trigger| GHA[GitHub Actions]
    end

    subgraph "CI/CD Pipeline"
        GHA --> |lint| ML[MegaLinter]
        GHA --> |security| REN[Renovate]
        ATL --> |plan/apply| TF[Terraform]
    end

    subgraph "IaC Orchestration"
        TF --> |provisions| CFN_NET[CFN: Network Stack]
        TF --> |provisions| CFN_ECS[CFN: ECS Stack]
        TF --> |provisions| CFN_HA[CFN: HAProxy Stack]
        TF --> |provisions| CFN_OBS[CFN: Observability Stack]
    end

    subgraph "AWS Infrastructure"
        CFN_NET --> VPC[VPC + Subnets + SGs]
        CFN_ECS --> ECS[ECS Cluster]
        ECS --> VAL[Validators x3]
        ECS --> API[API Nodes x2]
        CFN_HA --> HA[HAProxy EC2]
        CFN_OBS --> PROM[Prometheus]
        CFN_OBS --> GRAF[Grafana]
    end

    subgraph "Traffic Flow"
        CLIENT[Client] --> |HTTP :80| HA
        CLIENT --> |WS :6006| HA
        HA --> |round-robin| API
        API --> |peer| VAL
    end
```

## 📁 Repository Structure

```
ax-ripple-network/
├── 001_app/                        # Application code
│   ├── client/
│   │   ├── package.json            # Node.js dependencies
│   │   ├── client.js               # WebSocket failover test client
│   │   └── .env.example            # Environment variable template
│   └── docker/
│       ├── Dockerfile.validator    # Docker image for validator nodes
│       └── Dockerfile.api-node     # Docker image for API nodes
│
├── 002_configs/                    # Runtime configuration files
│   ├── haproxy/
│   │   └── haproxy.cfg             # HAProxy load balancer config
│   └── rippled/
│       ├── validator.cfg           # Rippled validator node config
│       └── api-node.cfg            # Rippled API node config
│
├── 003_scripts/                    # Operational scripts
│   ├── bootstrap-backend.sh        # Create S3/DynamoDB for TF state
│   ├── create-ecr-repos.sh         # Create ECR repositories (run once before first deploy)
│   ├── generate-validator-keys.sh  # Generate rippled validator tokens → push to Secrets Manager
│   ├── update-task-definitions.sh  # Update ECS task defs (secret rotation / emergency redeploy)
│   ├── validate-infra.sh           # Validate all infrastructure
│   └── failover-test.sh            # End-to-end failover test
│
├── 004_terraform/                  # Terraform orchestration layer (modular)
│   ├── shared-infra/               # Shared infrastructure (deploy FIRST)
│   │   ├── main.tf                 # Network + ECS cluster CFN stacks
│   │   ├── variables.tf            # region, environment, vpc_cidr
│   │   ├── outputs.tf              # VPC, subnets, SGs, cluster ARN
│   │   ├── providers.tf
│   │   ├── backend.tf              # S3 state: shared-infra/terraform.tfstate
│   │   ├── environments/
│   │   │   ├── dev.tfvars
│   │   │   └── prod.tfvars
│   │   └── cfn/
│   │       ├── network.yaml        # VPC, subnets, security groups
│   │       └── ecs-cluster.yaml    # Shared ECS cluster, execution role, service discovery
│   │
│   └── services/
│       ├── ax-ripple-network/      # Ripple service (validators, API, HAProxy, observability)
│       │   ├── main.tf             # Reads shared-infra state, deploys service CFN stacks
│       │   ├── variables.tf        # images, counts, haproxy, observability
│       │   ├── outputs.tf
│       │   ├── providers.tf
│       │   ├── backend.tf          # S3 state: services/ax-ripple-network/terraform.tfstate
│       │   ├── environments/
│       │   │   ├── dev.tfvars
│       │   │   └── prod.tfvars
│       │   └── cfn/
│       │       ├── ecs-services.yaml   # Task defs, ECS services, ECR repos
│       │       ├── haproxy.yaml        # HAProxy EC2 ASG
│       │       └── observability.yaml  # Prometheus + Grafana
│       │
│       └── atlantis/               # Atlantis service (Terraform PR automation)
│           ├── main.tf             # Reads shared-infra state, deploys Atlantis
│           ├── variables.tf        # image, GitHub secrets, repo allowlist
│           ├── outputs.tf
│           ├── providers.tf
│           ├── backend.tf          # S3 state: services/atlantis/terraform.tfstate
│           ├── environments/
│           │   ├── dev.tfvars
│           │   └── prod.tfvars
│           └── cfn/
│               └── atlantis.yaml   # Atlantis ECS task, service, IAM
│
├── .github/workflows/              # CI/CD pipelines
│   └── ci.yml                      # PR validation + Docker build & push to ECR
│
├── atlantis.yaml                   # Atlantis PR automation config
├── renovate.json                   # Dependency update bot config
├── .mega-linter.yml                # Multi-language linter config
├── .gitignore
├── LICENSE
├── README.md
└── docs/
    └── images/
        └── e2e-flow.svg            # Architecture flow diagram (3 perspectives)
```

## 🚀 Quick Start

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | >= 1.5.0 | IaC orchestration |
| AWS CLI | v2 | AWS access |
| Node.js | >= 18 | Client application |
| cfn-lint | latest | CloudFormation validation |

### 1. One-Time AWS Setup

```bash
# 1a. Create OIDC identity provider for GitHub Actions
#     (allows GitHub runners to assume IAM roles without static keys)
#     Note: AWS no longer validates thumbprints for token.actions.githubusercontent.com
#     but the CLI still requires at least one. Both known GitHub OIDC thumbprints are included.
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "1c58a3a8518e8759bf075b76b750d4f2df264fcd" "6938fd4d98bab03faadb97b34396831e3780aea1"

# 1b. Create IAM role for GitHub Actions
#     THIS is the account-specific part — the trust policy locks access
#     to YOUR GitHub org and repo. Replace <ACCOUNT_ID> and <YOUR_ORG>.
#
# Also create the ECS service-linked role (required once per account).
# Without this, CloudFormation cannot create ECS clusters.
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true
aws iam create-role \
  --role-name github-actions-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<YOUR_ORG>/ax-ripple-network:*"
        }
      }
    }]
  }'

# Attach permissions the role needs for the full deployment scope.
# Option A: Use AWS managed policies (broader, simpler)
for policy in \
  arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess \
  arn:aws:iam::aws:policy/AmazonECS_FullAccess \
  arn:aws:iam::aws:policy/AWSCloudFormationFullAccess \
  arn:aws:iam::aws:policy/AmazonEC2FullAccess \
  arn:aws:iam::aws:policy/AmazonVPCFullAccess \
  arn:aws:iam::aws:policy/SecretsManagerReadWrite \
  arn:aws:iam::aws:policy/CloudWatchLogsFullAccess \
  arn:aws:iam::aws:policy/AmazonRoute53AutoNamingFullAccess; do
  aws iam attach-role-policy --role-name github-actions-role --policy-arn "$policy"
done

# S3 + DynamoDB for Terraform state (no managed policy — use inline)
aws iam put-role-policy \
  --role-name github-actions-role \
  --policy-name terraform-state-access \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ],
        "Resource": [
          "arn:aws:s3:::ax-ripple-network-terraform-state",
          "arn:aws:s3:::ax-ripple-network-terraform-state/*"
        ]
      },
      {
        "Effect": "Allow",
        "Action": [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ],
        "Resource": "arn:aws:dynamodb:*:*:table/ax-ripple-network-terraform-locks"
      }
    ]
  }'

# IAM pass-role + role management (CloudFormation creates IAM roles for ECS tasks + HAProxy)
aws iam put-role-policy \
  --role-name github-actions-role \
  --policy-name iam-pass-role \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "iam:PassRole",
        "iam:GetRole",
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:ListInstanceProfilesForRole"
      ],
      "Resource": [
        "arn:aws:iam::443370674281:role/ax-ripple-*",
        "arn:aws:iam::443370674281:instance-profile/ax-ripple-*"
      ]
    }]
  }'

# Store the role ARN as GitHub org secret: AWS_ROLE_ARN

# 1c. Create Secrets Manager entries for Atlantis
aws secretsmanager create-secret --name atlantis/github-token \
  --secret-string "ghp_xxxxxxxxxxxx"
aws secretsmanager create-secret --name atlantis/webhook-secret \
  --secret-string "$(openssl rand -hex 32)"

# 1d. Generate validator keys + tokens and push to Secrets Manager
#
#     Uses the validator-keys tool inside the official xrpllabsofficial/xrpld
#     Docker image to generate a keypair and token for each of the 3 validators.
#
#     What it produces per validator:
#       - PUBLIC_KEY  (nHXXX) → goes into the [validators] UNL list
#       - TOKEN       (base64 blob) → rippled reads this as [validator_token]
#
#     IMPORTANT: Run this ONCE per environment. Re-running create_token
#     increments the key sequence; all validator services must be redeployed
#     simultaneously after any re-run.
#
chmod +x 003_scripts/generate-validator-keys.sh

# Dry run first — generates keys and prints output without touching AWS
./003_scripts/generate-validator-keys.sh

# When ready, push tokens + public keys directly to Secrets Manager:
ENVIRONMENT=dev ./003_scripts/generate-validator-keys.sh --push-secrets

# Output files (keep offline and secure):
#   /tmp/validator-keys/validator-1.txt  → PUBLIC_KEY + TOKEN for validator 1
#   /tmp/validator-keys/validator-2.txt  → PUBLIC_KEY + TOKEN for validator 2
#   /tmp/validator-keys/validator-3.txt  → PUBLIC_KEY + TOKEN for validator 3
#
# Secrets created in AWS Secrets Manager:
#   ax-ripple-dev/validator-seed          → validator 1 token
#   ax-ripple-dev/validator-seed-2        → validator 2 token
#   ax-ripple-dev/validator-seed-3        → validator 3 token
#   ax-ripple-dev/validator-public-keys   → comma-separated nHXXX public keys (UNL)

# 1f. Create ECR repositories (managed outside CloudFormation to avoid image conflicts)
#     ECR repos must exist BEFORE the first terraform apply — CFN does not manage them.
chmod +x 003_scripts/create-ecr-repos.sh
./003_scripts/create-ecr-repos.sh

# 1g. Bootstrap Terraform state backend (S3 + DynamoDB)
chmod +x 003_scripts/bootstrap-backend.sh
./003_scripts/bootstrap-backend.sh
```

### 2. Set GitHub Org Secret

```
GitHub → Settings → Secrets → Actions → New organization secret
  Name:  AWS_ROLE_ARN
  Value: arn:aws:iam::<ACCOUNT_ID>:role/github-actions-role
```

### 3. Run Bootstrap Workflow (one-time)

```
GitHub → Actions → "Bootstrap Infrastructure" → Run workflow
  Environment: dev
  Deploy AX Ripple Network: ✅
```

This deploys: **shared-infra → Atlantis → AX Ripple Network** in order.
After this, Atlantis is live and manages all future changes via PRs.

### 4. Validate & Test

```bash
# Validate all infrastructure is healthy
chmod +x 003_scripts/validate-infra.sh
./003_scripts/validate-infra.sh

# Test WebSocket client
cd 001_app/client
cp .env.example .env
# Update RIPPLED_WS_URL and RIPPLED_HTTP_URL with the HAProxy IP from Terraform outputs
npm install && npm start

# Run full failover test
chmod +x 003_scripts/failover-test.sh
./003_scripts/failover-test.sh
```

> **Note — Secret Rotation / Emergency Redeploy:**
> If validator secrets are rotated (new tokens generated), run the following to update
> ECS task definitions with the new Secrets Manager ARNs and force a redeploy:
> ```bash
> chmod +x 003_scripts/update-task-definitions.sh
> ./003_scripts/update-task-definitions.sh dev
> ```
> Under normal operation this is **not required** — Atlantis `apply` handles all ECS deployments.

## 🔧 How It Works

### Terraform → CloudFormation Pattern

Terraform acts as the **orchestration layer**, while CloudFormation handles **AWS-native provisioning**. Services consume shared infrastructure via `terraform_remote_state`:

```hcl
# Services read shared infra outputs
data "terraform_remote_state" "shared" {
  backend = "s3"
  config  = { bucket = "ax-ripple-network-terraform-state", key = "shared-infra/terraform.tfstate" }
}

# Then deploy into the shared ECS cluster
resource "aws_cloudformation_stack" "ecs_services" {
  template_body = file("${path.module}/cfn/ecs-services.yaml")
  parameters    = { ECSClusterArn = data.terraform_remote_state.shared.outputs.ecs_cluster_arn }
}
```

### Infrastructure Stacks

**Shared Infrastructure** (deployed once):

| Stack | Resources | Dependencies |
|-------|-----------|-------------|
| **Network** | VPC, Subnets (2 public + 2 private), IGW, NAT GW, Security Groups | None |
| **ECS Cluster** | Shared Fargate cluster, task execution role, service discovery namespace | Network |

**Services** (deployed independently, into shared infra):

| Stack | Resources | Dependencies |
|-------|-----------|-------------|
| **ECS Services** | Validator tasks (3), API tasks (2), ECR repos, service discovery entries | Shared Infra |
| **HAProxy** | EC2 ASG, Launch Template, HAProxy config, Elastic IP | Shared Infra, ECS Services |
| **Observability** | Prometheus, Grafana, EFS storage | Shared Infra, ECS Services, HAProxy |
| **Atlantis** | Atlantis ECS task, IAM role (TF state + CFN access), service discovery | Shared Infra |

### HAProxy Load Balancing

```
Client → HAProxy :80  (HTTP)  → rippled API nodes :5005 (JSON-RPC)
Client → HAProxy :6006 (WS)   → rippled API nodes :6006 (WebSocket)
```

- **Round-robin** load balancing across API nodes
- **Health checks** every 5s (3 failures = down, 2 successes = up)
- **Sticky sessions** for WebSocket connections
- **Stats dashboard** at `:8404/stats`

### CI/CD Pipeline

```
PR Opened → GitHub Actions CI (runs in parallel):
  ├── MegaLinter, Hadolint, cfn-lint, ShellCheck, Node.js syntax
  ├── Terraform fmt + validate (all 3 modules)
  └── Docker Build & Push to ECR (tagged r-1.0.X — next patch version)
        ↓ images exist in ECR before Atlantis plans

PR Opened → Atlantis (auto-runs terraform plan):
  ├── atlantis plan -p shared-infra
  ├── atlantis plan -p ax-ripple-network    ← references r-1.0.X image already in ECR
  └── atlantis plan -p atlantis

PR Approved → Developer comments to apply in order:
  ├── atlantis apply -p shared-infra        ← VPC, ECS cluster (deploy FIRST)
  ├── atlantis apply -p ax-ripple-network   ← validators, API nodes, HAProxy
  └── atlantis apply -p atlantis            ← Atlantis service itself

PR Merged → GitHub Actions CI:
  ├── Promote r-1.0.X image to :latest in ECR
  └── Create Git tag + GitHub Release r-1.0.X (auto-increment X, max 9)
```

> **Deployment is owned by Atlantis.** The CI pipeline builds and tags images.
> `terraform apply` (via Atlantis) is what actually deploys the new image to ECS —
> by updating the CloudFormation stack with the new image URI.
> There is no separate "deploy" step in CI.

## 🧪 Post-Deployment Flows

After infrastructure is deployed to AWS ECS, three scripts validate and demonstrate the system:

### 1. Test Flow — Validate the Network (`test-flow.sh`)

Non-interactive. Checks every component is healthy.

```bash
export HAPROXY_PUBLIC_IP=<ip>   # or let it read from Terraform outputs
./003_scripts/test-flow.sh
```

| Phase | What it checks |
|-------|---------------|
| 1. ECS Cluster | Cluster ACTIVE, API service running ≥ 2 tasks |
| 2. Validators | Peers visible, validation quorum set |
| 3. API Nodes | HTTP (JSON-RPC :80) responds, WebSocket (:6006) receives ledger event |
| 4. Ledger Progression | Validated ledger index increases over 10s (consensus working) |
| 5. HAProxy Routing | 6 HTTP requests show round-robin across ≥ 2 backends |
| 6. HAProxy Stats | Stats dashboard accessible, backend status UP |

### 2. Demo Flow — Full End-to-End (`demo-flow.sh`)

Interactive (pauses between steps for observation). Maps **1:1** to the task's "Recommended Demo Flow":

```bash
export HAPROXY_PUBLIC_IP=<ip>
export ECS_CLUSTER_NAME=<cluster>
export API_SERVICE_NAME=<service>
./003_scripts/demo-flow.sh
```

| Step | Task Requirement | What it does |
|------|-----------------|--------------|
| 1 | "Start the private network and confirm ledger progression" | Queries `server_info`, checks ledger index grows over 8s |
| 2 | "Show that HTTP requests succeed through the single public endpoint" | Sends 4 HTTP POST requests, shows round-robin across backends |
| 3 | "Start the subscriber client against the single public WebSocket endpoint" | Starts `client.js`, waits 20s, shows validated ledger events in log |
| 4 | "Stop one backend rippled API/proxy node" | `aws ecs stop-task` on one API node, waits 30s |
| 5 | "Show that HTTP continues to work through the same public endpoint" | HTTP POST to same `:80` endpoint → still responds |
| 6 | "Show that the WebSocket client detects interruption, reconnects, and resumes" | Client log shows: disconnect → reconnect → BACKEND SWITCH → resumed ledger events |
| 7 | Switch proof | HAProxy stats before/after + client log key events |

### 3. Failover Test — Automated Pass/Fail (`failover-test.sh`)

Fully automated (CI-friendly). Returns exit code 0/1.

```bash
export HAPROXY_PUBLIC_IP=<ip>
export ECS_CLUSTER_NAME=<cluster>
export API_SERVICE_NAME=<service>
./003_scripts/failover-test.sh
```

| Phase | Acceptance Criterion | Check |
|-------|---------------------|-------|
| 1 | Infrastructure running | HTTP responds, ≥ 2 API tasks |
| 2 | Client works | WebSocket connects, receives validated ledger events |
| 3 | Pre-failover state | HAProxy stats captured |
| 4 | **Failure injected** | One ECS API task stopped |
| 5 | HTTP continues | Same `:80` endpoint still responds 200 |
| 6 | WebSocket recovers | Disconnect detected → reconnected → new ledger events |
| 7 | **Switch proof** | Client log shows `BACKEND SWITCH DETECTED` + HAProxy stats show `DOWN` |
| 8 | Results | Pass/fail count, full summary |

### Expected Output During Failover

**Client log (`/tmp/ax-ripple-failover-test.log`):**
```json
{"timestamp":"...","level":"INFO","message":"📒 Validated ledger","ledgerIndex":42,"backendNode":"api-1"}
{"timestamp":"...","level":"INFO","message":"📒 Validated ledger","ledgerIndex":43,"backendNode":"api-1"}
{"timestamp":"...","level":"WARN","message":"❌ WebSocket disconnected","code":1006}
{"timestamp":"...","level":"INFO","message":"⏳ Scheduling reconnect","attempt":1,"delayMs":2000}
{"timestamp":"...","level":"INFO","message":"🔁 Reconnecting...","attempt":1}
{"timestamp":"...","level":"INFO","message":"✅ WebSocket connection established"}
{"timestamp":"...","level":"INFO","message":"🔄 BACKEND SWITCH DETECTED","previousNode":"api-1","currentNode":"api-2"}
{"timestamp":"...","level":"INFO","message":"📡 Connected to backend node","hostid":"api-2"}
{"timestamp":"...","level":"INFO","message":"📒 Validated ledger","ledgerIndex":44,"backendNode":"api-2"}
{"timestamp":"...","level":"INFO","message":"📒 Validated ledger","ledgerIndex":45,"backendNode":"api-2"}
```

**HAProxy stats (before/after):**
```
Before:  rippled_http/api-1: UP   rippled_http/api-2: UP
After:   rippled_http/api-1: DOWN rippled_http/api-2: UP
```

## 📊 Observability

| Component | Port | Purpose |
|-----------|------|---------|
| **Prometheus** | 9090 | Metrics collection |
| **Grafana** | 3000 | Dashboards (admin/admin) |
| **HAProxy Stats** | 8404 | Load balancer metrics |

## ⚖️ Tradeoffs

### Why Terraform + CloudFormation?
- ✅ Separation of orchestration vs provisioning
- ✅ Reusable CFN stacks across projects
- ❌ Added complexity / double IaC layer

### Why ECS over EKS?
- 💰 Lower cost (no control plane fees)
- ⚡ Faster setup, sufficient for PoC

### Why HAProxy over ALB?
- 🔧 Better control for WebSocket failover
- 📝 Clearer logging (critical for failover demo)

## 🔒 Security

- Validator seeds injected via **AWS Secrets Manager** (never committed)
- Private subnets for validators (no public IP)
- OIDC for GitHub Actions → AWS (no long-lived credentials)
- S3 state bucket: encrypted, public access blocked, DynamoDB locking

## 📝 License

MIT — see [LICENSE](LICENSE)

