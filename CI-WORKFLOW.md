# CI/CD Workflow Guide

> **AUDIENCE**: AI agents setting up CI for platform projects.

## Shared Reusable Workflow

All standard projects use the shared reusable workflow at `platform/.github/workflows/ci.yml`. The caller workflow is minimal:

```yaml
name: CI/CD

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  ci:
    uses: chris-arsenault/platform/.github/workflows/ci.yml@main
    secrets: inherit
```

This is the **entire CI workflow file** for standard projects. The shared workflow reads `platform.yml` and runs the appropriate steps based on the declared stack.

### What the shared workflow does

1. **Governance check** — validates that required lint/test steps exist (auto-passes when using the shared workflow)
2. **Rust lint** — `cargo clippy`, `cargo fmt --check` in `backend/`
3. **TypeScript lint** — `pnpm install`, `eslint`, `tsc --noEmit` in `frontend/`
4. **Python lint** — `uv sync`, `ruff check`, `ruff format --check` in `backend/`
5. **Terraform lint** — `terraform fmt -check -recursive` in `infrastructure/terraform/`
6. **SonarQube scan** — auto-configured from stack (sources, exclusions, AWS provider version)
7. **Deploy (main only)** — cargo-lambda build, pnpm build, migrations, terraform apply
8. **TrueNAS deploy (if configured)** — Docker build, GHCR push, Komodo deploy
9. **Report** — auto-detects lint/test outcomes and duration via GitHub API

### What it does NOT do

- .NET builds (use `sonar-scan-dotnet-begin/end` actions and a custom workflow)
- Matrix strategies (e.g., websites' multi-app typecheck)
- Custom deploy flows requiring secrets beyond OIDC_ROLE and STATE_BUCKET

---

## platform.yml

Every project must have a `platform.yml` in the repo root:

```yaml
project: <name>          # Project key (sonar, concurrency groups, migrations)
prefix: <prefix>         # AWS resource prefix (usually same as project)
stack:                   # Declares which lint/build/deploy steps to run
  - rust                 # cargo clippy, rustfmt, cargo-lambda build
  - typescript           # pnpm eslint, tsc, pnpm build
  - python               # ruff check, ruff format, scripts/build-lambda.sh
  - terraform            # terraform fmt, terraform apply
migrations: db/migrations  # Optional — enables run-migrations step
truenas: true            # Optional — enables Docker + Komodo deploy
```

Only include stack components your project actually has. The shared workflow skips steps for missing components.

---

## Standard Project Layout

The shared workflow expects this directory structure:

```
<project>/
  backend/               # Rust workspace OR Python package
    Cargo.toml           # (Rust)
    src/
  frontend/              # TypeScript/React SPA
    package.json
    pnpm-lock.yaml
    eslint.config.js
    src/
  infrastructure/
    terraform/
  platform.yml
  Makefile
  CLAUDE.md
  .github/workflows/ci.yml
```

**Conventions:**
- Rust backends live in `backend/` (not `apps/` or `src/`)
- TypeScript frontends live in `frontend/` (pnpm, not npm)
- Terraform lives in `infrastructure/terraform/`
- The `Makefile` has a `ci` target that mirrors the shared workflow's lint/test steps

---

## Makefile

Every project must have a `Makefile` with a `ci` target. Run `make ci` before committing.

Example for a Rust + TypeScript + Terraform project:

```makefile
.PHONY: ci lint typecheck terraform-fmt-check

ci: lint typecheck terraform-fmt-check

lint:
	cd backend && cargo clippy -- -D warnings
	cd backend && cargo fmt -- --check
	cd frontend && pnpm exec eslint .

typecheck:
	cd frontend && pnpm exec tsc --noEmit

terraform-fmt-check:
	terraform fmt -check -recursive infrastructure/terraform/
```

---

## Step Naming Convention

The shared `report-build` action auto-detects lint and test outcomes by step name prefix. Custom workflows must follow this convention:

- Steps starting with **`Lint`** are counted as lint (e.g., `Lint clippy`, `Lint eslint`, `Lint terraform`)
- Steps starting with **`Test`** are counted as test (e.g., `Test core`, `Test frontend`)

The report action queries the GitHub API for all step names and reports `lint_passed` / `test_passed` accordingly.

---

## Governance Check

The `governance-check` action runs as the first step in CI. It reads `platform.yml` and validates:

- If using the shared reusable workflow: **auto-passes** (all steps are guaranteed)
- If using a custom workflow: checks that step names matching the declared stack exist

This prevents drift — if someone removes a lint step, CI fails immediately.

---

## SonarQube Integration

The shared workflow runs SonarQube analysis automatically. It:
- Reads the CI token and URL from SSM (`/platform/sonarqube/ci-token`, `/platform/sonarqube/url`)
- Builds sources/exclusions lists from the stack declaration
- Passes `-Dsonar.terraform.provider.aws.version=6` for accurate terraform analysis

SonarQube is non-blocking (`continue-on-error: true`).

### .NET projects

.NET requires a different scanner that wraps the build. Use the split actions:

```yaml
- id: sonar
  uses: chris-arsenault/platform/.github/actions/sonar-scan-dotnet-begin@main
  with:
    project-key: <name>

# ... dotnet build, dotnet test ...

- uses: chris-arsenault/platform/.github/actions/sonar-scan-dotnet-end@main
  with:
    token: ${{ steps.sonar.outputs.token }}
```

---

## Custom Deploy

For projects that can't use standard deploy, set `deploy: false`:

```yaml
jobs:
  ci:
    uses: chris-arsenault/platform/.github/workflows/ci.yml@main
    with:
      deploy: false
    secrets: inherit

  deploy:
    if: github.ref == 'refs/heads/main'
    needs: [ci]
    runs-on: ubuntu-latest
    steps:
      # ... custom deploy steps ...
```

The shared workflow handles all lint/test/sonar/report. Only deploy is custom.

---

## Shared Actions Reference

| Action | Purpose |
|--------|---------|
| `sonar-scan` | SonarQube analysis for non-.NET projects |
| `sonar-scan-dotnet-begin` | Start .NET SonarQube analysis (before build) |
| `sonar-scan-dotnet-end` | Finalize .NET SonarQube analysis (after test) |
| `report-build` | CI dashboard reporting (auto-detects everything) |
| `governance-check` | Validates workflow against platform.yml stack |
| `run-migrations` | Upload and run database migrations |
| `deploy-truenas` | Docker + Komodo deploy for TrueNAS services |
