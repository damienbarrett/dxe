# Plan: dispose of the validated lock refresh, then close the last gap

## Status

Open. Written 2026-08-30 and revised the same day against an independent review
(`bump-disposition-review.md`), which found two execution blockers in the first
draft. Both are fixed below; every finding was verified before incorporation.

The immediate problem is not a defect. A **validated but uncommitted** lock
refresh is sitting in a linked worktree while the canary runs it and the primary
does not. That state decays: in two weeks nobody can tell whether the branch was
validated or abandoned, and the validation cost real machine time.

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

Promotion therefore requires validating the exact rebased commit and recording,
SHA-bound:

- candidate commit SHA and `flake.lock` SHA-256;
- `tests/release-check.sh` on the clean candidate;
- `tests/run-tier.sh unit/static`;
- `tests/run-tier.sh host-contract` — explicitly covering the `c985d0c` fix;
- the coverage gate;
- `./bin/dx-profile dx-test tests/run_all_tests.sh`, ending unqualified
  all-green on that commit.

Continuous canary health is supporting evidence, not the gate.

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
test pins the expected literal digest; it does not prove the pin follows the
locked `nix.version`, so it stays green throughout the mismatch.

If the refresh is landed, add a dated waiver adjacent to the alignment policy
recording: exact scope (stable lock at the promoted SHA with image 2.34.7);
reason; evidence (candidate commit and lock hash, green live run); residual risk
and why accepted; decision maker; and an expiry trigger — the next image-pin
maintenance event or the next stable-lock refresh, whichever comes first. Keep
it a separate documentation commit if a strictly lock-only functional commit
matters. If no waiver is acceptable, take the park path explicitly.

### Promotion and rollback

Not "when convenient" — that dissolves the urgency this plan opens with. Choose
a decision date and one maintenance window covering land, canary, and primary
adoption. Name the landing method and the resulting `main` commit.

Before touching the primary: assert the canary's `/guest-bootstrap/flake.lock`
hashes to the committed candidate, and that the candidate gates are green.

After `dx-recreate` on the primary: require successful bootstrap, the **expected
committed lock hash present in the primary**, `dx-status`, and the agreed live
checks.

`copying N paths` with N > 0 is a **diagnostic, not a success criterion**. The
count is contextual — observed at 2, 13, and 881 on different boots — and the
failed pin-bump attempt printed `copying 13 paths` immediately before erroring.
Absence of `did not materialise required bootstrap paths` is likewise a
diagnostic.

On failure: preserve logs, revert the lock commit, recreate with the unchanged
image and retained volumes, confirm the primary is back on the previous lock
hash. **A failed lock-only adoption must not be escalated into a factory reset
or salvage operation without a new decision.**

## Step 2 — Clean up, only after convergence

Make `dx-test` and the primary match `main`. Then remove the clean linked
worktree, and delete or retain `bump/lock-refresh` per the recorded disposition.

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

This is not an executable task yet — it has no selected design, reproducer, or
definition of done. It needs its own plan:

1. State the invariant: after remount, no binary from the persistent store may
   be trusted to prove that same trust root sound.
2. Enumerate failure cases: missing or corrupt core utilities, missing Nix,
   corrupt later tools, offline repair, and a healthy reused volume.
3. Compare designs explicitly — pre-remount verification of the target store
   using image-resident tooling; an absolute captured image toolchain used as
   the verifier; or deliberate fail-fast when independent repair is impossible.
   Do not select one merely by moving the call.
4. Add a failing regression where a prerequisite disappears between remount and
   verification. Source-shape assertions are not enough.
5. Preserve the existing invariant that the image-store identity marker is
   published only after successful post-remount validation.
6. Gate on unit and coverage plus isolated live and destructive recovery
   exercises appropriate to a bootstrap-path change.

Third priority stands: two newer defences sit in front of it, and it has never
been reached.

## Deferred — volume-reusing image-pin bump design

Not "collision quarantine": that named a strategy before one was chosen.
Skipping a same-name, different-content store path may violate the very content
identity the guest is meant to trust.

Record required safety properties instead of a design: no mismatched content may
be executed; failure must remain pre-remount and recoverable; existing volumes
must not be silently mutated into an ambiguous state; the fresh-volume path must
remain valid.

Revisit trigger: no later than the next required image-pin change. The alignment
waiver above depends on this being resolved or scheduled, so it cannot stay
open-ended.

## Definition of done

- the refresh is committed on `main` or preserved on a named parked ref;
- no dirty linked worktree is the sole holder of the change;
- the alignment policy is satisfied, or has a visible dated bounded waiver;
- the complete direct **and transitive** lock delta is recorded;
- the promoted commit has an all-green canary including the section-9 case that
  previously failed;
- on the land path, `main`, `dx-test`, and the primary share one committed lock
  hash and the primary health gate is green;
- rollback evidence retained until primary acceptance;
- the post-remount trust root is tracked separately with testable acceptance
  criteria, not treated as closed by this disposition.
