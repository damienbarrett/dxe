# Consolidation ledger — 2026-09-26

Sanitised for the repository. The private archive is referred to here only
by its identifier, `dxe-snapshot-20260926`; it is restore-verified
(2026-09-26) and retained privately, not committed. Key files (SSH
keypairs, etc.) are described generically, never by their private path.
Manifests (file lists, runtime inventory, GC settings) are retained in
that same private archive.

| ID | Item | Status | Disposition | Evidence | Date |
| --- | --- | --- | --- | --- | --- |
| S1 | Both clones + evidence dir + plan | preserved | Archive, restore-verified (files, modes, refs, diffs, fsck) | archive | 2026-09-26 |
| S2 | dxe unreachable: 42 commits, 57 trees, 28 blobs | preserved | Commits pinned as refs/archive/unreachable/*; trees/blobs in the private archive. 15 commits dispositioned below ("Historical refs") | private archive (dxe-snapshot-20260926) | 2026-09-26 |
| S3 | gc.auto | changed | Set to 0 in both clones; previously UNSET -> restore with `git config --unset gc.auto` | private archive (dxe-snapshot-20260926) | 2026-09-26 |
| S4 | dxe-agent uncommitted work (13 modified, 3 untracked) | preserved | Local branch preserve/dxe-agent-opencode @ ff8f6bd (keys excluded); -> Branch 5 | git log | 2026-09-26 |
| S5 | dxe dirty: bin/dx-herdr | assigned | Branch 1 (fix/ci-baseline) | | 2026-09-26 |
| S6 | dxe dirty: tests/test_section12_validate_linux.sh | assigned | Branch 5 | | 2026-09-26 |
| S7 | dxe dirty: tests/test_section10_docs.sh (*-context.md exemption) | assigned | Dropped in Branch 4 (note deleted instead) | | 2026-09-26 |
| S8 | dxe untracked: opencode-context.md | assigned | Deleted in Branch 4; live steps -> Branch 5 validation record | | 2026-09-26 |
| S9 | The dx-opencode profile's SSH key pair (dxe-agent, gitignored) | preserved | Private archive only; not carried forward (dx-opencode profile dropped) | private archive (dxe-snapshot-20260926) | 2026-09-26 |
| S10 | Runtime: dx-opencode container + 3 volumes | open | Decide at Branch 5 retirement (not auto-destroyed) | runtime-inventory.txt | 2026-09-26 |
| S11 | Runtime: no dx-tinty or legacy-mount container present | open | Input to Branch 7 inventory | runtime-inventory.txt | 2026-09-26 |
| S12 | S6/S7/S8 moved out of dxe working tree | preserved | section12 -> branch5-section12-opencode-assertions.patch; section10 -> dropped-section10-context-exemption.patch; opencode-context.md moved to archive dir | archive dir | 2026-09-26 |
| S13 | gc.auto | closed | Restored (unset) in both clones after pins + verified archive; plan updated: pins deleted after Branch 4 dispositions | git config | 2026-09-26 |
| S14 | Branch 1 fix/ci-baseline | done locally | 5 commits 14da20d..ae5d623; all CI steps reproduced green locally; awaiting push/CI | private recovery archive (progress log) | 2026-09-26 |
| S15 | Branch 1 fix/ci-baseline | landed | 10 commits 14da20d..086d9ce; branch CI 36206811575 green (both jobs); main fast-forwarded 71c2b50 -> 086d9ce; main CI 36207063275 pending | GitHub Actions | 2026-09-26 |
| S16 | Stray progress file written outside the intended private-archive location (a subagent wrote to the wrong directory) | closed | File moved into the private recovery archive; the stray directory removed | | 2026-09-26 |
| S17 | main CI | closed | main 086d9ce CI run 36207063275 green (both jobs) — first green main since 2026-08-01 | GitHub Actions | 2026-09-26 |
| D-Q2 | OpenCode partial on main | decided | User: revert now (Branch 2), re-land complete in Branch 6 | conversation | 2026-09-26 |
| D-QNAP | QNAP runtime | decided | User: accepted; Phase 0 early; impl after Branches 9 and 10. Target TVS-h674T (x86_64, to confirm) | conversation | 2026-09-26 |
| D-dxtest | dx-test data | decided | User: disposable; may be wiped for Step 4 | conversation | 2026-09-26 |
| S18 | Branch 2 revert/opencode-partial | pushed, CI pending | d5d74d7, 43a7bf9, 0cf61bd; local G1/G2/G3 green; ratchet 2138->2144 verified on clean export; awaiting user review before merge (checkpoint 1) | CI 36209094615 | 2026-09-26 |
| S19 | Branch 2 revert/opencode-partial | landed | main 086d9ce -> 0cf61bd; branch CI 36209094615 green; main CI 36209410452 pending; reviewed by main session (clean; -T hardening + dxPackages regex carried to Branch 6) | GitHub Actions | 2026-09-26 |
| S20 | Subagent brief | created | SUBAGENT-BRIEF.md in the private recovery archive: standing rules for all subagents (paths, progress file, git, CI-matching validation, ratchet method, containers, long runs) | private recovery archive | 2026-09-26 |
| S21 | Branch 3 approach | decided (main session) | test-image.png is unreferenced anywhere; remove the fetch rather than vendor a PNG; user may override to vendoring | plan | 2026-09-26 |
| S22 | main CI after Branch 2 | closed | main 0cf61bd CI run 36209410452 green (both jobs) | GitHub Actions | 2026-09-26 |
| S23 | Branch 3 fix/test-image-fixture | pushed, CI pending | 0b3e4d9 (remove fetchurl fixture + Section 6 guard), bd2418f (ratchet 2144->2143); reviewed by main session; CI 36210506410 | GitHub Actions | 2026-09-26 |
| S24 | Branch 3 fix/test-image-fixture | landed | branch CI 36210506410 green; main 0cf61bd -> bd2418f; main CI 36210738709 pending | GitHub Actions | 2026-09-26 |
| S25 | main CI after Branch 3 | closed | main bd2418f CI run 36210738709 green (both jobs); Step 4 baseline started on subagent | GitHub Actions | 2026-09-26 |
| S26 | Step 4 finding 1: dx-wait-ssh false "container stopped" | open -> Branch 4a | container_is_running/container_exists use `| grep -q` under pipefail callers; SIGPIPE on printf makes a matched name read as false; fresh dx-test bring-up aborted at ~92s while guest was healthy. Fix branch fix/container-running-sigpipe in linked worktree (Sonnet) | private recovery archive (run log, retained privately) | 2026-09-26 |
| S27 | Step 4 finding 2: live tier does not create a guest | recorded | Section 11 skips without a running container; first live run built nothing (963 pass, 1 fail = Section 4 key-only SSH probe fails instead of skipping) | private recovery archive (run log, retained privately) | 2026-09-26 |
| S28 | Step 4 baseline of main bd2418f | passed (addendum running) | G2 100%/21.43%; fresh dx-test factory-reset -> bring-up ~5 min -> live tier 1081/0/10 "All tests PASSED!" EXIT=0; booted generation == published, no drift; evidence sanitised into docs/evidence/20260926/main-baseline.md; Section 12 in-guest run in progress | private recovery archive (run log, retained privately) | 2026-09-26 |
| S29 | Step 4 finding 3: Section 12 runs in no gate | open -> Branch 4b | test_section12_validate_linux.sh gates on host uname; skipped on macOS live tier, not in kcov, not in CI. Needs to run inside the guest | evidence file | 2026-09-26 |
| S30 | Step 4 observation C: Section 18 write_history probe inconclusive on ssh known-hosts warning | open -> Branch 4b | probe output polluted by "Warning: Permanently added" -> SKIP instead of pass/fail | private recovery archive (run log, retained privately) | 2026-09-26 |
| S31 | Step 4 finding 4: stale Section 12 assertion | open -> Branch 4b | test_section12_validate_linux.sh:108 greps bootstrap.sh for a pre-refactor pattern ("idempotency checks"); substantive Section 12 checks passed in-guest (14/1/0) | private recovery archive (run log, retained privately) | 2026-09-26 |
| S32 | Step 4 complete | closed | Section 12 run in-guest 14/1/0 (1 stale assertion = finding 4); evidence file final; dx-test stopped, volumes intact | sanitised: docs/evidence/20260926/main-baseline.md | 2026-09-26 |
| S33 | Branch 4a fix/container-running-sigpipe | pushed, CI pending | ccc9fac fix+test, 596ac28 ratchet 2143->2134; reviewed; linked worktree under the private recovery archive (removed after merge) | GitHub Actions | 2026-09-26 |
| S34 | Guest-side same-shape pipelines | open -> Branch 4b | scripts/dx-theme.sh:30 (`tinty list | grep -qx`), scripts/dx-theme-write-tool-themes.sh:374 (`| head -n1`) under pipefail | 4a report | 2026-09-26 |
| S35 | Branch 4a fix/container-running-sigpipe | landed | branch CI 36212372284 green; main bd2418f -> 596ac28; main CI 36212653165 pending; worktree removed | GitHub Actions | 2026-09-26 |
| S36 | main CI after Branch 4a | closed | main 596ac28 CI run 36212653165 green (both jobs) | GitHub Actions | 2026-09-26 |

## Historical refs (Appendix B dispositions)

Per Appendix B of `checkout-consolidation-plan.md`: 15 unreachable commits
plus `refs/guest/herdr-tmux-navigation` (`3f2a910`, `e58fefc`) needed a
disposition. All 17 are dispositioned below; each was checked with
`git show --stat`, `git diff <sha>^ <sha> | git patch-id --stable` against
the named candidate(s), `git merge-base --is-ancestor` against `HEAD`, and
`git log -S`/`grep` of the current tree for the unique content. A missing
exact patch-id match does not by itself mean the functionality is missing —
several items below were reimplemented against a later refactor (module
split, base-image move) rather than cherry-picked, so the disposition rests
on behavioural/textual evidence, not only patch-id equality.

| SHA | Subject | Disposition | Evidence |
| --- | --- | --- | --- |
| `3f2a910` | add tmux-style Herdr pane navigation | Already present | Patch-id identical (`30488c1…`) to `9bc04a4`, an ancestor of `HEAD`; `herdr-navigator.lua` and `dx-herdr-navigate.sh` are in the current tree via that lineage. |
| `e58fefc` | persist Herdr config and sessions across rebuilds | Superseded | By `753c554` ("Seed Herdr config through a merger that understands key bindings"), which explicitly reconciles two independently-grown persistence implementations, keeping the piece each needed. Current tree has both `bootstrap/persistence.sh` and `bootstrap/herdr-config.sh`. |
| `7fe6caf` | "On herdr-guest-integration: tunnel-self-heal-wip" | Superseded | By `dc75be3` ("Keep tunnel state where macOS will not delete it") and `8ba2a69` ("Recover a tunnel whose metadata /tmp reaped out from under it"), both ancestors of `HEAD`. Current `bin/lib/dx-tunnel.sh` already has the `dx_tunnel_recover_peer`/`dx_tunnel_recover_key` self-heal logic this WIP was exploring. |
| `71e00fe` | disk-size wiring (WIP on `fix/dx-wait-ssh-probe-budget`) | Superseded | By `98e11a7` ("Wire DX_NIX_DISK_SIZE through to the guest, canonical default 64G (P10)"), confirmed ancestor of `HEAD`; matches current `bin/lib/dx-config.sh`/`docs/configuration.md`. |
| `7fd234b` | early OpenCode tests (WIP on `fix/dx-wait-ssh-probe-budget`) | Superseded | By `0f71be4` ("Add OpenCode to the optional AI toolchain"), whose `test_section6_tools.sh`/`test_section17_dx_ai_runtime.sh` additions are a fuller version of the same assertions. `0f71be4` was itself reverted off `main` by Branch 2 (`d5d74d7`); flagged for Branch 6 to consult if it re-lands OpenCode tests, but nothing here is unique work. |
| `8d7f85c` | "WIP on main: … Stop the audit suite depending on an unreachable commit" (migration retries in `bin/dx-migrate-persist`) | Superseded | By `5966c35` ("Retry the Apple Container runtime-client race in dx-migrate-persist") and `1222c08` ("Narrow the migrate retry to the signature it claims, and fix the alignment command"), both ancestors of `HEAD` — the later, narrower error check was kept, as intended. |
| `2003457` | WIP adding `dx-forward`/`dx-reverse` docs and tests | Already present | `bin/dx-forward` and `bin/dx-reverse` are fully implemented and documented on `main` today (16 README references). |
| `02cbe55` | "Link the essentials bash at /usr/bin/bash for SSH sessions" (WIP, targets the retired `dx-nixos-25.11` directory) | Superseded | By `dd06e2f` ("Resolve the essentials PATH before the reinstall skip-gate"); its exact comment text ("would never see a previous boot's…") is verbatim in current `bootstrap/base-and-storage.sh:install_essentials`. The `/usr/bin/bash` linking goal is met by `link_system_bash` in the same file. |
| `4cfeefa` | Same change as `02cbe55` (identical patch-id `84c07f6e…`; a duplicate WIP snapshot) | Superseded | Same as `02cbe55`. |
| `0c74f90` | WIP tweak to `test_section23_herdr.sh` (fixture SSH key instead of the default path) | Already present | The `DX_SSH_KEY="$fake_dir/ssh-key"` fixture pattern this WIP introduced is throughout the current file, with the same explanatory comment. |
| `d8070c1` | WIP adding `nvim/plugins/project-nvim.nix` | Already present | The file is byte-identical to the one in the current tree (empty `diff`). |
| `55e0efa` | "Persist the guest SSH host identity across rebuilds" (carries a `host-key-persistence-plan.md` explaining it is a re-implementation because its source branch targeted the retired `dx-nixos-25.11` bootstrap monolith) | Superseded | By `7c4128d` (identical subject), confirmed ancestor of `HEAD`; `dx_persist_host_keys` exists in current `bootstrap/system.sh`. |
| `e8246ff` | "Make guest bootstrap ownership and store import bounded and recoverable" | Superseded | By `3adeecd` (identical subject), confirmed ancestor of `HEAD`. |
| `e869eac` | "Harden fresh-bootstrap waits and publish guest release identity" | Superseded | By `278eb17` (identical subject), confirmed ancestor of `HEAD`; further refactored since into `bin/lib/dx-host-util.sh`. |
| `773c120` | "Move the base image to the official nixos/nix image" | Superseded | By `e8e0dd0` (identical subject), confirmed ancestor of `HEAD`; current `Containerfile` is `FROM nixos/nix:2.34.7@sha256:…`. |
| `3244307` | "WIP: Claude Code rate-limit checkpoint" | Rejected | Touches only `.claude/RESUME.md` (a session continuation note); no production or test content. |
| `1e29069` | "WIP: Claude Code rate-limit checkpoint" | Rejected | Same as `3244307`. |

**Summary:** 3 already present, 12 superseded, 2 rejected, 0 unique work,
0 pending. Nothing was implemented as part of this disposition pass — per
Branch 5's instructions, dispositioning is a classification exercise, not an
implementation one.
