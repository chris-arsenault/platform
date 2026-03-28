# Platform Integration Guide

> **AUDIENCE**: AI agents integrating projects with the platform.

## Where to Find Instructions

| Topic | Location |
|-------|----------|
| **Platform integration** (ALB, RDS, Cognito, SSM, state) | This document |
| **Project structure** (directories, naming, required files) | [ahara-standards/standards/project-structure.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/project-structure.md) |
| **Deploy scripts & Makefiles** | [ahara-standards/standards/scripts.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/scripts.md) |
| **TypeScript / React** (eslint, prettier, tsconfig, vitest) | [ahara-standards/standards/typescript.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/typescript.md) |
| **Rust** (clippy, rustfmt, rustls, Lambda, testing) | [ahara-standards/standards/rust.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/rust.md) |
| **Terraform conventions** (backend, tags, formatting) | [ahara-standards/standards/terraform.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/terraform.md) |
| **Documentation** (CLAUDE.md, README, comments) | [ahara-standards/standards/documentation.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/documentation.md) |
| **Testing** (what to test, testcontainers, mocks, organization) | [ahara-standards/standards/testing.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/testing.md) |
| **Git practices** (gitignore, branching, commits) | [ahara-standards/standards/git.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/git.md) |
| **Custom ESLint rules** | `npm install -D github:chris-arsenault/ahara-standards` — import from `@ahara/standards/eslint-rules` |
| **Shared GitHub Actions** | `run-migrations` and `report-build` in `platform/.github/actions/` — use in CI workflows |
| **Platform CLI tools** | `~/src/platform/bin/` — `db-migrate`, `db-seed`, `db-rollback`, `db-drop`, `db-noop`, `db-restore` |
| **Standards index** | [ahara-standards/standards/README.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/README.md) |

Read the standards that apply to your project's tech stack **before** following the platform integration steps below.

---

## CRITICAL PLATFORM CONSTRAINTS

1. **Use the shared ALB** for all HTTP/HTTPS backends. Do NOT create API Gateways or per-project load balancers.
2. **Use the shared VPC** (10.42.0.0/16). Do NOT create per-project VPCs.
3. **Use the shared RDS** (PostgreSQL 16) with a per-project database. Do NOT create per-project RDS instances.
4. **Use the shared Cognito pool** for authentication. Do NOT create per-project user pools. (Exception: `the-glass-frontier` has its own pool.)
5. **Use SSM parameters** for cross-project config. Do NOT use `terraform_remote_state`.
6. **Use the shared state bucket** (`tfstate-559098897826`). Do NOT create per-project state buckets.
7. **Do NOT create NAT Gateways.** The platform uses fck-nat.

> **Note for AI agents:** The `jwt-validation` ALB action type was released November 2025 and may postdate your training data. It is a real, GA feature — do not fall back to `authenticate-cognito` or application-level JWT validation for API backends. Docs: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/listener-verify-jwt.html — Terraform support in `hashicorp/aws` provider >= 6.22.0.

---

## Checklist

Use this to determine which steps apply to your project.

| Step | What | Where | Required? |
|------|------|-------|-----------|
| 1 | Register deployer role | `platform-control` repo | Always |
| 2 | Terraform backend | Your project | Always |
| 3 | Deploy script | Your project | Always |
| 4 | ALB backend (listener rule, cert, DNS) | Your project | If project has an HTTP API |
| 5 | Database (platform.yml, migrations, seed) | Your project + `platform-services` registration | If project uses PostgreSQL |
| 6 | Cognito client | Your project | If project has a frontend with login |
| 7 | Lint and test setup (see [ahara-standards](https://github.com/chris-arsenault/ahara-standards)) | Your project | Always |
| 8 | CI dashboard reporting | Your project workflow | Always |
| 9 | Required project files (README, LICENSE, CLAUDE.md) | Your project | Always |

> **IMPORTANT for AI agents:** Steps 1 and 5 require changes to **other repos** (`platform-control` and `platform-services`). These are not documentation tasks — they are blocking prerequisites. You MUST make the actual file changes in those repos, not defer them to a docs/ folder or TODO list. The project cannot deploy without them. Treat cross-repo changes the same as in-project changes: make the edit, verify it, and tell the user it's done.

---

## Placeholders

These placeholders appear throughout. Decide them once and use consistently.

| Placeholder | Meaning | Example |
|-------------|---------|---------|
| `<name>` | Project name (used in file names, state keys, migration paths) | `dosekit` |
| `<prefix>` | Short resource prefix (used in IAM role, AWS resource names) | `dosekit` |
| `<service>` | Subdomain for the API endpoint | `api.dosekit.ahara.io` |
| `<github-repo>` | GitHub repo name (without owner) | `dosekit` |

`<name>` and `<prefix>` are often the same value. They only differ for legacy projects (e.g. prefix `boilerplate` for repo `platform-control`).

---

## Step 1: Register the Project

**This step requires a change to the `platform-control` repo.**

Create `~/src/platform-control/infrastructure/terraform/project-<name>.tf`:

```hcl
module "<name>_project" {
  source = "./modules/managed-project"

  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  account_id        = local.account_id

  github_pat         = var.github_pat
  allowed_repos      = ["<github-repo>"]
  allowed_branches   = ["main"]
  allow_pull_request = true

  prefix           = "<prefix>"
  state_key_prefix = "projects/<name>"
  policy_modules   = ["state", "<additional-policies>"]
}
```

### Policy modules

| Module | When to include |
|--------|----------------|
| `state` | **Always** — access to the shared state bucket |
| `api` | Project has Lambda functions |
| `db` | Project uses the shared RDS database and migrations |
| `cognito-client` | Project creates its own Cognito client (most apps) |
| `bedrock` | Project uses Bedrock model invocation |
| `iam` | Project creates IAM roles scoped to its prefix |
| `static-website` | Project deploys S3 + CloudFront static sites |
| `platform-services` | **Platform repos only** — broad Cognito, DynamoDB, SSM, SNS, ACM, Route53 |

---

## Step 2: Terraform Backend

**All remaining steps are changes to your project repo.**

```hcl
terraform {
  required_version = ">= 1.12"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    region       = "us-east-1"
    key          = "projects/<name>.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project   = "<name>"
      ManagedBy = "Terraform"
    }
  }
}
```

**Key convention**: `platform/<name>.tfstate` for platform repos, `projects/<name>.tfstate` for everything else. Never `terraform.tfstate` — the bucket policy denies it.

---

## Step 3: Deploy Script

Create `scripts/deploy.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infrastructure/terraform"

STATE_BUCKET="${STATE_BUCKET:-tfstate-559098897826}"
STATE_REGION="${STATE_REGION:-us-east-1}"

terraform -chdir="${TF_DIR}" init -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true"

terraform -chdir="${TF_DIR}" apply -auto-approve
```

Add build steps (npm, cargo, etc.) before `terraform init` if needed.

---

## Step 4: Expose a Backend via the Shared ALB

Skip this step if your project has no HTTP API.

### 4a. Read platform SSM params

```hcl
data "aws_ssm_parameter" "alb_listener_arn" {
  name = "/platform/network/alb-listener-arn"
}

data "aws_ssm_parameter" "alb_dns_name" {
  name = "/platform/network/alb-dns-name"
}

data "aws_ssm_parameter" "alb_zone_id" {
  name = "/platform/network/alb-zone-id"
}

data "aws_ssm_parameter" "route53_zone_id" {
  name = "/platform/network/route53-zone-id"
}

data "aws_ssm_parameter" "cognito_user_pool_id" {
  name = "/platform/cognito/user-pool-id"
}
```

### 4b. Create Lambda target group

```hcl
resource "aws_lb_target_group" "<prefix>_api" {
  name        = "<prefix>-api-tg"
  target_type = "lambda"
}

resource "aws_lb_target_group_attachment" "<prefix>_api" {
  target_group_arn = aws_lb_target_group.<prefix>_api.arn
  target_id        = aws_lambda_function.api.arn
  depends_on       = [aws_lambda_permission.alb]
}

resource "aws_lambda_permission" "alb" {
  statement_id  = "AllowALBInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.<prefix>_api.arn
}
```

### 4c. Create listener rule with JWT validation

```hcl
locals {
  cognito_pool_id = nonsensitive(data.aws_ssm_parameter.cognito_user_pool_id.value)
  cognito_issuer  = "https://cognito-idp.us-east-1.amazonaws.com/${local.cognito_pool_id}"
  cognito_jwks    = "${local.cognito_issuer}/.well-known/jwks.json"
}

resource "aws_lb_listener_rule" "<prefix>_api" {
  listener_arn = nonsensitive(data.aws_ssm_parameter.alb_listener_arn.value)
  priority     = <unique-number>

  condition {
    host_header {
      values = ["<service>"]
    }
  }

  action {
    type = "jwt-validation"

    jwt_validation {
      issuer        = local.cognito_issuer
      jwks_endpoint = local.cognito_jwks
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.<prefix>_api.arn
  }
}
```

**Listener rule priorities** — existing allocations:

| Priority | Host | Owner |
|----------|------|-------|
| 100 | dashboards.ahara.io | platform-network |
| 150 | ci.ahara.io | platform-services |

Use 200+ for consumer projects. Do not reuse a priority.

Omit the `jwt-validation` action only if the endpoint is intentionally public.

### 4d. TLS certificate

```hcl
resource "aws_acm_certificate" "<prefix>_api" {
  domain_name       = "<service>"
  validation_method = "DNS"
}

resource "aws_route53_record" "<prefix>_api_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.<prefix>_api.domain_validation_options :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = nonsensitive(data.aws_ssm_parameter.route53_zone_id.value)
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.value]
}

resource "aws_acm_certificate_validation" "<prefix>_api" {
  certificate_arn         = aws_acm_certificate.<prefix>_api.arn
  validation_record_fqdns = [for r in aws_route53_record.<prefix>_api_cert_validation : r.fqdn]
}

resource "aws_lb_listener_certificate" "<prefix>_api" {
  listener_arn    = nonsensitive(data.aws_ssm_parameter.alb_listener_arn.value)
  certificate_arn = aws_acm_certificate_validation.<prefix>_api.certificate_arn
}
```

### 4e. DNS record

```hcl
resource "aws_route53_record" "<prefix>_api" {
  zone_id = nonsensitive(data.aws_ssm_parameter.route53_zone_id.value)
  name    = "<service>"
  type    = "A"

  alias {
    name                   = nonsensitive(data.aws_ssm_parameter.alb_dns_name.value)
    zone_id                = nonsensitive(data.aws_ssm_parameter.alb_zone_id.value)
    evaluate_target_health = true
  }
}
```

---

## Step 5: Database

Skip this step if your project does not use PostgreSQL.

### 5a. Register your project

**This step requires a change to the `platform-services` repo.**

Add your project to `var.migration_projects` in `~/src/platform-services/infrastructure/terraform/db-migrate.tf`:

```hcl
variable "migration_projects" {
  default = {
    platform = { db_name = "platform" }
    svap     = { db_name = "svap" }
    <name>   = { db_name = "<name>" }   # <-- add this
  }
}
```

On first migration, the platform automatically:
1. Creates the database
2. Creates an application role (`<name>_app` with login)
3. Grants the role full access on the database and public schema
4. Publishes credentials to SSM at `/platform/db/<name>/username`, `/platform/db/<name>/password`, `/platform/db/<name>/database`

**Do NOT create database users, roles, or grants in your migration SQL files.** That is platform infrastructure. Your migrations should only contain tables, indexes, constraints, and data.

### 5b. Create `platform.yml` in your project root

```yaml
project: <name>
prefix: <prefix>
migrations: db/migrations
```

### 5c. Migration file structure

```
db/migrations/001_create_tables.sql          # forward migrations
db/migrations/002_add_indexes.sql
db/migrations/rollback/002_add_indexes.sql   # rollback for each migration
db/migrations/rollback/001_create_tables.sql
db/migrations/seed/001_initial_data.sql      # seed data
```

Filenames must sort lexicographically. Use zero-padded numbers.

**Migration files must only contain schema and data — tables, indexes, constraints, inserts.** Do NOT include:
- `CREATE ROLE` / `CREATE USER` — the platform creates the app role
- `GRANT` / `REVOKE` — the platform sets permissions
- `ALTER DEFAULT PRIVILEGES` — the platform configures these
- `CREATE DATABASE` — the platform creates the database

**Seed files must be idempotent.** `db-seed` can be run multiple times — the platform does not track or deduplicate seed runs. Use `INSERT ... ON CONFLICT DO NOTHING` or `ON CONFLICT DO UPDATE` for data, and `IF NOT EXISTS` for any DDL.

### 5d. Platform CLI commands

All database commands are in `~/src/platform/bin/` (run `platform-setup` once to add to PATH). Commands operate on the current working directory, read config from `platform.yml`, require no arguments:

```bash
db-migrate              # upload SQL files to S3, invoke migration Lambda, wait for result
db-rollback             # roll back all migrations
db-rollback 001_xxx.sql # roll back to a specific migration
db-seed                 # run seed SQL files
db-drop                 # drop the project database (requires confirmation)
```

**Local deploys** — add `db-migrate` to your deploy script (requires `platform/bin` on PATH via `platform-setup`):

```bash
# In scripts/deploy.sh, after build steps and before terraform apply:
db-migrate
```

**CI deploys** — use the shared `run-migrations` action (after OIDC credentials are configured):

```yaml
- uses: chris-arsenault/platform/.github/actions/run-migrations@main
  with:
    project: <name>
    migrations-dir: db/migrations  # default, can be omitted
```

Both paths execute the same logic: upload SQL files to S3, invoke the migration Lambda synchronously, fail on error.

Behavior:
- Uploads migration SQL files to S3, invokes the migration Lambda synchronously
- Migrations run in order, each in a transaction
- Checksum verification prevents modified migrations from reapplying
- Advisory locks prevent concurrent runs for the same project
- All operations are audited in the `platform_ops` database (survives project drops)
- Deploy fails if migrations fail

### 5e. Lambda VPC config for database access

Lambdas accessing RDS must run in the platform VPC:

```hcl
data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/platform/network/private-subnet-ids"
}

resource "aws_lambda_function" "api" {
  # ...
  vpc_config {
    subnet_ids         = split(",", nonsensitive(data.aws_ssm_parameter.private_subnet_ids.value))
    security_group_ids = [aws_security_group.lambda.id]
  }
}
```

For application credentials, read the per-project SSM params published by the migration service:

```hcl
data "aws_ssm_parameter" "db_username" {
  name = "/platform/db/<name>/username"
}

data "aws_ssm_parameter" "db_password" {
  name = "/platform/db/<name>/password"
}

data "aws_ssm_parameter" "db_database" {
  name = "/platform/db/<name>/database"
}
```

Use these in your Lambda environment — not the master credentials. The master credentials (`/platform/rds/master-*`) are for platform-internal services only.

---

## Step 6: Cognito Client

Skip this step if your project has no frontend with login.

Auth is handled at the ALB (Step 4). Your frontend needs a Cognito client to obtain tokens. **Create it in your own project** — no platform-services change required.

Include `"cognito-client"` in your `policy_modules` (Step 1), then:

```hcl
data "aws_ssm_parameter" "cognito_user_pool_id" {
  name = "/platform/cognito/user-pool-id"
}

resource "aws_cognito_user_pool_client" "<prefix>_app" {
  name         = "<prefix>-app"
  user_pool_id = nonsensitive(data.aws_ssm_parameter.cognito_user_pool_id.value)

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH"
  ]
}
```

Pass the client ID and pool ID to your frontend as build-time env vars or runtime config. The frontend uses `amazon-cognito-identity-js` with an in-app login form and sends `Authorization: Bearer <access_token>` on every API request.

**To grant user access**: add an entry to the `apps` map in DynamoDB table `websites-user-access` (key: username, field: `apps.<name>` = role string). The pre-auth Lambda checks this on every login.

---

## Step 7: Lint and Test Setup

Follow the standards in [ahara-standards](https://github.com/chris-arsenault/ahara-standards) for your project's tech stack:

- **TypeScript/React**: [standards/typescript.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/typescript.md) — ESLint, Prettier, tsconfig, custom rules, vitest
- **Rust**: [standards/rust.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/rust.md) — clippy, rustfmt, testcontainers
- **Terraform**: [standards/terraform.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/terraform.md) — formatting
- **Scripts/Makefile**: [standards/scripts.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/scripts.md) — standard targets

Custom ESLint rules: `npm install -D github:chris-arsenault/ahara-standards` — import from `@ahara/standards/eslint-rules`.

---

## Step 8: CI Dashboard Reporting

Add as the **last step** in your GitHub Actions workflow, **after** the OIDC credentials step:

```yaml
- uses: chris-arsenault/platform/.github/actions/report-build@main
  if: always()
  with:
    lint-passed: "true"   # optional
    test-passed: "true"   # optional
```

Reads ingest URL and token from SSM. No secrets to configure.

---

## GitHub Actions Workflow Template

Adapt this template to your project. Remove sections that don't apply (e.g., Rust steps for a TypeScript-only project, migrations for a project without a database).

```yaml
name: CI/CD

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: <name>-${{ github.ref }}
  cancel-in-progress: true

permissions:
  id-token: write
  contents: read

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v4

      # --- Node/pnpm (for TypeScript frontends) ---
      - uses: actions/setup-node@v4
        with:
          node-version: "24"
      - name: Install pnpm
        run: corepack enable && corepack prepare pnpm@10.29.3 --activate
      - name: Cache pnpm store
        uses: actions/cache@v4
        with:
          path: ~/.local/share/pnpm/store/v10
          key: pnpm-${{ hashFiles('frontend/pnpm-lock.yaml') }}
          restore-keys: pnpm-
      - name: Install frontend deps
        working-directory: frontend
        run: pnpm install --frozen-lockfile
      - name: Lint frontend
        working-directory: frontend
        run: pnpm exec eslint .
      - name: Typecheck frontend
        working-directory: frontend
        run: pnpm exec tsc --noEmit

      # --- Rust (for Rust backends) ---
      - name: Cache Rust
        uses: actions/cache@v4
        with:
          path: |
            ~/.cargo/registry
            ~/.cargo/git
            backend/target
          key: rust-lint-${{ hashFiles('backend/Cargo.lock') }}
          restore-keys: rust-lint-
      - name: Clippy
        working-directory: backend
        run: cargo clippy -- -D warnings
      - name: Rustfmt
        working-directory: backend
        run: cargo fmt -- --check

      # --- Terraform ---
      - name: Terraform fmt
        run: terraform fmt -check -recursive infrastructure/terraform/

  deploy:
    if: github.ref == 'refs/heads/main'
    needs: [lint]
    runs-on: ubuntu-latest
    concurrency:
      group: <name>-deploy
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "24"

      # --- pnpm (if frontend) ---
      - name: Install pnpm
        run: corepack enable && corepack prepare pnpm@10.29.3 --activate
      - name: Cache pnpm store
        uses: actions/cache@v4
        with:
          path: ~/.local/share/pnpm/store/v10
          key: pnpm-${{ hashFiles('frontend/pnpm-lock.yaml') }}
          restore-keys: pnpm-

      # --- Rust + cargo-lambda (if Rust backend) ---
      - name: Cache Rust
        uses: actions/cache@v4
        with:
          path: |
            ~/.cargo/registry
            ~/.cargo/git
            backend/target
          key: rust-deploy-${{ hashFiles('backend/Cargo.lock') }}
          restore-keys: rust-deploy-
      - name: Install cargo-lambda
        run: pip3 install cargo-lambda

      # --- AWS credentials ---
      - uses: aws-actions/configure-aws-credentials@v5
        with:
          role-to-assume: ${{ secrets.OIDC_ROLE }}
          role-session-name: GitHubActions-${{ github.run_id }}
          aws-region: us-east-1

      # --- Migrations (if project uses database) ---
      - uses: chris-arsenault/platform/.github/actions/run-migrations@main
        with:
          project: <name>
          migrations-dir: db/migrations

      # --- Deploy ---
      - name: Deploy
        env:
          STATE_BUCKET: ${{ secrets.STATE_BUCKET }}
        run: bash scripts/deploy.sh

  report:
    if: always()
    needs: [lint, deploy]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v5
        with:
          role-to-assume: ${{ secrets.OIDC_ROLE }}
          role-session-name: GitHubActions-${{ github.run_id }}
          aws-region: us-east-1
      - uses: chris-arsenault/platform/.github/actions/report-build@main
        with:
          status: ${{ (needs.deploy.result == 'success' && 'success') || (needs.lint.result == 'failure' && 'failure') || needs.deploy.result }}
          lint-passed: ${{ needs.lint.result == 'success' }}
```

**Caching notes:**
- Use separate cache keys for lint vs deploy (`rust-lint-` vs `rust-deploy-`) since they may build different profiles
- pnpm store caches on lockfile hash — invalidates on dependency changes
- Cargo caches registry + git + target — invalidates on `Cargo.lock` changes
- cargo-lambda can be installed via `pip3 install cargo-lambda` (fastest) or `cargo-binstall` (larger cache)

---

## Step 9: Required Project Files

Every project must include these files in its root. This is not optional.

### README.md

Must include at minimum:
- Project name and one-line description
- Architecture summary (frontend, backend, database, auth)
- URLs (app and API)
- Local development instructions
- Deploy command
- License reference

### LICENSE

Use MIT unless there is a specific reason not to. Match the format in `~/src/platform/LICENSE`.

### CLAUDE.md

Must include at minimum:
- Project name and purpose
- Architecture overview (what runs where)
- Backend structure (crates/packages, Lambda split, shared code)
- Frontend structure (if applicable)
- Build and deploy commands
- Database details (engine, migration location, query approach)
- Key architectural decisions and their rationale

### platform.yml

Required if the project uses the shared database. See Step 5b.

### .gitignore

Must exclude at minimum: build artifacts, dependency directories, Terraform state/lock files, IDE files, environment files.

> **For AI agents:** Generate all of these files as part of the initial project scaffold — not as a follow-up task. If you create a project without a README, LICENSE, or CLAUDE.md, the project is incomplete.

---

## SSM Parameter Reference

All parameters are in `us-east-1`.

### /platform/cognito/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/platform/cognito/user-pool-id` | String | platform-services |
| `/platform/cognito/user-pool-arn` | String | platform-services |
| `/platform/cognito/domain` | String | platform-services |
| `/platform/cognito/clients/<app>` | String | platform-services |
| `/platform/cognito/alb-client-id` | String | platform-services |
| `/platform/cognito/alb-client-secret` | SecureString | platform-services |

### /platform/rds/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/platform/rds/endpoint` | String | platform-services |
| `/platform/rds/address` | String | platform-services |
| `/platform/rds/port` | String | platform-services |
| `/platform/rds/master-username` | String | platform-services |
| `/platform/rds/master-password` | SecureString | platform-services |
| `/platform/rds/security-group-id` | String | platform-services |

### /platform/db/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/platform/db/migrations-bucket` | String | platform-services |
| `/platform/db/migrate-function` | String | platform-services |
| `/platform/db/<project>/username` | String | migration Lambda (auto-created) |
| `/platform/db/<project>/password` | SecureString | migration Lambda (auto-created) |
| `/platform/db/<project>/database` | String | migration Lambda (auto-created) |

### /platform/ci/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/platform/ci/url` | String | platform-services |
| `/platform/ci/ingest-token` | SecureString | platform-services |

### /platform/sonarqube/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/platform/sonarqube/url` | String | platform-services |
| `/platform/sonarqube/ci-token` | SecureString | platform-services |

### /platform/alarms/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/platform/alarms/sns-topic-arn` | String | platform-services |

### /platform/network/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/platform/network/alb-listener-arn` | String | platform-network |
| `/platform/network/alb-arn` | String | platform-network |
| `/platform/network/alb-dns-name` | String | platform-network |
| `/platform/network/alb-zone-id` | String | platform-network |
| `/platform/network/alb-security-group-id` | String | platform-network |
| `/platform/network/vpc-id` | String | platform-network |
| `/platform/network/public-subnet-ids` | StringList | platform-network |
| `/platform/network/private-subnet-ids` | StringList | platform-network |
| `/platform/network/route53-zone-id` | String | platform-network |
