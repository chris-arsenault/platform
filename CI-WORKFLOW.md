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
    uses: chris-arsenault/ahara/.github/workflows/ci.yml@main
    with:
      rust_extra_ci_commands: |
        ./scripts/run-backend-integration-tests.sh
    secrets: inherit
```

For most projects, omitting `with:` is correct. `rust_extra_ci_commands` exists for repo-specific Rust checks that must stay inside the shared Rust cache/build topology instead of being split into separate jobs.

The shared workflow reads `platform.yml` and runs the appropriate steps based on the declared stack.

### What the shared workflow does

1. **Governance check** — validates that required lint/test steps exist (auto-passes when using the shared workflow)
2. **Rust lint + test** — `cargo clippy -- -D warnings -W clippy::cognitive_complexity`, `cargo fmt --check`, `cargo test` with coverage, plus optional repo-specific extra Rust CI commands (auto-detected from `Cargo.toml` location)
3. **TypeScript lint + test** — `pnpm install`, `eslint`, `tsc --noEmit`, `vitest` with coverage (auto-detected from `package.json` location)
4. **Python lint** — `uv sync`, `ruff check`, `ruff format --check` (auto-detected from `Cargo.toml` sibling)
5. **Terraform lint** — `terraform fmt -check -recursive` in `infrastructure/terraform/`
6. **SonarQube scan** — auto-configured sources, exclusions, and coverage report paths from stack
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
images:                  # Optional — multi-image TrueNAS deploy
  - api                  # Builds api/Dockerfile → ghcr.io/.../project/api:sha
  - web                  # Builds web/Dockerfile → ghcr.io/.../project/web:sha
rust_artifacts:          # Required if 'rust' in stack — explicit declaration of build outputs
  lambdas:               # Cargo bin names; built via cargo-lambda → target/lambda/<bin>/bootstrap (terraform consumes)
    - my-lambda
  binaries:              # Cargo bin → image dir mapping; built via cargo build → <image>/dist/<bin> (docker consumes)
    - { bin: my-server, image: backend }
```

Only include stack components your project actually has. The shared workflow skips steps for missing components.

`rust_artifacts` is mandatory whenever `rust` is in `stack`. Use `rust_artifacts: {}` for rust code with no deployable artifacts (e.g. a library-only crate). The two sub-keys are independent — a project can declare `lambdas`, `binaries`, both, or neither. `truenas: true` no longer implies a Rust binary build; declare `binaries:` if your Docker image needs one.

When `truenas: true` without `images`, a single image is built from the repo root. When `images` is present, each entry is a component directory containing its own `Dockerfile`, pushed to `ghcr.io/chris-arsenault/{project}/{component}:{sha}`. See [TRUENAS-DEPLOY.md](TRUENAS-DEPLOY.md) for full details.

---

## Standard Project Layout

The shared workflow auto-detects source directories from the filesystem:

- **Rust**: finds the shallowest `Cargo.toml` (typically `backend/`)
- **TypeScript**: finds the shallowest `package.json` outside `node_modules` and backend dirs (typically `frontend/`)
- **Python**: uses the same directory as Rust
- **Terraform**: always `infrastructure/terraform/`

Typical layout:

```
<project>/
  backend/               # Rust workspace OR Python package
    Cargo.toml
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

Directory names are not hardcoded — the workflow finds `Cargo.toml` and `package.json` wherever they live. The convention of `backend/` and `frontend/` is recommended but not required.

**Other conventions:**
- TypeScript uses pnpm (not npm)
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
- Reads the CI token and URL from SSM (`/ahara/sonarqube/ci-token`, `/ahara/sonarqube/url`)
- Builds sources/exclusions lists from the stack declaration
- Passes `-Dsonar.terraform.provider.aws.version=6` for accurate terraform analysis

SonarQube is non-blocking (`continue-on-error: true`).

### .NET projects

.NET requires a different scanner that wraps the build. Use the split actions:

```yaml
- id: sonar
  uses: chris-arsenault/ahara/.github/actions/sonar-scan-dotnet-begin@main
  with:
    project-key: <name>

# ... dotnet build, dotnet test ...

- uses: chris-arsenault/ahara/.github/actions/sonar-scan-dotnet-end@main
  with:
    token: ${{ steps.sonar.outputs.token }}
```

---

## Custom Deploy

For projects that can't use standard deploy, set `deploy: false`:

```yaml
jobs:
  ci:
    uses: chris-arsenault/ahara/.github/workflows/ci.yml@main
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
