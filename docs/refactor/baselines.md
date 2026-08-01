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
