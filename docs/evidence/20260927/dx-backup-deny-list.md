# dx-backup deny-list additions (Branch 18, `fix/dx-backup-deny-list`) — evidence

Sanitised evidence record for `checkout-consolidation-plan.md`'s Branch 18.
No home directory paths, keys, fingerprints, or NAS identifiers appear
below.

Branch `fix/dx-backup-deny-list`, from `main` `abd4d2d`. Commits, in order:
`96672b7` (deny-list additions: `.pnpm-store`, `.Trash-*`, `.tmp`,
`home/dx/.gemini/antigravity-cli`), `04e2a12` (default exclude-file
location), `434da45` (mid-task addition: nested-repository duplicate-path
fix), `b644917` (mid-task addition: `--hard-dereference` on the guest-side
archive create), `8ee92eb` (G2 coverage-gap closures), `d713906` (ratchet
re-measurement), plus this docs commit (this file, `docs/lifecycle.md`,
`checkout-consolidation-plan.md`).

## Why (user-approved 2026-09-27, option 1a)

The first real `dx-backup --dry-run --summary` on the primary guest
selected 3.23 GB; about 600 MB of it was rebuildable content the built-in
deny-list did not yet cover. Approved additions:

1. Built-in component deny: `.pnpm-store` (pnpm's content-addressable
   package store), `.Trash-*` (trash directories), `.tmp` (transient
   scratch, e.g. under `~/.codex`).
2. Built-in path deny: `home/dx/.gemini/antigravity-cli` (the `agy` binary
   bundle `dx-ai` reinstalls; sibling config/credentials elsewhere under
   `.gemini` stay in).
3. A default location for the user's extra exclude file:
   `${XDG_CONFIG_HOME:-$HOME/.config}/dxe/dx-backup-exclude`, read when
   `DX_BACKUP_EXCLUDE_FILE` is unset and that file exists; an explicit
   `DX_BACKUP_EXCLUDE_FILE` still wins.
4. `--dry-run --summary` "denied by the deny-list" line: **not
   implemented** — see "Item 4" below.

## Mid-task addition: a nested-repository duplicate-path crash

Found live on the primary guest while this branch was in flight: `dx-backup`
failed with macOS tar "Skipping hardlink pointing to itself" under
`git/shopping/scraper/...`. Root cause: `shopping/scraper` is a git
repository nested inside `shopping` (a plain subdirectory containing its own
`.git`, not a submodule), and `shopping` is itself at-risk-as-a-whole (no
remote). The outer whole-repo walk had no notion of a nested repository's
boundary, so it walked straight through `scraper`'s working tree and
`.git`, while the selector's own repo-discovery separately found `scraper`
and emitted it again via its own pass — every path under it appeared twice
in the listing. The guest's tar then treated the second occurrence as a
hardlink to the first, which the host's tar refused to extract.

Fixed with two independent, complementary changes:

1. **Selector-level dedup (root cause):** the outer walk now prunes at
   every OTHER discovered repository's boundary (`dx_pbs_walk_repo_files`
   gains an optional nested-repos-file parameter; a new
   `dx_pbs_nested_repos_for` computes it from the same `repos_file` the
   driver already builds). Chosen over de-duplicating the listing
   afterward: it fixes the boundary decision once, in the one place it
   belongs, and as a side effect also fixes a related correctness gap — a
   nested SAFE (pushed, clean) repository's own clean files were
   previously swept in wholesale by the outer's blind whole-repo walk,
   which had no way to know the nested repo's own git status.
2. **`--hard-dereference` (defense in depth):** `dx_backup_fetch_paths`'s
   guest-side tar create now passes `--hard-dereference`, so any duplicate
   path (from this shape, or a possible future one) is always shipped as
   an independent regular-file copy, never a self-referential hardlink
   record.

## Item 4 (not implemented) — why

`--dry-run --summary`'s "Denied by the deny-list: N files, B bytes" line,
to show how much the deny-list removed, was investigated and **not**
implemented: the at-risk walk prunes every component-denied directory
(`node_modules`, `.cache`, `.pnpm-store`, etc.) with `find -prune` before
that content is ever visited, so no per-file loop in the selector ever
sees what is inside one, to count or size it. Only PATH-shaped denies (the
Nix-profile generations pattern, `.gemini/antigravity-cli`, and
exclude-file patterns) are ever visible to count that way during the
existing single walk — and those are typically a small fraction of what
the deny-list actually removes. Making the count complete would mean
walking into every pruned directory to size it, which is exactly the walk
the pruning exists to avoid, and would slow every dry-run summary on a
real `/persist`. Left as an open follow-up in the plan with three options
recorded (a partial, clearly-labeled counter; a slower complete count; or
dropping the idea in favor of Branch 17's existing by-directory/by-reason
breakdown).

## Gates

| Gate | Result |
| --- | --- |
| G1 bash-3.2 (`tests/run-bash32-tests.sh`) | 7 files, 0 failures (117+24+98+70+47+24+99 = 479 passed, 0 failed, 0 skipped) |
| G1 pinned ShellCheck 0.10.0 (`--severity=warning`) | exit 0, 0 findings (throwaway `nixos/nix:2.34.8`, `-m 6g`) |
| G1 container-free contracts (`tests/run_all_tests.sh --skip-integration`) | "All tests PASSED!", exit 0 — on a clean local clone; see the worktree note below for why not the worktree directly |
| G2 coverage | `covered=100% scope_share=20.04%`, exit 0 (`tests/run-coverage-linux.sh`) |
| G3 Nix | not applicable — no `.nix` file changed; confirmed via `git diff --stat abd4d2d..HEAD -- '*.lock' '*flake.nix'` (empty) |
| Dual-target stand-in (Section 27 / QNAP Phase 0 dry-runs) | included in the G1 bash-3.2 run above (`test_section27_qnap_scripts.sh`, part of the 99-test file); stdin redirected from `/dev/null` throughout |
| G4 live | not run by this subagent — the task's design: no live gate is needed (the change is in selection rules the unit fixtures exercise exactly); the coordinating session runs `dx-backup --dry-run --summary` against the primary guest after landing and records before/after sizes. The nested-repo/`--hard-dereference` fix's own live re-verification is also the coordinating session's. |

## Red/green evidence (per increment)

- **Deny-list additions (`96672b7`):** 4 new fixture assertions
  (`.pnpm-store`, `.Trash-1000`, `.codex/.tmp`, `.gemini/antigravity-cli`)
  failed against the unchanged selector (62 passed, 4 failed). Green: 66
  passed, 0 failed, including Branch 10's inline/variable sync guard
  staying green untouched. Reverting just the production file reproduced
  the same 4-assertion red again.
- **Default exclude-file location (`04e2a12`):** 3 new tests in
  `tests/test_dx_backup.sh` (a fixture
  `$XDG_CONFIG_HOME/dxe/dx-backup-exclude`; an explicit override; a
  missing default file) — 1 failed for the right reason against unchanged
  `dx-backup` (44 passed, 1 failed). Green: 44 passed, 0 failed. Test
  bites confirmed.
- **Nested-repository dedup (`434da45`):** 3 assertions (a nested-repo
  fixture mirroring the reported `shopping/scraper` shape, plus a nested
  SAFE-repo case) failed against the unchanged selector (67 passed, 3
  failed: duplicate path/`.git` entries; an over-included nested-safe-repo
  file). Green: 70 passed, 0 failed. A real bug was hit and fixed along
  the way: the first draft's `"${nested_prune[@]}"` on an empty array is
  "unbound variable" under this file's `set -u` on bash 3.2 (pre-4.4) —
  fixed with this codebase's own existing `"${arr[@]+"${arr[@]}"}"` idiom.
  Test bites confirmed.
- **`--hard-dereference` (`b644917`):** 1 new EXEC_LOG assertion in
  `tests/test_dx_backup.sh` failed against unchanged code (46 passed, 1
  failed). Green: 47 passed, 0 failed; `tests/test_dx_restore.sh` (24
  passed, 0 failed) confirmed unaffected. Test bites confirmed. Also added
  a **characterization** test (a duplicate path in the fetch list still
  produces one correct mirror entry) that starts and stays green
  regardless of the fix on this test host: this host's `tar` is bsdtar,
  which — unlike GNU tar, the real guest's tar always — only treats a
  repeated path as a hardlink when the source's real link count is
  already > 1, so the exact reported crash (nlink 1, duplicate path) is
  not reproducible here; it is only truly provable live, on the real
  guest, which the coordinating session will do. The fake `container exec`
  test doubles in both `test_dx_backup.sh` and `test_dx_restore.sh` strip
  `--hard-dereference` before their real local exec for this reason
  (confirmed empirically: bsdtar errors outright,
  "Option --hard-dereference is not supported").
- **G2 coverage-gap closures (`8ee92eb`):** the first coverage run found
  `dx-persist-backup-select.sh` at 98.87% (175/177) — two new `done < FILE`
  lines closing a bare-`case`-body loop, fixed with this file's own
  `esac; :; done < FILE` idiom (verbatim precedent:
  `bin/lib/dx-tunnel.sh:57`). The second run then surfaced a third,
  pre-existing subshell-closing `)` that started registering as
  uninstrumented once the line immediately before it changed shape;
  marked `# KCOV_SUBSHELL_TERMINATOR` (verbatim precedent:
  `bootstrap/base-and-storage.sh`). Both are coverage-instrumentation-only
  fixes; `tests/test_persist_backup_select.sh` stayed at 70 passed, 0
  failed throughout.

## A note on validating from a worktree

This branch was authored in a git worktree, whose `.git` is a file
pointing at the main checkout's real git directory — the same situation
Branch 17's evidence documents. The scope-share ratchet was therefore
re-measured the same way: a self-contained `git clone --local
--no-hardlinks` of the worktree's tip into a scratch directory (not a
`git archive` export run inside a container mounting only the worktree,
which cannot resolve the `.git` file's pointer), replicating
`tests/run-coverage-linux.sh`'s own `scope_lines`/`total_lines`
computation directly.

The same artifact bit `tests/run_all_tests.sh --skip-integration`'s first
run against the worktree directly, mounted read-write into a throwaway
Ubuntu container: exactly one failure, `test_section6_tools.sh`'s "guest
dx-ai script is tracked for flake source inclusion" (a `git -C "$BASE_DIR"
ls-files --error-unmatch ...` check) — the container cannot resolve the
mounted worktree's `.git` file to the main checkout's real git directory,
which it does not have access to. Confirmed as exactly this, not a real
regression: re-running Section 6 alone, and then the full suite, against
a `git clone --local --no-hardlinks` scratch clone of the same tip instead
gave a clean 103/0/1 and then "All tests PASSED!" (exit 0) respectively.

## Ratchet

`scope_share_basis_points` raised 1997 → 2004 bp (5,456/27,219 scope-line
share, measured on a clean local clone of `8ee92eb`, not the worktree
directly — see the note above), committed separately (`d713906`). Raised,
not lowered: this branch adds real production scope lines
(`dx-persist-backup-select.sh`, `bin/lib/dx-backup.sh`), so leaving the
prior baseline in place would have been unearned slack.

## Landing (2026-09-27)

Rebased onto `main` `4b965d7` (docs-only movement since the branch base;
no conflicts); the ratchet re-measured on a clean export of the rebased tip
is unchanged at 2004 bp. The open point from the task — a "denied by the
deny-list" total in `--dry-run --summary` — was decided by the coordinating
session as option (c): not added (the walk prunes component-denied
directories before the selector sees them, so a cheap count would mislead;
the by-directory/by-reason breakdown is the tool for that). Re-checked on the
rebased tip: bash-3.2 suite, Sections 1, 10 and 27, the runtime-boundary
audit, the three backup/restore test files, the Phase 0 dry-runs, the private
identifier scan. G5: GitHub Actions on the pushed branch, green before `main`
was fast-forwarded. Live verification on the primary guest (a
`--dry-run --summary` and a real `dx-backup` against the very nested-repo
shape that crashed the earlier run) follows the landing and is recorded in
the coordinating session's promotion notes.
