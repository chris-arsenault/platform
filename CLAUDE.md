# Platform

This is an index repo. It contains no deployable code — only documentation and integration guides for the platform layer.

## What this repo is for

- `INTEGRATION.md` — canonical instructions for integrating any project with the platform
- `README.md` — repo map and dependency order

## What this repo is NOT for

- No Terraform, no application code, no CI workflows
- Do not add infrastructure here — it belongs in platform-control, platform-services, or platform-network

## Related repos (all under ~/src/)

- `platform-control` — IAM roles, OIDC, state buckets
- `platform-services` — Cognito, auth, observability, SSM bus
- `platform-network` — VPC, ALB, VPN, DNS
- `truenas` — TrueNAS server management, SonarQube
