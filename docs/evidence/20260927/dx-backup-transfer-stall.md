# dx-backup transfer stall (Branch 17, `fix/dx-backup-transfer-stall`) — evidence

Sanitised evidence record for `checkout-consolidation-plan.md`'s Branch 17.
No home directory paths, keys, fingerprints, or NAS identifiers appear
below.

Branch `fix/dx-backup-transfer-stall`, from `main` `2acffa9`, rebased onto
`main` `863c376` (Branch 11 Phase 1's runtime-boundary extraction landed
while this branch was in flight) before landing. Commits, in order:
`58349b8` (selector: `--with-reason`, `--hash-paths-file`), `fae89e7` (the
core fix: two-phase, unidirectional fetch transfer), `7b88bb8`
(`dx_backup_restore_status`'s ARG_MAX fallback), `3c1135f` (`dx-backup
--dry-run --summary`), `ed34a6f` (coverage-gap closures: ship-failure
branches, kcov line style), `dd790ec` (rebase follow-up: one exec missed
during conflict resolution, routed through `dx_runtime_exec`), `c906add`
(ratchet re-measurement after the rebase).

## The defect (found 2026-09-27 on the first real `dx-backup` of `dx-host`)

`bin/dx-backup --dry-run` worked (51,262 files / 3.2 GB selected). The real
run stalled for 20 minutes in `dx_backup_fetch_paths`: the guest `tar` was
sleeping with no output, the host extractor had received 0 bytes, the guest
listing phase before it had completed normally. The same code passed
Branch 10's live gate with a 240-file fixture, so the trigger is size: a
large NUL-separated name list (~3 MB) pushed through `container exec -i`'s
stdin while the archive streamed back through that same exec's stdout —
either Apple's `container exec` deadlocks on concurrent bidirectional
traffic, or stdin EOF is never delivered when the list is large. Not
characterised further; every exec is made unidirectional by construction
instead.

## Design as landed (settled in the task file; not re-decided here)

- **Two-phase fetch.** Ship the NUL-separated name list into a fresh guest
  temp file first, stdin-only (`sh -c 'cat > "$1"' -- DEST < SOURCE`,
  exactly `bin/dx-put`'s file-push shape, run through the runtime `-i`
  exec); then archive with `-T <guest temp file>` instead of `-T -`, stdin
  explicitly `/dev/null`, no `-i` at all. The guest temp file is removed
  afterward on both success and failure. New shared helpers
  `dx_backup_ship_list_to_guest` / `dx_backup_remove_guest_list` implement
  this once, reused by the ARG_MAX fallback below.
- **`dx_backup_restore_push` reviewed, unchanged.** Its archive-push exec
  is already stdin-only (`-i`; the guest's `tar -xf -` writes to disk,
  never to stdout); its mkdir/chown execs carry no stdin. No mixed
  direction found.
- **`--hash-paths` ARG_MAX.** `dx_backup_restore_status` passes every
  restore target as a positional argument to `container exec`. Above
  `DX_BACKUP_HASH_PATHS_ARG_THRESHOLD` (1000 — this codebase's paths are
  typically well under 100 bytes, so 1000 of them sit far below any real
  host ARG_MAX; below the threshold the extra guest round trip isn't worth
  paying), it ships the list into the guest as a file and calls the
  selector's new `--hash-paths-file ROOT LISTFILE` mode instead of
  `--hash-paths ROOT [RELPATH...]`.
- **Reviewing the at-risk selection size.** `bin/dx-backup --dry-run
  --summary` (requires `--dry-run`) prints the total files/bytes
  aggregated by `/persist`'s top-level directory and by selection reason
  (`modified-untracked`, `whole-repo`, `outside-repo`, `ignored-kept`),
  via a new selector mode (`--with-reason`, in `dx_pbs_list_driver`) and a
  host-side aggregator (`dx_backup_summarize`), instead of a full per-file
  listing.

## Gates

| Gate | Result |
| --- | --- |
| G1 bash-3.2 | `tests/run-bash32-tests.sh` full run: 462 passed, 0 failed across 7 files (`test_persist_backup_select.sh`, `test_dx_backup.sh`, `test_dx_restore.sh` among them) |
| G1 runtime-boundary (post-rebase) | `test_runtime_boundary_audit.sh` 5/5; `test_runtime_boundary_characterisation.sh` 26/26 |
| G1 pinned ShellCheck 0.10.0 (`--severity=warning`) | exit 0, no findings |
| G1 container-free contracts | `tests/run_all_tests.sh --skip-integration`: "All tests PASSED!" |
| G2 coverage | `covered=100%`; ratchet re-measured 1955 → 1997 bp (raised: this branch adds real scope-line production code, not just tests) |
| G3 Nix | not applicable — no `.nix` file changed; `flake.lock` unchanged |
| G4 live | **not yet run** — see below |
| G5 CI | not yet run (lands after G4) |

**A note on validating from a worktree.** This branch was authored in a
git worktree (`git worktree add`), whose `.git` is a file pointing at the
main checkout's real git directory. A throwaway container that mounts only
the worktree cannot resolve that pointer, which broke a couple of
assertions that shell out to `git` (looked content-related; were purely
this mounting artifact) and the coverage/ratchet measurement itself. Fixed
by validating against a self-contained `git clone --local --no-hardlinks`
of the worktree's tip into a scratch directory instead of a `git archive`
export of the worktree directly — incidentally closer to what CI's own
`actions/checkout` produces (a full standalone clone, not a linked
worktree).

## Red/green evidence (per increment)

- **Selector (`--with-reason`, `--hash-paths-file`):** reverting just the
  selector file failed 14/60 assertions (empty reason columns; "command not
  found" for the file-based hash mode). Green after: 60/60.
- **Core fix (two-phase fetch):** a `container` fake logging every exec
  call's flags/args, run against the pre-change `dx_backup_fetch_paths`,
  failed 5/28 assertions — the log showed the OLD single `-i` exec with
  `-T -`, not two execs. Green after: 28/28.
- **ARG_MAX fallback:** a 1001-path restore-batch fixture, run against the
  pre-change library, failed 2/22 assertions (no `--hash-paths-file` exec;
  `--hash-paths` used instead — classification and the restore push itself
  were already correct either way, only the *shape* was wrong). Green
  after: 22/22.
- **`--dry-run --summary`:** the library functions existed before the CLI
  was wired up; 2/38 assertions failed ("unrecognized argument
  '--summary'"). Green after wiring `bin/dx-backup`: 38/38.
- **Coverage-gap closures:** G2's first run found three real gaps — two
  multi-line `awk` scripts registering a kcov hit only on their first line
  (this file's own documented convention: collapse to one line); two
  behavioural gaps (the ship-exec-fails branch in both
  `dx_backup_fetch_paths` and `dx_backup_restore_status`'s ARG_MAX path,
  neither previously exercised); and two new `done < LISTFILE` lines in the
  selector never registering a hit (a bare `fi`/`done` keyword starts no
  traceable command of its own — the same convention, applied). All three
  fixed; tests green (40/24/60 across the three files).
- **Rebase follow-up:** `test_runtime_boundary_audit.sh` failed 4/5
  immediately after the rebase (`dx_backup_fetch_listing_with_reason`,
  added by a later, non-conflicting commit, still called raw `container
  exec`). Fixed; green 5/5.

## Live validation on `dx-test`

**Not yet performed.** The coordinating session confirmed `dx-test` free
(stopped, default 12 GB, AI generation present) and authorised the live
gate for this branch; the subagent's own permission classifier refused the
container-start command ("Interfere With Workloads") before any container
state changed. The task file's live plan (build a ~60,000-file fixture,
show the OLD code stalling under a bounded `timeout 300`, then the fix
completing; a second run transferring 0 bytes; `dx-restore --dry-run`
reporting the fixture identical; remove the fixture; capture `dx-backup
--dry-run --summary`'s output; the full live tier; a cold stop) is
recorded here for whoever runs it next. `dx-host` and the NAS were never
touched by this branch's work.

## Follow-up

See `docs/evidence/20260927/persist-backup.md`'s own "Follow-up" note for
the cross-reference from Branch 10's original evidence record to this
branch.

## Live gate (run by the coordinating session, 2026-09-27)

The subagent's permission classifier refused `dx-start-container` on
`dx-test`; per the user's decision the coordinating session ran the gate
from this worktree (default 12 GB, no memory override):

- Fixture: 60,000 small files under `/persist/branch17-fixture` (created in
  the guest in ~20 s), outside any repository, so all at risk.
- OLD code (`main` `863c376`, one exec with the list on stdin and the archive
  on stdout): `dx-backup` bounded to 300 s stalled for the whole bound with
  **0 bytes** received and no manifest — killed by the bound; the orphaned
  guest `tar` was terminated. (A first attempt used `timeout`, which macOS
  lacks; the bound is a `perl -e 'alarm shift; exec @ARGV'` wrapper.)
- NEW code: `dx-backup --dry-run --summary` reported 60,168 at-risk files /
  1,067,170 bytes, by top-level directory (`branch17-fixture` 60,000,
  `home` 167, one loose file) and by reason (all outside-repo). The real run
  transferred **60,168 files, 1,067,170 bytes** (about a minute after
  selection); the manifest has 60,168 entries and the mirror 60,164 regular
  files plus 4 symlinks. A second run: **0 files, 0 bytes transferred.**
- `dx-restore --dry-run` on `branch17-fixture/d1` (1,000 files) and on
  `home` (167 files): all "already identical". After changing one fixture
  file in the guest: 999 identical and exactly **1 "would OVERWRITE"**.
- A full-set `dx-restore --dry-run` (60,168 targets) was too slow to
  complete inside a 15-minute bound (per-target lookup over the batch hash
  result); recorded as a performance follow-up in the plan's Observations —
  the transfer fix and restore semantics are unaffected.
- Fixture removed from the guest; full live tier: **34 sections, 1482 passed,
  0 failed, 8 skipped**, "All tests PASSED!"; `dx-test` cold-stopped; the
  key pair copied into the worktree for the run was removed afterwards.
  `dx-host` and the NAS untouched.

## Landing (2026-09-27)

Already rebased onto `main` `863c376` by the subagent (Branch 11 Phase 1
had landed; every new exec routed through `dx_runtime_exec`). Re-checked by
the coordinating session on the tip: bash-3.2 suite, Sections 1, 10 and 27,
the runtime-boundary audit and characterisation tests, the backup/restore
test files, the Phase 0 dry-runs, the private identifier scan. G5: GitHub
Actions on the pushed branch, green before `main` was fast-forwarded.
