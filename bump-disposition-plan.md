# Plan: dispose of the validated lock refresh, then close the last gap

## Status

Open. Written 2026-08-30 and revised twice the same day against independent
reviews. The first review found two execution blockers; the second
independent review raised twelve findings, F1–F12. Every finding was
verified against the tree at `3ce623b` before incorporation. Two of the second
review's recommendations were corrected rather than adopted verbatim, and both
corrections are visible below: F3 named an "aarch64-linux Nix runner" when this
host has no Nix at all and the repository documents an in-guest path, and it
switched lock-file flags without reconciling against the repository's existing
spelling.

The immediate problem is not a defect. A **validated but uncommitted** lock
refresh is sitting in a linked worktree while the canary runs it and the primary
does not. That state decays: in two weeks nobody can tell whether the branch was
validated or abandoned, and the validation cost real machine time.

## Execution record — fill before the window opens

These fields are decided *before* the maintenance window, not chosen during it.
An unfilled field is a reason not to start.

| Field | Value |
| --- | --- |
| Decision maker | _unfilled_ |
| Decision date | _unfilled_ |
| Maintenance window | _unfilled_ (one window covering land, canary, primary adoption) |
| Evidence destination | _unfilled_ — a directory **outside both worktrees** |
| Previous `main` SHA | `3ce623b` (confirm at freeze time) |
| Previous lock SHA-256 | `34f29312a2da3447515d68c3c470fda7c63e9a2497c9fc3d1769c4f5f92b8b9b` |
| Raw lock commit SHA | _unfilled_ |
| Candidate tip SHA | _unfilled_ |
| Candidate lock SHA-256 | `ee4d64dcb658b5e01b1e916965fcc3900a33b3dfaa20da30a0b8995fd4a4b6f9` (reassert after rebase) |
| Landing method | `git merge --ff-only`, asserting candidate tip SHA == resulting `main` SHA |
| Rollback commit set | _unfilled_ — ordered, covering lock, fixes, and waiver |
| Follow-up artifacts | `post-remount-trust-root-plan.md`, `image-pin-collision-plan.md` |

**Candidate** has exactly one meaning in this document: the branch tip carrying
the *entire* intended stack — the preservation/lock commit, the waiver, and any
compatibility fix. Not the raw lock commit, which is recorded separately for
auditability. Any new commit invalidates the freeze and returns to the freeze
step.

The evidence destination must be outside the candidate worktree.
`tests/release-check.sh` asserts nothing but a clean worktree, so a log file
written next to the candidate fails the gate and changes the commit the evidence
claims to identify.

If integration changes the tree or the SHA by any route other than a
fast-forward, validate the resulting `main` commit again before touching the
primary.

## Step 0 — Preserve the change before touching anything

**The linked worktree is currently the sole holder of the refresh.**
`bump/lock-refresh` points at `aa4ccac` and contains no lock change; the refresh
exists only as an unstaged modification in `/Users/damien/Development/dxe-bump`.
Consequences, both verified:

- `git rebase main` refuses a dirty worktree, so the first draft's
  rebase-then-commit order cannot run;
- `git worktree remove` refuses while dirty, and forcing it would **discard the
  only copy**.

So, before any rebase, cleanup, or decision:

1. Assert the worktree diff touches exactly
   `container/aarch64-darwin-apple-container-dx-nixos-26.05/flake.lock` and that
   `git diff --check` is clean.
2. Commit it on `bump/lock-refresh` as a clearly labelled preservation commit.
   Prefer a commit over a stash: the whole point is durable, discoverable state.
3. Only then rebase onto current `main` (the branch predates `c985d0c`,
   `21e48ca`, and `d396a0a`).

The waiver and every compatibility fix land on the branch **before** final
validation, as separate revertible commits. A waiver added after the gates went
green describes a tree that was never validated.

**Parked** means: reachable from a named ref, worktree clean, reason and revisit
trigger recorded. Only then may the linked worktree be removed.

## Step 1 — Land the lock refresh (recommended)

A `flake.lock`-only change moving the stable inputs on their existing 26.05
branches. Produced by the documented recipe, run in the guest:

```
nix flake update nixpkgs nixvim home-manager \
    --flake container/aarch64-darwin-apple-container-dx-nixos-26.05
```

Direct inputs:

| input | from | to |
| --- | --- | --- |
| `nixpkgs` | `95ca1e20` (2026-06-30) | `d57af924` (2026-08-27) |
| `home-manager` | `868d0a69` | `65258d5c` |
| `nixvim` | `667c8471` | `e2c3f9f3` |

Expected transitive change: `flake-parts` `f7c1a2d3…` → `427bf4bd…`, via
`nixvim`. Unchanged, and required to stay unchanged: `nixpkgs-unstable` (so the
optional AI set does not move during a stable refresh) and `systems`.

**Any lock node changing outside this inventory is an abort condition.** That is
what makes "stable refresh only" mechanically reviewable rather than a claim.

Keep the targeted `nix flake update` form. It is idiomatic for current Nix and
it is what prevents the independent unstable track from moving; no flake
restructuring is warranted during a maintenance change.

### Evidence, and what it is not

Supporting evidence from the pre-rebase tree: a canary suite run at **1018
passed, 1 failed**, the single failure since diagnosed as a test depending on
the developer's gitignored `dx_key` and fixed in `c985d0c`; a volume-reusing
recreate that imported **881 paths in 8s** and booted first time; and a day of
healthy running on `dx-test`.

That is a *diagnosed* result on a *dirty* tree at `aa4ccac`, not a green result
on the candidate. `docs/release-maintenance.md` requires a clean worktree and a
committed bump for canary validation. Note also that
`tests/run-tier.sh unit/static` does **not** run section 9 — section 9 belongs
to `host-contract` — so a unit/static gate would not rerun the very test that
failed.

Continuous canary health is supporting evidence, not the gate. Promotion
requires the four gate groups below, run against one frozen candidate.

### Gate group A — mechanical lock audit

Prose naming four changed nodes is not a complete lock record, and checking node
names alone would miss a changed follow edge, `original` reference, added node,
or lock-format change. After rebase, compare the candidate lock to its new
`main` base and require **all** of:

- the changed file set is exactly the one lock file;
- the lock node set and top-level lock version are unchanged;
- root and transitive input edges and every `original` object are unchanged;
- the only changed JSON paths are `locked.lastModified`, `locked.narHash`, and
  `locked.rev`, on the four inventoried nodes;
- the complete `nixpkgs-unstable` and `systems` node objects are byte-for-byte
  unchanged;
- the evidence records full revisions and `narHash` values, not short SHAs.

Anything outside that allowlist is the abort condition stated above.

### Gate group B — repository gates

- `tests/release-check.sh` on the clean candidate;
- `bash -n` across every shell entrypoint and library, plus ShellCheck at
  `--severity=warning` **pinned to 0.10.0** — 0.11.0 aborts with
  `Non-exhaustive patterns in checkCmd` on the import-purity construct that
  `tests/test_refactor_contracts.sh` depends on;
- `tests/run-tier.sh unit/static`;
- `tests/run-tier.sh host-contract` — explicitly covering the `c985d0c` fix in
  section 9;
- `tests/run-bash32-tests.sh`;
- `tests/run-coverage-linux.sh` **explicitly**. Section 25's macOS skip is not a
  substitute for the coverage gate, and `run-tier.sh unit/static` says so in its
  own NOTE.

### Gate group C — Nix evaluation and builds

Nothing in group B proves the flake evaluates. This host has no `nix`, so
`tests/test_section5_nix.sh` silently skips its `nix flake check`; the coverage
runner exercises shell behavior, not the Nix job; and the macOS live suite skips
the Linux profile-build section. Meanwhile the candidate changes the dependency
graph for every stable output. `docs/refactor/validation-matrix.md` lists Nix
**evaluation** and aarch64-linux **builds** as distinct required tiers, and the
release runbook records build-environment conflicts that escaped
`nix flake check` — so evaluation and real builds are complementary, not
alternatives.

Run them **in the canary guest**, not on the host, and stage the source rather
than copying the working tree — the repository root holds SSH private keys that
have no reason to enter a guest. The path is documented in
`docs/refactor/validation-matrix.md`, "Running lint and Nix evaluation without a
host toolchain": `./bin/dx-put <staged-source-dir> /persist/inbox/`, then

```sh
flake=./container/aarch64-darwin-apple-container-dx-nixos-26.05

nix flake check --no-build --no-update-lock-file "$flake"

nix build --no-link --no-update-lock-file \
  "$flake#packages.aarch64-linux.default" \
  "$flake#packages.aarch64-linux.bootstrap-essentials" \
  "$flake#packages.aarch64-linux.ai-tools" \
  "$flake#homeConfigurations.dx.activationPackage"
```

The flag is deliberately not the repository's usual one. Checked-in commands use
`--no-write-lock-file`, which declines to *persist* a regenerated lock;
`--no-update-lock-file` refuses any lock update at all and therefore fails
rather than drifting a frozen candidate. Use the stricter flag here, and read
the difference as intentional rather than as a typo to be normalised.
`--no-link` keeps `result*` symlinks out of the clean worktree.

Running these in the canary rather than the primary keeps the primary's store
untouched until promotion. After both commands, reassert the candidate lock
SHA-256 and a clean worktree.

### Gate group D — two canary states

The primary adoption path reuses `/nix` and `/persist`, so a volume-preserving
recreate is the closest analogue and runs first. But a lock refresh also changes
the `bootstrap-essentials` and Home Manager closures a brand-new guest builds
from cold, and a mature canary can pass while a first seed or first activation
is broken. Both states are **required gates**: the tip does not land unless both
are green.

Reused-volume path first:

```sh
./bin/dx-profile dx-test ./bin/dx-recreate
./bin/dx-profile dx-test tests/run_all_tests.sh
```

Then, after the reused-volume logs are preserved, the fresh-volume path:

```sh
DX_TEST_DESTRUCTIVE=1 \
  ./bin/dx-profile dx-test tests/run-tier.sh destructive
./bin/dx-profile dx-test tests/run_all_tests.sh
```

Order is not arbitrary and the cost is not small. The destructive tier runs
`dx-factory-reset --force`, which removes all three volumes **and the SSH
keypair**, then rebuilds; it is the long pole of the window, and it destroys the
warm store the reused-volume path depends on. Run it second, never first.

Before enabling it, print and verify the resolved canary container, image, all
three volumes, key, context directory, and port — the tier's own guard only
refuses the default container name. If the existing `dx-test` state must be
retained for other reasons, create a second explicitly isolated profile rather
than skipping the fresh path.

A fresh-volume failure alongside a green reused-volume run is a do-not-land
signal and a separately diagnosable defect. It is not, by itself, a reason to
roll back a primary that has not yet been touched.

### Proving the running generation

`./bin/dx-profile dx-test tests/run_all_tests.sh` does not by itself recreate or
restart the canary. Section 11 accepts an existing container, and
`dx-start-container` deliberately skips `container start` when the container is
already running, then reports generation drift as a diagnostic whose failures
are swallowed on purpose — it "must never be the reason a start fails". A
bootstrap sync can therefore publish the candidate while the guest keeps
executing the generation it selected at its earlier boot, and the suite comes
back green about code that never ran.

Hashing `/guest-bootstrap/flake.lock` does not close that gap: it is a
compatibility symlink resolving through `current`, so it proves what was
*published*, not what PID 1 selected. The authority is the execution lease.

After every boot of the canary and of the primary, require **all three** facts
together:

1. the PID-1 lease names the running generation. Leases live in
   `/guest-bootstrap/.locks/leases` as `<generation>.<pid>`; PID 1 is the
   launcher that execs that generation's `bootstrap.sh`, so its lease alone
   names running code. Reuse `dx_bootstrap_lease_generation`
   (`bin/lib/dx-container.sh:131`) rather than re-parsing the listing;
2. that generation equals `readlink /guest-bootstrap/current` with the
   `generations/` prefix stripped;
3. `sha256sum /guest-bootstrap/generations/<gen>/flake.lock` equals the recorded
   candidate lock hash.

A missing lease, a drift warning, or a hash mismatch is a **hard failure**, not
a diagnostic. Repeat the proof after any compatibility fix or other candidate
change, and again on the primary after `dx-recreate`.

### The policy deviation, stated precisely

The alignment rule matches the **major.minor** of the locked release's default
Nix, "taking the newest patch tag within that minor". The locked default is now
2.34.8 against a pinned 2.34.7. **Major.minor still matches** — the exception is
to the newest-patch clause only, which is a narrower deviation than the first
draft implied.

It cannot be satisfied: moving the pin requires the destroy-and-rebuild-with-
salvage procedure, because of the store-path collision recorded in the same
document. The combination is empirically fine — the canary runs the bumped lock
on the 2.34.7 image — but it is a knowing exception.

A commit message is not durable enough. It leaves the checked-in runbook
asserting a rule the repository knowingly does not satisfy, and gives the next
refresh nowhere to discover whether the exception still holds. The Containerfile
test pins the expected literal digest line; it does not prove the pin follows the
locked `nix.version`, so it stays green throughout the mismatch.

If the refresh is landed, add a dated waiver adjacent to the alignment policy.
Scope it by the **complete pinned reference**, not by version string — the policy
itself pins `tag@sha256:manifest-list-digest` and requires re-querying the digest
immediately before any change, never copying a recorded one:

```
nixos/nix:2.34.7@sha256:bf1d938835ab96312f098fa6c2e9cab367728e0aad0646ee3e02a787c80d8fb8
```

Immediately before finalizing the waiver:

- re-evaluate the candidate's locked `nixpkgs#nix.version` without updating its
  lock — the in-guest command is already documented in
  `docs/release-maintenance.md`;
- re-query which `nixos/nix:2.34.x` patch tag is newest, and its current
  multi-platform digest, and confirm a `linux/arm64` manifest;
- record: the complete pinned reference above, the evaluated locked Nix version,
  the current newest tag, the candidate commit and lock hash, the reason,
  residual risk and why accepted, the decision maker, and an expiry trigger —
  the next image-pin maintenance event or the next stable-lock refresh,
  whichever comes first.

The waiver lands on the branch before final validation. Keep it a separate
documentation commit if a strictly lock-only functional commit matters. If no
waiver is acceptable, take the park path explicitly.

### How TDD applies here

A raw dependency lock refresh is not naturally Red → Green → Refactor. The
intended behavior is unchanged, so fabricating a failing expectation for a new
revision would test implementation data rather than behavior. Describe it
honestly as a **characterized dependency update**: cite the green old-lock
baseline, make the mechanical lock change, then prove the same behavior against
the new lock.

TDD becomes mandatory the moment validation exposes a compatibility defect or a
missing guard. For each one:

1. **Red.** Preserve the original failing command and output. If the existing
   gate is not a focused behavioral regression, add the smallest behavior test
   that fails on the candidate *for the diagnosed reason*, and demonstrate that
   failure.
2. **Green.** Make the minimum production or declarative Nix change that
   restores the intended behavior, in a commit separate from the raw lock.
3. **Refactor.** Remove duplication or improve names only while the focused test
   stays green. No opportunistic flake restructuring.
4. Run the focused test after every step, then return to the freeze step: the
   candidate SHA changed, so every candidate gate is rerun and the running-
   generation proof is repeated.

Tests must not be weakened to accept behavior a newer dependency introduced. An
intentional behavior change requires an explicit decision and a test stating the
new contract. This is `constitution.md` applied to this change, not an exception
to it.

### Promotion and rollback

Not "when convenient" — that dissolves the urgency this plan opens with. The
decision date, window, and landing method belong in the execution record above.

**Preflight, before any canary-destructive or primary-changing group.** Run the
repository's existing "Clean-configuration precondition" from
`docs/release-maintenance.md` rather than a parallel checklist:

- `.env` **absent, or reviewed line by line**. It is sourced as shell code by
  every child script, *after* the parent has exported its own values, so any
  line in it executes and a `DX_*` line silently re-overrides a profile's
  exports. It is currently absent — assert that, do not assume it.
- Inherited `DX_*` environment inventoried: exported values survive into every
  resolution and are treated as user-supplied.

Then, additionally:

- print the intended worktree's absolute path and HEAD, and hash the source lock
  from that resolved context directory — running the right command from the
  wrong worktree syncs the wrong source;
- print the resolved `DX_CONTAINER_NAME`, `DX_IMAGE`, all three volumes,
  `DX_SSH_KEY`, `DX_CONTEXT_DIR`, and port. `DX_CONTEXT_DIR` matters most:
  `tests/profiles/dx-test.env` does not set it, so it falls through to the
  project-root default;
- assert every canary resource is non-default and namespaced;
- assert the primary group resolves to exactly the approved primary resources;
- confirm the primary's image is the official-base build. `dx-start-container`
  carries a temporary old-base guard that aborts on `/bin/bash` presence, and its
  documented remedy is the destructive changeover this plan forbids escalating
  to. As of 2026-08-30 `dx-host` and `dx-test` share image digest
  `bd3097c1c59b`, so the guard will not fire — verify, do not assume;
- stop on any mismatch rather than correcting it mid-procedure.

Before touching the primary: assert the candidate gates are green and that the
canary proved its **running** generation carries the committed candidate lock.

After `dx-recreate` on the primary: require successful bootstrap, the three-fact
running-generation proof against the committed lock hash, `dx-status`, and the
agreed live checks.

`copying N paths` with N > 0 is a **diagnostic, not a success criterion**. The
count is contextual — observed at 2, 13, and 881 on different boots — and the
failed pin-bump attempt printed `copying 13 paths` immediately before erroring.
Absence of `did not materialise required bootstrap paths` is likewise a
diagnostic.

**On failure, roll back the complete landed stack**, not the lock commit alone:
the raw lock, every compatibility fix, and the waiver's closure or removal. A
partial revert can leave fixes written for packages that are no longer locked,
or leave the runbook recording an exception that no longer exists. Keep each
compatibility fix independently revertible, but name the whole rollback range in
the maintenance record.

Order: preserve logs, revert source first, then `dx-recreate` from the
rolled-back clean `main` with retained volumes. Do not garbage-collect during
the acceptance window. Prove recovery with the same three-fact check against the
*previous* lock hash, then rerun the primary health checks before declaring
recovery. Retain rollback evidence until primary acceptance.

**A failed lock-only adoption must not be escalated into a factory reset or
salvage operation without a new decision.**

## Step 2 — Clean up, only after convergence

Make `dx-test` and the primary match `main`. Then remove the clean linked
worktree, and delete or retain `bump/lock-refresh` per the recorded disposition.

## Execution sequence

1. **Preserve.** Verify the one-file diff and `git diff --check`, then commit on
   `bump/lock-refresh` before any rebase or cleanup.
2. **Fill the execution record.** Every field above, including the evidence
   destination outside both worktrees.
3. **Rebase** onto the selected current `main`; run gate group A; require a clean
   worktree.
4. **Decide land or park.** Re-evaluate alignment and add the digest-qualified
   waiver to the branch, or park it with owner and revisit trigger and stop after
   cleanup.
5. **Freeze the candidate.** Record candidate tip SHA, raw lock commit SHA, and
   candidate lock SHA-256 in the external evidence record.
6. **Gate group B** — repository gates.
7. **Gate group C** — Nix evaluation and the four builds, in the canary guest
   from staged source. Reassert lock hash and clean worktree.
8. **Gate group D, reused-volume.** Recreate, prove the running generation, run
   the full profile-aware suite.
9. **Gate group D, fresh-volume.** Preserve logs, run the guarded destructive
   tier on the isolated profile, prove the running generation again, rerun the
   full suite.
10. **Any incompatibility → Red → Green → Refactor**, each fix its own commit.
    Any new commit returns to step 5.
11. **Final freeze and land.** All evidence names one tip; `git diff --check`
    clean; worktree clean; lock hash unchanged. Fast-forward `main` and assert
    candidate tip SHA == `main` SHA and lock-hash equality. If that is
    impossible, validate the resulting `main` commit again.
12. **Promote and converge.** Primary preflight from clean `main`, `dx-recreate`,
    three-fact proof, health checks; accept or roll back the full stack. Then
    make `main`, `dx-test`, and the primary agree, remove only the clean linked
    worktree, and link the two follow-up artifacts. Do not begin Step 3 in this
    window.

## Step 3 — Post-remount trust root (separate design task)

Previously described here as `ensure_essentials_valid` being "dead code". That
was wrong, and the correction matters. It executes on every boot and can detect
or repair damage in closure members consumed later, while its own prerequisites
remain usable. The real defect is narrower and better named: a **recovery blind
spot for the post-remount trust root**.

`nix_restore_image_default_profile` runs after the remount and invokes
`readlink`, `mkdir`, `mktemp`, `rm`, `ln`, `chown`, and `mv` before
`ensure_essentials_valid` is reached. The verifier itself needs working shell
utilities, `run_as_dx`, and `nix`. So it cannot recover when the corrupted path
*is* one of its own prerequisites, or one of the earlier restore's.

This is not an executable task, and it is not tracked by prose in a plan that is
about to be closed. It is tracked in **`post-remount-trust-root-plan.md`**,
which carries the invariant, the per-failure outcome table, the designs to
compare, the testing-layer split, and the implementation constraints. Nothing in
it is implemented on the lock-refresh commit stack.

Third priority stands: two newer defences sit in front of it, and it has never
been reached.

## Deferred — volume-reusing image-pin bump design

Not "collision quarantine": that named a strategy before one was chosen.
Skipping a same-name, different-content store path may violate the very content
identity the guest is meant to trust.

Tracked in **`image-pin-collision-plan.md`**, which records the observed
collision, the required safety properties rather than a design, and the revisit
trigger: no later than the next required image-pin change. The alignment waiver
above expires into that item, so it cannot stay open-ended.

## Definition of done

- the refresh is committed on `main` or preserved on a named parked ref, and no
  dirty worktree is its sole holder;
- the complete lock delta passes the gate group A allowlist, and the full
  revisions, `narHash` values, and immutable lock hash are recorded;
- the alignment policy is satisfied, or has a visible dated, owned, bounded
  waiver scoped by the complete `tag@sha256:digest` reference;
- **one immutable tip** carries green syntax, ShellCheck, `unit/static`,
  `host-contract`, Bash 3.2, coverage, Nix evaluation, and the four
  output-build gates;
- **both** the reused-volume and fresh-volume canary paths are green on that
  tip, including the section-9 case that previously failed;
- canary and primary each proved their **running** bootstrap generation is
  current and carries the committed lock — not merely that the published link
  hashes correctly;
- any compatibility change was developed Red → Green → Refactor with a focused
  behavioral regression in its own commit;
- `main`, `dx-test`, and the accepted primary share one committed lock hash and
  the primary health gate is green;
- rollback covers the full landed stack and the waiver lifecycle, with evidence
  retained until primary acceptance;
- `post-remount-trust-root-plan.md` and `image-pin-collision-plan.md` exist, are
  linked from here, and carry testable acceptance criteria and revisit triggers —
  neither is treated as closed by this disposition.
