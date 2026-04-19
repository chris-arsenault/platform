# Platform

Index repo for the platform layer — shared AWS infrastructure, identity, deployment management, and CI tooling.

## Repos

| Repo | Purpose | Path |
|------|---------|------|
| [ahara-infra](https://github.com/chris-arsenault/ahara-infra) | Consolidated AWS infrastructure — IAM/OIDC/deployer roles (control), VPC/ALB/VPN/DNS (network), Cognito/RDS/migrations/CI ingest/observability (services) — single Terraform state, plus the Rust Lambda workspace and platform DB migrations | `~/src/ahara-infra` |
| [nas-sonarqube](https://github.com/chris-arsenault/nas-sonarqube) | SonarQube on TrueNAS — Docker Compose, CI token Lambda | `~/src/nas-sonarqube` |
| [ahara-tf-patterns](https://github.com/chris-arsenault/ahara-tf-patterns) | Reusable Terraform modules — ALB API, SPA, static site, Cognito, Lambda | `~/src/ahara-tf-patterns` |

## Deploy Order

```
ahara-infra   (single Terraform apply — control + network + services resolve via the module DAG)
       │
       └── consuming projects (websites, svap, tastebase, dosekit, etc.)
```

Deploy: `cd ~/src/ahara-infra && ./scripts/deploy.sh`

## This Repo Also Contains

- `INTEGRATION.md` — canonical instructions for AI agents integrating projects with the platform
- `CI-WORKFLOW.md` — shared reusable CI/CD workflow, platform.yml, governance, SonarQube
- `TRUENAS-DEPLOY.md` — TrueNAS deploy pattern (Docker, Komodo, secret-paths.yml)
- `.github/workflows/ci.yml` — shared reusable CI/CD workflow (called by all standard projects)
- `.github/actions/` — `sonar-scan`, `report-build`, `governance-check`, `run-migrations`, `deploy-truenas`

## Integration

See [INTEGRATION.md](INTEGRATION.md) for full instructions.
