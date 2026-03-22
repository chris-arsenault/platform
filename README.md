# Platform

Index repo for the platform layer — shared AWS infrastructure, identity, deployment management, and CI tooling.

## Repos

| Repo | Purpose | Path |
|------|---------|------|
| [platform-control](https://github.com/chris-arsenault/platform-control) | IAM deployer roles, OIDC, shared state bucket, GitHub secrets | `~/src/platform-control` |
| [platform-services](https://github.com/chris-arsenault/platform-services) | Cognito, auth-trigger, shared RDS, database migrations, CI dashboard, observability | `~/src/platform-services` |
| [platform-network](https://github.com/chris-arsenault/platform-network) | VPC, subnets, shared ALB, WireGuard VPN, NAT, DNS | `~/src/platform-network` |
| [truenas](https://github.com/chris-arsenault/truenas) | TrueNAS server IaC, Docker Compose stacks (SonarQube) | `~/src/truenas` |

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
- `.github/actions/report-build/` — composite GitHub Action for CI dashboard reporting
- `scripts/deploy-all.sh` — deploys all platform repos in order
- `scripts/migrate-state.sh` — one-time migration from per-project state buckets to shared bucket

## Integration

See [INTEGRATION.md](INTEGRATION.md) for full instructions.
