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
| 9 | `fix/bootstrap-start-generation` | Make a restarted guest run the bootstrap code that was just published, not the previous version | M | Yes | No (Q4 resolved: fail the start) | Not started |
| 6 | `feat/opencode` | Land OpenCode as one complete delivery: the original support plus safe migration, rollback and ownership repair | M | Yes | No (Q1 resolved: after Branch 9) | Code exists, preserved as this repository's own local branch `preserve/dxe-agent-opencode` |
| **Priority 3 — backlog** | | | | | | |
| 7 | `test/herdr-acceptance` | Two missing Herdr tests: bad-snapshot recovery and pane-history deletion | S | Possibly | No (Q3 resolved: do them) | Not started |
| 8 | `refactor/legacy-migration-cleanup` | Check that every guest has left the old base image, then delete the old-base guards. This finishes `refactor-plan.md` | S–M | Yes (inventory) | No | Not started |
| 10 | `feat/persist-backup` | "B1": incremental host backup and restore of the guest's `/persist` data | M | Yes | No (Q5 resolved) | Not started |
| 11 | `feat/qnap-runtime` (several branches) | Run DXE on the QNAP (TVS-h674T, x86_64) via Docker over SSH. Phase 0 (inventory plus a throwaway spike, no repo code) may run any time after item 4 | L | Yes, plus the QNAP | No (accepted 2026-09-26) | Phase 0 optional early |
| 12 | `fix/store-trust` (may split in two) | Safe handling of the two Nix-store trust problems in `store-trust-plan.md` | L | Yes | No (Q6 resolved: fail fast) | Not started |
| 13 | `refactor/bootstrap-v2`, `refactor/declarative-nix` | The two remaining large proposals. No branch until you accept one | L each | Yes | Q7 (still open) | Not started |

```text
Priority 1:  0 ✓ ─► 1 ✓ ─► 2 ✓ ─► 3 ✓ ─► 4 ✓ ─► 4a ✓ ─► 4b ✓ ─► 4c   (main complete, green, buildable, proven on a guest)
Priority 2:  5 ✓ ─► 9 ─► 6   (duplicate clone already retired; see "Where things stand")
Priority 3:  7 ─► 8 ─► 10 ─► 11 ─► 12 ─► 13 (only accepted proposals)
             QNAP Phase 0 (no code) can run any time after item 4
```

Why this order:

- Items 0–4 make `main` trustworthy and complete. Every later branch is
  validated against it.
- Branch 2 (the revert) comes before the baseline check, so Step 4 validates
  the `main` you intend to keep.
- Branch 5 is docs-only, so it doesn't make `main` work. It can be written any
  time.
- **Branch 9 (the start-generation fix) now comes before Branch 6.** Q1
  (resolved 2026-09-26) chose to fix the "boots the previous version" bug
  first rather than ship OpenCode behind a scripted workaround: OpenCode
  changes bootstrap code, so it would otherwise hit the bug on the very next
  restart of your primary guest.
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

## Branch 6 — `feat/opencode` (size M, code exists)

**Depends on:** Branches 1–3 merged, Step 4 passed, and Branch 9 landed.
**Decision:** Q1 -- **resolved 2026-09-26: fix the start-generation bug
first.** Branch 9 now runs before this one (see the summary table and "Why
this order").

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

Two missing acceptance cases from the completed Herdr review. Add one test per
increment:

1. Recovery from a corrupt or too-new Herdr snapshot.
2. The deletion half of pane-history cleanup.

If a test passes immediately, label it a characterisation test. If it fails,
the fix goes in the same increment. Afterwards, remove "Optional follow-up"
from `plans.md`.

---

## Branch 8 — `refactor/legacy-migration-cleanup` (size S–M)

**Finishes `refactor-plan.md`.** The only remaining item is Phase 6 item 1:
remove the old-base guards in `bootstrap.sh:11–29` and
`bin/dx-start-container:21–44`, once no guest still uses the old base image.

1. **Inventory (no code).** List every container, image and volume. Include
   the default guest, `dx-test`, `dx-tinty`, the container behind the leftover
   `dx-mount-dx-mount-legacy-plain-…` key, and anything else found. Check each
   against the old-base guard gate in `docs/refactor/migration-gates.md`, and
   record dated evidence in `docs/evidence/`. If any guest still uses the old
   base, you decide whether to migrate or destroy it before continuing.
2. **Characterise:** confirm a test covers the new-base start path without
   the guard. It should start green.
3. **Remove** the guards with their dedicated tests and changeover docs, one
   guard per commit.
4. **Close the plan:**
   - Move the "Measurable targets" table in `refactor-plan.md` to
     `docs/refactor/` if you want to keep tracking it.
   - Delete `refactor-plan.md` and its `plans.md` entry.

---

## Branch 9 — `fix/bootstrap-start-generation` (size M; Q4 resolved; now runs before Branch 6)

**Q4 -- resolved 2026-09-26: A, fail the start** if publishing the new
bootstrap version fails or times out, with a manual start or reboot that has
no publisher still just working. **Q1 -- resolved 2026-09-26:** this branch
now lands before Branch 6, instead of OpenCode shipping behind a scripted
restart-and-verify workaround (see the summary table and "Why this order").

**Problem (`dx-start-plan.md`):** `dx-start-container` starts the guest
*before* the host publishes the new bootstrap code. A guest with a retained
bootstrap volume therefore runs the *previous* version, silently, after every
bootstrap edit. The only current workaround is starting it a second time.

1. **Observability (can merge alone):** record the bootstrap version that
   actually booted somewhere the host can read. Today it is only visible
   inside a lease file in a running guest. Red: a test that expects the
   record and finds none.
2. **The fix:** fail the start with a clear error if publishing the new
   version fails or times out (Q4 = A) -- nothing boots that wasn't asked
   for. Test these cases:
   - an edited start;
   - first boot;
   - no-change start;
   - manual start or reboot with no publisher (must still just work);
   - timeout;
   - a dead guest.

   Keep publication locking and retention of older versions.
3. Close `dx-start-plan.md`: move the invariants to
   `docs/refactor/decisions/` and the operator notes to `docs/lifecycle.md`,
   then delete the plan and its `plans.md` entry.

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
