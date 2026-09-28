# DXE consolidation plan

Moved into the repository on 2026-09-26. Prepared 2026-09-25; rewritten
2026-09-26 against the repository objectives; **trimmed to remaining work
only on 2026-09-27**, per this plan's own retirement step ("After Branch 6
merges: retire the duplicates", item 3): now that the duplicate repository
is retired, remove the completed consolidation steps and keep only what
remains. History for every removed step, branch and decision is in `git log`
and `docs/evidence/` -- nothing was archived elsewhere.

---

## Summary

### Where things stand

Updated 2026-09-27, after this trim.

- **`main` is `51226bf`.** Priority 1 (a complete, green, buildable `main`,
  proven on a guest) is done: Steps 0 and 4 and Branches 1, 2, 3, 4a, 4b and
  4c all landed and validated. Priority 2 and almost all of Priority 3 are
  also done: Branches 5, 6 (OpenCode), 7, 8, 9 (the start-generation fix), 10
  (persist backup), 14 (`dx-ai` no-source-builds), 15 (keyring
  bootstrap-recreate), 16 (keyring owned by `dx-ai`) and 17 (`dx-backup`
  transfer stall) are all landed, CI green, live-verified on `dx-test`. See
  the table below for each branch's evidence record.
- **`dx-host` (the primary guest) runs current `main`** (promoted 2026-09-28
  to `6bfe9f0`'s payload per Appendix D -- Branch 12, the hardening branch
  and Phase 4 included, via a container-only recreate onto its existing
  volumes -- after four earlier promotions on 2026-09-26/27). It has every landed branch, including
  Branch 16 (the keyring is started by `dx-ai`/`dx-keyring`, not bootstrap;
  verified live after the promotion: `dx-keyring status` was `stale` after
  the restart and `live` with one `dbus-daemon` and one
  `gnome-keyring-daemon` after a cold `dx-ai`) and Branch 17's transfer
  fix. Its first real `dx-backup` exposed a nested-repository duplicate-path
  defect (fixed by Branch 18); the promotion's backup was a full tar copy.
- **`dx-test` is the disposable guest** used for every live gate. Wipe and
  recreate it freely.
- **No QNAP guest exists yet.** The QNAP (TVS-h674T, confirmed **x86_64** in
  Phase 0) has had only a throwaway inventory and disposable spike (Phase 0,
  destroyed after), the Apple-side runtime-boundary extraction (Phase 1), and
  a remote Docker-over-SSH adapter developed and characterised entirely
  against fake `ssh`/`docker` boundaries (Phase 2), whose exit gate's one
  live step -- a read-only `dx-status` and preflight against a disposable
  profile -- ran on 2026-09-27 and passed (nothing on the NAS created or
  changed). Phase 3 (direct storage mode) landed 2026-09-27 and Phase 4 (the
  architecture-neutral guest) landed 2026-09-28, both live-gated on the
  NAS with disposable resources: the first native x86_64 DXE guest
  bootstrapped on the QNAP in about two minutes (evidence:
  `docs/evidence/20260927/direct-volume-storage.md`,
  `docs/evidence/20260928/arch-neutral-guest.md`). Phase 5 (remote-aware
  SSH and workflows) landed 2026-09-28 the same way: the disposable guest
  was reached directly on the NAS's Tailscale address from the controller
  (evidence: `docs/evidence/20260928/remote-aware-ssh.md`). **Phase 6**
  (lifecycle hardening) is in progress on `feat/qnap-lifecycle`, items
  1/2/4/5/6/7/8 implemented against fakes only, items 3/9 waiting on the
  coordinating session's maintenance window against the real NAS (which
  also covers Phase 0's own still-open 8b/8c items); **Phase 7**
  (promotion to a real QNAP profile) is not started.
- **Remaining work:** Branch 11 Phases 6-7 (below) and Branch 13 (the two
  large proposals, Q7 -- still open, not urgent). Branch 12
  (`fix/store-trust`) and the four small follow-ups (`fix/test-hardening`)
  landed 2026-09-28.

### Feature-branch breakdown

The work is listed in the order to do it: easiest and most unblocking first.
**Only one code branch is open at a time.** Merge it to `main`, then start the
next. The only exception: if a branch is stuck waiting on you or on hardware,
the next one may start.

| # | Branch | What it delivers, in plain terms | Size | Needs a running container? | Waiting on a decision? | Status |
| --- | --- | --- | --- | --- | --- | --- |
| **Priority 1 — `main` complete, working and tested** | | | | | | |
| 0 | *(no branch)* | Safety snapshot of both clones, then start the container runtime | ~1–2 h | Starts it | No | **Done** 2026-09-26 — evidence: `docs/evidence/20260926/consolidation-ledger.md` |
| 1 | `fix/ci-baseline` | Make CI green again | S | No (CI only) | No | **Done** 2026-09-26 — `main` = `086d9ce`, CI green (git log) |
| 2 | `revert/opencode-partial` | Remove the half-finished OpenCode support from `main`; it returns complete in Branch 6 | S | No (CI only) | No | **Done** 2026-09-26 — `main` = `0cf61bd`, CI green (git log) |
| 3 | `fix/test-image-fixture` | Remove the unused `test-image.png` download so guest builds stop depending on a GitHub avatar | XS | Yes (Nix eval) | No | **Done** 2026-09-26 — `main` = `bd2418f`, CI green (git log) |
| 4 | *(no branch)* | Baseline check: build every guest output from `main`, run it on a freshly recreated `dx-test`, and record evidence that `main` works | ~half day | Yes | No (`dx-test` is disposable) | **Done** 2026-09-26 — evidence: `docs/evidence/20260926/main-baseline.md` |
| 4a | `fix/container-running-sigpipe` | Fix the false "container stopped" abort in `dx-wait-ssh` (Step 4 finding 1) | S | No | No | **Done** 2026-09-26 — `main` = `596ac28`, CI green (git log) |
| 4b | `test/live-tier-hygiene` | Make Section 12 run inside the guest as part of the live tier; make Section 4's SSH probe skip (not fail) without a guest; make Section 14's history probe immune to SSH's known-hosts warning | S | Yes (`dx-test`) | No | **Done** 2026-09-26 — `main` = `3e41f4a`, live tier 1105/0/8 (git log) |
| 4c | `fix/guest-sigpipe-pipelines` | Fix the same `\| grep -q` / `\| head -n1` under `pipefail` SIGPIPE shape as Branch 4a, in `bootstrap/activation.sh` and the guest theme scripts | S | No | No | **Done** 2026-09-26 — `main` ratchet re-measured at `a96e67f`, CI green (git log) |
| **Priority 2 — fix the start-generation bug, then finish in-flight work** | | | | | | |
| 5 | `docs/plan-cleanup` | Remove stale plan text, delete the OpenCode handoff note, import August evidence, move this plan into the repo | S | No | No | **Done** 2026-09-26 — plan moved into the repo at `9064bb9`; evidence: `docs/evidence/20260926/consolidation-ledger.md` |
| 9 | `fix/bootstrap-start-generation` | Make a restarted guest run the bootstrap code that was just published, not the previous version | M | Yes | No (Q4 resolved) | **Done** 2026-09-26 — evidence: `docs/refactor/decisions/D7-start-generation.md` |
| 6 | `feat/opencode` | Land OpenCode as one complete delivery: the original support plus safe migration, rollback and ownership repair | M | Yes | No (Q1 resolved) | **Done** 2026-09-26 — evidence: `docs/evidence/20260926/opencode-relanding.md` |
| **Priority 3 — backlog** | | | | | | |
| 7 | `test/herdr-acceptance` | Two missing Herdr tests: bad-snapshot recovery and pane-history deletion | S | Yes (`dx-test`) | No (Q3 resolved) | **Done** 2026-09-26 — evidence: `docs/evidence/20260926/herdr-acceptance.md` |
| 8 | `refactor/legacy-migration-cleanup` | Check that every guest has left the old base image, then delete the old-base guards. This finishes `refactor-plan.md` | S–M | Yes (inventory) | No | **Done** 2026-09-27 — evidence: `docs/evidence/20260926/legacy-guard-removal.md`; `refactor-plan.md` closed |
| 10 | `feat/persist-backup` | "B1": incremental host backup and restore of the guest's `/persist` data | M | Yes | No (Q5 resolved) | **Done** 2026-09-27 — evidence: `docs/evidence/20260927/persist-backup.md` |
| 11 | `feat/qnap-runtime` (several branches) | Run DXE on the QNAP (TVS-h674T, x86_64) via Docker over SSH | L | Yes, plus the QNAP | No (accepted 2026-09-26) | Phase 0 done except 8b/8c (deferred into Phase 6's maintenance window). Phases 1-5 landed on `main` (arch-neutral guest, remote-aware SSH over the NAS's own Tailscale address) — see the Branch 11 section below for each phase's evidence record. **Phase 6 (lifecycle, reboot, operational hardening) in progress on `feat/qnap-lifecycle`**, items 1/2/4/5/6/7/8 implemented against fakes only, items 3/9 waiting on the maintenance window; **Phase 7 not started** — see below |
| 12 | `fix/store-trust` | Safe handling of the two Nix-store trust problems in `store-trust-plan.md` | L | Yes | No (Q6 resolved: fail fast) | Implemented on the branch 2026-09-27, not yet landed — see Branch 12 section |
| 13 | `refactor/bootstrap-v2`, `refactor/declarative-nix` | The two remaining large proposals. No branch until you accept one | L each | Yes | Q7 (still open) | Not started |
| 14 | `fix/dx-ai-no-source-builds` | Stop `dx-ai` from silently compiling heavy AI tools from source when a `nixpkgs-unstable` refresh misses the binary cache | S–M | Yes (`dx-test`) | No | **Done** 2026-09-27 — evidence: `docs/evidence/20260927/dx-ai-no-source-builds.md` |
| 15 | `fix/keyring-bootstrap-recreate` | Make `dx-recreate` of an AI-opted-in guest work again | S | Yes (`dx-test`) | Policy B chosen 2026-09-27 | **Done** 2026-09-27 — evidence: `docs/evidence/20260927/keyring-recreate.md`; superseded by Branch 16 |
| 16 | `refactor/keyring-owned-by-dx-ai` | Move the guest keyring out of bootstrap: `dx-ai`/`dx-keyring` own it with a real liveness probe | S | Yes (`dx-test`) | Option 4 chosen 2026-09-27 | **Done** 2026-09-27 — evidence: `docs/evidence/20260927/keyring-owned-by-dx-ai.md`; `dx-host` gets it at its next promotion |
| 17 | `fix/dx-backup-transfer-stall` | Make `dx-backup`'s transfer unidirectional (it deadlocked on large selections) and add `--dry-run --summary` for the at-risk breakdown | S–M | Yes (`dx-test`) | No | **Done** 2026-09-27 — evidence: `docs/evidence/20260927/dx-backup-transfer-stall.md`; `dx-host` gets it at its next promotion |
| 18 | `fix/dx-backup-deny-list` | Add user-approved entries to `dx-backup`'s deny-list (`.pnpm-store`, `.Trash-*`, `.tmp`, the `agy` binary bundle), a default location for the exclude file, and fix a nested-repository duplicate-path crash found live along the way | S | Yes (`dx-test`; unit fixtures only) | No (option 1a chosen 2026-09-27) | **Done** 2026-09-27 — landed on `main` (rebased onto `4b965d7`, CI green); evidence: `docs/evidence/20260927/dx-backup-deny-list.md`; the guest selector reaches `dx-host` through `dx-sync-bootstrap` (done at landing), the host side is on `main` immediately |

**Remaining order:** Branch 11 Phases 6-7 have no outstanding
prerequisites -- Phases 0-5, Branch 12 (store trust) and the four small
follow-ups (`fix/test-hardening`) are all on `main`. Branch 13 stays parked
behind Q7.

---

## How every branch is built and landed

This section is short on purpose. The full rules are in Appendix C.

1. **Start from green `main`.**
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
   the branch. Use clean commits.
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

## Branch 11 — QNAP runtime (`qnap-dxe-plan.md`; accepted 2026-09-26)

**Status 2026-09-27:** Phase 0 is done except items 8b/8c (a reboot test
during an agreed maintenance window; see `qnap-dxe-plan.md`'s Phase 0).
Phase 1 (runtime-boundary extraction) is done -- evidence:
`docs/evidence/20260927/runtime-boundary.md`. Phase 2 (the remote
Docker-over-SSH adapter, `feat/qnap-docker-adapter`) is done -- developed and
characterised entirely against fake `ssh`/`docker` boundaries, the NAS never
touched; evidence: `docs/evidence/20260927/docker-adapter.md`. One gap was
found and flagged, not closed (outside that branch's allowed-file scope):
`bin/dx-mount` does not yet refuse under `DX_RUNTIME=docker-ssh` even though
DQ8's capability table already answers `bind_mounts: no` correctly -- see
`docs/refactor/docker-adapter-mapping.md`'s "Flagged for review" item 4. It
is tracked under `qnap-dxe-plan.md`'s Phase 5 item 7 (fail-closed capability
checks), not as a branch of its own. Phase 2's one live step -- a read-only
`dx-status` and preflight against a disposable QNAP profile -- was run by the
coordinating session on 2026-09-27 after the user's go and passed; the exit
gate is met in full (see the evidence record). **Phase 3 (direct storage
mode, `feat/qnap-direct-storage`) is done on the branch** -- developed and
characterised entirely against fake `ssh`/`docker` boundaries and
guest-bootstrap fixtures, the NAS never touched; see `qnap-dxe-plan.md`'s
own Phase 3 status paragraph and `docs/refactor/direct-volume-storage.md`
for the full design. Its exit gate's "recreate preserves `/nix`,
`/persist`..." check needed a real x86_64 QNAP guest and was run as part of
Phase 4's gate. **Phase 4 (the architecture-neutral guest,
`feat/qnap-arch-neutral`) landed 2026-09-28** -- items 1-5 (the
context-tree rename, item 6, stays a pending standalone mechanical commit),
both live gates passed: `dx-test`'s full live tier under the profile
environment, and on the NAS a disposable 8 GB / 4 CPU x86_64 guest that
bootstrapped natively in ~120 s with all 21 required tools, `dx-status`
and `dx-reclaim` under the QNAP profile, and a container-only recreate
onto its existing volumes. The gates found five real defects before
landing (see `docs/evidence/20260928/arch-neutral-guest.md`), the most
important being that Docker injects `HOME=/root` where Apple leaves it
unset, which had let the essentials install work on Apple by accident;
the bootstrap now names its root profile explicitly. See
`qnap-dxe-plan.md`'s own Phase 4 status and
`docs/refactor/arch-neutral-guest.md` for the full design. **Phase 5
(make SSH and user workflows remote-aware, `feat/qnap-remote-ssh`) is
done on the branch, fakes only** -- items 1-8 implemented (item 9,
running `tailscaled` inside the guest, stays deferred per the
2026-09-26 decision recorded in `qnap-dxe-plan.md`'s own Phase 5 section
until items 1-8 land): a new `dx_runtime_guest_ssh_address` contract
operation and `--publish` rendering make a `docker-ssh` guest's SSH port
publish directly on the NAS's own discovered Tailscale address rather
than controller loopback; the shared SSH option/endpoint builder,
`dx-wait-ssh`, `dx-status`, and `dx-tunnel.sh`'s dial sites all reach it
through that one seam; a per-profile known-hosts file pins the guest's
SSH host identity for `docker-ssh` profiles; `dx-enter` forces its own
ssh pty (`-tt`) exactly when Docker's own exec requests one; `dx-export`
is atomic; and `dx-mount`/`dx-nix-disk`/a bind-mount volume spec all fail
closed under `docker-ssh` before any remote mutation (closing the
`bin/dx-mount` gap Phase 2 found, and a wider adapter-level gap found
during this phase). Developed and characterised entirely against fake
`ssh`/`docker`/`nc` boundaries, the NAS never touched; design:
`docs/refactor/remote-aware-ssh.md`. **Landed 2026-09-28** after both
live gates passed: `dx-test`'s full live tier under the profile
environment, and on the NAS a disposable x86_64 guest whose SSH port was
bound to the Tailscale address only and which the controller reached
directly for every DQ8 command (the pin recorded on first contact and
kept on the second; both refusals before any remote change; removed with
nothing labelled left). See `docs/evidence/20260928/remote-aware-ssh.md`;
the gate scripts, not the branch, needed three fixes. The exit gate's
"from an external network" run is the user's own check, still to come.
**Phase 6 (QNAP lifecycle, reboot, and operational hardening,
`feat/qnap-lifecycle`) is in progress, not landed** -- items 1, 2, 4, 5,
6, 7, and 8 implemented against fakes only (design:
`docs/refactor/qnap-lifecycle.md`); items 3 and 9 (restart policy, restart
ordering) wait on the coordinating session's own maintenance window
against the real NAS. See `qnap-dxe-plan.md`'s own Phase 6 status for the
detail; no live gate has run for this phase yet.

**Target:** QNAP TVS-h674T. Its Intel Core 12th-gen CPU means **x86_64**
(confirmed by Phase 0's `uname -m`). On `main` (before this branch lands)
the guest flake still builds only `aarch64-linux`, which is why the QNAP
plan's **Phase 4** (an architecture-neutral guest) was required, not
optional; `feat/qnap-arch-neutral` (above) now evaluates both systems, not
yet landed.

- Store trust (Branch 12) is not a prerequisite for Phases 2-7: a QNAP guest
  starts with fresh volumes.
- **Branching:** one branch per QNAP phase or increment, for example
  `feat/qnap-docker-adapter`, `feat/qnap-x86_64-guest`. Each lands only when
  complete and validated.
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

## Branch 12 — `fix/store-trust` (size L; Q6 resolved; implemented, not yet landed)

`store-trust-plan.md` had two problems with no design:

- **Pin collision:** changing the Nix base-image pin while reusing `/nix` can
  meet a store path with the same name but different content.
- **Remount verification:** after a remount, the tools that verify the store
  themselves live in that store.

**Status 2026-09-27:** both resolved on the branch, not yet landed to
`main`. Design comparison in `docs/refactor/store-trust-design.md`;
implementation is `nix_verify_no_bootstrap_path_collision` (Problem 1,
Design P1-A) and `verify_remount_prerequisites` (Problem 2, Design 2-3),
plus a new authorised-scope addition, `bin/dx-reset-nix-volume` (a real,
tested, `/persist`-preserving volume-scoped recovery path both refusals
name). One branch, as originally sequenced (no shared verifier was found
between the two selected designs, but no isolation benefit to splitting
either). The August alignment waiver in `docs/release-maintenance.md` is
re-scoped (mechanism exists; awaiting live application to the primary),
and the conflicting rollback wording (a pin-change revert claiming both
"`/nix` and `/persist` are preserved" and "no volume-reusing pin change is
valid") is corrected: a rollback is a pin change like any other, so it goes
through the same collision check and, if refused, the same
`dx-reset-nix-volume` recovery.

1. ~~Characterise each problem.~~ Done — `docs/refactor/store-trust-design.md`.
2. ~~Deliver one complete, verified failure-and-recovery path per problem.~~
   Done, one branch (no shared verifier; no isolation benefit found to
   splitting).
3. ~~Close the August alignment waiver..., and correct its conflicting
   rollback wording.~~ Re-scoped (not fully closed — awaiting live
   application); rollback wording corrected.

**Remaining before this branch lands:** the dual-target gate (Apple
`dx-test` live tier; QNAP non-regression per Appendix C, no QNAP guest
exists yet so this reduces to `tests/qnap/` + Section 27 staying green) and
the live/destructive recovery exercise on `dx-test` (reset the Nix volume,
keep `/persist`, bootstrap, verify tools return and the persisted home is
intact) — see this branch's own progress file / final report for the exact
steps.

**Needed before any base-image pin change and before refactor v2.**

---

## Branch 13 — Large proposals (Q7; not started)

No branch is created until you accept a proposal. An accepted proposal is
first rewritten into small increments like the ones above. It is never merged
as a whole phase stack.

| Proposal | What it is, briefly | If accepted, starts after |
| --- | --- | --- |
| Bootstrap refactor v2 (`refactor-v2-final.md`, 436 lines) | Restructures guest bootstrap internals: identity and publication threading, explicit volume state, claim cleanup, test split. No user-visible feature. | Branch 12 |
| Declarative Nix audit (`declarative-nix-plan-a.md`, 520 lines) | Moves shell-script configuration into Home Manager: SSH/sudo config, shell setup, Herdr TOML and similar. Also proposes changing the coverage metric. | Can start any time for the small conversions |

---

## Open follow-ups (not yet branches)

- **A live tmux-resurrect restore probe in Section 6 is timing-flaky** (seen
  on Branch 16's live tier, 2026-09-27; the file was untouched by that
  branch). `test_section6_tools.sh`'s restore check probes tmux server
  start-up timing rather than a settled state. Backlog: make the probe wait
  for the observable condition (bounded poll) instead of a fixed delay, the
  way the Herdr acceptance tests do, and prove it stable across three
  consecutive live runs.
- **`dx-status` has no "keyring: not running" line** for Branch 15's failure
  policy B warning path (guest reachable, keyring not started). Not
  blocking; `bin/dx-status`'s existing host-script test fixture (a fake
  `container exec ... bash` responder) answers every exec identically
  regardless of command, so adding a distinguishable keyring probe there
  needs that fixture extended first.
- **`dx-restore --dry-run` over a very large target set is slow** (found on
  Branch 17's live gate, 2026-09-27). `dx_backup_restore_status` resolves
  each target's guest hash by scanning the batch result per target, so a
  full-mirror dry-run over 60,000 targets is effectively O(n^2) and had not
  finished after 13 minutes (correctness was proven on 1,000- and 167-file
  subsets, including a deliberate conflict). Backlog: join the local and
  guest hash lists in one pass (sort + join, or a single awk over both
  files) and prove the full 60k dry-run completes in well under a minute.
- **Section 27's fake `ssh` blocks forever when its stdin is an open
  pipe or socket** (found 2026-09-27 when a live-gate script ran
  `tests/run-tier.sh live` without `</dev/null`: the tier sat 22 minutes
  inside `test_section27_qnap_scripts.sh`, and two stale copies of the same
  test from an earlier run were found hung the same way). The standing
  rule "stdin from /dev/null" masks it. Backlog: make the Phase 0 scripts'
  fake `ssh` (and any other recording fake that may be reached with an
  inherited stdin) redirect its own stdin from /dev/null, and add a
  bounded-time test that runs Section 27 with stdin held open.
- **`--dry-run --summary` shows no "denied by the deny-list" total — decided
  2026-09-27 (coordinating session, option c): the walk prunes component-
  denied directories before the selector sees them, so any cheap counter
  would understate the true amount and mislead; the existing by-directory /
  by-reason breakdown (Branch 17) is the tool for judging the deny-list.
  Revisit only if a complete, sized count is ever needed.

## Standing rules (from the user, 2026-09-26/27; still in force)

- **The repository is public.** Nothing identifying the NAS (hostnames,
  tailnet names, IPs, usernames, pool or `/share/...` paths, key material,
  fingerprints) and no absolute home-directory paths in tracked files; the
  ssh alias `qnap-dxe` and runtime discovery stand in for them. A private
  identifier scan runs before every push; Section 1 enforces the generic
  patterns in CI. Full inventory/spike reports live outside the repository.
- **The QNAP is a production system.** Read-only by default; anything that
  creates, changes or deletes a resource there, restarts a service, or
  reboots it needs the user's explicit approval each time; reboots only in an
  agreed maintenance window. Subagents never touch it.
- **`dx-host` is the user's primary guest.** Promotions follow Appendix D
  with explicit approval and a tested backup; no subagent starts, stops,
  recreates or execs into it. `dx-test` is disposable.
- **No oversized guests.** Guests stay at the profile default (12 GB / 4 CPU
  on the Mac; the QNAP is more constrained still). Build-memory problems are
  fixed in the tooling (Branch 14), not by enlarging guests.
- **Ask before significant changes and before decisions of the kind "where
  does this live / which host / which name".** Routine, reversible
  increments of an agreed branch do not need a question; subagents never
  make such decisions -- they stop and report.
- **Coding runs in lower-power subagents** (Sonnet for judgement, Haiku for
  small fully specified edits) that keep an external crash-recovery progress
  file, follow the standing brief, and never push; the coordinating session
  reviews, rebases, scans, pushes and lands. Live gates on `dx-test` are run
  by the coordinating session when a subagent's permission classifier refuses
  a lifecycle command.
- **Keep existing patterns; share across arm64/x86_64 and runtimes wherever
  pragmatic** (one lifecycle model with runtime adapters; flake outputs
  parameterised over systems; per-architecture pins in one place).
- **Dual-target gate** (Appendix C): shared lifecycle changes pass the live
  tier on both targets once a QNAP guest exists.

## Decisions for you

Q1–Q6 and the QNAP part of Q7 are resolved (collapsed below to one line each;
the branch each gated is done). Only the rest of **Q7** (the two large
proposals other than QNAP) remains open, and it is not urgent -- it's only
needed before Branch 13.

### Q1. Ship OpenCode before fixing the "boots the previous version" bootstrap bug? — **Resolved 2026-09-26: B, fix the bug first.** Branch 9 ran before Branch 6; both are done.

### Q2. OpenCode was partly on `main`: finish it or pull it out? — **Resolved 2026-09-26: revert (Branch 2), then re-land complete (Branch 6).** Both done; OpenCode data under `/persist/home/dx` was preserved and Branch 6's migration accepted it.

### Q3. Do the two optional Herdr tests, and should the AI tool list live in one place? — **Resolved 2026-09-26: do the tests; keep the three lists**, guarded by the existing consistency contract test rather than generating them from one source. Branch 7, done.

### Q4. After a bootstrap edit, what should `dx-start-container` do if publishing the new version fails or times out? — **Resolved 2026-09-26: A, fail the start** with a clear error; a reboot or manual start with no publisher still just works either way. Branch 9 implements this; done.

### Q5. Backups: what, where, how long, how often? — **Resolved 2026-09-26:** a normal folder on the Mac inside Time Machine's backup scope (default `~/Backups/dxe-persist/`); one current mirror, no separate daily/weekly generations; on demand only, no schedule yet. Branch 10 implements this; done.

### Q6. Store trust: is "stop safely and tell me how to recover" acceptable, or must it self-repair? — **Resolved 2026-09-26: A, fail fast** before running anything untrusted, with a tested recovery procedure (for example rebuilding the `/nix` volume from scratch). Needed for Branch 12, not yet started.

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
| Bootstrap refactor v2 | **Park** until Branch 12 is done, then re-decide | Its phases assume today's code. The store-trust fix will change that code, so it would need rebaselining anyway. |
| Declarative Nix audit | **Reject as a single programme; accept its items one at a time** as small branches, alongside other work | Each conversion (for example SSH or sudo config into Home Manager) is independently useful and small. A big-bang migration conflicts with limiting work in progress. |
| QNAP runtime | **Resolved 2026-09-26: accepted** as Branch 11. Phases 0-5 landed (Phase 4 on 2026-09-28: the first native x86_64 guest bootstrapped on the QNAP; Phase 5 the same day: that guest reached directly on the NAS's Tailscale address from the controller); Phases 6-7 remain | The target is a TVS-h674T (x86_64, confirmed in Phase 0); Phase 4's per-system flake outputs and keyed Antigravity pin let the guest build natively there; Phase 5 reaches it directly on the NAS's own Tailscale address instead of a jump host. |

**Coverage metric conflict:** only relevant if you accept both v2 and the Nix
audit's item #12. That item replaces the coverage ratio with a ceiling on
uncovered lines; v2's Phase 4 measures the old ratio. Recommendation: finish
v2 on the current metric, then change the metric separately.

### Defaults assumed (tell me if any are wrong)

- **Plain `opencode`, no auto-approve alias.** The other tools do have "skip
  permissions" aliases in `home/shell.nix`. If you want `opencode --auto` for
  parity, it's a one-line change plus a test.
- **No `dx-opencode` profile or key.** Destructive tests use `dx-test`.
- **Small complete pieces merge early.** A validated, self-contained
  increment of a larger initiative can merge while the rest continues on its
  branch.
- **One working directory, one branch at a time.** No extra worktrees are
  needed, given the one-branch-at-a-time rule.
- **Clean commits.** `main` receives clean, reviewed commits. Published
  `main` history is never rewritten.

---

# Appendices (reference)

Appendix A (inventory and snapshot details) and Appendix B (historical
commits to account for) covered Step 0's one-time archival work and are
retired now that it is complete and disposed of: see
`docs/evidence/20260926/consolidation-ledger.md` and `git log`. Appendices C
and D keep their original letters because evidence records already cite them
by name.

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

Use this for every runtime-affecting branch (anything under `bin/`, `bin/lib/`
or `container/…`).

**Explicit approval required (user rule, 2026-09-26):** every promotion to
`dx-host` needs the user's explicit approval for that specific promotion,
and a tested backup of `/persist` (step 2 below) must exist *before* it
runs. No subagent promotes to `dx-host` on its own; the coordinating
session runs this appendix with the user, after they have seen the
rehearsed dry run on `dx-test`.

**Status 2026-09-27:** see "Where things stand" above. Promotions so far:
`main` `08700a8` (2026-09-26, the start-generation fix), `main` `122258c`
(2026-09-27, Branches 6-15 including OpenCode and persist-backup), and
`main` `abd4d2d` (2026-09-27, Branches 16 and 17 and Phase 1), and `main`
`6688a7c` (2026-09-27, Phases 2 and 3: a container-only recreate onto the
existing volumes so the two new create-time env tokens took effect; backup
current beforehand, `/persist` file count identical, keyring `stale` then
`live` after a cold `dx-ai`), and `main` `6bfe9f0` (2026-09-28, Branch 12,
the hardening branch and Phase 4: container-only recreate for the third
create-time env token; backup current beforehand, `/persist` file count
identical, the new store-trust checks passed on the primary's real volume,
`dx-status` now shows the keyring line), and `main` `1cceb58` (2026-09-28,
Phase 5: container-only recreate with an unchanged create argv, so the
primary guest now runs on the shared remote-aware SSH builder, the atomic
`dx-export` and the capability refusals; backup current beforehand,
`/persist` file count identical, SSH ready 56 s after the stop, keyring
`stale` then `live` after a cold `dx-ai`). `dx-host` is current; the next
promotion follows the next runtime-affecting landing.

**Before promoting:**

1. Record the current source SHA, lock, image digest, running bootstrap
   version, Home Manager and AI generations, and volumes.
2. Back up `/persist` with applications quiesced, using `dx-backup` (Branch
   10), and test the restore on a scratch location.
3. Stop Nix garbage collection from removing previous generations until the
   rollout is accepted.
4. Rehearse promotion and backout on `dx-test`.

**Promote:**

1. Re-fetch `main`. If it moved, merge it into the branch and re-run the full
   gates.
2. Fast-forward `main` and push normally. Never force-push.
3. Confirm CI is green for that exact `main` SHA.
4. Promote using the rehearsed steps.

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
