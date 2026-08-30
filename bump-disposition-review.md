# Review of `bump-disposition-plan.md`

## Overall assessment

The plan makes the right disposition call: either promote the tested stable-lock
refresh promptly or preserve and park it deliberately. It also correctly keeps
the Nix image-pin problem separate and resists turning a small promotion task
into an importer redesign.

It is not yet safe to use as an execution runbook. Two issues block execution as
written:

1. the only copy of the lock refresh is an uncommitted change, so the proposed
   `rebase`-then-`commit` order cannot run and the cleanup step could discard the
   work; and
2. the validation belongs to a dirty, pre-rebase tree and ended with one failed
   test. The named fix is in a test tier that the plan's final gate does not run.

The recommendation should remain **land the refresh**, but only after the plan
is amended to preserve the change first, record a durable and time-bounded image
alignment waiver, validate the exact rebased commit, and define promotion and
rollback checks. Step 3 should become a separate design task with a regression
case and acceptance criteria; it is currently a diagnosis, not an executable
plan.

## State independently observed during this review

The following was checked read-only on 2026-08-30:

- `main` was clean at `d396a0a`; `bump/lock-refresh` pointed at `aa4ccac`, its
  merge base with `main`.
- `/Users/damien/Development/dxe-bump` had exactly one tracked modification:
  `container/aarch64-darwin-apple-container-dx-nixos-26.05/flake.lock`.
- The modified lock's SHA-256 was
  `ee4d64dcb658b5e01b1e916965fcc3900a33b3dfaa20da30a0b8995fd4a4b6f9`.
  The running `dx-test` guest had that exact lock. The checked-in lock and the
  running primary both had
  `34f29312a2da3447515d68c3c470fda7c63e9a2497c9fc3d1769c4f5f92b8b9b`.
- Both `dx-test` and `dx-host` were running, and their configured status checks
  reported their guest tools and persistent volumes. This supports the plan's
  current-health statement, but it is not a substitute for a green candidate
  test run.
- The lock diff changes four nodes, not three: the direct inputs `nixpkgs`,
  `home-manager`, and `nixvim`, plus transitive input `flake-parts`.
  `nixpkgs-unstable` and `systems` are unchanged.
- Since `aa4ccac`, `main` has changed the section-9 host tests in `c985d0c`, the
  pin-bump documentation and its section-10 assertions in `21e48ca`, and added
  the disposition plan in `d396a0a`.

No promotion, rebase, worktree cleanup, or destructive guest operation was
performed as part of this review.

## What the plan does well

- It identifies the operational risk precisely: validated-but-uncommitted state
  becomes unauditable quickly.
- It states a recommendation and an alternative instead of leaving an implicit
  decision.
- It preserves the independent `nixpkgs-unstable` track.
- It distinguishes a lock refresh from an image-pin change and correctly avoids
  prescribing `dx-recreate` for the latter.
- It uses the isolated canary before the primary and records useful operational
  evidence, including the large importer exercise.
- It recognizes that the post-remount toolchain problem is a trust/bootstrap
  design question rather than a simple call reorder.
- Deferring the collision problem is good scope control.

## Findings and recommendations

### F1 — Blocker: the proposed Git sequence cannot preserve the current work

The plan says to rebase and then commit. The branch itself contains no lock
refresh; the refresh exists only as an unstaged modification in its linked
worktree. A normal `git rebase main` refuses a dirty worktree. Likewise,
`git worktree remove` refuses to remove it while dirty, while forcing removal
would discard the only copy of the refresh.

The alternative to "park the branch" has the same problem: the branch ref does
not currently preserve the change.

Recommendation:

1. First assert that the worktree diff contains only the intended lock file and
   that `git diff --check` is clean.
2. Commit the lock on `bump/lock-refresh` before rebasing. A clearly labelled
   preservation commit is preferable to a stash because the plan's purpose is
   to make the state durable and discoverable.
3. Rebase that commit onto the current `main`, resolve any lock conflict, and
   recheck the complete node delta.
4. Define **parked** to mean: the refresh is reachable from a named ref, the
   worktree is clean, the reason and revisit trigger are recorded, and only then
   may the linked worktree be removed.

The commit message can be amended during or after the rebase if the final
wording depends on the waiver decision.

### F2 — Blocker: the evidence is not tied to the candidate that would be promoted

The canary is running the intended lock, which is useful evidence, but it is
running an uncommitted tree based on `aa4ccac`. The maintenance runbook explicitly
requires a clean worktree and a committed bump for canary validation
(`docs/release-maintenance.md`, lines 227–228).

The recorded result, "1018 passed, 1 failure", is a diagnosed result rather than
a green result. The fix in `c985d0c` changes `tests/test_section9_host_scripts.sh`.
However, `tests/run-tier.sh unit/static` does not run section 9; section 9 belongs
to the `host-contract` tier. Therefore the verification paragraph does not even
require a rerun of the test that failed.

Rebasing also changes the candidate. The code under test is mostly unaffected,
but promotion evidence should identify one immutable commit rather than rely on
that inference.

Recommendation: after committing and rebasing, validate the exact candidate and
record all of the following in a small evidence table:

- candidate commit SHA and `flake.lock` SHA-256;
- exact command, date, target profile, exit status, and pass/fail count;
- `tests/release-check.sh` on the clean candidate;
- `tests/run-tier.sh unit/static`;
- `tests/run-tier.sh host-contract`, specifically covering the `c985d0c` fix;
- the coverage gate if the plan retains it as a promotion requirement;
- lock-preserving Nix evaluation and the relevant aarch64-linux builds; and
- `./bin/dx-profile dx-test tests/run_all_tests.sh`, ending in an unqualified
  all-green result on that commit.

Continuous canary health should remain supporting evidence, not the release
gate.

### F3 — High: a commit-message-only alignment waiver is not durable enough

The plan correctly notices a policy deviation, but it slightly overstates it.
The documented rule is to match the locked default Nix's **major.minor** and use
the newest image patch in that minor. Versions 2.34.8 and 2.34.7 still match on
major.minor; the proposed exception is to the newest-patch part of the policy.
That distinction should be stated accurately.

Recording the exception only in a commit message leaves the checked-in runbook
asserting a rule the repository knowingly does not satisfy. It also gives the
next lock refresh no obvious place to discover whether the exception is still
valid. The Containerfile test enforces the currently expected literal pin; it
does not dynamically prove that the pin follows the locked `nix.version`, so it
can stay green throughout this policy mismatch.

Recommendation: if the refresh is landed, add a dated temporary waiver adjacent
to the alignment policy or in a linked decision record. Record:

- exact scope: stable lock at the promoted SHA with image 2.34.7;
- reason: the proven 2.34.7-to-2.34.8 store-path collision makes volume reuse
  invalid, while a pin change requires the documented salvage procedure;
- evidence: exact canary commit/lock hash and green live run;
- residual risk and why it is accepted;
- owner/decision maker; and
- expiry or revisit trigger, such as the next image-pin maintenance event or
  the next stable-lock refresh, whichever occurs first.

Keep that decision in a separate documentation commit if retaining a strictly
lock-only functional commit matters. If no such waiver is acceptable, choose
the plan's park alternative explicitly.

### F4 — Medium: the lock-delta inventory is incomplete

The table lists the three intended direct inputs, but the actual lock diff also
moves `flake-parts` from `f7c1a2d3…` to `427bf4bd…` through `nixvim`. That may be
an expected transitive update, but reviewers should not have to discover it by
diffing the file after reading a table that appears exhaustive.

Recommendation:

- label the current three rows **direct inputs**;
- add `flake-parts` as an expected transitive change;
- state explicitly that `nixpkgs-unstable` and `systems` are unchanged;
- record the exact targeted `nix flake update` command used; and
- make an unexpected changed lock node an abort condition.

This also makes the claim "stable refresh only" mechanically reviewable.

### F5 — High: promotion success and rollback are underspecified

"Adopt ... when convenient" weakens the urgency established in the opening.
The plan also does not say how the commit reaches `main`, what exact revision the
primary must run, or what happens if primary activation fails.

`copying N paths` with `N > 0` and absence of one diagnostic are useful importer
observations, but they do not prove that the expected lock is active or that the
guest is healthy. The count is contextual and may change as the persistent store
changes; it should not be the semantic success criterion.

Recommendation:

- choose a decision deadline and one maintenance window for land, canary, and
  primary adoption;
- name the landing method and resulting `main` commit;
- before touching the primary, assert that canary `/guest-bootstrap/flake.lock`
  hashes to the committed candidate and that the candidate gates are green;
- after `dx-recreate`, require successful bootstrap, expected committed lock
  hash in the primary, `dx-status`, and the chosen primary smoke/live checks;
- retain importer count and error-string checks as diagnostics; and
- document the abort and recovery path. For this lock-only change that will
  normally mean preserving logs, reverting the lock commit, and recreating with
  the unchanged image and retained volumes, but the exact commands and success
  checks should be confirmed before promotion.

The plan should explicitly forbid escalating a failed lock-only adoption into a
factory reset or salvage operation without a new decision.

### F6 — Medium: Step 3 identifies a real trust cycle but calls it "dead code"

The ordering concern is real. `nix_restore_image_default_profile` runs after the
remount and invokes `readlink`, `mkdir`, `mktemp`, `rm`, `ln`, `chown`, and `mv`
before `ensure_essentials_valid` runs. The verifier in turn needs working shell
utilities, `run_as_dx`, and `nix`. It therefore cannot recover when one of its
own prerequisites, or a prerequisite of the earlier restore, is the corrupted
path.

That does not make `ensure_essentials_valid` dead code. It still executes on
healthy boots and can detect or repair damage in later-consumed closure members
when its foundational utilities and Nix remain usable. The precise defect is a
**recovery blind spot for the post-remount trust root**.

Step 3 currently has no selected design, regression case, deliverables, or
definition of done. The global verification paragraph cannot turn it into an
executable task.

Recommendation: split Step 3 into a separate design-and-implementation plan:

1. State the invariant: after remount, no binary from the persistent store may
   be trusted merely to prove that same trust root sound.
2. Define the failure cases to support: missing/corrupt core utilities, missing
   Nix, corrupt later tools, offline repair, and a healthy reused volume.
3. Compare explicit designs, for example pre-remount verification of the target
   store with image-resident tooling, an absolute captured image toolchain used
   as the verifier, or deliberate fail-fast recovery when independent repair is
   impossible. Do not select one solely by moving the call.
4. Add a failing regression that demonstrates a prerequisite disappearing
   between remount and verification. Existing source-shape assertions are not
   enough.
5. Preserve the invariant that the image-store identity marker is published
   only after successful post-remount validation.
6. Require unit/coverage gates plus isolated live and destructive recovery
   exercises appropriate to a bootstrap-path change.

The existing priority statement is reasonable once the issue is described this
way.

### F7 — Medium: the deferred item needs a trigger and should not preselect a solution

The deferral is sensible, but "collision quarantine" and "quarantine or skip"
make an unproven strategy sound like the decided design. Skipping a same-name,
different-content store path may violate the very content identity the guest is
meant to trust. The deferred work also has no owner, date, or trigger, even
though the proposed alignment waiver depends on eventually resolving or
scheduling the pin bump.

Recommendation: rename it to **volume-reusing image-pin bump design** and record
only the required safety properties: no mismatched content may be executed,
failure must remain pre-remount and recoverable, existing volumes must not be
silently mutated into an ambiguous state, and the fresh-volume path must remain
valid. Set a revisit trigger no later than the next required image-pin change.

## Recommended revised sequence

1. **Decide land or park by a stated date.** Landing remains recommended.
2. **Preserve the dirty lock immediately.** Verify the one-file diff and commit
   it on the named branch before any rebase or worktree cleanup.
3. **Record the policy decision.** Add a durable temporary waiver, or select the
   park path. Do not rely on commit prose alone.
4. **Rebase onto current `main`.** Re-audit all changed lock nodes and confirm
   the candidate worktree is clean.
5. **Validate that immutable candidate.** Run the unit/static, host-contract,
   Nix evaluation/build, coverage-as-applicable, and full isolated live gates;
   record SHA-bound results.
6. **Land through the named integration method.** Confirm the resulting `main`
   commit and lock hash.
7. **Promote to the primary in a bounded window.** Check the exact lock hash,
   bootstrap and guest health, and the agreed primary smoke/live gate. Use the
   documented rollback on failure.
8. **Clean up only after convergence.** Make `dx-test` and the primary match
   `main`; then remove the clean linked worktree and delete or retain the branch
   according to the recorded disposition.
9. **Open Step 3 separately.** Give the bootstrap trust-root work its own design
   decision, reproducer, implementation, and recovery validation.

## Suggested definition of done

The disposition is complete when all of these are true:

- the refresh is either committed on `main` or preserved on a named parked ref;
- no dirty linked worktree is the sole holder of the lock change;
- the alignment policy is either satisfied or has a visible, dated, bounded
  waiver;
- the complete direct and transitive lock delta is recorded;
- the exact promoted commit has an all-green canary result, including the
  section-9 regression that previously failed;
- for the land path, `main`, `dx-test`, and the primary have the same committed
  lock hash and the primary health gate is green;
- rollback evidence and logs are retained until primary acceptance; and
- the post-remount trust-root issue is tracked separately with testable
  acceptance criteria rather than being considered completed by this lock
  disposition.
