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

