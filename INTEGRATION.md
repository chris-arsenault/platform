# Platform Integration Guide

Instructions for integrating a project with the platform. This document is written for AI agents working in client projects.

## Platform Overview

The platform is a set of shared AWS infrastructure managed across three repos. All projects deploy to a single AWS account (`559098897826`) in `us-east-1`. Cross-project configuration is shared via SSM Parameter Store under the `/platform/*` namespace.

### Repos

| Repo | Path | Purpose |
|------|------|---------|
| `platform-control` | `~/src/platform-control` | Creates per-project deployer IAM roles, S3 state buckets, and injects GitHub Actions secrets (OIDC_ROLE, STATE_BUCKET, PREFIX) |
| `platform-services` | `~/src/platform-services` | Manages shared Cognito user pool, pre-auth Lambda, DynamoDB user-access table, SSM parameter bus, budget/cost alerts |
| `platform-network` | `~/src/platform-network` | Manages VPC (10.42.0.0/16), public/private subnets, shared ALB with HTTPS listener, WireGuard VPN, NAT, Route53 DNS |

### Preferred Application Stack

- **Frontend**: React + Vite (TypeScript)
- **Backend**: Rust Lambdas preferred; TypeScript (Node 24) Lambdas acceptable when Rust is overkill
- **Data**: S3 for most storage needs. DynamoDB when you need key-value lookups. Shared PostgreSQL RDS for relational data.
- **Auth**: Cognito (shared pool for personal projects, separate pool for Glass Frontier)

### Infrastructure Stack

- **IaC**: Terraform >= 1.12, AWS provider ~> 6.0
- **State**: Single S3 bucket (`tfstate-559098897826`) with namespaced keys, native lock files (`use_lockfile = true`)
- **CI/CD**: GitHub Actions with OIDC federation (no long-lived credentials)
- **DNS**: Route53, zone `ahara.io` (zone ID published to SSM)
- **VPC**: Single VPC in us-east-1, two public subnets (AZ a/b), two private subnets (AZ a/b)
- **Database**: Shared PostgreSQL 16 on RDS `db.t4g.micro` — per-project databases on the same instance
- **Load Balancing**: Shared ALB with host-based routing — projects attach their own listener rules and certs
- **NAT**: fck-nat (no NAT Gateway — cost matters)

---

## Step 1: Register the Project in platform-control

Every project that deploys to AWS needs a deployer role. This is created in `platform-control`.

### 1a. Create a project definition file

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

  prefix         = "<short-prefix>"
  policy_modules = ["state", "<additional-policies>"]
}
```

**Fields:**
- `allowed_repos` — GitHub repo names (without owner) that can assume this role
- `prefix` — short unique string used to name the IAM role (`deployer-<prefix>`), state bucket (`tf-state-<prefix>-559098897826`), and scope IAM policies
- `policy_modules` — list of permission sets from the policy library (see below)

### 1b. Choose policy modules

Available modules in `~/src/platform-control/infrastructure/terraform/modules/policy-library/`:

| Module | Grants |
|--------|--------|
| `state` | S3 access to the project's own state bucket |
| `api` | API Gateway, Lambda, CloudWatch Logs |
| `bedrock` | Amazon Bedrock model invocation |
| `control-plane` | IAM role/policy management, GitHub OIDC, S3 buckets |
| `iam` | IAM role/policy management (scoped to prefix) |
| `platform-services` | Cognito, DynamoDB, Lambda, SSM, SNS, ACM, Route53, Budgets |
| `reverse-proxy` | EC2, EBS, EIP, security groups (for proxy instances) |
| `static-website` | S3, CloudFront, Route53, ACM (for static sites) |
| `vpn` | EC2, NLB, EIP, VPC networking (for VPN infrastructure) |

If your project needs permissions not covered by an existing module, create a new one in the policy library.

### 1c. Apply

After merging to main, `platform-control` CI applies automatically. This creates:
- IAM role `deployer-<prefix>` with OIDC trust for the specified GitHub repos
- S3 bucket `tf-state-<prefix>-559098897826` for Terraform state
- GitHub Actions secrets on each repo: `OIDC_ROLE`, `STATE_BUCKET`, `PREFIX`

---

## Step 2: Set Up the Project's Terraform

### 2a. Backend configuration

All projects share a single state bucket (`tfstate-559098897826`). The `key` determines where your state lives within it.

**Key naming convention:**
- Platform repos: `platform/<name>.tfstate` (e.g. `platform/control.tfstate`, `platform/network.tfstate`)
- Consumer projects: `projects/<name>.tfstate` (e.g. `projects/websites.tfstate`, `projects/svap.tfstate`)

**Never use bare `terraform.tfstate`** — the bucket policy denies writes to root-level keys. Always use a `<category>/<name>.tfstate` path.

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

The `bucket` is provided at init time via the deploy script default. The `key` is hardcoded in the backend block and must match the `state_key_prefix` configured in platform-control (your deployer role only has write access to your prefix).

### 2b. Deploy script

Create `scripts/deploy.sh`:

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

The script must be parameterless — `STATE_BUCKET` defaults to the shared bucket and is only overridden in CI via the injected secret.

### 2c. GitHub Actions workflow

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

## Step 3: Consume Platform Resources via SSM

All shared resources are published to SSM Parameter Store. Read them with `data "aws_ssm_parameter"` — never use `terraform_remote_state`.

### Cognito (from platform-services)

For projects that need user authentication against the shared Cognito pool:

```hcl
data "aws_ssm_parameter" "cognito_user_pool_id" {
  name = "/platform/cognito/user-pool-id"
}

data "aws_ssm_parameter" "cognito_user_pool_arn" {
  name = "/platform/cognito/user-pool-arn"
}

data "aws_ssm_parameter" "cognito_domain" {
  name = "/platform/cognito/domain"
}

data "aws_ssm_parameter" "cognito_client_<app>" {
  name = "/platform/cognito/clients/<app>"
}
```

SSM values are marked sensitive by Terraform. Wrap with `nonsensitive()` for non-secret values like pool IDs and client IDs.

**To register a new Cognito client**, add an entry to `var.cognito_clients` in `~/src/platform-services/infrastructure/terraform/variables.tf` and apply. The client ID will be published to `/platform/cognito/clients/<key>`.

**To grant a user access to your app**, add an entry to the `apps` map in the DynamoDB `websites-user-access` table (key: username, value: role string). The pre-auth Lambda checks this table on every login and rejects users without an entry for the requesting app.

### Network (from platform-network)

For projects that need to attach to the shared VPC or ALB:

```hcl
# Shared ALB
data "aws_ssm_parameter" "alb_listener_arn" {
  name = "/platform/network/alb-listener-arn"
}

data "aws_ssm_parameter" "alb_dns_name" {
  name = "/platform/network/alb-dns-name"
}

data "aws_ssm_parameter" "alb_zone_id" {
  name = "/platform/network/alb-zone-id"
}

data "aws_ssm_parameter" "alb_security_group_id" {
  name = "/platform/network/alb-security-group-id"
}

# Cognito for ALB auth actions
data "aws_ssm_parameter" "alb_cognito_pool_arn" {
  name = "/platform/network/alb-cognito-pool-arn"
}

data "aws_ssm_parameter" "alb_cognito_client_id" {
  name = "/platform/network/alb-cognito-client-id"
}

data "aws_ssm_parameter" "alb_cognito_domain" {
  name = "/platform/network/alb-cognito-domain"
}

# VPC
data "aws_ssm_parameter" "vpc_id" {
  name = "/platform/network/vpc-id"
}

data "aws_ssm_parameter" "public_subnet_ids" {
  name = "/platform/network/public-subnet-ids"
}

data "aws_ssm_parameter" "route53_zone_id" {
  name = "/platform/network/route53-zone-id"
}
```

### Attaching a service to the shared ALB

The shared ALB has an HTTPS listener with a default 404 response. To route traffic to your service:

1. Create a target group in the platform VPC
2. Create a listener rule on the shared listener with a host-header condition
3. Manage your own ACM certificate and attach it via `aws_lb_listener_certificate`
4. Create a Route53 alias record pointing to the ALB

```hcl
resource "aws_lb_target_group" "my_service" {
  name        = "<prefix>-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = nonsensitive(data.aws_ssm_parameter.vpc_id.value)
  target_type = "ip"

  health_check {
    path    = "/health"
    matcher = "200"
  }
}

resource "aws_lb_listener_rule" "my_service" {
  listener_arn = nonsensitive(data.aws_ssm_parameter.alb_listener_arn.value)
  priority     = <unique-number>  # must not conflict with other rules

  condition {
    host_header {
      values = ["myservice.ahara.io"]
    }
  }

  # Include authenticate-cognito action if you want ALB-level auth
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
    target_group_arn = aws_lb_target_group.my_service.arn
  }
}

# TLS — manage your own cert and attach to the shared listener
resource "aws_acm_certificate" "my_service" {
  domain_name       = "myservice.ahara.io"
  validation_method = "DNS"
}

resource "aws_lb_listener_certificate" "my_service" {
  listener_arn    = nonsensitive(data.aws_ssm_parameter.alb_listener_arn.value)
  certificate_arn = aws_acm_certificate.my_service.arn
}

# DNS
resource "aws_route53_record" "my_service" {
  zone_id = nonsensitive(data.aws_ssm_parameter.route53_zone_id.value)
  name    = "myservice.ahara.io"
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

Pick a priority that doesn't conflict. Use 200+ for consuming projects.

### SonarQube (from platform-services)

```hcl
data "aws_ssm_parameter" "sonarqube_url" {
  name = "/platform/sonarqube/url"
}

data "aws_ssm_parameter" "sonarqube_ci_token" {
  name = "/platform/sonarqube/ci-token"
}
```

### Shared RDS (from platform-services)

A shared PostgreSQL 16 instance (`db.t4g.micro`) is available for projects that need relational data. Each project should create its own database and application user — do not use the master credentials directly in application code.

```hcl
data "aws_ssm_parameter" "rds_endpoint" {
  name = "/platform/rds/endpoint"
}

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

data "aws_ssm_parameter" "rds_security_group_id" {
  name = "/platform/rds/security-group-id"
}
```

**Creating a per-project database**: Use a `postgresql` Terraform provider or a provisioner to connect with the master credentials and create a project-specific database and user:

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

**Connectivity**: The RDS instance is in the VPC private subnets. Lambdas that need database access must run inside the VPC. Add `vpc_config` to your Lambda:

```hcl
resource "aws_lambda_function" "api" {
  # ...
  vpc_config {
    subnet_ids         = split(",", nonsensitive(data.aws_ssm_parameter.private_subnet_ids.value))
    security_group_ids = [aws_security_group.lambda.id]
  }
}
```

The Lambda's security group must allow outbound traffic to port 5432, and the RDS security group already allows ingress from the VPC CIDR (`10.42.0.0/16`).

### Observability (from platform-services)

To send alarms to the shared SNS topic:

```hcl
data "aws_ssm_parameter" "alarm_topic_arn" {
  name = "/platform/alarms/sns-topic-arn"
}

resource "aws_cloudwatch_metric_alarm" "example" {
  alarm_actions = [nonsensitive(data.aws_ssm_parameter.alarm_topic_arn.value)]
  # ...
}
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

### /platform/sonarqube/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/platform/sonarqube/url` | String | platform-services |
| `/platform/sonarqube/ci-token` | SecureString | platform-services |
| `/platform/sonarqube/cognito-client-id` | String | platform-services |
| `/platform/sonarqube/cognito-client-secret` | SecureString | platform-services |

### /platform/rds/*

| Parameter | Type | Source |
|-----------|------|--------|
| `/platform/rds/endpoint` | String | platform-services |
| `/platform/rds/address` | String | platform-services |
| `/platform/rds/port` | String | platform-services |
| `/platform/rds/master-username` | String | platform-services |
| `/platform/rds/master-password` | SecureString | platform-services |
| `/platform/rds/security-group-id` | String | platform-services |

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

- **Never use `terraform_remote_state`** — read from SSM instead.
- **Deploy scripts must be parameterless** — defaults are baked in, CI overrides via env vars.
- **One deployer role per project** — scoped to least-privilege via the policy library.
- **All resources use the project prefix** — naming convention: `<prefix>-<resource>`.
- **The Glass Frontier Cognito pool is separate** — it has real external users. Everything else uses the shared platform Cognito pool.
- **Cost matters** — single VPC, shared ALBs, no NAT Gateway (fck-nat instead). Avoid creating per-project VPCs or load balancers.
