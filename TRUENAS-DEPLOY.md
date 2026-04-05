# TrueNAS Deploy Guide

> **AUDIENCE**: AI agents deploying Docker Compose services to TrueNAS via Komodo.

## Overview

TrueNAS-hosted services are deployed as Docker Compose stacks managed by [Komodo](https://github.com/moghingold/komodo). The deploy flow:

1. Terraform creates AWS resources (Lambda, SSM params, Cognito client)
2. Docker image is built and pushed to GHCR
3. Komodo pulls the compose file from GitHub, sets environment from SSM, and deploys

The shared reusable workflow handles steps 2-3 automatically when `truenas: true` is set in `platform.yml`.

---

## Project Layout

### Single-image project (e.g., nas-sonarqube)

```
<project>/
  compose.yaml           # Docker Compose for TrueNAS
  Dockerfile             # Single image (root level)
  secret-paths.yml       # SSM paths for compose environment variables
  backend/               # Rust Lambda (if any)
  infrastructure/
    terraform/
  platform.yml
  Makefile
  CLAUDE.md
```

### Multi-image project (e.g., airwave)

```
<project>/
  compose.yaml           # References both images
  backend/               # Rust source + Dockerfile
    Dockerfile
    Cargo.toml
    src/
  frontend/              # TypeScript source + Dockerfile
    Dockerfile
    package.json
    src/
  secret-paths.yml
  infrastructure/
    terraform/
  platform.yml
  Makefile
  CLAUDE.md
```

Each component directory has its own `Dockerfile`. The directory name is the component name used in the image path.

---

## Dockerfiles must not compile

The shared workflow compiles Rust (`cargo clippy --release`) and builds frontends (`pnpm run build`) before the Docker step. Dockerfiles must COPY pre-built artifacts from the CI workspace — **not** compile from source.

**Rust backend Dockerfile:**

```dockerfile
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY target/release/<binary> /usr/local/bin/<binary>
CMD ["<binary>"]
```

**Frontend Dockerfile:**

```dockerfile
FROM nginx:alpine
COPY dist/ /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf
```

This is possible because the Docker build runs on the same CI runner that just compiled everything. The build artifacts (`target/release/`, `dist/`) are already present. Docker just packages them.

**Do NOT use multi-stage builds that compile from source.** That duplicates the compilation the shared workflow already performed, adding minutes to every build. The Dockerfile is a packaging step, not a build step.

Note: the Rust binary is compiled for linux-amd64 (GitHub runner architecture), which must match the target container's architecture.

---

## platform.yml

### Single image

```yaml
project: <name>
prefix: <name>
stack:
  - rust
  - terraform
truenas: true
```

Builds from root → `ghcr.io/chris-arsenault/<project>:<sha>`

### Multi-image

```yaml
project: <name>
prefix: <name>
stack:
  - rust
  - typescript
truenas: true
images:
  - api
  - web
```

Builds each component from its directory → `ghcr.io/chris-arsenault/<project>/<component>:<sha>`

The `truenas: true` flag tells the shared workflow to:
1. Build Docker image(s) — single from root, or one per entry in `images`
2. Push to GHCR at `ghcr.io/chris-arsenault/<project>[/<component>]:<sha>`
3. Read `secret-paths.yml` for Komodo environment variables
4. Call the `deploy-truenas` action with stack name = project name

---

## secret-paths.yml

Maps compose environment variable names to SSM parameter paths. These are **paths, not values** — safe to commit:

```yaml
DB_USER: /platform/truenas-db/<name>/username
DB_PASSWORD: /platform/truenas-db/<name>/password
ADMIN_PASSWORD: /platform/<name>/admin-password
```

The `deploy-truenas` action reads this file, resolves the SSM values via the Komodo proxy Lambda, and sets them in the Komodo stack environment. Compose reads them as `${DB_USER}`, `${DB_PASSWORD}`, etc.

---

## compose.yaml

Standard Docker Compose with `${VAR}` references to environment variables set by Komodo.

### Single image

```yaml
services:
  app:
    image: ghcr.io/chris-arsenault/<project>:${IMAGE_TAG}
    restart: unless-stopped
    ports:
      - "<host-port>:8080"
    environment:
      DB_USER: "${DB_USER}"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/health"]
      interval: 15s
      timeout: 5s
      retries: 20
      start_period: 60s
```

### Multi-image

```yaml
services:
  api:
    image: ghcr.io/chris-arsenault/<project>/api:${IMAGE_TAG}
    restart: unless-stopped
    environment:
      DB_USER: "${DB_USER}"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/health"]
      interval: 15s
      timeout: 5s
      retries: 20
      start_period: 60s

  web:
    image: ghcr.io/chris-arsenault/<project>/web:${IMAGE_TAG}
    restart: unless-stopped
    depends_on:
      api:
        condition: service_healthy
```

`IMAGE_TAG` is set automatically by the deploy action to the git SHA. All images in the stack share the same tag.

---

## TrueNAS Database

TrueNAS services use a separate PostgreSQL instance on TrueNAS (192.168.66.3:5432), not the shared RDS. Database management is handled by the `platform-db-migrate-truenas` Lambda in `platform-services`.

To register a new TrueNAS database project, add it to `var.truenas_db_projects` in `platform-services/infrastructure/terraform/db-migrate-truenas.tf`:

```hcl
variable "truenas_db_projects" {
  default = {
    <name> = { db_name = "<name>" }
  }
}
```

The Lambda creates the database, application role, and publishes credentials to SSM at `/platform/truenas-db/<name>/username` and `/platform/truenas-db/<name>/password`.

---

## Networking

TrueNAS services are reached via WireGuard VPN. The reverse proxy (nginx on EC2) routes traffic from the shared ALB to TrueNAS:

- **ALB** → **CloudFront** → **ALB** → **nginx reverse proxy** → **WireGuard** → **TrueNAS**
- Routes are defined in `platform-network/infrastructure/terraform/locals.tf` under `reverse_proxy_routes`
- Each route needs: `address` (TrueNAS IP), `port` (container host port), `auth` (cognito/passthrough)
- Optional: `max_body_size` for routes that handle large uploads

To add a new reverse proxy route, add an entry to `reverse_proxy_routes` in platform-network.

---

## Custom Post-Deploy Steps

If a service needs steps after the standard deploy (e.g., bootstrapping tokens, seeding data), add them as a separate job in the caller workflow:

```yaml
jobs:
  ci:
    uses: chris-arsenault/platform/.github/workflows/ci.yml@main
    secrets: inherit

  bootstrap:
    if: github.ref == 'refs/heads/main'
    needs: [ci]
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ secrets.OIDC_ROLE }}
          role-session-name: GitHubActions-${{ github.run_id }}
          aws-region: us-east-1
      # ... custom steps ...
```

---

## WAF Considerations

The ALB has a WAF with `AWSManagedRulesCommonRuleSet`. The `SizeRestrictions_BODY` rule blocks request bodies over 8KB. If your service accepts large uploads through the reverse proxy:

1. Add `max_body_size` to the route in `reverse_proxy_routes` (nginx layer)
2. The WAF has an exemption for `sonar.ahara.io/api/ce/submit` — similar exemptions can be added in `platform-network/infrastructure/terraform/waf.tf`
