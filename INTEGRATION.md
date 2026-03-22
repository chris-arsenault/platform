# Platform Integration Guide

**This document is for AI agents.** Follow these instructions exactly when integrating a project. Do not create per-project VPCs, load balancers, API Gateways, or Cognito pools. All of these exist as shared infrastructure — use them.

## Mandatory Architecture

Every project on this platform MUST use the following shared infrastructure:

- **Shared ALB** for all HTTP/HTTPS traffic — attach a listener rule, do NOT create an API Gateway
- **Shared VPC** — deploy all networked resources (Lambdas, RDS connections, containers) into the platform VPC, do NOT create a new VPC
- **Shared Cognito** — use the platform user pool for authentication, do NOT create a new user pool (exception: the-glass-frontier has its own pool for external users)
- **Shared RDS** — use the platform PostgreSQL instance with a per-project database, do NOT create a new RDS instance
- **Shared state bucket** — store Terraform state in `tfstate-559098897826` with a namespaced key, do NOT create a new state bucket
- **SSM for cross-project config** — read shared resource IDs from `/platform/*` SSM parameters, do NOT use `terraform_remote_state`

## Preferred Tech Stack

- **Frontend**: React + Vite (TypeScript), deployed as static assets to S3 + CloudFront
- **Backend**: Rust Lambda behind the shared ALB. TypeScript (Node 24) Lambda acceptable when Rust is overkill
- **Data**: S3 for most storage. DynamoDB for key-value lookups. Shared RDS (PostgreSQL 16) for relational data
- **Auth**: Shared Cognito pool — ALB handles authentication automatically via `authenticate-cognito` action

## Do NOT Use

- **API Gateway** — the shared ALB replaces this. API Gateway creates per-project endpoints, costs more, and fragments routing
- **Per-project VPCs** — everything runs in the platform VPC (10.42.0.0/16)
- **Per-project load balancers** — attach to the shared ALB via listener rules
- **NAT Gateway** — the platform uses fck-nat. Do not create NAT Gateways
- **Per-project Cognito pools** — use the shared pool (exception: the-glass-frontier)
- **Per-project RDS instances** — use the shared instance with a per-project database

---

## Step 1: Register the Project

Create `~/src/platform-control/infrastructure/terraform/project-<name>.tf`:

```hcl
module "<name>_project" {
  source = "./modules/managed-project"

  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  account_id        = local.account_id

  github_pat         = var.github_pat
  allowed_repos      = ["<github-repo-name>"]
  allowed_branches   = ["main"]
  allow_pull_request = true

  prefix           = "<short-prefix>"
  state_key_prefix = "projects/<name>"
  policy_modules   = ["state", "<additional-policies>"]
}
```

**Fields:**
- `prefix` — short unique string for IAM role (`deployer-<prefix>`) and resource naming (`<prefix>-*`)
- `state_key_prefix` — S3 key prefix for state files. Platform repos use `platform`, consumer projects use `projects/<name>`
- `policy_modules` — permissions from the policy library:

| Module | Use when your project needs |
|--------|----------------------------|
| `state` | Always required — access to the shared state bucket |
| `api` | Lambda functions, CloudWatch Logs |
| `bedrock` | Bedrock model invocation |
| `iam` | Creating IAM roles scoped to your prefix |
| `static-website` | S3 + CloudFront static sites |
| `platform-services` | Cognito, DynamoDB, SSM writes, SNS, ACM, Route53 |

---

## Step 2: Terraform Backend

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
      Project   = "<Project Name>"
      ManagedBy = "Terraform"
    }
  }
}
```

**Key naming:** `platform/<name>.tfstate` for platform repos, `projects/<name>.tfstate` for everything else. Never use bare `terraform.tfstate` — the bucket policy denies it.

---

## Step 3: Deploy Script

Create `scripts/deploy.sh` (must be parameterless):

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infrastructure/terraform"

STATE_BUCKET="${STATE_BUCKET:-tfstate-559098897826}"
STATE_REGION="${STATE_REGION:-us-east-1}"

terraform -chdir="${TF_DIR}" init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true"

terraform -chdir="${TF_DIR}" apply -auto-approve
```

Add build steps before `terraform init` if your project has Lambda code or frontend assets.

---

## Step 4: Expose a Backend via the Shared ALB

This is how every backend service MUST be exposed. Do not use API Gateway.

```hcl
# --- Read platform SSM params ---

data "aws_ssm_parameter" "alb_listener_arn" {
  name = "/platform/network/alb-listener-arn"
}

data "aws_ssm_parameter" "alb_dns_name" {
  name = "/platform/network/alb-dns-name"
}

data "aws_ssm_parameter" "alb_zone_id" {
  name = "/platform/network/alb-zone-id"
}

data "aws_ssm_parameter" "vpc_id" {
  name = "/platform/network/vpc-id"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/platform/network/private-subnet-ids"
}

data "aws_ssm_parameter" "route53_zone_id" {
  name = "/platform/network/route53-zone-id"
}

data "aws_ssm_parameter" "alb_cognito_pool_arn" {
  name = "/platform/network/alb-cognito-pool-arn"
}

data "aws_ssm_parameter" "alb_cognito_client_id" {
  name = "/platform/network/alb-cognito-client-id"
}

data "aws_ssm_parameter" "alb_cognito_domain" {
  name = "/platform/network/alb-cognito-domain"
}

# --- Target group for your Lambda ---

resource "aws_lb_target_group" "api" {
  name        = "<prefix>-api-tg"
  target_type = "lambda"
}

resource "aws_lb_target_group_attachment" "api" {
  target_group_arn = aws_lb_target_group.api.arn
  target_id        = aws_lambda_function.api.arn
  depends_on       = [aws_lambda_permission.alb]
}

resource "aws_lambda_permission" "alb" {
  statement_id  = "AllowALBInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.api.arn
}

# --- Listener rule (Cognito auth + forward) ---

resource "aws_lb_listener_rule" "api" {
  listener_arn = nonsensitive(data.aws_ssm_parameter.alb_listener_arn.value)
  priority     = <unique-number>  # 200+ for consumer projects, must not conflict

  condition {
    host_header {
      values = ["<service>.ahara.io"]
    }
  }

  action {
    type  = "authenticate-cognito"
    order = 1

    authenticate_cognito {
      user_pool_arn              = nonsensitive(data.aws_ssm_parameter.alb_cognito_pool_arn.value)
      user_pool_client_id        = nonsensitive(data.aws_ssm_parameter.alb_cognito_client_id.value)
      user_pool_domain           = nonsensitive(data.aws_ssm_parameter.alb_cognito_domain.value)
      on_unauthenticated_request = "authenticate"
      scope                      = "openid email profile"
      session_cookie_name        = "alb-auth"
      session_timeout            = 3600
    }
  }

  action {
    type             = "forward"
    order            = 2
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# --- TLS cert (managed by your project, attached to shared listener) ---

resource "aws_acm_certificate" "api" {
  domain_name       = "<service>.ahara.io"
  validation_method = "DNS"
}

resource "aws_route53_record" "api_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.api.domain_validation_options :
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

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for r in aws_route53_record.api_cert_validation : r.fqdn]
}

resource "aws_lb_listener_certificate" "api" {
  listener_arn    = nonsensitive(data.aws_ssm_parameter.alb_listener_arn.value)
  certificate_arn = aws_acm_certificate_validation.api.certificate_arn
}

# --- DNS ---

resource "aws_route53_record" "api" {
  zone_id = nonsensitive(data.aws_ssm_parameter.route53_zone_id.value)
  name    = "<service>.ahara.io"
  type    = "A"

  alias {
    name                   = nonsensitive(data.aws_ssm_parameter.alb_dns_name.value)
    zone_id                = nonsensitive(data.aws_ssm_parameter.alb_zone_id.value)
    evaluate_target_health = true
  }
}
```

**Listener rule priorities** — existing allocations:
- 100: reverse proxy (dashboards.ahara.io) — owned by platform-network

Use 200+ for consumer projects. Do not reuse an existing priority.

Omit the `authenticate-cognito` action only if the service is intentionally public.

---

## Step 5: Connect to Shared RDS

For projects that need relational data. Use the shared PostgreSQL 16 instance — do not create a new one.

```hcl
data "aws_ssm_parameter" "rds_address" {
  name = "/platform/rds/address"
}

data "aws_ssm_parameter" "rds_port" {
  name = "/platform/rds/port"
}

data "aws_ssm_parameter" "rds_master_username" {
  name = "/platform/rds/master-username"
}

data "aws_ssm_parameter" "rds_master_password" {
  name = "/platform/rds/master-password"
}
```

Create a per-project database and user:

```hcl
provider "postgresql" {
  host     = nonsensitive(data.aws_ssm_parameter.rds_address.value)
  port     = nonsensitive(data.aws_ssm_parameter.rds_port.value)
  username = nonsensitive(data.aws_ssm_parameter.rds_master_username.value)
  password = data.aws_ssm_parameter.rds_master_password.value
  sslmode  = "require"
}

resource "postgresql_role" "app" {
  name     = "<project>_app"
  login    = true
  password = random_password.db_app.result
}

resource "postgresql_database" "app" {
  name  = "<project>"
  owner = postgresql_role.app.name
}
```

Lambdas accessing RDS must run in the VPC:

```hcl
resource "aws_lambda_function" "api" {
  # ...
  vpc_config {
    subnet_ids         = split(",", nonsensitive(data.aws_ssm_parameter.private_subnet_ids.value))
    security_group_ids = [aws_security_group.lambda.id]
  }
}
```

---

## Step 6: Cognito Authentication

The shared Cognito pool is used for all personal projects. If your backend is behind the shared ALB with an `authenticate-cognito` action (Step 4), auth is handled automatically — the ALB injects user claims into the request headers.

To register a new Cognito client for your app, add an entry to `var.cognito_clients` in `~/src/platform-services/infrastructure/terraform/variables.tf`.

To grant a user access to your app, add an entry to the `apps` map in the DynamoDB `websites-user-access` table. The pre-auth Lambda checks this table on every login.

For frontend apps that need to initiate the OAuth flow directly:

```hcl
data "aws_ssm_parameter" "cognito_user_pool_id" {
  name = "/platform/cognito/user-pool-id"
}

data "aws_ssm_parameter" "cognito_domain" {
  name = "/platform/cognito/domain"
}

data "aws_ssm_parameter" "cognito_client" {
  name = "/platform/cognito/clients/<app>"
}
```

---

## GitHub Actions Workflow

```yaml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: <project>-deploy
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

### /platform/rds/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/platform/rds/endpoint` | String | platform-services |
| `/platform/rds/address` | String | platform-services |
| `/platform/rds/port` | String | platform-services |
| `/platform/rds/master-username` | String | platform-services |
| `/platform/rds/master-password` | SecureString | platform-services |
| `/platform/rds/security-group-id` | String | platform-services |

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
| `/platform/network/alb-cognito-pool-arn` | String | platform-network |
| `/platform/network/alb-cognito-client-id` | String | platform-network |
| `/platform/network/alb-cognito-domain` | String | platform-network |

---

## Rules

- **Use the shared ALB** — do not create API Gateways or per-project load balancers
- **Use the shared VPC** — do not create per-project VPCs
- **Use the shared RDS** — do not create per-project database instances
- **Use the shared Cognito pool** — do not create per-project user pools (exception: the-glass-frontier)
- **Use SSM for cross-project config** — do not use `terraform_remote_state`
- **Deploy scripts must be parameterless** — defaults baked in, CI overrides via env vars
- **One deployer role per project** — scoped to least-privilege via the policy library
- **All resources use the project prefix** — naming convention: `<prefix>-<resource>`
- **Cost matters** — single VPC, shared ALB, shared RDS, fck-nat. Every new resource should use existing shared infrastructure first
