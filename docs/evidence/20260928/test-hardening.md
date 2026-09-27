# Test hardening (`fix/test-hardening`) — evidence

Sanitised evidence record for the four "Open follow-ups" the consolidation
plan carried. No home-directory paths, keys, fingerprints, or NAS identifiers
appear below.

Branch `fix/test-hardening`, from `main` `6688a7c`, rebased onto `756d269`
before landing (Branch 12 had landed meanwhile; one conflict, two independent
test blocks appended at the same place in Section 9, both kept; every other
file's delta identical before and after). Implemented by a Sonnet subagent
against fixtures and fakes only; reviewed, live-checked on `dx-test` and landed
by the coordinating session (user decision 7a, 2026-09-27: all four items, one
branch, in parallel with Phase 4 and Branch 12).

## What changed (one commit per item)

1. **Section 27's fake `ssh` no longer blocks on an inherited open stdin.**
   The reparse dispatch drained stdin unconditionally; only `exec -i` (the
   real tar stream in the Phase 0 spike's step 6) is ever piped, so the drain
   is now gated on `exec -i` and every other subcommand redirects its own
   stdin from `/dev/null`. New bounded test (a never-closing FIFO on the test
   process's own stdin, 20 s bound): red on the old fake (timed out, status
   124), green after. Section 27 wall time fell from 43 s to 24 s.
2. **`dx_backup_restore_status` is one pass, not O(n²).** The per-target awk
   scan of the whole guest-hash batch is replaced by one local-hashes pass and
   a single two-file awk join with exact field-1 matching (Branch 17's rule).
   New 60,000-target fixture: the old algorithm had not finished after 10
   minutes; the new one classifies exactly 40,000 identical / 10,000 conflict /
   10,000 create. Its wall time varied from 87 s alone to 337–452 s while two
   other subagents' suites ran on the same host, so the test's bound was
   widened to 1,800 s rather than weakening the assertion; the sub-minute
   figure is re-confirmed on a quiet host below. Existing fixtures unchanged.
3. **Section 6's live tmux-resurrect probe waits for the observable
   condition.** A bounded poll (10 × 1 s) for the `@resurrect-dir` option and
   both key bindings together replaces a single immediate read. Unit-proven
   with a fake `tmux` that answers "unsettled" three times; the live stability
   proof is below.
4. **`dx-status` shows the keyring.** A "keyring: live / stale / not running"
   line through `dx_runtime_exec` (so docker-ssh profiles get it for free);
   the not-started and probe-failure cases both say "not running". The
   Section 9 fixture now distinguishes `bash -lc` script bodies by substring,
   which no existing assertion depended on.

## Gates

| Gate | Result |
| --- | --- |
| bash-3.2 (subagent) | 655 passed, 0 failed |
| Container-free contracts (`run_all_tests.sh --skip-integration`, subagent) | 1,558 passed, 0 failed, 18 skipped |
| Pinned ShellCheck 0.10.0 and apt 0.9.0 | clean |
| Nix (`nix flake check`) | all checks passed; `flake.lock` unchanged |
| Coverage (`tests/run-coverage-linux.sh`) | `covered=100%`, `scope_share=21.29%` (re-run by the coordinating session on the rebased tip, exit 0); ratchet 2164 → 2139 on the branch, re-baselined to 2129 after the rebase (union with Branch 12's test growth; 6,883 / 32,323 on a clean export) |
| Private identifier scan | clean |

## Live checks on `dx-test` (coordinating session, 2026-09-28)

Run from the branch worktree after the fast tier finished (quiet host), stdin
from `/dev/null` throughout.

- **Item 4:** `dx-status` printed `keyring: stale` right after the restart
  (Branch 16's expected post-restart state) and `keyring: live` after a cold
  `dx-ai` started D-Bus and the Secret Service.
- **Item 3:** Section 6 ran three consecutive times against the live guest:
  158 passed, 0 failed, 1 skipped each time — no timing flake.
- **Item 2, first attempt:** `dx-restore --dry-run` over Branch 17's retained
  mirror (60,168 manifest entries) still had not finished after 15 minutes
  and was stopped at the bound — the same outcome as before the fix. The
  O(n²) join is gone, but the run spends its time in the local hashing loop:
  one `dx_pbs_hash_entry` subprocess per mirror entry, all 60,168 of them,
  every one wasted in this case because the guest held none of the paths
  (each would classify as `create`). The refinement — hash locally only for
  targets the guest reports present, with an all-absent 60k fixture that
  must finish in well under a minute — was sent back to the subagent; the
  re-timed live run is recorded below.
- **Item 2, re-timed after the refinement (only guest-present targets are
  hashed locally):** the same full-mirror dry-run over 60,168 manifest
  entries against `dx-test` now completes, exit 0, in **97 s** (60,118
  `create`, 46 `identical`, 4 `OVERWRITE`), where two earlier attempts had
  not finished in 13 and 15 minutes. The unit fixture for the all-absent case
  went from 424 s (60,000 local hashes) to 4 s (none). The plan's "well
  under a minute" target is not quite met live: the remaining ~1.5 minutes is
  the guest-side status/hash batch for 60,168 target paths over one exec,
  which this branch did not touch. Recorded as is; a further cut would be a
  separate, smaller follow-up only if full-mirror dry-runs turn out to be a
  routine operation (they are not today).

## Landing (2026-09-28)

Rebased onto `main` `756d269` (Branch 12 had landed meanwhile; one
two-blocks-appended conflict in Section 9, both kept; every other file's delta
identical before and after). Ratchet re-measured on a clean export after the
refinement: 6,913 / 32,477 = 2128 bp, equal to the committed baseline. Private
identifier scan clean. The subagent's confirming coverage run and the
coordinating session's own (`covered=100%`, `scope_share=21.29%` before the
refinement, 21.28% after) both passed. `dx-test` was cold-stopped after the
live checks.
