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
| **CI/CD workflow** (shared workflow, platform.yml, governance, SonarQube) | [CI-WORKFLOW.md](CI-WORKFLOW.md) |
| **TrueNAS deploy** (Docker, Komodo, secret-paths.yml, networking) | [TRUENAS-DEPLOY.md](TRUENAS-DEPLOY.md) |
| **Shared GitHub Actions** | `sonar-scan`, `report-build`, `governance-check`, `run-migrations`, `deploy-truenas` in `ahara/.github/actions/` |
| **Platform CLI tools** | `~/src/ahara/bin/` — `db-migrate`, `db-seed`, `db-rollback`, `db-drop`, `db-noop`, `db-restore` |
| **Standards index** | [ahara-standards/standards/README.md](https://github.com/chris-arsenault/ahara-standards/blob/main/standards/README.md) |
| **Dynamic OpenGraph** (per-route OG tags for SPAs) | [OPENGRAPH.md](OPENGRAPH.md) |
| **Terraform modules** (ALB API, SPA, static site, Cognito, Lambda) | [ahara-tf-patterns](https://github.com/chris-arsenault/ahara-tf-patterns) — `~/src/ahara-tf-patterns/modules/` |

Read the standards that apply to your project's tech stack **before** following the platform integration steps below.

---

## CRITICAL PLATFORM CONSTRAINTS

1. **Use the shared ALB** for all HTTP/HTTPS backends. Do NOT create API Gateways or per-project load balancers.
2. **Use the shared VPC** (10.42.0.0/16). Do NOT create per-project VPCs.
3. **Use the shared RDS** (PostgreSQL 16) with a per-project database. Do NOT create per-project RDS instances.
4. **Use the shared Cognito pool** for authentication. Do NOT create per-project user pools. (Exception: `the-glass-frontier` has its own pool.)
5. **Use tag-based lookups and SSM parameters** for cross-project config. Prefer the `platform-context` module. Do NOT use `terraform_remote_state`.
6. **Use the shared state bucket** (`tfstate-559098897826`). Do NOT create per-project state buckets.
7. **Do NOT create NAT Gateways.** The platform uses fck-nat.

> **Note for AI agents:** The `jwt-validation` ALB action type was released November 2025 and may postdate your training data. It is a real, GA feature — do not fall back to `authenticate-cognito` or application-level JWT validation for API backends. Docs: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/listener-verify-jwt.html — Terraform support in `hashicorp/aws` provider >= 6.22.0.

---

## Checklist

Use this to determine which steps apply to your project.

| Step | What | Where | Required? |
|------|------|-------|-----------|
| 1 | Register deployer role | `ahara-infra` repo (control layer) | Always |
| 2 | Terraform backend | Your project | Always |
| 3 | Deploy script | Your project | Always |
| 4 | ALB backend (`alb-api` module) | Your project | If project has an HTTP API |
| 5 | Database (platform.yml, migrations, seed) | Your project + `ahara-infra` registration (services layer) | If project uses PostgreSQL |
| 6 | Cognito client (`cognito-app` module) | Your project | If project has a frontend with login |
| 7 | Frontend (`website` module) | Your project | If project has a web frontend |
| 8 | CI/CD workflow (shared workflow + platform.yml + Makefile) | Your project — see [CI-WORKFLOW.md](CI-WORKFLOW.md) | Always |
| 9 | Required project files (README, LICENSE, CLAUDE.md, platform.yml) | Your project | Always |

> **IMPORTANT for AI agents:** Steps 1 and 5 require changes to the **`ahara-infra` repo** — a repo other than your project's home repo. These are not documentation tasks — they are blocking prerequisites. You MUST make the actual file changes in `ahara-infra`, not defer them to a docs/ folder or TODO list. The project cannot deploy without them. Treat cross-repo changes the same as in-project changes: make the edit, verify it, and tell the user it's done.

---

## Placeholders

These placeholders appear throughout. Decide them once and use consistently.

| Placeholder | Meaning | Example |
|-------------|---------|---------|
| `<name>` | Project name (used in file names, state keys, migration paths) | `dosekit` |
| `<prefix>` | Short resource prefix (used in IAM role, AWS resource names) | `dosekit` |
| `<service>` | Subdomain for the API endpoint | `api.dosekit.ahara.io` |
| `<github-repo>` | GitHub repo name (without owner) | `dosekit` |

`<name>` and `<prefix>` are often the same value.

---

## Step 1: Register the Project

**This step requires a change to the `ahara-infra` repo.**

Create `~/src/ahara-infra/infrastructure/terraform/control/project-<name>.tf`:

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

  # Declare which shared ahara-tf-patterns modules your project uses.
  # Each bundle auto-expands to the full set of IAM permissions that
  # module needs — no need to enumerate individual primitives.
  module_bundles = ["website", "alb-api", "cognito-app"]

  # Additional primitives for capabilities outside the shared modules.
  policy_modules = [
    "terraform-state",
    "db-migrate",
  ]
}
```

### Module bundles

The preferred way to declare permissions. Each bundle maps to a shared module in `ahara-tf-patterns` and auto-expands to the set of IAM primitives that module needs. When a shared module gains new resource types, the bundle is updated in one place and all consumers pick up the new permissions on the next `ahara-infra` deploy.

| Bundle | Use when your project includes... | Expands to |
|--------|-----------------------------------|-----------|
| `website` | `ahara-tf-patterns/modules/website` | `s3-website`, `cloudfront-distribution`, `acm-dns`, `wafv2`, `kms-admin`, `iam-roles`, `lambda-deploy`, `ssm-write` |
| `alb-api` | `ahara-tf-patterns/modules/alb-api` | `lambda-deploy`, `alb-target-group`, `acm-dns`, `iam-roles` |
| `cognito-app` | `ahara-tf-patterns/modules/cognito-app` | `cognito-client`, `ssm-write` |
| `lambda` | `ahara-tf-patterns/modules/lambda` (standalone) | `lambda-deploy`, `iam-roles` |

### Primitive policy modules

For capabilities outside the shared modules, use primitives directly. These names match the keys in `ahara-infra/infrastructure/terraform/control/modules/managed-project/policy-map.tf`:

| Primitive | When to include |
|-----------|----------------|
| `terraform-state` | **Always** — access to the shared state bucket |
| `db-migrate` | Project uses the shared RDS database and migrations |
| `dynamodb` | Project uses DynamoDB tables |
| `bedrock-inference` | Project uses Bedrock model invocation |
| `sns` | Project publishes to SNS topics |
| `secrets-manager` | Project uses AWS Secrets Manager |
| `komodo-deploy` | Project deploys via Komodo to TrueNAS |
| `ec2-vpc-compute` / `ec2-security-groups` | Project manages EC2 / VPC resources |
| `rds` | Project manages RDS instances (`ahara-infra` only) |
| `cognito-pool` | Project manages the shared Cognito user pool (`ahara-infra` only) |
| `control-plane` | **`ahara-infra` only** — broad privileged access |

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

`scripts/deploy.sh` is a **local-only** convenience script. It runs the full deploy pipeline on the developer's machine: build, migrate, terraform apply. CI does **not** call this script — it replicates the same steps explicitly in the workflow.

This separation exists because:
- CI and local have different auth (OIDC role vs local credentials)
- CI uses the `run-migrations` action; local uses `db-migrate` CLI
- CI needs `if:` guards to skip deploy on PRs; the script always deploys
- Debugging CI failures is easier when steps are visible in the workflow

Create `scripts/deploy.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infrastructure/terraform"

STATE_BUCKET="${STATE_BUCKET:-tfstate-559098897826}"
STATE_REGION="${STATE_REGION:-us-east-1}"

# Build steps — add project-specific builds here
# e.g. cargo lambda build --release, pnpm run build

# Run migrations
db-migrate

# Deploy infrastructure
terraform -chdir="${TF_DIR}" init -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true"

terraform -chdir="${TF_DIR}" apply -auto-approve
```

The CI workflow must replicate these same steps explicitly — see the workflow template below. **Do not call `scripts/deploy.sh` from CI.**

---

## Step 4: Expose a Backend via the Shared ALB

Skip this step if your project has no HTTP API.

Use the [`alb-api`](https://github.com/chris-arsenault/ahara-tf-patterns/tree/main/modules/alb-api) module from `ahara-tf-patterns`. It handles Lambda creation, ALB target groups, listener rules with JWT validation, TLS certificates, and DNS — all from a single module call.

### Single-Lambda API

```hcl
module "api" {
  source   = "git::https://github.com/chris-arsenault/ahara-tf-patterns.git//modules/alb-api"
  prefix   = "<prefix>"
  hostname = "api.<name>.ahara.io"

  environment = {
    DB_HOST     = nonsensitive(data.aws_ssm_parameter.db_host.value)
    DB_USERNAME = nonsensitive(data.aws_ssm_parameter.db_username.value)
    DB_PASSWORD = nonsensitive(data.aws_ssm_parameter.db_password.value)
    DB_NAME     = nonsensitive(data.aws_ssm_parameter.db_database.value)
  }

  lambdas = {
    api = {
      binary = "${path.module}/../../backend/target/lambda/api/bootstrap"
      routes = [
        { priority = <unique-number>, paths = ["/api/*"], authenticated = true }
      ]
    }
  }
}
```

`prefix` must match the project prefix from Step 1 — it scopes all resource names so they fall within the deployer role's IAM permissions.

### Multiple Lambdas on One Hostname

Pass multiple entries in the `lambdas` map. Each gets its own Lambda, target group, and listener rules:

```hcl
module "api" {
  source   = "git::https://github.com/chris-arsenault/ahara-tf-patterns.git//modules/alb-api"
  prefix   = "<prefix>"
  hostname = "api.<name>.ahara.io"

  environment = { DB_HOST = "..." }

  iam_policy = [jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "${aws_s3_bucket.media.arn}/*" },
      { Effect = "Allow", Action = ["bedrock:InvokeModel"], Resource = "*" },
    ]
  })]

  lambdas = {
    tastings-api = {
      binary = "../../backend/target/lambda/tastings-api/bootstrap"
      routes = [
        { priority = 210, paths = ["/tastings", "/tastings/*"], methods = ["GET", "HEAD"], authenticated = false },
        { priority = 211, paths = ["/tastings", "/tastings/*"], authenticated = true },
      ]
    }
    recipes-api = {
      binary = "../../backend/target/lambda/recipes-api/bootstrap"
      routes = [
        { priority = 212, paths = ["/recipes", "/recipes/*"], methods = ["GET", "HEAD"], authenticated = false },
        { priority = 213, paths = ["/recipes", "/recipes/*"], authenticated = true },
      ]
    }
  }
}
```

### Unauthenticated Endpoints

Set `authenticated = false` on routes that should not require a JWT. The `jwt-validation` action is omitted for those rules:

```hcl
routes = [
  { priority = 150, paths = ["/*"], authenticated = false }
]
```

### Non-ALB Lambdas (Async Processing, Triggers)

For Lambdas that are not HTTP-triggered (background processors, Cognito triggers), use the [`lambda`](https://github.com/chris-arsenault/ahara-tf-patterns/tree/main/modules/lambda) module directly. You can reuse the IAM role from `alb-api`:

```hcl
module "processing" {
  source   = "git::https://github.com/chris-arsenault/ahara-tf-patterns.git//modules/lambda"
  name     = "<prefix>-processing"
  binary   = "../../backend/target/lambda/processing/bootstrap"
  role_arn = module.api.role_arn
  timeout  = 300

  environment = { BEDROCK_MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0" }
}
```

For Lambdas that need access to TrueNAS/WireGuard services, set `vpn_access = true`.

### What the module handles internally

- **Lambdas**: `provided.al2023` runtime, `bootstrap` handler, `x86_64`, 256 MB, VPC in private subnets with platform Lambda SG. Binary is zipped automatically.
- **IAM**: Shared role with `AWSLambdaBasicExecutionRole` + `AWSLambdaVPCAccessExecutionRole` + optional inline policy via `iam_policy = [jsonencode(...)]` (list-wrapped to support computed values)
- **ALB**: Target group, target group attachment, Lambda permission, listener rules with optional `jwt-validation`
- **TLS**: ACM certificate with DNS validation, listener certificate attachment
- **DNS**: Route53 A record aliased to the shared ALB. Zone is resolved from the last two labels of `hostname` (e.g. `ahara.io` for `api.tastebase.ahara.io`). Pass an explicit `zone_name` for delegated subzones or multi-label TLDs.
- **Platform discovery**: All lookups (ALB, Cognito, VPC, subnets, SGs) handled internally via `platform-context`

### Module outputs

| Output | Description |
|--------|-------------|
| `function_names` | Map of lambda key → function name |
| `function_arns` | Map of lambda key → function ARN |
| `role_arn` | Shared IAM role ARN (reusable for non-ALB lambdas) |
| `role_name` | Shared IAM role name |
| `hostname` | The configured hostname |

### Listener rule priorities

Existing allocations:

| Priority | Host | Owner |
|----------|------|-------|
| 100 | dashboards.ahara.io | ahara-infra (network) |
| 150 | ci.ahara.io | ahara-infra (services) |

Use 200+ for consumer projects. Do not reuse a priority.

**CORS:** OPTIONS preflight requests are handled platform-wide by a Lambda at ALB priority 1. Do NOT create per-project OPTIONS listener rules. Your Lambda still needs `tower-http CorsLayer` (or equivalent) to add CORS headers on actual (non-preflight) responses.

---

## Step 5: Database

Skip this step if your project does not use PostgreSQL.

### 5a. Register your project

**This step requires a change to the `ahara-infra` repo.**

Add your project to `var.migration_projects` in `~/src/ahara-infra/infrastructure/terraform/services/db-migrate.tf`:

```hcl
variable "migration_projects" {
  default = {
    svap      = { db_name = "svap" }
    dosekit   = { db_name = "dosekit" }
    tastebase = { db_name = "tastebase" }
    <name>    = { db_name = "<name>" }   # <-- add this
  }
}
```

The shared `ahara` database is registered automatically from the root prefix — do not add it to `migration_projects`.

On first migration, the platform automatically:
1. Creates the database
2. Creates an application role (`<name>_app` with login)
3. Grants the role full access on the database and public schema
4. Publishes credentials to SSM at `/ahara/db/<name>/username`, `/ahara/db/<name>/password`, `/ahara/db/<name>/database`

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

All database commands are in `~/src/ahara/bin/` (run `platform-setup` once to add to PATH). Commands operate on the current working directory, read config from `platform.yml`, require no arguments:

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
- uses: chris-arsenault/ahara/.github/actions/run-migrations@main
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
- All operations are audited in the `ahara_ops` database (survives project drops)
- Deploy fails if migrations fail

### 5e. Lambda VPC config and database credentials

If you use the `alb-api` module (Step 4), VPC placement is handled automatically — Lambdas are deployed to private subnets with an egress-all security group. No manual VPC configuration needed.

Pass database credentials as environment variables via the module's `environment` parameter. Read the per-project SSM params published by the migration service:

```hcl
data "aws_ssm_parameter" "db_username" {
  name = "/ahara/db/<name>/username"
}

data "aws_ssm_parameter" "db_password" {
  name = "/ahara/db/<name>/password"
}

data "aws_ssm_parameter" "db_database" {
  name = "/ahara/db/<name>/database"
}

module "api" {
  source   = "git::https://github.com/chris-arsenault/ahara-tf-patterns.git//modules/alb-api"
  prefix   = "<prefix>"
  hostname = "api.<name>.ahara.io"

  environment = {
    DB_HOST     = module.ctx.rds_address
    DB_PORT     = module.ctx.rds_port
    DB_USERNAME = nonsensitive(data.aws_ssm_parameter.db_username.value)
    DB_PASSWORD = nonsensitive(data.aws_ssm_parameter.db_password.value)
    DB_NAME     = nonsensitive(data.aws_ssm_parameter.db_database.value)
  }

  lambdas = { ... }
}
```

Use per-project credentials — not the master credentials. The master credentials (`/ahara/rds/master-*`) are for platform-internal services only.

If you need RDS host/port without the full `alb-api` module, use `platform-context`:

```hcl
module "ctx" {
  source = "git::https://github.com/chris-arsenault/ahara-tf-patterns.git//modules/platform-context"
}
# module.ctx.rds_address, module.ctx.rds_port, etc.
```

---

## Step 6: Cognito Client

Skip this step if your project has no frontend with login.

Auth is handled at the ALB (Step 4). Your frontend needs a Cognito client to obtain tokens. **Create it in your own project** — no `ahara-infra` change required.

Include `"cognito-client"` in your `policy_modules` (Step 1), then use the [`cognito-app`](https://github.com/chris-arsenault/ahara-tf-patterns/tree/main/modules/cognito-app) module:

### SPA client (most apps)

```hcl
module "cognito" {
  source = "git::https://github.com/chris-arsenault/ahara-tf-patterns.git//modules/cognito-app"
  name   = "<prefix>-app"
}
```

This creates a public client (no secret) with standard auth flows and publishes the client ID to SSM at `/ahara/cognito/clients/<prefix>-app`.

### Server/OAuth client (e.g. MCP connector)

For confidential clients that need an authorization code grant:

```hcl
module "cognito_mcp" {
  source        = "git::https://github.com/chris-arsenault/ahara-tf-patterns.git//modules/cognito-app"
  name          = "<prefix>-mcp"
  callback_urls = ["https://claude.ai/api/mcp/auth_callback"]
  logout_urls   = ["https://claude.ai/api/mcp/auth_logout"]
}
```

This creates a confidential client (with secret) and enables OAuth code flow with `openid`, `profile`, `email` scopes.

### Module outputs

| Output | Description |
|--------|-------------|
| `client_id` | Cognito user pool client ID |
| `client_secret` | Client secret (sensitive, only set for server clients) |

Pass the client ID and pool ID to your frontend as runtime config (see Step 7). The frontend uses `amazon-cognito-identity-js` with an in-app login form and sends `Authorization: Bearer <access_token>` on every API request.

**To grant user access**: add an entry to the `apps` map in DynamoDB table `websites-user-access` (key: username, field: `apps.<name>` = role string). The pre-auth Lambda checks this on every login.

---

## Step 7: Frontend Deployment

Skip this step if your project has no web frontend.

Use the [`website`](https://github.com/chris-arsenault/ahara-tf-patterns/tree/main/modules/website) module. It deploys files to S3 behind CloudFront with a custom domain, ACM certificate, WAF, KMS encryption, and CloudFront invalidation on deploy.

Include `"website"` in your `module_bundles` (Step 1) — it auto-grants all required IAM permissions including `s3-website`, `cloudfront-distribution`, `acm-dns`, `wafv2` (CloudFront-scoped), and `kms-admin`.

### SPA (React, Vue, etc.)

```hcl
module "frontend" {
  source         = "git::https://github.com/chris-arsenault/ahara-tf-patterns.git//modules/website"
  prefix         = "<prefix>"
  hostname       = "<name>.ahara.io"
  site_directory = "${path.module}/../../frontend/dist"

  runtime_config = {
    cognitoUserPoolId = module.ctx.cognito_user_pool_id
    cognitoClientId   = module.cognito.client_id
    apiBaseUrl        = "https://api.<name>.ahara.io"
  }
}
```

`prefix` must match the project prefix from Step 1 — it's used for the S3 bucket name, KMS key, WAF, and all other resources.

The `runtime_config` map is injected as `window.__APP_CONFIG__` via a `config.js` file (served with `no-cache`). `index.html` is also `no-cache`; all other assets are `immutable` with 1-year max-age. SPA routing (404/403 → index.html) is enabled by default.

### Multiple hostnames

To serve one CloudFront distribution from multiple FQDNs (apex + subdomains, or hostnames across multiple Route53 zones), pass `aliases`:

```hcl
module "frontend" {
  source         = "git::https://github.com/chris-arsenault/ahara-tf-patterns.git//modules/website"
  prefix         = "tsonu-music"
  hostname       = "music.tsonu.com"
  aliases        = ["tsonu.com", "www.tsonu.com", "music.ahara.io"]
  site_directory = "..."
}
```

Each alias is added to the CloudFront distribution, covered by the ACM cert as a SAN, and given an A/AAAA record in the appropriate Route53 zone. Zones are auto-derived from each hostname (last 2 labels) — Route53 zones for both `tsonu.com` and `ahara.io` must exist in the AWS account. No IAM changes needed; the `acm-dns` policy already covers all hosted zones.

### With dynamic OpenGraph tags

Add `og_config` to deploy the platform OG server as a CloudFront origin. The OG server generates HTML with per-route meta tags for social media link previews:

```hcl
module "frontend" {
  source         = "git::https://github.com/chris-arsenault/ahara-tf-patterns.git//modules/website"
  prefix         = "<prefix>"
  hostname       = "<name>.ahara.io"
  site_directory = "${path.module}/../../frontend/dist"
  runtime_config = { ... }

  og_config = {
    site_name = "<Name>"
    defaults = {
      title       = "<Name>"
      description = "Default description"
      image       = "/social.png"
    }
    routes = [
      {
        pattern     = "/items/:slug"
        query       = "SELECT title, description, image_url FROM items"
        match_field = "title"
        title       = "{{title}}"
        description = "{{description}}"
        image       = "{{image_url}}"
      }
    ]
    environment = { DB_HOST = "...", DB_USERNAME = "...", DB_PASSWORD = "...", DB_NAME = "..." }
  }
}
```

When `og_config` is set, the module deploys the platform OG server Lambda (from S3 artifact published by `ahara-infra`), creates a function URL, and configures CloudFront with dual origins (S3 for static assets, Lambda for HTML). The SPA error fallback is replaced by the Lambda handling all HTML routes.

### Optional parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `encrypt` | `true` | KMS encryption on the S3 bucket |
| `og_config` | `null` | OpenGraph route configuration (see above) |

### Module outputs

| Output | Description |
|--------|-------------|
| `url` | Full HTTPS URL |
| `hostname` | The configured hostname |
| `bucket_name` | S3 bucket name (for CI artifact uploads) |
| `distribution_id` | CloudFront distribution ID |
| `distribution_arn` | CloudFront distribution ARN |
| `distribution_domain_name` | CloudFront domain name |

---

## Step 8: CI/CD Workflow

See **[CI-WORKFLOW.md](CI-WORKFLOW.md)** for full details.

Standard projects use the shared reusable workflow — the entire `.github/workflows/ci.yml` is:

```yaml
name: CI/CD

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  ci:
    uses: chris-arsenault/ahara/.github/workflows/ci.yml@main
    secrets: inherit
```

The shared workflow reads `platform.yml` and runs lint, test, sonar, deploy, and reporting automatically. No per-project configuration needed beyond declaring the stack.

For TrueNAS-hosted services, see **[TRUENAS-DEPLOY.md](TRUENAS-DEPLOY.md)**.

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

Use MIT unless there is a specific reason not to. Match the format in `~/src/ahara/LICENSE`.

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

## Resource Discovery Reference

The [`platform-context`](https://github.com/chris-arsenault/ahara-tf-patterns/tree/main/modules/platform-context) module reads all commonly-needed platform resources automatically. You only need raw lookups for per-project database credentials (`/ahara/db/<project>/*`).

### Tag-Based Lookups (preferred)

Use tags to discover shared infrastructure. These are resilient to resource replacement — the tag moves with the resource.

| Resource Type | Tag | Values | Data Source | Attributes |
|---------------|-----|--------|-------------|------------|
| VPC | `vpc:role` | `ahara` | `data "aws_vpc"` | `id`, `cidr_block` |
| Subnets | `subnet:access` | `private`, `public` | `data "aws_subnets"` | `ids` |
| ALB | `lb:role` | `ahara` | `data "aws_lb"` | `arn`, `dns_name`, `zone_id` |
| ALB Listener | *(derived from ALB)* | | `data "aws_lb_listener"` port 443 | `arn` |
| Security Group | `sg:role` + `sg:scope` | See table below | `data "aws_security_group"` | `id` |
| Route53 Zone | *(name-based)* | `ahara.io.` | `data "aws_route53_zone"` | `zone_id` |

**Security group tags:**

| `sg:role` | `sg:scope` | Purpose | Owner |
|-----------|-----------|---------|-------|
| `lambda` | `ahara` | Shared Lambda egress | ahara-infra (network) |
| `alb` | `public` | ALB public ingress | ahara-infra (network) |
| `rds` | `ahara` | Shared RDS access | ahara-infra (services) |
| `nat` | `internet` | NAT instance | ahara-infra (network) |
| `reverse-proxy` | `base` | Reverse proxy base | ahara-infra (network) |
| `reverse-proxy` | `<hostname>` | Per-service proxy | ahara-infra (network) |
| `vpn-client` | `ahara` | Opt-in Lambda VPN access | ahara-infra (network) |
| `wireguard` | `truenas` | VPN tunnel | ahara-infra (network) |

### SSM Parameters

SSM is used for values that aren't discoverable via tags (Cognito, RDS connection details, CI tokens).

All platform SSM parameters are published by the `ahara-infra` services layer unless noted otherwise.

#### /ahara/cognito/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/ahara/cognito/user-pool-id` | String | ahara-infra |
| `/ahara/cognito/user-pool-arn` | String | ahara-infra |
| `/ahara/cognito/domain` | String | ahara-infra |
| `/ahara/cognito/issuer-url` | String | ahara-infra |
| `/ahara/cognito/clients/<app>` | String | ahara-infra / cognito-app module |
| `/ahara/cognito/alb-client-id` | String | ahara-infra |
| `/ahara/cognito/alb-client-secret` | SecureString | ahara-infra |

#### /ahara/rds/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/ahara/rds/endpoint` | String | ahara-infra |
| `/ahara/rds/address` | String | ahara-infra |
| `/ahara/rds/port` | String | ahara-infra |
| `/ahara/rds/master-username` | String | ahara-infra |
| `/ahara/rds/master-password` | SecureString | ahara-infra |

#### /ahara/db/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/ahara/db/migrations-bucket` | String | ahara-infra |
| `/ahara/db/migrate-function` | String | ahara-infra |
| `/ahara/db/<project>/username` | String | migration Lambda (auto-created) |
| `/ahara/db/<project>/password` | SecureString | migration Lambda (auto-created) |
| `/ahara/db/<project>/database` | String | migration Lambda (auto-created) |

#### /ahara/ci/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/ahara/ci/url` | String | ahara-infra |
| `/ahara/ci/ingest-token` | SecureString | ahara-infra |

#### /ahara/sonarqube/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/ahara/sonarqube/url` | String | ahara-infra |
| `/ahara/sonarqube/ci-token` | SecureString | ahara-infra |

#### /ahara/alarms/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/ahara/alarms/sns-topic-arn` | String | ahara-infra |
