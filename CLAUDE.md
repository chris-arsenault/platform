# Platform

Index repo for the platform layer. Contains documentation, CI tooling, shared workflows, and orchestration scripts.

## Contents

- `INTEGRATION.md` — canonical integration guide for AI agents
- `CI-WORKFLOW.md` — shared reusable CI/CD workflow, platform.yml, governance, SonarQube
- `TRUENAS-DEPLOY.md` — TrueNAS deploy pattern (Docker, Komodo, networking)
- `.github/workflows/ci.yml` — shared reusable workflow (called by all standard projects)
- `.github/actions/` — sonar-scan, report-build, governance-check, run-migrations, deploy-truenas
- `scripts/deploy-all.sh` — deploys platform-control → platform-services → platform-network

## Do not add infrastructure here

Terraform and application code belong in:
- `platform-control` — IAM roles, OIDC, shared state bucket
- `platform-services` — Cognito, RDS, database migrations, CI ingest
- `platform-network` — VPC, ALB, VPN, DNS

## Related repos (all under ~/src/)

- `platform-control` — deploys first, creates deployer roles for all other repos
- `platform-services` — shared Cognito pool, PostgreSQL RDS, migration service, CI dashboard Lambda
- `platform-network` — single VPC, shared ALB with jwt-validation, WireGuard VPN
- `nas-sonarqube` — SonarQube on TrueNAS, CI token Lambda
- `ahara-portal` — platform front door, user admin, auth management
