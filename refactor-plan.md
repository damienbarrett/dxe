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

Phases 0, 0.5, 1a, 1b, 2, 3, 4, and 5 are complete, and checked off in
[`docs/refactor/checklists/`](docs/refactor/checklists). Of Phase 6's six
items, 2, 3, 4, and 6 are also complete; items 1 and 5 remain open, with the
reason recorded in the checklist itself.

## Open work

- **[Phase 6, item 1](docs/refactor/checklists/phase-6.md#items) — remove the
  old-base guards** in `bootstrap.sh` and `bin/dx-start-container`, once the
  default guest, side containers, and named profiles have all moved off the
  old base. Open by design until the
  [old-base guard gate](docs/refactor/migration-gates.md#old-base-guards) is
  signed off; the primary guest's changeover is done, so the remaining
  inventory is side containers and named profiles only.
- **[Phase 6, item 5](docs/refactor/checklists/phase-6.md#items) — archive
  completed upgrade material from [`plan.md`](plan.md)**, only after its
  remaining status items (P7, P10, B1) are confirmed complete. Open; that
  precondition is not yet met.

## Definition of done

Most of this refactor's definition-of-done criteria are already satisfied by
the completed phases above. One is not:

- Temporary compatibility readers and old-base guards are removed only after
  their [migration gates](docs/refactor/migration-gates.md) are satisfied.
  (Ties to the open Phase 6, item 1 above.)

## Measurable targets

The criteria above are qualitative, which makes "done" arguable. These are the
numbers to check against the assessment baseline. This table is a live
baseline, not a record of finished work — it stays even though most of this
document's narrative does not.

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
