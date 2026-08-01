# Validation matrix

Part of the [refactor plan](../../refactor-plan.md).

Run the smallest applicable tier on every Red-Green-Refactor cycle and all
tiers before completion.

| Tier | Runs on | Purpose | Required checks |
| --- | --- | --- | --- |
| Syntax/lint | CI + local | Fast shell feedback | `bash -n` for all shell entrypoints and libraries; mandatory ShellCheck |
| Unit/static | CI + local | Pure parsing, planning, schema, and Nix structure | No Apple Container binary in `PATH`; config snapshots, manifest audit/migration, tunnel, lease, AI-generation, and bootstrap module tests; Nix **evaluation** only |
| Host contract | CI + local | Failure and state-machine behavior | Fake `container`, `ssh`, `scp`, `ps`, `kill`, `tar`, and filesystem fixtures; exact process identity, command-boundary transport, orchestration snapshots, and concurrent state transitions |
| Bash 3.2 compatibility | CI (`macos-*` runner) + local mac | Enforce the supported host interpreter | `/bin/bash` host syntax, config, manifest, tunnel, and host-contract suites; no guest modules or live runtime; asserts `/bin/bash --version` is 3.2.x first |
| Shell coverage | CI + local Linux runner | Enforce [D1](decisions/D1-coverage.md) | Pinned `kcov` environment; 100% over declared sourceable scope; ratcheted scope share; reviewed exclusions |
| Nix build | mac only | Guest closure actually builds | `nix build` of the aarch64-linux outputs; not reproducible on a hosted x86_64 runner |
| Live isolated | mac only | End-to-end runtime behavior | `./bin/dx-profile dx-test tests/run_all_tests.sh` against non-default resources |
| Destructive isolated | mac only | Factory reset and cleanup | Explicit opt-in; assert resource names are not any default before execution |
| Runtime compatibility | mac only | Supported Apple Container surface | Documented Apple Container versions; legacy manifest/tunnel/bootstrap state; restart-safe leases and migration audits |

The `Runs on` column is the operative part of [D3](decisions/D3-ci.md). The first
three tiers plus Bash 3.2 compatibility and coverage are the contract CI enforces.
Nix builds and the live/destructive/runtime-compatibility tiers are the
developer's pre-promotion responsibility on a real macOS host, because Apple
Container requires virtualization a hosted runner does not have and
`flake.nix` pins `system = "aarch64-linux"`.

## Useful final commands

```sh
# CI-equivalent tiers, runnable anywhere including a container-free machine
tests/run_all_tests.sh --skip-integration
tests/run-bash32-tests.sh
tests/run-coverage-linux.sh
shellcheck bin/dx* bin/lib/*.sh tests/*.sh \
  container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh \
  container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap/*.sh \
  container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/*.sh \
  container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib/*.sh
nix flake check --no-build --no-write-lock-file \
  container/aarch64-darwin-apple-container-dx-nixos-26.05

# mac-only tiers, before promotion
nix build --no-write-lock-file \
  ./container/aarch64-darwin-apple-container-dx-nixos-26.05#<output>
./bin/dx-profile dx-test tests/run_all_tests.sh
```

Two mechanical notes for the runner: adjust glob handling so an absent optional
directory does not become a literal ShellCheck argument, and prefer
`nix flake check --no-build` in CI so evaluation errors are caught without
attempting a cross-architecture build that will fail for the wrong reason.
