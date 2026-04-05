# Platform

Index repo for the platform layer — shared AWS infrastructure, identity, deployment management, and CI tooling.

## Repos

| Repo | Purpose | Path |
|------|---------|------|
| [platform-control](https://github.com/chris-arsenault/platform-control) | IAM deployer roles, OIDC, shared state bucket, GitHub secrets | `~/src/platform-control` |
| [platform-services](https://github.com/chris-arsenault/platform-services) | Cognito, auth-trigger, shared RDS, database migrations, CI dashboard, observability | `~/src/platform-services` |
| [platform-network](https://github.com/chris-arsenault/platform-network) | VPC, subnets, shared ALB, WireGuard VPN, NAT, DNS | `~/src/platform-network` |
| [nas-sonarqube](https://github.com/chris-arsenault/nas-sonarqube) | SonarQube on TrueNAS — Docker Compose, CI token Lambda | `~/src/nas-sonarqube` |

## Deploy Order

```
platform-control   (IAM roles, shared state bucket, GitHub secrets)
       │
       ├── platform-services  (Cognito, RDS, migrations, CI ingest, observability)
       │
       └── platform-network   (VPC, ALB, VPN — reads Cognito SSM from services)
              │
              └── consuming projects (websites, svap, the-canonry, etc.)
```

Deploy all: `scripts/deploy-all.sh`

## This Repo Also Contains

- `INTEGRATION.md` — canonical instructions for AI agents integrating projects with the platform
- `CI-WORKFLOW.md` — shared reusable CI/CD workflow, platform.yml, governance, SonarQube
- `TRUENAS-DEPLOY.md` — TrueNAS deploy pattern (Docker, Komodo, secret-paths.yml)
- `.github/workflows/ci.yml` — shared reusable CI/CD workflow (called by all standard projects)
- `.github/actions/` — `sonar-scan`, `report-build`, `governance-check`, `run-migrations`, `deploy-truenas`
- `scripts/deploy-all.sh` — deploys all platform repos in order

## Integration

See [INTEGRATION.md](INTEGRATION.md) for full instructions.
