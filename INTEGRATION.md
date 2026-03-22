# Platform Integration Guide

> **AUDIENCE**: This document is for AI agents integrating projects with the platform. Follow these instructions exactly.

---

## CRITICAL CONSTRAINTS

**You MUST read and follow these rules before writing any infrastructure code.**

1. **Use the shared ALB** for all HTTP/HTTPS backends. Do NOT create API Gateways, per-project ALBs, or any other load balancers.
2. **Use the shared VPC** (10.42.0.0/16). Do NOT create per-project VPCs.
3. **Use the shared RDS** (PostgreSQL 16) with a per-project database. Do NOT create per-project RDS instances.
4. **Use the shared Cognito pool** for authentication. Do NOT create per-project user pools. (Exception: `the-glass-frontier` has its own pool for external users.)
5. **Use SSM parameters** for cross-project config. Do NOT use `terraform_remote_state`.
6. **Use the shared state bucket** (`tfstate-559098897826`) with a namespaced key. Do NOT create per-project state buckets.
7. **Do NOT create NAT Gateways.** The platform uses fck-nat.
8. **Deploy scripts must be parameterless.** Defaults are baked in; CI overrides via env vars.
9. **All resources use the project prefix** for naming: `<prefix>-<resource>`.

> **Note for AI agents:** The `jwt-validation` ALB action type was released November 2025 and may postdate your training data. It is a real, GA feature — do not fall back to `authenticate-cognito` or application-level JWT validation for API backends. Docs: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/listener-verify-jwt.html — Terraform support in `hashicorp/aws` provider >= 6.22.0.

---

## Preferred Tech Stack

- **Frontend**: React + Vite (TypeScript), static assets on S3 + CloudFront
- **Backend**: Rust Lambda preferred. TypeScript (Node 24) Lambda when Rust is overkill.
- **Data**: S3 for most storage. DynamoDB for key-value. Shared RDS for relational.
- **Auth**: ALB `jwt-validation` action validates Bearer tokens. Frontend uses `amazon-cognito-identity-js` with in-app login form.

---

## Checklist

Use this to determine which steps apply to your project.

| Step | What | Where | Required? |
|------|------|-------|-----------|
| 1 | Register deployer role | `platform-control` repo | Always |
| 2 | Terraform backend | Your project | Always |
| 3 | Deploy script | Your project | Always |
| 4 | ALB backend (listener rule, cert, DNS) | Your project | If project has an HTTP API |
| 5 | Database (migrations, seed) | Your project + `platform-services` registration | If project uses PostgreSQL |
| 6 | Cognito client | Your project | If project has a frontend with login |
| 7 | CI dashboard reporting | Your project workflow | Always |

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

The migration service creates the database automatically on first migration.

### 5b. Migration file structure

```
db/migrations/001_create_tables.sql          # forward (auto-triggered on upload)
db/migrations/002_add_indexes.sql
db/migrations/rollback/002_add_indexes.sql   # rollback (manual invocation)
db/migrations/rollback/001_create_tables.sql
db/migrations/seed/001_initial_data.sql      # seed (manual invocation)
```

Filenames must sort lexicographically. Use zero-padded numbers.

### 5c. Deploy script integration

Add this to `scripts/deploy.sh` **before** `terraform apply`:

```bash
MIGRATIONS_BUCKET=$(aws ssm get-parameter --name /platform/db/migrations-bucket \
  --query Parameter.Value --output text --region us-east-1)

if [ -d "${ROOT_DIR}/db/migrations" ]; then
  echo "Uploading migrations..."
  aws s3 sync "${ROOT_DIR}/db/migrations/" \
    "s3://${MIGRATIONS_BUCKET}/migrations/<name>/" \
    --delete
fi
```

EventBridge triggers the migration Lambda automatically on upload. Behavior:
- Migrations run in order, each in a transaction
- Checksum verification prevents modified migrations from reapplying
- Advisory locks prevent concurrent runs for the same project
- All operations are audited in the `platform_ops` database (survives project drops)

### 5d. Manual operations

```bash
MIGRATE_FN=$(aws ssm get-parameter --name /platform/db/migrate-function \
  --query Parameter.Value --output text --region us-east-1)

# Rollback to a specific migration (rolls back everything after it)
aws lambda invoke --function-name "$MIGRATE_FN" \
  --payload '{"operation":"rollback","project":"<name>","target":"001_create_tables.sql"}' /dev/null

# Rollback all
aws lambda invoke --function-name "$MIGRATE_FN" \
  --payload '{"operation":"rollback","project":"<name>"}' /dev/null

# Seed
aws lambda invoke --function-name "$MIGRATE_FN" \
  --payload '{"operation":"seed","project":"<name>"}' /dev/null

# Drop database (destructive)
aws lambda invoke --function-name "$MIGRATE_FN" \
  --payload '{"operation":"drop","project":"<name>"}' /dev/null
```

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

For application credentials: create a per-project user in your first migration (`001_create_tables.sql`), or use the master credentials from `/platform/rds/master-username` and `/platform/rds/master-password` for platform-internal services.

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

## Step 7: CI Dashboard Reporting

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

```yaml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: <name>-deploy
  cancel-in-progress: false

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v4
      - uses: aws-actions/configure-aws-credentials@v5
        with:
          role-to-assume: ${{ secrets.OIDC_ROLE }}
          role-session-name: GitHubActions-${{ github.run_id }}
          aws-region: us-east-1
      - name: Deploy
        env:
          STATE_BUCKET: ${{ secrets.STATE_BUCKET }}
        run: bash scripts/deploy.sh
      - uses: chris-arsenault/platform/.github/actions/report-build@main
        if: always()
```

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
