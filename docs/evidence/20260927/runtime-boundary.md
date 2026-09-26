# Runtime boundary extraction (Branch 11 / Phase 1, `refactor/runtime-boundary`) — evidence

Sanitised evidence record for `qnap-dxe-plan.md`'s Phase 1 and
`checkout-consolidation-plan.md`'s Branch 11. No home directory paths, keys,
fingerprints, or NAS identifiers appear below.

Branch `refactor/runtime-boundary`, from `main` `2acffa9`, rebased onto
`main` `f3b7cb5` before landing; 21 commits plus the landing re-measure.
Shape: the inventory (increment 0, reviewed by the coordinating session
before any code moved), 26 characterisation tests around the nine files that
had no hermetic fake-`container` coverage (increment 1), the contract and
Apple adapter with the `DX_RUNTIME` registry field (increment 2), eleven
one-file-or-group migration commits (increment 3), the automated source
audit (increment 4), fixes found by validation, the ratchet re-measures, the
docs (increment 5) and the live-gate evidence.

## What changed (mechanical, no behaviour change)

- `bin/lib/dx-runtime.sh`: 25 `dx_runtime_<op>` functions dispatching on
  `DX_RUNTIME` (default `apple`; `docker` refused with "not implemented until
  Phase 2"); plain function calls with no intermediate subshell or pipe, so
  a caller's stdin (piped, redirected from a file, or a TTY) and the guest
  command's exit status pass through unchanged — proven in
  `tests/test_sourceable_coverage.sh`.
- `bin/lib/dx-runtime-apple.sh`: the existing Apple `container` behaviour as
  argument-passthrough functions; `dx_runtime_apple_run_ephemeral` carries
  `dx-migrate-persist`'s bounded retry on the Apple runtime-client race
  verbatim (moved into the adapter because the race is the Apple CLI's, per
  the coordinating session's decision); host-identity and the four DQ2
  capability queries defined with Apple's fixed answers, unwired in Phase 1.
- Every entrypoint and library under `bin/` now calls the contract; the
  existing wrapper names in `bin/lib/dx-container.sh` are unchanged for
  their callers. Two additions beyond DQ2's literal list (ephemeral run;
  Apple's `system` start/status) and two things deliberately outside it
  (`dx-reclaim`'s host-side sparse-image measurement, `dx-nix-disk`) are
  explained in `docs/refactor/runtime-boundary.md`.
- `tests/test_runtime_boundary_audit.sh` (Section 32) fails if any file under
  `bin/` other than `bin/lib/dx-runtime-apple.sh` invokes a raw `container`
  lifecycle verb; zero remain.

## Gates

| Gate | Result |
| --- | --- |
| G1 bash-3.2 | 99/0 |
| G1 pinned ShellCheck 0.10.0 | two warnings in the new audit test's own exception list fixed; then clean |
| G1 container-free contracts (runner-matched) | green throughout, 0 failures on the finished tree |
| G2 coverage | `covered=100%` over the scope including both new libraries; ratchet 1948 → 1954 on the branch's base (scope grew faster than total), re-measured after the rebase |
| G3 Nix | not applicable (no `.nix`/lock file changed) |
| G4 live | `dx-test`, below |
| G5 CI | GitHub Actions on the pushed rebased branch, green before `main` was fast-forwarded |

Red/green: the audit test was proven red/green against disposable fixtures;
the registry field and dispatch had red tests first; a coverage-invisible
`apple) ;;` case arm was fixed the way `dx-backup.sh` documents.

## Live validation on `dx-test` (default 12 GB, through the adapter)

- `dx-start-container` + `dx-wait-ssh`: clean.
- `tests/run-tier.sh live`: **1441 passed, 0 failed, 9 skipped**.
- `dx-stop-container` → `dx-start-container` → `dx-wait-ssh`: clean.
- `dx-recreate` (stdin from /dev/null; its trailing interactive attach ends
  harmlessly with "not a terminal" under a non-interactive harness) then an
  independent `dx-wait-ssh`: ready.
- `dx-backup --dry-run` into a scratch `DX_BACKUP_DIR`: 168 files /
  662,590 bytes would transfer — exec with stdin and `-u` through the
  adapter, clean.
- `dx-test` cold-stopped at the end; memory 12288 MB throughout; `dx-host`
  and the NAS untouched.

Dual-target stand-in: Section 27 green; the Phase 0 dry-runs print their
command lists. Phase 2 adds `bin/lib/dx-runtime-docker.sh` behind the same
contract without touching the entrypoints again.

## Landing (2026-09-27)

Rebased onto `main` `f3b7cb5` (Branch 16 had landed meanwhile); only
`tests/coverage/ratchet.env` overlapped, and every file's delta is identical
before and after the rebase (verified by diffing the diffs), so the results
above stand for the rebased commits. Re-checked by the coordinating session
on the rebased tip: bash-3.2 suite, Sections 1, 10 and 27, the audit test,
the Phase 0 dry-runs, the private identifier scan.
