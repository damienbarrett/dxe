# DXE Refactoring Plan

Assessment snapshot: 2026-07-31. Plan revision: 2026-08-01.

This file is the summary layer. The detail lives in [`docs/refactor/`](docs/refactor):

| Document | Contents |
| --- | --- |
| [assessment.md](docs/refactor/assessment.md) | What works today, size baseline, the findings table, cleanup candidates, patterns already in the repo |
| [constraints.md](docs/refactor/constraints.md) | Invariants every phase preserves; target host and guest shape |
| [decisions/](docs/refactor/decisions) | D1–D6, each stated exactly once |
| [checklists/](docs/refactor/checklists) | The working artifacts: one file per phase, items plus exit gate |
| [migration-gates.md](docs/refactor/migration-gates.md) | The four legacy-removal gates and their check commands |
| [risk-controls.md](docs/refactor/risk-controls.md) | Commit strategy, reader-before-writer, backout |
| [validation-matrix.md](docs/refactor/validation-matrix.md) | Test tiers, where each runs, final commands |

## Executive recommendation

Keep the current Bash/Nix architecture. The lifecycle model is clear, the small
create/destroy wrappers are appropriately narrow, and the NixVim configuration
is already decomposed well. A language rewrite or a merger of the lifecycle
commands would add migration risk without addressing the main maintenance
costs.

Refactor around five seams instead:

1. Make the shared host code sourceable without platform checks or other import
   side effects, then enforce the test and lint baseline in CI.
2. Replace the duplicated `dx-forward`/`dx-reverse` control-socket
   implementations with one tunnel state engine and two thin directional
   wrappers.
3. Turn `dx-mount` into a pure plan/validation layer plus a small mutation
   layer, and stop sourcing its user-writable identity manifests.
4. Split the guest bootstrap into directly testable phases, share and package
   its keyring primitives with `dx-ai`, separate mutable AI state from the
   published payload, and make bootstrap publication transactional.
5. Remove temporary migration code when its operational precondition is met,
   then reduce documentation and test-implementation coupling.

The recommended order deliberately builds testable seams before moving
destructive or boot-critical behavior.

## Phases

| Phase | Goal | Seam | Decisions | Optional? |
| --- | --- | --- | --- | --- |
| [0](docs/refactor/checklists/phase-0.md) | Freeze behavior at the risky boundaries | prep | [D3](docs/refactor/decisions/D3-ci.md) (minimal) | no |
| [0.5](docs/refactor/checklists/phase-0.5.md) | Standalone safety fixes, in place | — | [D6](docs/refactor/decisions/D6-command-boundaries.md), [D4-core](docs/refactor/decisions/D4-mount-manifest.md) | no |
| [1a](docs/refactor/checklists/phase-1a.md) | Guardrails: runner tiers, toolchain, CI, coverage | 1 | [D1](docs/refactor/decisions/D1-coverage.md), [D3](docs/refactor/decisions/D3-ci.md) | no |
| [1b](docs/refactor/checklists/phase-1b.md) | Side-effect-free core | 1 | [D2](docs/refactor/decisions/D2-config.md), [D6](docs/refactor/decisions/D6-command-boundaries.md) | no |
| [2](docs/refactor/checklists/phase-2.md) | Consolidate SSH tunnel management | 2 | — | no |
| [3](docs/refactor/checklists/phase-3.md) | Separate `dx-mount` planning from execution | 3 | [D4](docs/refactor/decisions/D4-mount-manifest.md) | hardening half |
| [4](docs/refactor/checklists/phase-4.md) | Sourceable bootstrap phases, safe publication | 4 | [D5](docs/refactor/decisions/D5-bootstrap-state.md), [D6](docs/refactor/decisions/D6-command-boundaries.md) | hardening half |
| [5](docs/refactor/checklists/phase-5.md) | Finish AI updater decomposition | 4 | — | yes |
| [6](docs/refactor/checklists/phase-6.md) | Remove temporary code, reduce doc coupling | 5 | — | yes |

Phases 2 and 3 are independent of each other and can be done in either order, or
one without the other.

## Where the value lands, and where you can stop

The phases are not an all-or-nothing commitment. Each of the following is a
coherent stopping point that leaves no half-finished migration:

- **After Phase 0.5** — three P1 safety findings are closed for a few days' work:
  exact process identity before signalling, private timeout bookkeeping, and no
  more shell evaluation of the mount identity file. No file has moved, so nothing
  here commits you to the rest of the plan.
- **After Phase 1a** — the quality gates stop being optional and every later phase
  gets cheaper to verify.
- **After Phase 1b** — the largest structural payoff: the suite becomes portable
  and the host code is independently testable.
- **After Phase 2 or after Phase 3** — independent of each other.
- **After Phase 3's D4-core** — the manifest is a bounded data format with atomic
  publication. The [hardening](docs/refactor/decisions/D4-mount-manifest.md#stopping-point)
  that follows buys write-once-under-concurrency and a legacy conversion path.
- **After Phase 4's D5-core** — bootstrap publication is transactional and writable
  AI state has moved under `/persist`. The
  [hardening](docs/refactor/decisions/D5-bootstrap-state.md#stopping-point) that
  follows buys concurrent-sync safety and lease-verified collection; stop here only
  if automatic generation collection stays off.
- **Phases 5 and 6** are optional throughout.

Do not stop in the middle of a phase that has begun writing a new persisted
format (Phases 2, 3, and 4), because the read-old/write-new window is only
safe once both readers exist. See
[reader-before-writer](docs/refactor/risk-controls.md#reader-before-writer).

### A note on proportionality

D4 and D5 are the two largest work items in this plan, and most of their weight is
concurrency hardening — protecting against two invocations of a single-developer
CLI racing on one machine. The defects that motivated them are much smaller: a
`source` of a user-writable file, and a delete-before-transfer. Both are fully
fixed by the `-core` tiers.

The hardening is specified because it is the correct end state, not because it is
urgent. Tiering it keeps the safety work fast and leaves the rest genuinely
optional rather than nominally optional.

## Definition of done

The refactor is complete when:

- The public CLI and lifecycle behavior pass the existing and new contract
  suites.
- The non-live suite runs on a machine without Apple Container installed.
- Mandatory lint, Nix evaluation, and measured shell coverage run in CI with no
  silent skip; the [D1](docs/refactor/decisions/D1-coverage.md) coverage policy is
  met over its declared scope and its scope share has not regressed.
- Root `.env`, named profiles, manifests, and keyring metadata are parsed as
  bounded data formats and never evaluated as shell code. Intentional sourced
  code is installed/read-only and named as code, not disguised as `.env` data.
- Configuration follows [D2](docs/refactor/decisions/D2-config.md) precedence,
  records origins, and is resolved once as a complete versioned snapshot across
  every orchestrated child process; stale or partial markers fail closed.
- [D6](docs/refactor/decisions/D6-command-boundaries.md) command boundaries contain
  no interpolated configuration code, and process-control fallbacks prove exact,
  non-reused target identity.
- Forward and reverse tunneling share one state engine whose per-key locks make
  concurrent start/stop transitions linearizable.
- `dx-mount` computes one immutable plan used by both preview and execution.
- Mount manifests use the [D4](docs/refactor/decisions/D4-mount-manifest.md) codec;
  if hardening shipped, they remain complete and semantically write-once under
  concurrent attach, migration, and destroy attempts.
- Bootstrap tests source real phase modules, and a failed sync preserves the
  last-known-good payload.
- Published bootstrap generations are immutable; AI pin/lock state lives in
  versioned `/persist` generations selected through an atomic `current` pointer.
- Full isolated live and destructive tests pass before promotion.
- The host-library and host-contract suites pass under the automated Bash 3.2
  job, and macOS contributors can reproduce Linux coverage with the pinned
  runner.
- Temporary compatibility readers and old-base guards are removed only after
  their [migration gates](docs/refactor/migration-gates.md) are satisfied.

## Measurable targets

The criteria above are qualitative, which makes "done" arguable. These are the
numbers to check against the assessment baseline.

| Metric | Baseline (2026-07-31) | Target |
| --- | ---: | --- |
| Duplicated control-socket logic across `dx-forward`/`dx-reverse` | 242 identical lines | ~0; direction-specific code only |
| Largest host script | `dx-mount`, 487 lines | No file in `bin/` over ~250 lines |
| Largest guest script | `bootstrap.sh`, 724 lines | No bootstrap module over ~200 lines |
| Largest test file | `test_section9_host_scripts.sh`, 1,719 lines | No test file over ~400 lines |
| Tests asserting production source text | 492 `assert_file_contains`/`assert_file_not_contains` calls | Behavior assertions replace them wherever the subject is executable code; documentation assertions convert per Phase 6 |
| `sed`/`awk` extractions of production files in tests | 5 | 0 |
| Skipped checks in a full run | 14, unclassified | Every skip classified; CI-required skips = 0 |
| Non-live suite on a container-free machine | Cannot run | Green, and fast enough to run per commit |
| Production test-mode branches | 4 (`dx-forward`, `dx-reverse`, `dx-mount`, `bootstrap.sh`) | 0 |
| Production sites evaluating data-designated files as shell | 5: root `.env`, mount identity, profile, keyring (Bash startup), keyring (`dx-ai`). Fish and Nushell already parse rather than evaluate. | 0; intentional code files remain explicitly `.sh` |
| Config values interpolated into generated shell programs | Present in bootstrap launch and persistence migration | 0; fixed programs receive positional or validated environment data |
| Runtime-process selection | Substring match on `--uuid NAME` | Exact argument match plus stable process-identity revalidation |
| Legacy mount manifests with no conversion path | Audit/read only; current code never upgrades them | With D4-hardening: complete records convert atomically, incomplete records report destroy/recreate remediation |
| Automated Bash 3.2 gate | Manual mac-only responsibility | Required CI compatibility job on a `macos-*` runner, reproducible locally |
| Writes inside the published bootstrap payload | `dx-ai` edits `flake.nix` and `flake.lock` | 0; AI state uses versioned `/persist` generations and one atomic pointer |
| Shell lines inside the measured coverage scope | 0 (no `bin/lib/`, no coverage job) | Baselined at Phase 1b exit; ratcheted, never regresses — see [D1](docs/refactor/decisions/D1-coverage.md) |

The duplication figure is measured, not estimated: normalizing direction words
(`forward`/`reverse`, `-L`/`-R`) across the two parallel blocks
([`bin/dx-forward`](bin/dx-forward#L83-L394), 312 lines;
[`bin/dx-reverse`](bin/dx-reverse#L83-L379), 297 lines) leaves 242 byte-identical
lines and only 70 genuinely direction-specific ones. That ratio is the case for
Phase 2 in a single number, and it is worth re-running after the consolidation
to confirm the shared engine actually absorbed them.

Line-count targets are direction, not law — a 260-line file with one clear
responsibility is a better outcome than a 240-line file plus an artificial
helper module. Treat a miss as a prompt to justify the file, not to split it
reflexively.
