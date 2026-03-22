# Platform

Index repo for the platform layer. Contains documentation, CI tooling, and orchestration scripts.

## Contents

- `INTEGRATION.md` — canonical integration guide for AI agents
- `README.md` — repo map and deploy order
- `.github/actions/report-build/` — composite action for CI dashboard (used by all project workflows)
- `scripts/deploy-all.sh` — deploys platform-control → platform-services → platform-network
- `scripts/migrate-state.sh` — one-time state bucket migration (already run)

## Do not add infrastructure here

Terraform and application code belong in:
- `platform-control` — IAM roles, OIDC, shared state bucket
- `platform-services` — Cognito, RDS, database migrations, CI ingest, observability
- `platform-network` — VPC, ALB, VPN, DNS

## Related repos (all under ~/src/)

- `platform-control` — deploys first, creates deployer roles for all other repos
- `platform-services` — shared Cognito pool, PostgreSQL RDS, migration service, CI dashboard Lambda
- `platform-network` — single VPC, shared ALB with jwt-validation, WireGuard VPN
- `truenas` — TrueNAS server management, Docker Compose stacks
