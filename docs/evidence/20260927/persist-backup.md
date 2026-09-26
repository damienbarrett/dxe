# /persist backup and restore (Branch 10, `feat/persist-backup`) — evidence

Sanitised evidence record for `checkout-consolidation-plan.md`'s Branch 10
(the `plan.md` B1 item, decision Q5). No home directory paths, keys,
fingerprints, or NAS identifiers appear below.

Branch `feat/persist-backup`, from `main` `bf49f4d`, rebased onto `main`
`6d9a4ca` before landing (commit ids below are the rebased ones). Commits, in
order: `182f55d` (selection rules: the guest selector library), `0c4d82f`
(`dx-backup` capture: manifest diff, one incremental tar transfer, mirror
pruning, atomic manifest), `e269bbc` (`dx-restore`: targets, conflict check,
`--dry-run`, `--force`, push with ownership), `b87d077` (docs; `plan.md`
retired), `f478c6a` (ratchet), `c1e109e` (`DX_BACKUP_DIR` registered in the
config registry), `2e3a1c3` (guest tool assumptions found live: no `awk` in
dx's profile, root-owned `/persist` entries, `COPYFILE_DISABLE` on the
restore tar), `db63e9f` (ratchet), `98b8c7d` (review fix: exact-path match in
the restore conflict check; deny-list duplication guarded by a test),
`718ecdb` and the landing re-measure (ratchet).

## Design as landed (user decisions 2026-09-27)

- Destination `DX_BACKUP_DIR/<DX_CONTAINER_NAME>/` with `DX_BACKUP_DIR` a
  registered config field defaulting to `~/Backups/dxe-persist`; layout
  `current/` (one mirror), `manifest.tsv`, `last-run.log`.
- Transport: the existing tar-over-`container exec` idiom; no new guest
  dependency.
- Selection (guest selector `scripts/lib/dx-persist-backup-select.sh`,
  shipped through the bootstrap volume): committed, unmodified files whose
  repository has them on a remote are skipped; modified/staged/untracked
  files, files outside any repository, and whole repositories with unpushed
  commits or no remote (including their `.git/`) are at risk; ignored files
  are included minus a component deny-list (`node_modules`, `target`,
  `.direnv`, `result*`, `__pycache__`, `.cache`, `dist`, `build`, `.venv`,
  `.tox`, `.pytest_cache`, `.mypy_cache`) and the AI-generation profile
  trees; `DX_BACKUP_EXCLUDE_FILE` extends it. A `.git` file (not a directory)
  is treated as outside any repository, with a warning.
- Incremental: the host diffs the guest listing (`path size mtime sha256`)
  against `manifest.tsv`, fetches only new/changed paths in one tar stream,
  removes paths no longer at risk, and rewrites the manifest atomically.
- Restore: `dx-restore [--dry-run] [--force] [PATH…]` pushes from `current/`
  into `/persist`, restoring `dx` ownership; refuses without `--force` when a
  target exists in the guest with different content.

## Gates

| Gate | Result |
| --- | --- |
| G1 bash-3.2 | green, including the three new test files |
| G1 container-free contracts (runner-matched) | "All tests PASSED!" (re-run after every increment) |
| G1 pinned ShellCheck 0.10.0 | exit 0 |
| G2 coverage | `covered=100%`; ratchet 1785 → 1945 (own scope lines) → 1948 after the rebase |
| G3 Nix | not applicable (no `.nix` file changed) |
| G4 live | `dx-test`, below |
| G5 CI | GitHub Actions on the pushed rebased branch, green before `main` was fast-forwarded |

Red/green per increment: forcing the whole-repo at-risk check to "safe"
failed 7/42 selection assertions; forcing the diff to report empty sets
failed 8/21 capture assertions; forcing the restore status to "identical"
failed 3/16 restore assertions; the review fix's suffix-path case failed on
the old substring match; the deny-list sync test failed when one inline
copy was mutated. All green afterwards.

## Live validation on `dx-test` (default 12 GB)

Fixture under `/persist` as `dx`: repo A (local bare "remote", pushed
commit, an uncommitted edit, a staged `.gitignore`, a gitignored secret-like
file), repo B (local bare "remote", pushed commit plus one unpushed commit),
a loose file, a `node_modules` cache directory.

- The first `dx-backup --dry-run` exposed two guest-side gaps a host-only
  fixture could not show (`awk` absent from dx's profile; noisy
  permission-denied output on root-owned `/persist` entries) and, at
  restore, a noisy PAX header from the host's tar — all fixed in `2e3a1c3`,
  re-synced, re-run clean.
- `dx-backup`: **240 files, 670,505 bytes transferred**; `manifest.tsv` has
  240 lines; every fixture file present byte-for-byte; repo A's pushed,
  unmodified file and the whole cache directory correctly absent.
- Second `dx-backup`: **"0 files, 0 bytes transferred."**
- Fixture deleted in the guest; `dx-restore --dry-run` lists every file as
  "would create"; `dx-restore --force <fixture>` restored **81 files**; the
  restored content pulled back and diffed against the mirror is
  **byte-for-byte identical**, and `git log` in restored repo B shows both
  commits including the never-pushed one (repo A's `.git/` is absent by
  design: it was safe).
- Full live tier (`tests/run-tier.sh live`): **1394 passed, 0 failed,
  8 skipped** across 32 files. `dx-test` cold-stopped afterwards; `dx-host`
  and the NAS never touched.

Dual-target stand-in: Section 27 and the Phase 0 dry-runs green; no QNAP
file touched.

## Landing (2026-09-27)

Rebased onto `main` `6d9a4ca` (Branches 8, 14, 15 and the promotion docs had
landed meanwhile); `README.md` and `tests/coverage/ratchet.env` overlapped
and were merged by hand. This branch's own files are byte-identical before
and after the rebase, so the results above stand for the rebased commits.
Re-checked by the coordinating session on the rebased tip: bash-3.2 suite,
Sections 1, 10 and 27, the Phase 0 dry-runs, the private identifier scan.
