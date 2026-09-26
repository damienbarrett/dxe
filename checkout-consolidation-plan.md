# DXE consolidation plan

Moved into the repository on 2026-09-26; the coordinating session's copy
outside the repository is retired.

Prepared 2026-09-25. Rewritten 2026-09-26 against the repository objectives
and your notes, after re-checking both clones, GitHub CI history, the plan
documents and the local container runtimes. Nothing has been changed in either
repository yet: this is still a plan.

---

## Summary

### Where things stand

Updated 2026-09-26, after Branches 1-3, 4a, 5 and 4b landed, Step 4 passed,
and the duplicate-repository retirement below (originally planned for after
Branch 6 lands) was carried out early.

- **`main` is now `3e41f4a`.** Branches 1, 2, 3, 4a, 5 and 4b are all landed
  fast-forwards; CI is green on each. Step 4's baseline check passed on a
  freshly recreated `dx-test`. Branch 4b (`test/live-tier-hygiene`, seven
  commits) is **done**: the full live tier ran 1105 passed / 0 failed / 8
  skipped. Branch 4c (`fix/guest-sigpipe-pipelines`) is in progress; its
  scope widened past the two guest theme scripts once the same SIGPIPE shape
  turned up twice more in `bootstrap/activation.sh` (see its section below).
- **This plan now lives in the repository** as `checkout-consolidation-plan.md`
  at the root (Branch 5 item 5, commit `9064bb9`). The coordinating session's
  external copy (`~/Development/dxe-consolidation-plan.md`) is retired: it now
  only points here. Edit the plan through a docs branch and CI like any other
  change.
- **`main` is green again and contains only complete work.** Branch 1
  (`fix/ci-baseline`, 10 commits) landed as `086d9ce`, the first fully green
  CI since 2026-08-01. Branch 2 (`revert/opencode-partial`, 3 commits) landed
  as `0cf61bd`, removing the half-finished OpenCode support.
  - Beyond the four known failures, it also fixed a lint failure seen only
    with the runner's older ShellCheck.
  - It also fixed a coverage-probe failure that happened only under Docker, and
    a line-counting bug in the coverage script. The coverage threshold is
    re-measured at 21.38%.
- **A fresh guest build of `main` is probably broken.** The Home Manager config
  downloads a GitHub avatar as `test-image.png` with a pinned hash. The image
  has since changed upstream: today's download hashes to `PPs6NBjz…`, but
  `main` expects `4lDgsPtt…`. Nothing in the repository uses that file, so
  Branch 3 removes the download.
- **OpenCode is off `main` and waits for one complete delivery (Branch 6).**
  - The original support (`0f71be4`) was reverted by Branch 2 on 2026-09-26.
  - The rest is preserved on **this repository's own local branch**
    `preserve/dxe-agent-opencode` (`ff8f6bd`): safe migration of existing
    OpenCode settings, rollback to older AI tool sets, and ownership repair.
    (It originally lived in `dxe-agent/`, deleted 2026-09-26 -- see below.)
  - Guests that already opted in keep their OpenCode data; nothing deletes it.
    Until Branch 6 lands, a `dx-ai` run installs without `opencode`.
- **The duplicate clone and its throwaway test profile are retired.**
  `dxe-agent/` and `dxe-evidence-20260831/` were deleted on 2026-09-26 after
  verification: the preserved OpenCode work now lives in `dxe` itself, as
  local branch `preserve/dxe-agent-opencode` (`ff8f6bd`), and the August
  evidence is imported at `docs/evidence/20260831/` (Branch 5). The
  `dx-opencode` throwaway test-guest profile's container, volumes and image
  tag were also deleted -- it was never a real launcher (see "Your notes,
  answered" above), and this plan already runs its destructive tests against
  `dx-test` instead. Every merged branch was retired locally and on
  `origin`; `origin` now carries only `main`. This is most of "After Branch 6
  merges: retire the duplicates" below, done early because nothing depended
  on keeping the duplicate around until Branch 6 lands; that section now
  lists only what remains.
- **Some planning docs are stale.** For example, `refactor-v2-final.md` still
  asks for fix P7 to be landed, but it landed as `9ab640b`. `refactor-plan.md`
  says Phase 6 item 5 is open, but its checklist marked it done on 2026-09-19.
  Branch 5 cleans these up.
- **The container runtime is running.** Apple Container is started. OrbStack
  (Docker) is installed but stopped; start it only when a faithful
  GitHub-runner reproduction is needed.

### Feature-branch breakdown

The work is listed in the order to do it: easiest and most unblocking first.
**Only one code branch is open at a time.** Merge it to `main`, then start the
next. The only exception: if a branch is stuck waiting on you or on hardware,
the next one may start.

**Priority 1 is a working, tested `main` that contains only complete work**
(items 0–4). Green CI alone isn't enough to show that. CI's Linux job runs on
x86_64 and only *evaluates* the Nix flake: it never builds the guest. And
nothing has checked `main` on a real guest since August. So priority 1 ends
with an actual build-and-run check of `main`.

| # | Branch | What it delivers, in plain terms | Size | Needs a running container? | Waiting on a decision? | Status |
| --- | --- | --- | --- | --- | --- | --- |
| **Priority 1 — `main` complete, working and tested** | | | | | | |
| 0 | *(no branch)* | Safety snapshot of both clones, then start the container runtime | ~1–2 h | Starts it | No | **Done** 2026-09-26 |
| 1 | `fix/ci-baseline` | Make CI green again | S | No (CI only) | No | **Done**: `main` = `086d9ce`, CI green |
| 2 | `revert/opencode-partial` | Remove the half-finished OpenCode support from `main`; it returns complete in Branch 6 | S | No (CI only) | No | **Done**: `main` = `0cf61bd`, CI green |
| 3 | `fix/test-image-fixture` | Remove the unused `test-image.png` download so guest builds stop depending on a GitHub avatar | XS | Yes (Nix eval) | No | **Done**: `main` = `bd2418f`, CI green |
| 4 | *(no branch)* | Baseline check: build every guest output from `main`, run it on a freshly recreated `dx-test`, and record evidence that `main` works | ~half day | Yes | No (`dx-test` is disposable) | **Passed**: fresh guest, live tier 1081/0/10; Section 12 in-guest run finishing |
| 4a | `fix/container-running-sigpipe` | Fix the false "container stopped" abort in `dx-wait-ssh` (Step 4 finding 1) | S | No | No | **Done**: `main` = `596ac28`, CI green |
| 4b | `test/live-tier-hygiene` | Make Section 12 run inside the guest as part of the live tier; make Section 4's SSH probe skip (not fail) without a guest; make Section 14's history probe immune to SSH's known-hosts warning | S | Yes (`dx-test`) | No | **Done**: `main` = `3e41f4a`, seven commits, live tier 1105/0/8 |
| 4c | `fix/guest-sigpipe-pipelines` | Fix the same `\| grep -q` / `\| head -n1` under `pipefail` SIGPIPE shape as Branch 4a, in `bootstrap/activation.sh` and the guest scripts `scripts/dx-theme.sh:30` and `scripts/dx-theme-write-tool-themes.sh:374` | S | No | No | In progress |
| **Priority 2 — fix the start-generation bug, then finish in-flight work (the duplicate clone was retired early)** | | | | | | |
| 5 | `docs/plan-cleanup` | Remove stale plan text, delete the OpenCode handoff note, import August evidence, move this plan into the repo | S | No | No | **Done**: `main` = `9064bb9`, CI green |
| 9 | `fix/bootstrap-start-generation` | Make a restarted guest run the bootstrap code that was just published, not the previous version | M | Yes | No (Q4 resolved: fail the start) | **Done**: landed on `main` 2026-09-26 and `dx-host` promoted to `main` `08700a8` per Appendix D. Step 1 found the core defect already fixed on `main`; Step 2 implemented D7 option 3 and closed `dx-start-plan.md` |
| 6 | `feat/opencode` | Land OpenCode as one complete delivery: the original support plus safe migration, rollback and ownership repair | M | Yes | No (Q1 resolved: after Branch 9) | **Done**: landed on `main` 2026-09-26 (rebased onto `d5ca161`, CI green, live tier 1247/0/8 on `dx-test`); `dx-host` promotion is a separate open decision (Appendix D) |
| **Priority 3 — backlog** | | | | | | |
| 7 | `test/herdr-acceptance` | Two missing Herdr tests: bad-snapshot recovery and pane-history deletion | S | Yes (`dx-test`) | No (Q3 resolved: do them) | **Done**: landed on `main` 2026-09-26 (rebased onto `483aca4`, CI green): `d07cce1`, `fccf536`, `67a9578`; live Section 23 44/44 ×3; ratchet re-measured to 1821 bp |
| 8 | `refactor/legacy-migration-cleanup` | Check that every guest has left the old base image, then delete the old-base guards. This finishes `refactor-plan.md` | S–M | Yes (inventory) | No | **Done**: landed on `main` 2026-09-27 (rebased onto `bf49f4d`, CI green; live tier on a fresh 12 GB `dx-test` 1281/0/8). Increments 1-4 (`07ff94f` inventory + gate sign-off, `995123a` guest-side guard removed, `2690ba9` host-side guard removed, plus this closing commit): old-base guard gate signed off 2026-09-26, `refactor-plan.md` closed. G1-G3 and the dual-target stand-in green. G4 (full Apple live tier on `dx-test`) pending -- `dx-test` is in use by Branch 14. Not yet merged into `main` |
| 10 | `feat/persist-backup` | "B1": incremental host backup and restore of the guest's `/persist` data | M | Yes | No (Q5 resolved) | Not started |
| 11 | `feat/qnap-runtime` (several branches) | Run DXE on the QNAP (TVS-h674T, x86_64) via Docker over SSH. Phase 0 (inventory plus a throwaway spike, no repo code) may run any time after item 4 | L | Yes, plus the QNAP | No (accepted 2026-09-26) | Phase 0 **done** 2026-09-26: inventory and disposable spike passed on the NAS (steps 1-7, 8a, 9); steps 8b/8c await a maintenance window. Phases 1-7 not started |
| 12 | `fix/store-trust` (may split in two) | Safe handling of the two Nix-store trust problems in `store-trust-plan.md` | L | Yes | No (Q6 resolved: fail fast) | Not started |
| 13 | `refactor/bootstrap-v2`, `refactor/declarative-nix` | The two remaining large proposals. No branch until you accept one | L each | Yes | Q7 (still open) | Not started |
| 14 | `fix/dx-ai-no-source-builds` | Stop `dx-ai` from silently compiling heavy AI tools from source when a `nixpkgs-unstable` refresh misses the binary cache (found on Branch 6, 2026-09-26) | S–M | Yes (`dx-test`, disposable) | No | **Done**: landed on `main` 2026-09-27 (rebased onto `cf9f35f`, CI green); fresh 12 GB guest's first `dx-ai` from cache, peak ~8.6 GiB; live tier 1298/0/8; see `docs/evidence/20260927/dx-ai-no-source-builds.md` |
| 15 | `fix/keyring-bootstrap-recreate` | Make `dx-recreate` of an AI-opted-in guest work: resolve the keyring binaries from the AI generation explicitly and warn instead of aborting bootstrap (found on Branch 14's live gate) | S | Yes (`dx-test`) | Policy B chosen 2026-09-27 | **Done**: landed on `main` 2026-09-27 (rebased onto `7f1a81d`, CI green; live: recreate ×2 clean, Section 17 99/0, live tier green); `dx-host` promotion pending |

```text
Priority 1:  0 ✓ ─► 1 ✓ ─► 2 ✓ ─► 3 ✓ ─► 4 ✓ ─► 4a ✓ ─► 4b ✓ ─► 4c   (main complete, green, buildable, proven on a guest)
Priority 2:  5 ✓ ─► 9 ✓ ─► 6   (duplicate clone already retired; see "Where things stand")
Priority 3:  7 ─► 8 ─► 10 ─► 11 ─► 12 ─► 13 (only accepted proposals)
             QNAP Phase 0 (no code) can run any time after item 4
             14 is an independent bugfix found on Branch 6; it can run any time
```

Why this order:

- Items 0–4 make `main` trustworthy and complete. Every later branch is
  validated against it.
- Branch 2 (the revert) comes before the baseline check, so Step 4 validates
  the `main` you intend to keep.
- Branch 5 is docs-only, so it doesn't make `main` work. It can be written any
  time.
- **Branch 9 (the start-generation fix) now comes before Branch 6, and is
  done.** Q1 (resolved 2026-09-26) chose to fix the "boots the previous
  version" bug first rather than ship OpenCode behind a scripted workaround:
  OpenCode changes bootstrap code, so it would otherwise hit the bug on the
  very next restart of your primary guest. Step 1 characterised the defect
  live and found its core symptom already fixed on `main` (two pre-existing
  commits), landing only an observability increment (`dx-status` surfaces the
  booted generation) and the D7 design proposal. Step 2 implemented D7's
  accepted option 3 -- a bounded host-side confirmation in
  `dx-start-container` that fails the start when a real publish's generation
  never reaches the guest's execution lease (Q4) -- and closed
  `dx-start-plan.md` into
  [D7](docs/refactor/decisions/D7-start-generation.md) and
  `docs/lifecycle.md`/`docs/troubleshooting.md`. Branch 6 (OpenCode) is next.
- Branch 6's code already exists, preserved as this repository's own local
  branch `preserve/dxe-agent-opencode`. Merging it is now the only thing left
  of the duplicate-clone retirement (Priority 2's other items were carried
  out early -- see "Where things stand").
- Branches 7–8 are small and finish existing plans.
- QNAP (11) waits for the start-generation fix (9), because both change the
  same start and lifecycle scripts, and for backups (10), because the QNAP plan
  requires backup and restore first.
- Store trust (12) doesn't block QNAP: a QNAP guest starts with fresh volumes.

The **decisions at the end** (Q1–Q7): Q1, Q2 (revert), Q3, Q4, Q5, Q6 and the
QNAP part of Q7 are resolved. The rest of Q7 (the two large proposals) is not
urgent -- it's only needed before Branch 13.

### Your notes, answered

- **"I don't think I want a separate `dx-opencode`."** Agreed, and nothing
  depends on one. OpenCode already installs through `dx-ai` like `claude`,
  `codex`, `gemini`, `agy` and `herdr`, and you run it as plain `opencode`.
  In `dxe-agent/`, `dx-opencode` is not a launcher. It is a throwaway
  *test-guest profile* (`tests/profiles/dx-opencode.env`: its own container,
  volumes, port 2399 and SSH key), created to run destructive tests. This plan
  now drops it and runs those tests against the existing `dx-test` profile.
  That also removes the old question about migrating the `dx-opencode` SSH
  key (old D3).
- **Auto-approve alias (old D2):** resolved. No `opencode --auto` alias. See
  "Defaults assumed" at the end if you want parity with the other tools'
  aliases.
- **"Decisions very difficult to understand":** the decisions are rewritten
  at the end with background, options and a recommendation. There are fewer
  of them: seven, down from thirteen. They are renamed **Q1–Q7** because the
  repository already has unrelated decision records called D1–D6 in
  `docs/refactor/decisions/`.
- **Easiest first and maximise merged work:** this is now the ordering rule.
  A small, complete, validated piece of a larger initiative may merge on its
  own (see "Defaults assumed").

---

## Review against the repository objectives

| Objective | What I found | What this plan does about it |
| --- | --- | --- |
| Completed work on `main`; `main` production-ready | `main` has failed CI since 2026-08-21. The guest's Home Manager build depends on a changed upstream image. OpenCode on `main` lacks safe migration and rollback. | Branches 1 and 3 restore a green, buildable `main` first. Branch 2 removes the partial OpenCode feature; Branch 6 re-lands it complete (Q2, resolved). |
| Completed initiatives no longer shown as outstanding | Stale items: P7 in `refactor-v2-final.md`, Phase 6 item 5 in `refactor-plan.md`, the "Recorded conflict (resolved)" paragraph in `plans.md`, and the root `opencode-context.md` handoff note. | Branch 5 removes them. Lasting context goes to `docs/` or `docs/evidence/`. Each later branch removes its own finished tasks when it merges. |
| In-flight initiatives isolated | Unfinished OpenCode work sits uncommitted in a second clone. Other initiatives exist only as plan files. | One branch per initiative, created when work starts. Dependencies are listed in the table above and in each branch section. |
| All tests pass; 100% meaningful coverage of new or changed code | The existing kcov gate only measures `bin/lib`, guest `bootstrap/` and guest `scripts/lib`. `dx-ai.sh` and host entry points fall outside it. | The existing 100% gate stays. A changed-code coverage report and a behaviour checklist are added per branch (Appendix C). |
| Red → Green → Refactor, small verifiable increments | The previous revision described the process abstractly. | Every branch below lists concrete increments with their red evidence. |
| Idiomatic, declarative Nix | The test image is a network `fetchurl` of a mutable URL. The OpenCode helper is correctly packaged through `home.file`. | Branch 3 vendors the image. Nix rules are in Appendix C. |
| Plans easy for a human to follow | The previous revision was hard to navigate, and its decisions were hard to act on. | The plan is restructured around branches. Reference material moved to appendices. Decisions are rewritten. |

---

## How every branch is built and landed

This section is short on purpose. The full rules are in Appendix C.

1. **Start from green `main`** (only Branch 1 starts from the current red one).
   If a branch needs another unmerged branch, say so at the top of its
   section, and merge the prerequisite first.
2. **Red → Green → Refactor for each increment:**
   - **Red:** write a behaviour test and see it fail for the right reason.
     Keep that output as evidence. A test for behaviour that already works
     ("characterisation") may start green; label it as such.
   - **Green:** make the smallest complete change, using existing helpers.
     Cover normal, edge, error and repeat-run cases, and check for unwanted
     side effects.
   - **Refactor:** tidy up with all tests still passing, then re-run the
     affected suites and coverage.
   - **Prove the test bites:** temporarily revert the fix and watch the test
     fail again.
3. **Merge only complete, validated work.** Stubs and failing tests stay on
   the branch. Use clean commits; the original WIP history is kept in the
   private archive from Step 0.
4. **Update the docs in the same merge.** Remove the finished tasks from
   `plans.md` and the owning plan. Move anything future agents will need into
   `docs/` (operations), `docs/refactor/decisions/` (design rationale) or
   `docs/evidence/<date>/` (test results).
5. **Gates:**
   - Every branch needs G1 (static and contract tests) and G5 (green CI on
     the exact commit).
   - Runtime-affecting branches also need G2 (coverage), G3 (Nix build) and
     G4 (live guest test).
   - The gates are defined in Appendix C.
   - Runtime changes are promoted to your primary guest with the procedure in
     Appendix D.

---

## Step 0 — Safety snapshot and runtime start (no branch)

**Done 2026-09-26.**
- The archive, restore-verified, and the private ledger are in
  `~/dxe-recovery/20260926/`.
- Agent progress logs are in `~/dxe-recovery/progress/`.
- `gc.auto` has been restored.
- The steps below are kept until the M1-style close-out (after Branch 6) for
  audit.

Do this once, before touching either clone. Full detail: Appendix A.

1. Close any Claude Code, OpenCode or Antigravity sessions and editors that
   are using `dxe/` or `dxe-agent/`.
2. In both clones:
   1. Run `git config gc.auto 0` (note the previous value) so Git doesn't
      delete unreachable commits while you work.
   2. Pin every unreachable commit as a local ref,
      `refs/archive/unreachable/<sha>`. Never push these refs, and never use
      `git push --mirror`.
   3. Once the pins exist and the archive in step 3 is verified, restore the
      previous `gc.auto` setting. Nothing is then at risk: the pinned commits
      are reachable, and the loose trees and blobs are in the archive.
3. Make a private archive of both whole directories, including `.git`,
   uncommitted files and ignored SSH keys, plus `dxe-evidence-20260831/` and
   this file. Test-restore the archive to a scratch location and run
   `git fsck` there. `git bundle` alone is not enough: it skips uncommitted
   files and keys.
4. Commit `dxe-agent`'s uncommitted work onto a local branch,
   `preserve/dxe-agent-opencode`, using an explicit file list. Do not commit
   `dx-opencode_key`.
5. Start the runtime:
   1. Run `container system start`.
   2. Optionally start OrbStack. The coverage runner can use Docker.
   3. Record `container list --all` and the volume list. This is the start of
      Branch 8's inventory.
6. Start a private **consolidation ledger** next to the archive. It is one
   table with a row per item: every dirty file, ref, tag, unreachable commit,
   key and evidence file, each with its disposition. A sanitised copy is
   committed later, without keys or private filenames.

**Done when:** everything in both clones can be recovered without the
original directories, and `container list --all` works.

---

## Branch 1 — `fix/ci-baseline` (done 2026-09-26)

**Landed.** `main` was fast-forwarded from `71c2b50` to `086d9ce`. CI is green
on the branch (run 36206811575) and on `main` (run 36207063275). The commit
messages carry the red/green evidence.

| Commit | What it fixed |
| --- | --- |
| `14da20d` | Host AI install message listed OpenCode (Bash 3.2 contract failure) |
| `fc9696d` | Library purity check now also requires empty stderr and exit 0; host libraries checked under Bash 3.2, guest libraries under Bash 5 |
| `687210b` | ShellCheck SC2120: explicit arguments at the `dx_ai_setup_credentials` call site |
| `a8ca75a` | ShellCheck SC2218: the `ln -T` test shim defined before first use |
| `4248f1c` | Runner-only ShellCheck 0.9.0 false positive (SC2034) in `test_section9_host_scripts.sh` |
| `6c0e60c` | The fake `shasum` in `test_sourceable_coverage.sh` now reads its input. This removes a pipe failure that happened every time under Docker and was hidden locally |
| `909b83c` | That probe script now reports the failing line instead of dying silently |
| `56f8392` | That probe runs with a closed stdin |
| `e7289aa` | The coverage line count no longer includes kcov's own output files |
| `ae5d623`, `72735ab`, `086d9ce` | Coverage scope-share threshold re-measured on the committed tree: now 2138 bp, with a dated rationale in `tests/coverage/ratchet.env` |

**Lessons for later branches:**

- A local reproduction must match the GitHub runner's tools: ShellCheck 0.9.0
  and `jq` on the Ubuntu 24.04 runner.
- Coverage probes can behave differently under Docker than under Apple
  `container`. Use OrbStack for a faithful check when a CI-only failure
  appears.

---

## Branch 2 — `revert/opencode-partial` (done 2026-09-26)

**Landed.** `main` fast-forwarded `086d9ce` → `0cf61bd`; CI green on the branch
(run 36209094615) and on `main` (run 36209410452).

| Commit | What it did |
| --- | --- |
| `d5d74d7` | Removed OpenCode from the guest runtime: `aiPackages`, `dx-ai.sh` (tool list, Herdr integrations, help text, persisted-settings directories and symlinks), the five `activation.sh` lines, and the OpenCode-only tests. `dx_ai_setup_credentials` is byte-identical to its pre-OpenCode form. Kept real "absent" assertions: not in `aiPackages`, `--supports opencode` exits 1, no OpenCode directories prepared |
| `43a7bf9` | Removed OpenCode from the host install message and `docs/guest.md` |
| `0cf61bd` | Scope-share ratchet re-measured on the committed tree: 2138 → 2144 bp (fewer test lines than covered lines removed) |

Red evidence: the changed tests were run against unchanged `main` in a clean
worktree and failed as expected (10 failures). Runtime note: guests keep any
OpenCode data under `/persist/home/dx`; Branch 6's migration must accept it.

**Carried to Branch 6:** the `ln -sfnT` hardening on the `.gemini`, `.claude`,
`.claude.json` and `.codex` symlinks went out with the feature (a pre-existing
real `~/.claude` directory would again get a nested symlink instead of an
error); and `opencode` dropped out of Section 6's "never in default packages"
regex. Both return with tests when OpenCode re-lands.

---

## Branch 3 — `fix/test-image-fixture` (done 2026-09-26)

**Landed.** `main` fast-forwarded `0cf61bd` → `bd2418f`; CI green on the branch
(run 36210506410) and on `main` (run 36210738709).

| Commit | What it did |
| --- | --- |
| `0b3e4d9` | Removed the `testImage` `fetchurl` of a GitHub avatar and the `home.file."test-image.png"` line (nothing referenced the file). Red: building the pinned fetch fails with a hash mismatch; the Home Manager evaluation declared the file. Green: evaluation no longer declares it; `nix flake check` passes; `flake.lock` unchanged. Added a Section 6 guard against the mutable avatar host (a blanket "no `fetchurl`" guard was wrong: `agy` legitimately fetches a pinned release tarball) |
| `bd2418f` | Scope-share ratchet re-measured: 2144 → 2143 bp (11 test lines added) |

---

## Step 4 — Baseline check of `main` (no new branch)

**Goal:** evidence that `main` (after Branches 1–3) builds and runs on a real
guest, not just that CI is green.
**Depends on:** Branches 1–3 merged; the container runtime running (Step 0).
`dx-test` is disposable (confirmed 2026-09-26): wipe and recreate it freely.

**Where each gate actually runs (clarified 2026-09-26):**

- The `aarch64-linux` build environment **is the guest itself.** Creating
  `dx-test` builds the image, and bootstrap builds the flake outputs and the
  Home Manager activation package inside the guest. Section 12
  (`test_section12_validate_linux.sh`) is written to run inside a Linux guest
  with Nix. Do not spend hours building `homeConfigurations.dx.activationPackage`
  in a scratch container; the fresh guest is the build proof.
- A scratch `nixos/nix` container is only needed for `nix flake check` and the
  pinned ShellCheck, and CI already runs both on every push.
- Coverage (G2) runs on the host through Apple `container`.

1. **G2:** `tests/run-coverage-linux.sh` on `main`'s SHA. Record
   `covered=100%` and the scope share.
2. **G4, live, on a fresh `dx-test`:**
   1. Reset `dx-test` completely with the repository's own tooling under the
      profile: `./bin/dx-profile dx-test ./bin/dx-factory-reset --force`
      removes its container, image, volumes and test key (`dx-destroy` keeps
      volumes, which would not be a fresh build). Record `container list
      --all` and `container volume list` before and after, and confirm only
      `dx-test-*` resources went. The script warns that the first Nix download
      takes a long time; run the live tier detached and poll.
   2. Bring the fresh guest up first. The live tier does **not** create a
      guest: Section 11 skips when the profile's container is not running
      (found 2026-09-26; a run without a guest passed 963 checks, failed one
      SSH live probe that should have skipped, and built nothing). Run the
      documented lifecycle layers under the profile, detached and logged:
      `dx-create-keys`, `dx-create-image`, `dx-create-volumes`,
      `dx-create-container`, `dx-start-container`, `dx-wait-ssh` (what
      `bin/dx` does before its final `dx-ssh`). The image build and first
      bootstrap take an hour or more. Then run
      `./bin/dx-profile dx-test bash tests/run-tier.sh live`.
   3. Read the booted bootstrap generation from the launcher lease under
      `.locks/leases/` inside the guest and compare it with what was published.
   4. The live tier includes Section 17's guest checks, which run `dx-ai` on
      `dx-test` and install the AI bundle there. With OpenCode off `main`, that
      is simply part of `main`'s behaviour, so let it run (it adds download
      time). Keep `DX_TEST_DESTRUCTIVE` unset; the destructive factory-reset
      test is not part of this baseline.
3. **Record** everything under `docs/evidence/<date>/main-baseline.md`
   (committed by Branch 5): commit, lock hash, image digest, commands, exit
   codes, totals, and every skip with its reason and the gate that covers it.

**If something fails:** one Red → Green increment per failure on its own
descriptively named `fix/…` branch from `main`; merge; re-run only the failed
gate plus CI. A failure that only OpenCode's persistence code could fix is
recorded as a Branch 6 dependency instead. While the main checkout is busy
with the live tier, a fix may be developed in a linked worktree under
`~/dxe-recovery/progress/tmp/` (the one-branch-at-a-time rule still holds:
Step 4 is not a branch).

**Findings so far (2026-09-26):**

1. **`dx-wait-ssh` can abort a healthy bring-up with a false "container
   stopped" error.** `container_is_running` and `container_exists` in
   `bin/lib/dx-container.sh` pipe the container list into `grep -q`; when
   `grep` exits on an early match, the writer gets a broken pipe and, under the
   caller's `pipefail`, a matched name reads as "not running". A fresh `dx-test`
   bring-up aborted at ~92 s while the guest was bootstrapping normally. The
   test helpers already document this pitfall (`stdin_matches`); the
   production library needs the same idiom. **Branch 4a
   `fix/container-running-sigpipe`** (in progress) fixes both helpers with
   deterministic tests. Likely the cause of any intermittent "stopped before
   SSH became responsive" errors you have seen on the primary guest.
2. **The live tier validates a running guest; it does not create one.** The
   sequence above is corrected accordingly. Side observation: Section 4's
   key-only SSH live probe fails instead of skipping when no guest is running;
   the other live checks skip. → Branch 4b.
3. **Section 12 runs in no gate.** `test_section12_validate_linux.sh` is
   written for a Linux environment with Nix but gates on the *host's*
   `uname -s`, so the macOS live tier skips it, the kcov runner never calls
   it, and CI runs container-free. Its assertions (the `default` and
   `ai-tools` outputs install into a profile, `nvim` starts, no AI tools in
   the default profile) were run in the guest by hand as a Step 4 addendum:
   14 passed, 1 failed. The failure is a stale source-text heuristic
   (`test_section12_validate_linux.sh:108` greps `bootstrap.sh` for a pattern
   from before the bootstrap was split into modules), not a defect in `main`.
   → Branch 4b makes the live tier run it inside the guest and replaces or
   removes that heuristic.
4. **Section 14's `write_history` probe reports "inconclusive"** when SSH's
   "Permanently added … to the list of known hosts" warning lands in the probe
   output. A skip that should be a pass/fail. → Branch 4b.

**Result (2026-09-26):** `main` at `bd2418f` factory-reset → fresh `dx-test`
bring-up in about 5 minutes (warm binary cache) → live tier 1081 passed, 0
failed, 10 skipped (all classified), exit 0. The booted bootstrap generation
matched the published one with no drift, across the run's own container
restart. Evidence: `~/dxe-recovery/progress/evidence/main-baseline-2026-09-26.md`,
to be committed by Branch 5.

**Done when:** G2 and the live tier pass on `main`'s exact SHA, or each
remaining gap is a named, recorded blocker with an owner.

---

## Branch 4a — `fix/container-running-sigpipe` (size S; done 2026-09-26)

**Landed.** `main` fast-forwarded `bd2418f` → `596ac28`.

| Commit | What it did |
| --- | --- |
| `ccc9fac` | Fixed `container_is_running`/`container_exists` in `bin/lib/dx-container.sh`: they piped the container list into `grep -F -x -q`, and `grep -q` exits at its first match, closing the pipe while a still-writing `printf` could get SIGPIPE/EPIPE, which under the caller's `pipefail` (e.g. `dx-wait-ssh`) turned a real match into "not running". Red: a stub `container` listing the target first, then 20,000 filler lines, made both helpers return false under `pipefail` (`tests/test_section20_skip_integration.sh`, 12 passed/2 failed). Green: dropped `-q`, redirected to `/dev/null` instead (the `stdin_matches` idiom `tests/test_helpers.sh` already documents), with a comment pointing at it; 14 passed/0 failed. Proved the test bites by stashing only the production fix and re-running red. Searched `bin/lib/*.sh` and `bin/dx-*` for the same shape: no other in-scope instance; noted the guest-side `scripts/dx-theme.sh:30` and `scripts/dx-theme-write-tool-themes.sh:374` look like the same shape but are out of scope (→ Branch 4c) |
| `596ac28` | Scope-share ratchet re-measured: 2143 → 2134 bp (scope rose by 4 lines in `bin/lib/dx-container.sh`; the +91-line regression test outweighed it) |

Fixes Step 4 finding 1. Developed in a linked worktree because Step 4 occupied
the main checkout.

## Branch 4b — `test/live-tier-hygiene` (size S; after 4a; done 2026-09-26)

**Landed.** `main` fast-forwarded `596ac28` → `3e41f4a` (seven commits).

| Commit | What it did |
| --- | --- |
| `71d9896` | Commit 0: updated this plan's status (4a and 5 done, 4b in progress) |
| `dd2ce62` | Fixed `requires_container`'s (`tests/test_helpers.sh`) same SIGPIPE-under-`pipefail` shape Branch 4a fixed in production: it piped `container list --quiet` into `grep -F -x -q`. Red: the same big-stub-list technique as Branch 4a's Section 20 regression block made `requires_container` report a running container as not running under `pipefail`. Green: `stdin_matches -F -x -- "$DX_CONTAINER_NAME"` |
| `b344146` | Made Section 4's key-only SSH probe skip cleanly (not fail) without a guest |
| `233d51a` | Fixed Section 14's `write_history` probe: it reported "inconclusive", never fail. Two real bugs found live against `dx-test`: missing `-o LogLevel=ERROR` (SSH known-hosts warning polluted the captured probe output) and a wrong hardcoded history filename (project.nvim 4.1.1's real default is `project_history.json`, not `project_history`) |
| `3e49f6b` | Ran Section 12 inside the guest (relayed over `dx-put`/`dx-ssh`) instead of always skipping on macOS; replaced the stale "bootstrap.sh has idempotency checks" source-text heuristic with a comment pointing at the live tier's own container-restart evidence |
| `f3be4b7` | Fixed a pinned-ShellCheck 0.10.0 SC2034 false positive in Section 20, found during validation |
| `3e41f4a` | Re-measured the scope-share ratchet after the live-tier hygiene fixes (2134 → 2120 bp) |

Validated end to end: `run-bash32-tests.sh` (79/0/0); Ubuntu container-free
contracts (`run_all_tests.sh --skip-integration`, all green, Section 0's
ShellCheck lint confirmed running); pinned ShellCheck 0.10.0 over the full CI
file set (clean); `run-coverage-linux.sh` (100% covered, ratchet re-measured
and rebaselined); `nix flake check` (lock file unchanged); and the full live
tier on `dx-test`: **1105 passed / 0 failed / 8 skipped**, including Section
4's SSH probe, Section 12 running inside the guest, and Section 14's
`write_history` probe all passing live.

---

## Branch 4c — `fix/guest-sigpipe-pipelines` (size S; after 4b; in progress)

Branch 4a's SIGPIPE-under-`pipefail` audit (`ccc9fac`) found the same
`| grep -q` / `| head` shape in two guest scripts, under their own
`set -eo pipefail`, and left them untouched as out of that task's scope:
`scripts/dx-theme.sh:30` and `scripts/dx-theme-write-tool-themes.sh:374`.
Re-running that audit over all of `container/.../{bootstrap.sh,bootstrap,
scripts}` at the start of this branch found the same shape twice more in
`bootstrap/activation.sh` -- the AI-tools opt-in guard at line 218 and the
ownership-marker content check at lines 136-137 -- and confirmed two other
hits are false positives: `bootstrap/system.sh:47`'s
`sed -n '...p' flake.nix | head -1` only ever emits the single `nixpkgs.url`
line `flake.nix` actually contains, so there is nothing for `head` to race;
and the `-quit` in `bootstrap/base-and-storage.sh:175`'s
`find ... -print -quit | grep -q .` already stops `find` itself after one
match, not by relying on the downstream `grep -q`. Four increments, each with
a stub-based red test in the style of Branch 4a's Section 20 regression
block:

1. **`bootstrap/activation.sh:218`** decides whether the AI tools are
   installed by piping `run_as_dx "nix profile list"` into `grep -qE`, which
   can intermittently read "installed" as "not installed" during boot on a
   guest with a long profile list. Red: a stub `run_as_dx` whose output puts
   the matching `Flake attribute: ...ai-tools` line first, then tens of
   thousands of filler lines, makes the check read a real match as absent
   under `pipefail`. Green: extract the predicate into a small named function
   (kept in `activation.sh`, still 100%-covered kcov scope) using the
   read-all idiom (`grep -E ... >/dev/null`).
2. **`bootstrap/activation.sh:136-137`** has the same `grep -q` shape, over a
   two-line ownership-marker file. A standalone probe confirmed the writer is
   too small to make the race reproducible (the whole marker never exceeds
   the pipe buffer), so this is a characterisation/consistency fix, not a
   proven defect: the same read-all idiom, for consistency with the
   documented `stdin_matches` idiom and increment 1's fix.
3. **`scripts/dx-theme.sh:30`** pipes into `grep -qx`, which exits at its
   first match the same way `grep -q` does. Red: a stub that emits the target
   line first, then tens of thousands of filler lines, makes the check read a
   real match as absent under `pipefail`. Green: replace the early-exit
   `grep -qx` with the read-all idiom (`grep -x -- … >/dev/null`, matching
   `tests/test_helpers.sh`'s `stdin_matches` and Branch 4a's fix).
4. **`scripts/dx-theme-write-tool-themes.sh:374`** pipes into
   `grep -oE … | head -n1 || true`: `head -n1` exits after its first line the
   same way, closing the pipe on `grep -oE`'s writer. A standalone probe (20
   runs each on bash 5/Linux and bash 3.2/macOS) confirmed the trailing
   `|| true` already absorbs the resulting SIGPIPE (rc 141 every time)
   without ever losing the correct captured value, so this is a
   hygiene/consistency fix -- it removes a needless, masked SIGPIPE rather
   than a proven dropped match. Green: replace `grep -oE … | head -n1` with
   `grep -m1 -oE …` so `grep` itself stops after one match instead of relying
   on a downstream `head` to do it, and no longer needs `|| true` to hide a
   SIGPIPE it no longer raises.

Validation: G1, coverage ratchet (`bootstrap/activation.sh` is in kcov's
declared scope and must stay 100% covered; the two `scripts/` files are guest
`container/.../scripts/`, outside kcov's declared `scripts/lib` scope but
counted in the ratchet's `total_lines`; changed lines there need the
Appendix C changed-code report the same way `dx-ai.sh` does), both CI jobs,
`nix flake check` (not required -- no `.nix` files change -- but cheap to
confirm nothing broke), and the live tier on `dx-test` (Section 17 confirms
the AI bundle is detected as installed; Section 14's theme-switching checks
exercise both theme scripts).

---

## Branch 5 — `docs/plan-cleanup` (size S, docs only)

**Can be written any time; merges after priority 1 (items 0–4).** It also
commits Step 4's baseline evidence record.

1. **Delete `opencode-context.md`** (untracked handoff note). What it records:
   - landed work, which is already in the code and `docs/guest.md`;
   - the alias question, which is resolved (no alias);
   - live-verification steps, which move to Branch 6's validation record.

   Nothing else in it is lasting.
2. **`refactor-plan.md`:** remove the "Phase 6, item 5 … Open" bullet;
   `docs/refactor/checklists/phase-6.md:45` marked it done on 2026-09-19. Only
   item 1 (old-base guards) remains, which is Branch 8.
3. **`refactor-v2-final.md:226–229`:** delete the instruction to land P7; it
   landed as `9ab640b`. **`plans.md`:**
   - delete the "Recorded conflict (resolved)" paragraph;
   - refresh the status date;
   - update "Optional follow-up" to match Q3.
4. **Import the August evidence.** Copy `dxe-evidence-20260831/` (`RECORD.md`
   and ten logs) to `docs/evidence/20260831/` after scanning for secrets. Add a
   short `README.md` saying the results apply to commit `27cce6f`, not today's
   code, and keep the backfilled-record caveats. Link the August alignment
   waiver to `store-trust-plan.md`.
5. **Move this plan into the repo** as `checkout-consolidation-plan.md` at the
   root, where the other plans live, and list it under "Partially complete" in
   `plans.md`. The Section 10 docs test requires every root plan to appear in
   `plans.md` exactly once. The name avoids confusion with the retired
   `consolidation-plan.md` (R1–R8).
6. **Commit the sanitised ledger** as
   `docs/evidence/<date>/consolidation-ledger.md`, including the historical-ref
   dispositions from Appendix B. Then delete the
   `refs/archive/unreachable/*` pins
   (`git for-each-ref --format='%(refname)' refs/archive/unreachable | xargs -n1 git update-ref -d`).
   The verified archive keeps the originals.

**Red → Green:** the Section 10 link/index contract is the test. Adding the
root plan before its `plans.md` entry must fail it; adding the entry makes it
pass.

**Done when:** `tests/test_section10_docs.sh` and CI are green.

---

## Branch 6 — `feat/opencode` (size M; landed on `main` 2026-09-26)

**Depends on:** Branches 1–3 merged, Step 4 passed, and Branch 9 landed.
**Decision:** Q1 -- **resolved 2026-09-26: fix the start-generation bug
first.** Branch 9 now runs before this one (see the summary table and "Why
this order").

**Status (2026-09-26): landed on `main`** (rebased onto `d5ca161`,
CI green on the rebased branch, then fast-forwarded; see the evidence
record's "Landing" section). The Appendix D promotion of OpenCode to
`dx-host` is a separate user decision, still open. All six increments
below are done, including 4.5 (the
two-loader-paths design is justified, not reduced -- see the increment 3
commit message) and 4.6 (Section 12 present/absent assertions, done as
part of increment 1). G1 (bash32, runner-matched Ubuntu contracts,
pinned ShellCheck 0.10.0), G2 (100% kcov coverage, ratchet re-measured
1910 → 1921 → 1917 bp across the branch), and G3 (`nix flake check`,
`flake.lock` unchanged) are all green. The full live-`dx-test` list below
is done: fresh opt-in (a), the full live tier (b, 1247/0/8), and
retained-state migration with a real five-tool recovery (c) all passed;
`dx-test` is stopped (d). Evidence:
`docs/evidence/20260926/opencode-relanding.md`. One live-guest finding,
unrelated to OpenCode, recorded separately below ("Observations from
Branches 1–2"): building `codex` from source can OOM under the profile's
default 12 GB container allocation.

After Branch 2's revert, this branch re-lands OpenCode as **one complete
delivery**:

- Re-apply the original support: the content of `0f71be4`, and of Branch 1's
  `14da20d` install-message change, adapted to current `main`.
- Add the `dxe-agent` work below.
- Its migration must accept the OpenCode data that opted-in guests kept after
  the revert.
- Restore the `ln -sfnT` hardening for the `.gemini`, `.claude`, `.claude.json`
  and `.codex` symlinks in `dx_ai_setup_credentials`, with a behavioural test
  (a pre-existing real `~/.claude` directory must produce an error, not a
  nested symlink). The revert took it out with the feature.
- Put `opencode` back into Section 6's "AI CLI tools excluded from default
  dxPackages" regex.

### What gets imported from `preserve/dxe-agent-opencode`

The source is local branch `preserve/dxe-agent-opencode` (`ff8f6bd`), now
local to this repository (`dxe`): it originally lived in `dxe-agent/`, which
was deleted 2026-09-26 after verification, once the branch was confirmed safe
in `dxe` and in the Step 0 archive (see "Where things stand").

- Commit `f69d1e4`: tests for OpenCode generation persistence and Herdr
  behaviour.
- The uncommitted implementation, 13 modified files:
  - `dx-ai.sh`: per-generation tool manifests and recovery of older
    five-tool AI generations, meaning those from before OpenCode;
  - `bootstrap/activation.sh`: migrates existing OpenCode config and data
    without losing conflicts, refuses unsafe symlinks, and repairs ownership
    of the persisted XDG directories;
  - `bootstrap/persistence.sh`;
  - `home/tools.nix`: installs the new helper through Home Manager
    `home.file`;
  - `docs/guest.md`;
  - the tests.
- The new helper `scripts/lib/dx-opencode-persistence.sh` (131 lines, inside
  kcov scope).
- `docs/refactor/opencode-validation.md`, imported as historical evidence.
  Correct its coverage units (they are scope-share basis points, not branch
  counts) and label its missing `/tmp` logs.
- The Section 12 assertions from `dxe/`'s working tree.

**Not imported:**

- `tests/profiles/dx-opencode.env`, the `dx-opencode_key` pair and their
  `.gitignore` lines (your note);
- the `flake.nix` hash change (Branch 3 replaces it);
- the `plans.md` date change;
- the duplicate `bin/dx-herdr` edit (landed in Branch 1).

### Increments

The branch lands as one delivery: partial persistence migration is unsafe on
its own. It is still built and reviewed in these steps.

| Inc. | Red | Green |
| --- | --- | --- |
| 4.1 Import | n/a (move code) | Cherry-pick from `preserve/dxe-agent-opencode` onto a branch from green `main`, resolving conflicts with Branch 1's SC2120 fix. Retarget destructive test docs and usage to `dx-test`. |
| 4.2 Migration of existing OpenCode config/data | Run the new Section 17 migration and conflict tests against `main`'s implementation in an isolated fixture. They should fail. | The helper with its conflict preservation and symlink refusal |
| 4.3 Rollback to a pre-OpenCode AI generation | Test: recovering a real five-tool generation fails on `main`, because every generation must contain `opencode` | Per-generation manifests |
| 4.4 Ownership repair | Test: a root-owned persisted `~/.local/share` blocks setup | Bounded root repair in activation after the helper's symlink preflight |
| 4.5 Refactor | — | The helper is loaded from two paths: `/guest-bootstrap/scripts/lib/` in activation and `~/.local/lib/dx/` for `dx-ai`. Confirm both are needed, or reduce to one. |
| 4.6 Section 12 | The assertions fail if `opencode` leaks into the default profile | Already written |

**Coverage:**

- The new helper must be at 100% under kcov.
- `dx-ai.sh` sits outside kcov scope, but about 80 of its lines changed, so it needs
  a changed-code coverage report (Appendix C).

**Validation:** G1–G5, plus these live tests on `dx-test`:

1. Back up any `dx-test` data you care about.
2. Fresh opt-in: start `dx-test` with no AI tools installed, then run
   `DX_TEST_DESTRUCTIVE=1 ./bin/dx-profile dx-test bash tests/run_all_tests.sh --section=17`.
3. Run the full live tier: `./bin/dx-profile dx-test bash tests/run-tier.sh live`,
   **after** step 2 and without `DX_TEST_DESTRUCTIVE`.
4. Migration with a real predecessor: prepare `dx-test` with pre-existing
   OpenCode files and a real five-tool AI generation. Opt in, recreate, then
   recover the old generation. Confirm the files, conflicts and ownership
   survive, and each old tool still runs.

Record every skipped check with the reason and the gate that covers it
instead.

**Rollout to your primary guest:** Appendix D, using the Q1 answer.

### After Branch 6 merges: retire the duplicates

**Most of this was done early, on 2026-09-26**, ahead of Branch 6 landing
(see "Where things stand"): `dxe-agent/` and `dxe-evidence-20260831/` are
deleted; `preserve/dxe-agent-opencode` is a local branch in `dxe` itself;
the `dx-opencode` test-guest profile's container, volumes and image tag are
deleted; every merged branch (including `fix/dx-wait-ssh-probe-budget`) is
retired locally and on `origin`; `origin` carries only `main`; `gc.auto` is
back to its prior (unset/default) setting; and the `refs/archive/unreachable/*`
pins are gone (Branch 5). What remains, once Branch 6 lands:

1. Confirm nothing still refers to the deleted `dxe-agent/` path: shell
   profile, launchers, editor sessions, container mounts.
2. Re-verify the private archive covers `preserve/dxe-agent-opencode` as it
   stands at merge time (it was already verified once, at deletion time;
   repeat only if the branch changed since).
3. In a small docs-only commit, update this plan's status and the ledger.
   Remove the completed consolidation steps (Steps 0 and 4, Branches 1, 2, 3,
   5, 6 and 9) from this plan and keep only what remains.

---

## Branch 7 — `test/herdr-acceptance` (size S; only if Q3 says yes)

**Status (2026-09-26): landed on `main`** (rebased onto `483aca4`, CI green,
then fast-forwarded). Both acceptance cases passed
immediately against unchanged code (characterisation tests, no production
fix needed): `d07cce1` (corrupt/too-new snapshot recovery), `fccf536`
(history-cleanup marker deletion, plus one Section 10 docs assertion),
`67a9578` (scope-share ratchet re-measured to 1821 bp). Live Section 23
44/44, run three times with no failures; `dx-test` cold-stopped and cleaned
after every run. See `docs/evidence/20260926/herdr-acceptance.md`.

Two missing acceptance cases from the completed Herdr review. Add one test per
increment:

1. Recovery from a corrupt or too-new Herdr snapshot.
2. The deletion half of pane-history cleanup.

If a test passes immediately, label it a characterisation test. If it fails,
the fix goes in the same increment. Afterwards, remove "Optional follow-up"
from `plans.md`.

---

## Branch 8 — `refactor/legacy-migration-cleanup` (size S–M; landed on `main` 2026-09-27)

**Closed `refactor-plan.md`.** Its only remaining item, Phase 6 item 1
(remove the old-base guards in `bootstrap.sh`/`bootstrap/system.sh` and
`bin/dx-start-container`), is done.

1. **Inventory** (`07ff94f`): every container, image, and volume, checked
   against the old-base guard gate in `docs/refactor/migration-gates.md`.
   The primary (`dx-host`) probed `OLD_BASE_ABSENT`; `dx-test` and any
   future guest are off the old base by Containerfile construction; no
   `dx-tinty` guest exists; no container references the cached old-base
   image or the leftover `dx-mount-dx-mount-legacy-plain-…` key files.
   Recorded in `docs/evidence/20260926/legacy-guard-removal.md`, with the
   gate signed off in the same commit.
2. **Characterised:** `tests/test_bootstrap_publication.sh`'s
   `run_start_container` cases and `tests/test_section3_bootstrap.sh`'s
   guard cases already covered the new-base start path and were green; no
   new test was needed.
3. **Removed**, one guard per commit, each behind a red "guard absent"
   assertion that failed while the guard was present: `guard_old_base` in
   guest `bootstrap/system.sh` and its call in `bootstrap.sh` (`995123a`);
   the `bin/dx-start-container` guard block (`2690ba9`). Both commits
   updated the changeover text in `docs/release-maintenance.md` that named
   the removed guard(s), keeping its "History" entry per the migration
   gate.
4. **Closed the plan:** moved the Measurable targets table to
   `docs/refactor/baselines.md`; ticked Phase 6 item 1 in
   `docs/refactor/checklists/phase-6.md`; deleted `refactor-plan.md` and
   its `plans.md` entry; fixed the resulting cross-references in
   `README.md`, `plans.md`, and the `docs/refactor/*.md` files that had
   pointed at it.

G1 (bash-3.2, pinned ShellCheck 0.10.0, Ubuntu container-free contracts),
G2 (coverage + ratchet re-measure on a clean export), and G3 (`nix flake
check` -- not needed, no `.nix` file changed) all green; the dual-target
stand-in (`tests/test_section27_qnap_scripts.sh`, the Phase 0 QNAP
dry-run) also green. G4 (the full Apple live tier on `dx-test`, plus a
`dx-stop-container`/`dx-start-container` cycle) is pending -- `dx-test`
was in use by Branch 14 while this branch's increments landed. Not yet
merged into `main`.

---

## Branch 9 — `fix/bootstrap-start-generation` (size M; Q4 resolved; landed on `main` 2026-09-26)

**Q4 -- resolved 2026-09-26: A, fail the start** if publishing the new
bootstrap version fails or times out, with a manual start or reboot that has
no publisher still just working. **Q1 -- resolved 2026-09-26:** this branch
landed before Branch 6, instead of OpenCode shipping behind a scripted
restart-and-verify workaround (see the summary table and "Why this order").

**Problem (`dx-start-plan.md`, now closed):** `dx-start-container` starts the
guest *before* the host publishes the new bootstrap code. A guest with a
retained bootstrap volume therefore runs the *previous* version, silently,
after every bootstrap edit. The only workaround was starting it a second
time.

**Step 1 finding (commits `91765b3`, `23a9d79`, `43896c9`):** live
characterisation on `dx-test` found the core defect **already fixed on
`main`** by two commits that predate `dx-start-plan.md`'s "Open questions"
(`ba49f39`, launcher logs its resolved generation; `a3ee4e3`, launcher waits
for *this* boot's publication with a bounded fallback) -- confirmed live,
repeatedly, across both start paths (retained-volume recreate; in-place
stop/start), not just read off the diff. What Step 1 landed: the
observability increment alone (`dx-status` now surfaces the booted bootstrap
generation, live or dead -- requirement 4), and
[D7](docs/refactor/decisions/D7-start-generation.md) as a design proposal for
the one remaining gap, Q4 itself (a publish that succeeds host-side but never
reaches the guest was only ever a swallowed warning, not a failure).

**Step 2 (commits `753322f`, `dcbe6b2`, `6f78d24`, `2257631`):** implemented
D7's accepted option 3 -- a bounded host-side confirmation
(`DX_BOOTSTRAP_CONFIRM_TIMEOUT`, default 5s, chosen from a live measurement)
in `dx-start-container` that fails the start when a real publish's execution
lease never reaches the guest, naming both generations and the remedy
(restart the guest). Live-verified on `dx-test`, including a naturally-
occurring (not injected) demonstration of the exact failure and its remedy.
Closed `dx-start-plan.md`: its invariants moved into
[D7](docs/refactor/decisions/D7-start-generation.md), its operator notes into
`docs/lifecycle.md` and `docs/troubleshooting.md`, and the plan itself
(plus its `plans.md` entry) deleted.

Not yet merged into `main` -- the coordinating session merges after review.

---

## Branch 10 — `feat/persist-backup` (size M; Q5)

**Specified in `plan.md` as B1:** incremental host backup of the at-risk
contents of the guest's `/persist`.

1. Define the backup set and write failing restore tests.
2. Implement on-demand capture **and** restore for that set. A capture without
   a working restore does not merge.
3. Add incremental behaviour: a no-change run transfers nothing.
4. Add the schedule you choose in Q5.
5. Delete `plan.md` and its `plans.md` entry, and document operation in
   `docs/lifecycle.md`.

This backup is needed before any future storage migration and before QNAP.

**Done.** `bin/dx-backup` and `bin/dx-restore`, shared logic in
`bin/lib/dx-backup.sh`, and the guest selection-rule library shipped through
the bootstrap volume (`container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib/dx-persist-backup-select.sh`,
sourceable and fixture-testable with no container, exactly like
`dx-opencode-persistence.sh`). Selection rules, the deny-list, the
incremental capture, and restore (dry-run, `--force` refusal, a full round
trip including an unpushed repository's `.git` history) are covered by
`tests/test_persist_backup_select.sh`, `tests/test_dx_backup.sh`, and
`tests/test_dx_restore.sh` over the fake-`container` boundary. Item 4 above
(a schedule) does not apply: Q5 resolved on-demand only, no schedule yet.
`plan.md` (B1 was its only content) and its `plans.md` entry are deleted;
operation is documented in
[`docs/lifecycle.md`](docs/lifecycle.md#backing-up-and-restoring-persist).
Live-verified on `dx-test` once the coordinating session confirms the guest
is free (see the branch's progress file for the exact commands and results).

Not yet merged into `main` -- the coordinating session merges after review.

---

## Branch 11 — QNAP runtime (`qnap-dxe-plan.md`; accepted 2026-09-26)

**Target:** QNAP TVS-h674T. Its Intel Core 12th-gen CPU means **x86_64**;
Phase 0 confirms this with `uname -m`. The guest flake currently builds only
`aarch64-linux`, so the QNAP plan's **Phase 4** (an architecture-neutral
guest) is required, not optional.

- **Phase 0 (no repo code, optional early):** any time after Step 4. Do the
  inventory and the disposable `dxe-spike-*` proof exactly as
  `qnap-dxe-plan.md` describes, including a reboot during an agreed
  maintenance window. Record a sanitised target note. It answers the
  architecture question and sizes the work. It opens no branch, so it doesn't
  count against the one-branch-at-a-time rule.
- **Phases 1–7 (implementation):** after Branch 9 (start-generation fix) and
  Branch 10 (backup).
  - Phase 1 extracts the runtime boundary from the same lifecycle scripts
    Branch 9 changes, so doing both at once would conflict. The fixed start
    order should be what the Docker adapter inherits.
  - The QNAP plan requires backup and restore first.
  - Store trust (Branch 12) is not a prerequisite, because a QNAP guest starts
    with fresh volumes.
- **Branching:** one branch per QNAP phase or increment, for example
  `feat/qnap-runtime-boundary`, `feat/qnap-docker-adapter`,
  `feat/qnap-x86_64-guest`. Each lands only when complete and validated.
- **Nix note for Phase 4:**
  - Parameterise the flake's systems with the existing pattern, for example
    `nixpkgs.lib.genAttrs [ "aarch64-linux" "x86_64-linux" ]` over the
    outputs, rather than duplicating outputs.
  - Keep the committed lock.
  - The Apple `aarch64` build must not change.
- **Validation:** the QNAP plan's own gates, plus the Apple regression tier.
  The Mac remains the reference for the Apple runtime's live gates. An x86_64
  QNAP can't supply the `aarch64` G3 build check.
- **Not in the first QNAP release:** `dx-mount DIR`, which bind-mounts a Mac
  checkout into the guest (a QNAP non-goal). If you depend on it daily, keep
  using the Mac guest for that work.

---

## Branch 12 — `fix/store-trust` (size L; Q6)

`store-trust-plan.md` has two problems with no design yet:

- **Pin collision:** changing the Nix base-image pin while reusing `/nix` can
  meet a store path with the same name but different content.
- **Remount verification:** after a remount, the tools that verify the store
  themselves live in that store.

1. Characterise each problem.
2. Deliver one complete, verified failure-and-recovery path per problem. Use
   separate branches if they don't share code; if they share a verifier, land
   the shared piece first.
3. Close the August alignment waiver in `docs/release-maintenance.md`, and
   correct its conflicting rollback wording. It says a pin-change revert keeps
   `/nix` and `/persist`, but also that no volume-reusing pin change is valid.

**Needed before any base-image pin change and before refactor v2.**

---

## Branch 13 — Large proposals (Q7)

No branch is created until you accept a proposal. An accepted proposal is
first rewritten into small increments like the ones above. It is never merged
as a whole phase stack.

| Proposal | What it is, briefly | If accepted, starts after |
| --- | --- | --- |
| Bootstrap refactor v2 (`refactor-v2-final.md`, 436 lines) | Restructures guest bootstrap internals: identity and publication threading, explicit volume state, claim cleanup, test split. No user-visible feature. | Branches 9 and 12 |
| Declarative Nix audit (`declarative-nix-plan-a.md`, 520 lines) | Moves shell-script configuration into Home Manager: SSH/sudo config, shell setup, Herdr TOML and similar. Also proposes changing the coverage metric. | Branch 1; the small conversions can start any time |

---

## Branch 14 — `fix/dx-ai-no-source-builds` (size S–M; found on Branch 6, 2026-09-26; landed on `main` 2026-09-27)

**Status (2026-09-27): landed on `main`.** All increments and gates green;
live on a freshly created `dx-test` at the profile default 12 GB: the first
`dx-ai` came from the cache (only the allow-listed trivial derivations built
locally), peak ~8.6 GiB, Section 17 destructive 99/0, live tier 1298/0/8.
Evidence: `docs/evidence/20260927/dx-ai-no-source-builds.md`. Its live gate
also exposed the recreate/keyring defect recorded below and tracked as
Branch 15.

`dx-ai` refreshes `nixpkgs-unstable` before installing the optional AI tools
bundle, and previously pinned that input to nixpkgs **master**, which is
ahead of Hydra's binary cache. A refresh could land on a revision whose AI
tools were not yet cached for the guest's architecture, and Nix silently
built the miss from source inside the guest -- observed for `codex-cli`,
which OOM-killed the guest building `codex-core`/`codex-tui` at the
profile's default 12 GB (see "Observations" below, now resolved). The user
does not want bigger guests (especially not on the QNAP); the fix is to stop
`dx-ai` from ever building anything heavy without being asked, not to raise
the default.

1. **Track the cached channel, not master.** `nixpkgs-unstable` now points at
   the `nixpkgs-unstable` branch of `NixOS/nixpkgs` (the channel branch that
   only advances once Hydra has built it, so it is cached on
   cache.nixos.org for both `aarch64-linux` and `x86_64-linux`), re-locked in
   a real Nix. `flake.lock` changed in that one node only (`original.ref`:
   `master` -> `nixpkgs-unstable`; `locked.{rev,narHash,lastModified}`
   moved); every other node is byte-identical.
2. **Refuse silent source builds.** `dx_ai_check_cached` runs `nix build
   --dry-run` after the refresh and parses the derivations Nix says it will
   build, against a small allow-list of always-local, trivial ones (the
   `dx-ai-tools` buildEnv itself and its `builder.pl` companion, and
   `agy`/`claude-code`'s own tiny fetch+unpack -- both unfree-licensed
   upstream, so Hydra never builds or caches either one, on any revision).
3. **Fall back, then fail closed.** `dx_ai_ensure_cached` retries a miss
   against the previously published AI generation's own (already-working)
   lock; if that is clean, it continues on that revision with a notice. If
   it isn't (or there is no previous generation), it refuses before `nix
   profile add`, prints the packages that would be built from source and
   the remedy, and leaves the published generation untouched.
   `DX_AI_ALLOW_SOURCE_BUILDS=1` skips only that final refusal.

**A finding surfaced during implementation, not a decision this branch made
unilaterally:** nixpkgs' `claude-code` package is licensed `unfree`, so
-- exactly like `agy` -- Hydra never builds or caches it, on any revision,
for any architecture. Its own two derivations therefore show up in `nix
build --dry-run`'s "will be built" list on every single `dx-ai` run, forever,
regardless of how well the `nixpkgs-unstable` channel is cached otherwise.
Treating that the same as a genuine risk would make `dx-ai` refuse on a
fresh guest's very first run (no previous generation to fall back to)
unless `DX_AI_ALLOW_SOURCE_BUILDS=1` is set every time -- a regression
unrelated to the actual `codex` OOM incident this branch fixes. Branch 14
allow-lists `claude-code`'s trivial fetch+unpack the same way as `agy`'s
(both are small, `dontBuild=1`, seconds-long, evidenced against nixpkgs
revision `d54020a6ac3211e9f4201631bdf67678818c0cdf`). If you would rather
keep the allow-list to exactly the two items originally named (the
`dx-ai-tools` buildEnv and `agy`), tell the coordinating session and the
allow-list in `dx-ai.sh` narrows accordingly -- the practical effect is that
`dx-ai` then needs `DX_AI_ALLOW_SOURCE_BUILDS=1` on every `claude-code`
version bump, including a guest's first-ever run.

---

## Branch 15 — `fix/keyring-bootstrap-recreate` (size S; found on Branch 14's live gate, 2026-09-27)

Fixes the recreate/keyring defect recorded above: `dx-recreate` of a guest
whose `/persist` already holds a published AI generation aborted bootstrap
right after Home Manager activation, leaving the guest stopped (volumes
intact).

`dbus`/`gnome-keyring` are declared only in `flake.nix`'s `aiPackages`, so
they exist only in the AI generation's isolated profile
(`/persist/home/dx/.local/state/dx-ai/current/profile/bin`); Home Manager's
own profile (`homeConfigurations.dx`, `dxPackages`) never installs either
one, on either `dx-test` or `dx-host`. `setup_keyring_service` (guest
`bootstrap/persistence.sh`) resolved `dbus-daemon` by asking dx's login
shell to find it on `PATH` (`run_as_dx 'command -v dbus-daemon'`), which
depended on dx's `~/.profile` already reflecting the generation-profile
`PATH` prepend (`home/shell.nix`) at the moment bootstrap ran it -- not
guaranteed on a fresh `/home/dx`.

1. **Resolve explicitly, not via PATH.** A new `dx_resolve_keyring_bin`
   helper checks two fixed locations directly -- the published AI
   generation's profile first, dx's Home Manager profile as a fallback --
   for both `dbus-daemon` and `gnome-keyring-daemon`, instead of asking dx's
   login shell to resolve either on `PATH`. This is the same shape
   `scripts/dx-ai.sh`'s own `dx_ai_ensure_keyring` already uses for `dx-ai`'s
   own runs (prepend the generation profile to `PATH`, then a plain
   `command -v`), adapted to run from root without dx's shell environment.
2. **Failure policy B (user decision, 2026-09-27): degrade loudly, not
   fatally.** If neither binary can still be resolved (no AI generation has
   ever been published, or it is incomplete), `setup_keyring_service` logs
   an explicit `Warning:` naming what was missing and that `dx-ai` will
   start the keyring on its next run, and returns success so bootstrap
   continues to sshd. A guest with no keyring service is still reachable; a
   guest that never starts sshd is not. Option A (keep it fatal) was
   rejected.
3. Stale comments at both the `setup_keyring_service` call site and its
   definition (which said Home Manager installs `dbus-daemon` into dx's
   profile -- no longer true) are corrected.

**Status (2026-09-27): landed on `main`** (rebased onto `7f1a81d`, CI green, then fast-forwarded; `dx-host` still needs promoting to a `main` that contains it — see Appendix D). All gates green: G1 (bash-3.2,
ShellCheck 0.10.0 pinned, syntax, Container-free contracts,
`test_refactor_contracts.sh`) and G2 (100% sourceable coverage, scope-share
ratchet 1791 bp) green in throwaway containers. G3 not applicable (no
`.nix` file changed). G4 live on `dx-test`: `dx-recreate` on the fixed
bootstrap completes cleanly (no keyring warning), `DX_TEST_DESTRUCTIVE=1`
Section 17 (99/0/0), the full live tier (one regression found in the new
test's own fixture -- a `mkdir /persist` that a bare macOS host refuses --
fixed and re-verified), and a second `dx-recreate` proving idempotence.
`dx-test` cold-stopped afterward, volumes and AI generation intact. Full
detail in `docs/evidence/20260927/keyring-recreate.md`.

The precise start-vs-recreate mechanism could not be nailed down to a
single deterministic cause: reproducing the pre-fix guest's `dx-recreate`
live (once, per the "do not retry" instruction) did not reproduce Branch
14's failure, despite an otherwise byte-identical bootstrap log sequence
(down to matching Home Manager activation timings against Branch 14's own
retry). It looks like a race around Home Manager's freshly-written
`~/.profile`/`~/.bash_profile` becoming visible to a fresh process
immediately after activation, not a deterministic ordering defect -- see
the evidence doc for the full comparison. This does not affect the fix:
`dx_resolve_keyring_bin` checks fixed absolute paths directly and does not
depend on `~/.profile`/login-shell PATH at all.

Follow-up candidate (not done in this branch, not blocking): `dx-status`
(host) does not show a "keyring: not running" line for policy B's warning
path. The task's failure-policy description mentions this as the intended
observable outcome, but `bin/dx-status` was not in this branch's file list
and its existing host-script test fixture (a fake `container exec ... bash`
responder) answers every exec identically regardless of command, so adding
a distinguishable keyring probe there needs that fixture extended too.

---

## Observations from Branches 1–2 (for the item 5 review)

- **The coverage ratchet metric is fragile.** It was re-measured four times in
  one day (2176 → 2139 → 2140 → 2138 → 2144 bp). The metric is the share of
  *all* shell lines that sit in the measured scope, so adding tests lowers it
  and deleting tests raises it, the opposite of what a coverage gate should
  reward. `declarative-nix-plan-a.md` #12 proposes replacing it with a ceiling
  on uncovered production lines. Recommendation for the item 5 review: adopt
  #12 early as its own small branch (it is independent of the rest of that
  audit) and settle the refactor-v2 ordering question against it. Until then,
  keep re-measuring per the file's own rule.
- **CI compiles kcov from source on every run** in the coverage step, which
  costs several minutes per run. A prebuilt or cached runner image would help.
  Out of scope for the consolidation; backlog candidate.
- **Subagent operating rules** now live in
  `~/dxe-recovery/progress/SUBAGENT-BRIEF.md`, and each task prompt references
  it. Mandatory progress files are why Branch 1's stall and Branch 2's
  session-limit stop cost nothing.
- **`dx-ai`'s "build from source" fallback was memory-fragile (found on
  Branch 6, 2026-09-26; resolved by Branch 14).** A fresh guest's first
  `dx-ai` run refreshes `nixpkgs-unstable` before installing the optional AI
  tools bundle, so it depended on the binary cache actually having every AI
  tool built for `aarch64-linux` at whatever revision that refresh lands on.
  When the cache missed (observed for `codex-cli` at `codex-0.157.0`), Nix
  fell back to building a large Rust workspace from source locally, which
  needs far more memory than the profile's 12 GB default -- it OOM-killed
  (`rustc ... terminated by a deadly signal`) building `codex-core`/
  `codex-tui` under the default 12 GB / 4 CPU `dx-test`/`dx-host`
  allocation, and only succeeded after a disposable-guest-only recreate at
  24 GB. This was not an OpenCode-specific defect (`codex` is one of the
  five original optional tools). Branch 14 resolved it without raising the
  profile's default memory: `nixpkgs-unstable` now tracks the
  `nixpkgs-unstable` channel branch (cached on cache.nixos.org, not
  master), and `dx-ai` checks `nix build --dry-run` after every refresh and
  refuses to build anything heavy from source, falling back to the
  previously published generation's own lock first and failing closed
  (with the remedy) rather than OOMing if that also misses.
  `DX_AI_ALLOW_SOURCE_BUILDS=1` opts back into building from source.

- **Recreating an AI-opted-in guest fails in bootstrap (found on Branch 14's
  live gate, 2026-09-27; fixed by Branch 15).** `dx-recreate` of a guest
  whose `/persist` holds a published AI generation aborted right after Home
  Manager activation: `setup_keyring_service` (guest `bootstrap/persistence.sh`)
  resolved `dbus-daemon` through `run_as_dx`'s login PATH, but `dbus` and
  `gnome-keyring` are declared only in `aiPackages`, i.e. they exist only in
  dx-ai's isolated generation profile, never in the Home Manager profile.
  A plain start resolved them (the 2026-09-26 `dx-host` promotion worked);
  a recreate (fresh `/home/dx`) did not, and bootstrap's `set -e` stopped the
  container before sshd. Reproduced twice on `dx-test` at 12 GB; the files
  were byte-identical to `main`, so it was not Branch 14's. `dx-host` had
  the same shape (checked read-only). Branch 15 resolves the keyring
  binaries from the published AI generation explicitly (Home Manager's
  profile as a fallback), and the user chose failure policy B: warn loudly
  and keep the guest reachable rather than fail bootstrap, if the keyring
  still cannot start after correct resolution.

- **The keyring's D-Bus liveness check accepts a stale socket file (found
  during the 2026-09-27 `dx-host` promotion; proposed as Branch 16).** After
  `dx-stop-container`/`dx-start-container`, the previous boot's
  `/tmp/dbus-*` socket file still exists in the container's writable layer,
  `dx_keyring_address_is_live` treats it as a live bus, `setup_keyring_service`
  skips starting `dbus-daemon` ("keyring persistence completed in 0s"), and
  `gnome-keyring-daemon` is started against a dead address; `dx-ai`'s own
  `dx_ai_ensure_keyring` does the same and starts a second keyring daemon.
  Observed on `dx-host` read-only, and consistent with an earlier probe
  before the promotion, so it is long-standing, not Branch 15's. Impact:
  `agy` cannot persist OAuth tokens via Secret Service after a restart until
  the bus is restarted; nothing else. Proposed fix (Branch 16, S): probe the
  bus for real (connect to the socket, or check the recorded owner pid is
  alive), remove a stale address file and socket on boot, and never start a
  second keyring daemon; test with a fixture socket file and no listener.

## Decisions for you

The questions are listed in the order they're needed. Each has the background
you need to answer it. As of 2026-09-26, Q1, Q2, Q3, Q4, Q5, Q6 and the QNAP
part of Q7 are all resolved (each marked below with a short "Resolved
2026-09-26" line, background kept for the record). Only the rest of **Q7**
(the two large proposals other than QNAP) remains open, and it is not urgent
-- it's only needed before Branch 13. Branches 2–5 and Step 4 needed no
decisions.

### Q1. Can OpenCode ship before the "boots the previous version" bug is fixed? — **Resolved 2026-09-26: B, fix the bug first** *(needed for Branch 6)*

**Background:**

- Whenever bootstrap code changes, a restarted guest first boots the
  *previous* version (Branch 9 fixes this). OpenCode changes bootstrap code,
  so on your primary guest the first restart after merging would silently run
  the old code.
- The workaround is to restart a second time and confirm the right version is
  running, by reading the lease file inside the guest.
- This bug predates OpenCode. Every bootstrap change since it was found has
  had the same exposure.

**Options:**

- **A. Ship with a scripted workaround.** Write down the restart-and-verify
  steps, rehearse them three times on `dx-test`, and use them for the primary.
  Fix the bug later in Branch 9.
- **B. Fix the bug first.** Do Branch 9 before Branch 6. It is safer, but the
  OpenCode work and the `dxe-agent` clone wait several more weeks.

**Recommendation: A.** It matches "easiest first". The risk is bounded,
because the workaround is verified by evidence, not assumed. Branch 9 stays
next in line for bootstrap work.

**Resolved 2026-09-26: B.** Against the recommendation above, you chose to
fix the bug first: Branch 9 now runs before Branch 6 (see the summary table
and "Why this order"). OpenCode waits for it; the scripted restart-and-verify
workaround is not used.

### Q2. OpenCode is partly on `main`: finish it or pull it out? — **Resolved 2026-09-26: revert**

You chose to remove the partial feature from `main` now (Branch 2) and re-land
it complete in Branch 6. That keeps `main` to complete work only.
Consequences:

- **Branch 2's revert changes bootstrap code**, so it is promoted to your
  primary guest with the Appendix D procedure.
- **OpenCode data is kept.** Any OpenCode data already under
  `/persist/home/dx` stays in place, and Branch 6's migration must accept it.
- **Don't expect `opencode` from `dx-ai`** on the primary guest between
  Branch 2 and Branch 6.

### Q3. Herdr follow-ups: do them, and should the AI tool list live in one place? — **Resolved 2026-09-26: do the tests; keep the three lists** *(needed for Branch 7)*

**Background:**

- The Herdr review listed two missing tests (Branch 7) as optional.
- It also noted that the list of AI tools is repeated in three places: the
  Nix package list, the host install message and the docs. Today a contract
  test keeps them consistent; it is what caught the missing `opencode` in the
  install message (Branch 1).

**Options:**

- **Tests:** do them (small), or drop them.
- **Tool list:** keep three lists guarded by the test, or generate them from
  one source.

**Recommendation:** do the two tests. Keep the three lists with the
consistency test: it works, and one source of truth across Nix, host shell
and prose would add machinery for little gain.

**Resolved 2026-09-26:** agreed as recommended. Do the two Herdr tests
(Branch 7: bad-snapshot recovery and pane-history deletion). Keep the three
tool lists, guarded by the existing consistency contract test, rather than
generating them from one source.

### Q4. After a bootstrap edit, what should `dx-start-container` do if publishing the new version fails or times out? — **Resolved 2026-09-26: A, fail the start** *(needed for Branch 9)*

**Options:**

- **A. Fail the start** with a clear error. Nothing boots that you didn't ask
  for.
- **B. Boot the previous version**, but report a degraded or failed result.

A reboot or manual start with no publisher involved should still just work
either way.

**Recommendation: A.** Silently running old code is the bug being fixed.
Option B would keep a milder form of it.

**Resolved 2026-09-26: A.** Fail the start with a clear error if publishing
the new version fails or times out. A reboot or manual start with no
publisher still just works either way. Branch 9 implements this.

### Q5. Backups: what, where, how long, how often? — **Resolved 2026-09-26** *(needed for Branch 10)*

**Please tell me:**

- **Destination:** for example an external drive, a NAS path or a cloud bucket.
- **Retention:** for example 7 daily and 4 weekly copies.
- **Frequency:** for example hourly, daily, or manual only at first.
- **Anything beyond Git repositories in `/persist`** that must be included,
  for example `~/.claude`, `~/.codex` credentials or unpushed notes.

**Recommendation:** include credentials and anything not reproducible;
exclude caches that can be rebuilt. Start with manual on-demand backup and a
proven restore, then add the schedule.

**Resolved 2026-09-26:**

- **Destination:** a normal folder on the Mac, inside Time Machine's backup
  scope (default `~/Backups/dxe-persist/`).
- **Retention:** one current mirror -- no separate daily/weekly generations.
- **Frequency:** on demand first, with a proven manual backup-and-restore;
  a schedule is added later.
- Branch 10 implements this.

### Q6. Store trust: is "stop safely and tell me how to recover" acceptable, or must it self-repair? — **Resolved 2026-09-26: A, fail fast with a tested recovery path** *(needed for Branch 12)*

**Background:** in some corrupted-store cases there may be no trustworthy
tool left inside the guest to repair it automatically.

**Options:**

- **A. Fail fast** before running anything untrusted, with a tested recovery
  procedure, for example rebuilding the `/nix` volume from scratch.
- **B. Require automatic repair** in every case. This may not be possible
  without extra infrastructure.

**Recommendation: A.**

**Resolved 2026-09-26: A.** Fail fast before running anything untrusted, with
a tested recovery procedure (for example rebuilding the `/nix` volume from
scratch). Option B (mandatory automatic repair in every case) is not
required.

### Q7. The large proposals: accept, reject or keep parked? *(QNAP resolved; the others are needed before Branch 13, not urgent)*

**Status 2026-09-26:** QNAP is resolved (accepted, Branch 11). The bootstrap
refactor v2 and declarative-Nix audit proposals remain open -- still your
call, still not urgent.

For each proposal:

- **Accept:** it gets a branch after its prerequisites.
- **Reject:** the plan is deleted, with a one-line reason in `plans.md`.
- **Park:** it stays listed as "Open" with a revisit trigger, which the
  repository's `plans.md` already supports.

| Proposal | Recommendation | Why |
| --- | --- | --- |
| Bootstrap refactor v2 | **Park** until Branches 9 and 12 are done, then re-decide | Its phases assume today's code. The start-generation and store-trust fixes will change that code, so it would need rebaselining anyway. |
| Declarative Nix audit | **Reject as a single programme; accept its items one at a time** as small branches, alongside other work | Each conversion (for example SSH or sudo config into Home Manager) is independently useful and small. A big-bang migration conflicts with limiting work in progress. |
| QNAP runtime | **Resolved 2026-09-26: accepted** as Branch 11. Phase 0 may run early; implementation follows Branches 9 and 10 | The target is a TVS-h674T (x86_64, to confirm in Phase 0), so the plan's Phase 4 architecture work is required. |

**Coverage metric conflict:** only relevant if you accept both v2 and the Nix
audit's item #12. That item replaces the coverage ratio with a ceiling on
uncovered lines; v2's Phase 4 measures the old ratio. Recommendation: finish
v2 on the current metric, then change the metric separately.

### Defaults assumed (tell me if any are wrong)

- **Plain `opencode`, no auto-approve alias** (from your note). The other
  tools do have "skip permissions" aliases in `home/shell.nix`. If you want
  `opencode --auto` for parity, it's a one-line change plus a test.
- **No `dx-opencode` profile or key.** Destructive tests use `dx-test`.
- **Small complete pieces merge early.** A validated, self-contained
  increment of a larger initiative can merge while the rest continues on its
  branch (from your "move as much work to main" note).
- **One working directory, one branch at a time.** No extra worktrees are
  needed, given the one-branch-at-a-time rule.
- **Clean commits.** `main` receives clean, reviewed commits. The original
  `dxe-agent` and WIP history stays in the private archive with a mapping
  table. Published `main` history is never rewritten.
- **Test image stored in the repo** rather than re-pinning the GitHub URL
  (Branch 3).

---

# Appendices (reference)

## Appendix A — Inventory and snapshot details

Baseline taken 2026-09-26. Re-check it at Step 0; use full SHAs in the private
manifest.

| Item | State | Disposition |
| --- | --- | --- |
| `dxe/` | `main` = `origin/main` = `71c2b50`. Modified: `bin/dx-herdr`, `tests/test_section10_docs.sh`, `tests/test_section12_validate_linux.sh`. Untracked: `opencode-context.md` | Canonical. Changes go to Branches 1 and 6. The Section 10 edit is dropped and the note deleted (Branch 5) |
| `dxe/` ignored files | `dx_key`, `dx-test_key`, `dx-mount-dx-mount-legacy-plain-bge3wc-d63c62d699_key` (each with `.pub`); `.claude/`, `bin/.claude/`, `.antigravitycli/`; `tests/coverage/out/` | Keys stay; the legacy mount key feeds Branch 8. Agent state goes into the archive only. Coverage output can be regenerated |
| `dxe-agent/` | `main` at `f69d1e4`, one commit ahead of `origin`. 13 modified and 3 untracked files | Branch 6, then retire |
| `dxe-agent/` ignored files | `dx-opencode_key` pair; `tests/coverage/out/` | Archive only; not carried forward |
| `dxe-evidence-20260831/` | `RECORD.md` and ten logs | Branch 5 → `docs/evidence/20260831/` |
| This file | `~/Development/dxe-consolidation-plan.md`, outside any repo | Branch 5 moves it into the repo |
| `fix/dx-wait-ssh-probe-budget` | Local and remote both at `71c2b50`, the same as `main` | Delete after Branch 6 |
| `refs/guest/herdr-tmux-navigation` | `3f2a910`, `e58fefc`, not in `main` | Appendix B |
| `refs/claude/checkpoint-ae11ab94` | `4130eed`; only `.claude/RESUME.md` changed | Provenance only; archive |
| Tags | `dxe-sync-safety-point` (in `main`); `design-history/sigbus-fix-a428c55` (**not** in `main`; the tag is its only reference) | Keep both permanently |
| Unreachable objects in `dxe` | 42 commits, 57 trees, 24 blobs; `dxe-agent` has none. Stashes are empty | Pin at Step 0; see Appendix B |
| GitHub | Branches `main` and `fix/dx-wait-ssh-probe-budget`; no open PRs | Re-check before deleting anything |
| Runtimes | Apple Container service not started; OrbStack not running; no local `nix` | Step 0 starts them. G3 runs inside an `aarch64-linux` container |

**Snapshot rules:**

- Pause all writers first.
- Record the prior `gc.auto` and maintenance settings, including "unset".
- Record HEADs, refs, status, binary diffs, untracked and ignored files,
  remotes and reflogs.
- Write the archive outside both trees.
- Verify it by restoring and comparing file hashes, symlinks and permissions,
  and by running `git fsck --full`.
- Never push `refs/archive/*`, and never do a mirror push.
- Never stage key files.

## Appendix B — Historical commits to account for

These go in the Branch 5 ledger. For each item, record one of: already
present, superseded (with the reason), rejected, or unique work (then give it
a branch).

- **Herdr navigation ref:**
  - `3f2a910` is patch-equivalent to `9bc04a4` on `main`.
  - `e58fefc`'s persistence work appears superseded by `753c554` and
    `bootstrap/herdr-config.sh`. Confirm this by comparing behaviour and tests.
- **Of 42 unreachable commits:** 18 match `main`, 9 are empty index snapshots,
  and 15 need a look:
  - `7fe6caf`: tunnel self-healing. Compare with `8ba2a69` and `dc75be3`.
  - `71e00fe`: disk-size wiring. Compare with `98e11a7`.
  - `7fd234b`: early OpenCode tests. Compare with `0f71be4` and Branch 6; keep
    the newer behaviour tests.
  - `8d7f85c`: migration retries. Compare with `5966c35` and `1222c08`; keep
    the later, narrower error check.
  - `2003457`, `02cbe55`, `4cfeefa`, `0c74f90`, `d8070c1`: older test,
    bootstrap and Neovim changes.
  - `55e0efa`, `e8246ff`, `e869eac`, `773c120`: older implementation
    revisions.
  - `3244307`, `1e29069`: continuation-note checkpoints.

A missing exact patch match does not prove that functionality is missing.
Loose blobs and trees are covered by the archive.

## Appendix C — Gates, coverage and Nix rules

| Gate | What to run and where |
| --- | --- |
| G1 Static and contracts | The ShellCheck and syntax commands from `.github/workflows/ci.yml`; `tests/run-bash32-tests.sh` on macOS `/bin/bash` 3.2; and under Bash 5 on Linux, `tests/run_all_tests.sh --skip-integration` plus `tests/test_refactor_contracts.sh` (the aggregate runner doesn't dispatch the latter) |
| G2 Coverage | `tests/run-coverage-linux.sh`, using Docker, Podman or Apple `container`. Requires 100% of the declared kcov scope, the scope-share ratchet, non-skipped Section 25, and the changed-code report below |
| G3 Nix | In a named `aarch64-linux` Nix environment (CI's x86_64 job only evaluates the flake): `nix flake check --no-build --no-write-lock-file` on `container/aarch64-darwin-apple-container-dx-nixos-26.05`. Then build `default`, `ai-tools`, `bootstrap-essentials` and `homeConfigurations.dx.activationPackage`, run Section 12, and confirm the lock file is unchanged |
| G4 Live | On isolated guests (`dx-test`), per the branch's own list. Record the version that actually booted, not just the `current` pointer. A zero exit code with required checks skipped is a fail |
| G5 CI | Both jobs green for the exact commit that lands. Queued, skipped or cancelled runs don't count |

**Evidence:** for each gate, record the commit, lock hash, image digest,
profile, command, environment, exit code, totals and skips in
`docs/evidence/<date>/`, not only in `/tmp`.

**Dual-target gate (user rule, 2026-09-26):** any change to shared
lifecycle code (`bin/`, `bin/lib/`, `container/…`) must pass the live tier
on **both** targets: Apple `container` (`dx-test`) and the QNAP runtime
(Branch 11), once a QNAP guest exists (Phase 3 onward of Branch 11). Until
a QNAP guest exists, QNAP non-regression means `tests/qnap/` and Section
27 stay green and the Phase 0 spike still passes; that stands in for the
QNAP live tier and is not itself the dual-target gate. Do not treat a
green Apple-only G4 as sufficient for shared lifecycle code once a QNAP
guest exists.

**Changed-code coverage:**

- kcov measures only `bin/lib`, guest `bootstrap/` and guest `scripts/lib`.
- For each branch, list every changed production file and map its behaviours
  and failure cases to tests.
- Every added or changed executable line must be exercised by a behavioural
  test, including files outside the kcov scope (such as `dx-ai.sh` and
  `bin/dx-*`). Extend the instrumentation or attach a focused report.
- Never add exclusions or weaken assertions to reach 100%.
- Tests must exercise production code, not a copy of it. A source-text check
  alone doesn't prove runtime behaviour.

**Nix rules:**

- Use the existing Home Manager patterns (`programs.*`, `home.file`,
  `xdg.configFile`, `pkgs.formats.*`) and repository helpers before adding
  anything new.
- Shell is fine for runtime work Nix can't express safely: state-preserving
  migration, conflict handling, root ownership repair. Keep it minimal, say
  why, and test the real filesystem behaviour.
- Never force mutable user data into the Nix store.
- Prove Nix changes by building them and testing the generated config,
  including repeat activation. A successful evaluation is not enough.
- Keep the stable and AI inputs separate, and keep the committed lock.
- When moving logic from shell to Nix, keep its assertions and add Nix checks
  before deleting the old tests. Don't lower the coverage ratchet to make a
  conversion pass.

## Appendix D — Promoting to your primary guest, and backing out

Use this for runtime-affecting branches (2, 6, 8, 9, 10, 11, 12).

**Explicit approval required (user rule, 2026-09-26):** every promotion to
`dx-host` needs the user's explicit approval for that specific promotion,
and a tested backup of `/persist` (step 2 below) must exist *before* it
runs. No subagent promotes to `dx-host` on its own; the coordinating
session runs this appendix with the user, after they have seen the
rehearsed dry run on `dx-test`.

**Status (2026-09-27):** `dx-host` (the primary guest) was promoted to
`main` `122258c` on 2026-09-27 following this appendix, with the user's
explicit approval: fresh manual `/persist` backup (kept privately;
103,241 files, 6.15 GiB, count verified against the guest), stop,
`dx-start-container` with the publication confirmation (running ==
published generation), `dx-wait-ssh`, verification (SSH, Home Manager
activation completed in 9 s, all 103,242 `/persist` files present), then a
cold `dx-ai` (no Herdr server running) that published a six-tool AI
generation from the cache in under a minute -- `dx-host` now has OpenCode
(1.18.31). The previous promotion (`main` `08700a8`, 2026-09-26) followed the
same steps. The 2026-09-27 recreate caution is lifted: `dx-host` runs a
bootstrap containing Branch 15, so `dx-recreate` is safe again.

**Open finding from this promotion (needs a decision; see "Observations"):**
after a container restart the keyring's D-Bus session is not actually
running -- the previous boot's socket file survives in the container's
writable layer and the liveness check accepts it. Not caused by Branch 15
and not a regression of this promotion; it affects only `agy`'s
Secret-Service token persistence until the bus is restarted.

**Before promoting:**

1. Record the current source SHA, lock, image digest, running bootstrap
   version, Home Manager and AI generations, and volumes.
2. Back up `/persist` with applications quiesced: B1 once it exists,
   otherwise a manual backup whose restore you have tested on a scratch
   location.
3. Stop Nix garbage collection from removing previous generations until the
   rollout is accepted.
4. Rehearse promotion and backout on `dx-test`.

**Promote:**

1. Re-fetch `main`. If it moved, merge it into the branch and re-run the full
   gates.
2. Fast-forward `main` and push normally. Never force-push.
3. Confirm CI is green for that exact `main` SHA.
4. Promote using the rehearsed steps. Until Branch 9 lands, that includes the
   Q1 restart-and-verify workaround.

**Verify:**

- The *running* bootstrap version matches the accepted one, read from the
  launcher's lease file.
- SSH works.
- Home Manager activation succeeded.
- `/persist` data matches the backup.
- If you've opted into AI tools, update them explicitly with `dx-ai`, using a
  cold Herdr upgrade: no Herdr server may be running during `dx-ai`. Record
  the AI lock and tool versions separately from the bootstrap lock.

**Back out:**

1. On any failure, stop and keep the evidence.
2. Revert as a reviewed commit and redeploy the recorded good version, then
   verify the running version again.
3. Reverting code does **not** undo a `/persist` migration. First test
   whether the old code reads the migrated data. If it can't, restore the
   backup into separate storage and reconcile any newer writes. Never
   overwrite newer data blindly.
4. Same-pin backouts keep volumes. A base-image pin change needs the
   store-trust procedure (Branch 12).
5. Never turn a failed rollout into a factory reset.
