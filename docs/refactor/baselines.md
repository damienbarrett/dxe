# Refactor baselines and inventories

Captured 2026-08-01 before production files moved. These tables are the Phase 0
working record; live capability skips remain explicit rather than disappearing.

## Skip inventory

| Count | Classification | Check |
| ---: | --- | --- |
| 1 | CI-required | ShellCheck (section 0) |
| 2 | CI-required | Nix flake evaluation in sections 5 and 8 |
| 11 | mac-only | SSH, guest tools, NixVim launch, Tinty, Nushell, persistence/migration, dx-ai, and tunnel live behavior |

CI installs ShellCheck and Nix, so the three CI-required entries cannot skip
there. The eleven live entries are exercised only by the isolated macOS
pre-promotion command.

## Production-only seams

The original four branches were `DX_FORWARD_TEST_MODE`,
`DX_REVERSE_TEST_MODE`, `DX_MOUNT_TEST_MODE`, and `DX_BOOTSTRAP_TEST_MODE`.
They are assigned to Phases 2, 2, 3, and 4 respectively and are removed by the
implementation.

## Command boundaries

| Boundary | Classification |
| --- | --- |
| container/bootstrap launcher | fixed program plus positional bootstrap root (Phase 1b/4) |
| persistence migration helpers | fixed programs plus positional sentinel/volume data (Phase 1b) |
| bootstrap sync/extract/publish | fixed program plus positional root/generation data (Phase 4) |
| `dx-ssh`, `dx-enter`, `dx-reclaim` user commands | intentional public user-command contracts |
| status, GC, readiness probes | fixed programs with no interpolated configuration |

## Test-coupling baseline

The assessment baseline is 492 `assert_file_contains` /
`assert_file_not_contains` calls and five `sed`/`awk` extractions of production
files. The largest contributors were section 9 (173), section 14 (99), section
10 (69), section 6 (58), and section 3 (38). Later changes are measured against
those per-file figures, not a moving total.

## Measurable targets

Moved here from the now-closed `refactor-plan.md` (Branch 8,
`refactor/legacy-migration-cleanup`, 2026-09-26) so the numbers stay
available after the plan document's removal. The criteria the former plan
stated are qualitative, which makes "done" arguable; these are the numbers
to check against the assessment baseline. This table is a live baseline, not
a record of finished work — it stays even though the plan's narrative did
not.

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
| Shell lines inside the measured coverage scope | 0 (no `bin/lib/`, no coverage job) | Baselined at Phase 1b exit; ratcheted, never regresses — see [D1](decisions/D1-coverage.md) |

The duplication figure is measured, not estimated: normalizing direction words
(`forward`/`reverse`, `-L`/`-R`) across the two parallel blocks
([`bin/dx-forward`](../../bin/dx-forward#L83-L394), 312 lines;
[`bin/dx-reverse`](../../bin/dx-reverse#L83-L379), 297 lines) leaves 242 byte-identical
lines and only 70 genuinely direction-specific ones. That ratio is the case for
Phase 2 in a single number, and it is worth re-running after the consolidation
to confirm the shared engine actually absorbed them.

Line-count targets are direction, not law — a 260-line file with one clear
responsibility is a better outcome than a 240-line file plus an artificial
helper module. Treat a miss as a prompt to justify the file, not to split it
reflexively.
