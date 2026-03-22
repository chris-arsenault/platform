# Platform

Index repo for the platform layer — shared AWS infrastructure, identity, and deployment management.

## Repos

| Repo | Purpose | Path |
|------|---------|------|
| [platform-control](https://github.com/chris-arsenault/platform-control) | IAM deployer roles, OIDC, state buckets, GitHub secrets | `~/src/platform-control` |
| [platform-services](https://github.com/chris-arsenault/platform-services) | Cognito, auth-trigger, DynamoDB user-access, SSM bus, observability | `~/src/platform-services` |
| [platform-network](https://github.com/chris-arsenault/platform-network) | VPC, subnets, WireGuard VPN, shared ALB, NAT, DNS | `~/src/platform-network` |
| [truenas](https://github.com/chris-arsenault/truenas) | TrueNAS server IaC, Docker Compose stacks (SonarQube) | `~/src/truenas` |

## Dependency Order

```
platform-control  (creates deployer roles + state buckets)
       │
       ├── platform-network  (VPC, ALB, VPN)
       ├── platform-services (Cognito, auth, observability)
       │
       └── consuming projects (websites, svap, the-canonry, etc.)
```

## Integration

See [INTEGRATION.md](INTEGRATION.md) for instructions on integrating a new project with this platform.
