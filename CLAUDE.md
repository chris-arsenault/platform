# Platform

Index repo for the platform layer. Contains documentation, CI tooling, shared workflows, and orchestration scripts.

## Contents

- `INTEGRATION.md` — canonical integration guide for AI agents
- `CI-WORKFLOW.md` — shared reusable CI/CD workflow, platform.yml, governance, SonarQube
- `TRUENAS-DEPLOY.md` — TrueNAS deploy pattern (Docker, Komodo, networking)
- `.github/workflows/ci.yml` — shared reusable workflow (called by all standard projects)
- `.github/actions/` — sonar-scan, report-build, governance-check, run-migrations, deploy-truenas

## Do not add infrastructure here

Terraform and application code belong in `ahara-infra`, under the appropriate layer:
- `infrastructure/terraform/control/` — IAM roles, OIDC, deployer roles, policy library
- `infrastructure/terraform/network/` — VPC, ALB, WireGuard VPN, NAT, DNS, WAF
- `infrastructure/terraform/services/` — Cognito, RDS, database migrations, CI ingest, auth-trigger, CORS, komodo-proxy, OG server, observability

All three layers share a single Terraform state (`ahara/infra.tfstate`) and deploy via one `terraform apply`.

## Related repos (all under ~/src/)

- `ahara-infra` — single consolidated infrastructure repo; Rust Lambda workspace in `backend/`, platform migrations in `db/migrations/`, one OIDC deployer role for the whole stack
- `nas-sonarqube` — SonarQube on TrueNAS, CI token Lambda
- `ahara-portal` — platform front door, user admin, auth management
