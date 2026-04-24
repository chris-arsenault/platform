# Improved Rust CI Proposal For Shared Workflow

This proposal documents how the Ahara shared reusable workflow could be improved for Rust repositories that rely on workspace-wide tests, integration tests, benchmark compilation, and stricter clippy coverage than the current baseline.

## Current Gap

The current shared Rust CI flow does:

- `cargo fmt -- --check`
- `cargo clippy --release -- -D warnings -W clippy::cognitive_complexity`
- `cargo llvm-cov --release --lib`

That is a good baseline, but it misses several important classes of verification for multi-crate Rust repos:

- integration tests under `tests/`
- binary targets
- benchmark target compilation
- workspace-wide `--all-targets` lint coverage
- doctest and non-lib target regressions that only appear outside `--lib`

## Proposed Improvement

The shared Rust CI flow should move closer to a repository-wide verification contract by default.

Recommended baseline:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings -W clippy::cognitive_complexity
cargo test --workspace
```

Recommended optional extension:

```bash
cargo bench --workspace --no-run
```

If benchmark compile time is considered too expensive for every Rust repo, it could be guarded by a manifest flag such as:

```yaml
rust_ci:
  bench_no_run: true
```

## Why This Is Better

- `--workspace --all-targets` matches how real Rust repos are structured.
- Integration regressions stop slipping past the shared workflow.
- Binary-only compilation problems become visible in CI.
- Repositories do not need ad hoc local supplements just to get back to a normal Rust quality bar.
- The shared workflow becomes a more faithful substitute for a strong `make ci`.

## Suggested Manifest Extensions

If Ahara wants to keep the shared workflow configurable without reintroducing arbitrary shell hooks, a structured `rust_ci` block would be cleaner than raw extra commands.

Example:

```yaml
rust_ci:
  workspace: true
  all_targets: true
  integration_tests: true
  bench_no_run: true
  llvm_cov_lib_only: false
```

That keeps policy declarative and easier to govern than `rust_extra_ci_commands`.

## Migration Strategy

1. Update the shared workflow to use `cargo clippy --workspace --all-targets`.
2. Update the shared workflow to run `cargo test --workspace`.
3. Decide whether benchmark compilation is always-on or manifest-gated.
4. Remove the need for repo-local workarounds in Rust-heavy repos.

## Recommendation

The most practical immediate improvement is:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings -W clippy::cognitive_complexity
cargo test --workspace
```

That change alone would materially improve the shared workflow for Rust repos without requiring any per-repo escape hatch.
