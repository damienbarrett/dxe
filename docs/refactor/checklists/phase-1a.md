# Phase 1a — Guardrails

**Goal:** make skipped quality gates visible and enforced, before the code moves.
**Owns:** seam 1 (enforcement half).
**Decisions:** [D1](../decisions/D1-coverage.md), [D3](../decisions/D3-ci.md).

Phase 1a and [Phase 1b](phase-1b.md) were one phase. They are separated because
they have almost no dependency on each other, and because bundling them put
fifteen items behind a single exit gate: a stall midway left a half-migrated
`dx-lib.sh` facade *and* no enforced gate.

Guardrails go first. Every commit in Phase 1b is then verified by CI as it lands,
which is the entire argument for doing this work early. Phase 1a depends only on
[Phase 0](phase-0.md)'s harness split.

## Items

- [x] **1. Make the runner capability-aware.** Four tiers:
  - `unit/static`: no Apple Container and no live guest;
  - `host-contract`: fake `container`, `ssh`, `scp`, and process commands;
  - `live`: isolated Apple Container profile;
  - `destructive`: explicit opt-in and non-default resources.

- [x] **2. Move the clean-worktree assertion** out of the behavior suite and into a
  release/checklist command ([`test_section13_final_review.sh`](../../../tests/test_section13_final_review.sh#L12-L18)).
  Stop changing executable bits on every test run.

- [x] **3. Provide the host developer toolchain.** Add a native bootstrap or host
  `devShell` for Bash, ShellCheck, and Nix, plus an optional pre-push hook for
  syntax and lint. Add a pinned Linux coverage image and local wrapper that
  can use a documented OCI provider on macOS, so the exact CI `kcov` command
  is reproducible even though `kcov` is not native to the host. The planned
  entrypoint is `tests/run-coverage-linux.sh`.

- [x] **4. Add the full CI matrix** per [D3](../decisions/D3-ci.md), extending
  Phase 0's minimal job:
  - a primary hosted-Linux job for syntax, mandatory ShellCheck, the no-container
    suite, host contracts, coverage, and Nix evaluation;
  - a non-live Bash 3.2 compatibility job on a hosted `macos-*` runner for host
    syntax, config, manifest, tunnel, and host-command contracts. It asserts
    `/bin/bash --version` reports 3.2.x before running.

  A developer machine may report a missing optional live capability, but CI must
  fail rather than skip a required gate, checked against the Phase 0 skip
  inventory. Expose the compatibility job locally as `tests/run-bash32-tests.sh`,
  which verifies its interpreter before running rather than silently using a newer
  Bash.

- [x] **5. Add executable-shell coverage reporting** with `kcov` over the stubbed
  contract suite, scoped per [D1](../decisions/D1-coverage.md). Publish the
  exclusion file alongside the report and assert its contents. Publish **both**
  numbers: the gated 100% over declared scope and the ratcheted share of total
  shell lines inside that scope. Validate declarative Nix through
  evaluation/build and behavior tests rather than pretending line coverage
  measures it.

  The declared scope is nearly empty until Phase 1b creates `bin/lib/`. That is
  expected: baseline the ratchet at the Phase 1b exit gate, not here.

## Two mechanical notes for the runner

- Adjust glob handling so an absent optional directory does not become a literal
  ShellCheck argument.
- Prefer `nix flake check --no-build` in CI so evaluation errors are caught
  without attempting a cross-architecture build that will fail for the wrong
  reason.

## Exit gate

- Every skip classified **CI-required** in the Phase 0 inventory is now a hard
  failure; every remaining skip is classified **mac-only** and named in CI
  output.
- A contributor can run the syntax, lint, unit/static, and host-contract tiers
  locally and reproduce coverage through the documented pinned Linux runner.
- Linux CI produces the D1 coverage artifact with both numbers, and the Bash 3.2
  compatibility job passes the host-contract suites having first asserted its
  interpreter version.
- The behavior suite no longer fails on an intentionally dirty development tree,
  and no test run mutates executable bits.
