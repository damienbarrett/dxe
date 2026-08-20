# DXE refactor v2 plan review (A)

Reviewed 2026-08-21 against `refactor-v2-plan.md` (untracked, 248 lines) and the
working tree on branch `bootstrap-ownership-import-performance` at `3adeecd`.

Every load-bearing claim in the plan was checked against the code rather than
read for plausibility. All of them hold. The findings below are corrections and
additions, not rebuttals.

**Verdict: the plan is factually sound and correctly prioritized. Phases 0–3
should proceed in order. Two of its phases are scoped against premises that have
already changed, one invariant is stated more broadly than the repository
enforces it, and the coverage gate the plan relies on is currently carrying
enough unearned slack that it would not detect the regression Phase 4 risks.**

| # | Severity | Finding | Action |
| --- | --- | --- | --- |
| A1 | Blocking for Phase 4 | The coverage ratchet is stale by ~330 bp, so the gate Phase 4 depends on cannot currently detect a real regression | Re-baseline `tests/coverage/ratchet.env` to the measured tree with rationale, before Phase 4 |
| A2 | Correction | Phase 2's compatibility adapter is already unnecessary — `setup_nix_volume` has no production callers | Delete the adapter and its tests outright; drop the migration window |
| A3 | Correction | The Bash 3.2 invariant is host-only, and "no arrays" is wrong even there | Scope the constraint to Phase 3; correct the acceptance criterion |
| A4 | Elevation | Priority 3 is a latent `set -u` abort on the host's main entry point, not only a design smell | Do not let Phase 3 slip behind the file moves |
| A5 | Improvement | Phase 4 is the highest-risk, lowest-return item in the set | Defer; consider splitting only the test file |
| A6 | Low | One live instance of the `local var="$(...)"` status trap the plan warns about | Fix opportunistically in Phase 1/2 |

## What the plan gets right

Verified against the tree, not taken from the plan's own summary:

- **`DX_NIX_PENDING_IMAGE_STORE_IDENTITY` is genuine hidden state.** Ten
  production references in `bootstrap/base-and-storage.sh`: exported and written
  at `:489`, `:499`, `:538`; read at `:155` and `:512`. The read at `:155` is a
  silent re-derivation fallback
  (`identity="${DX_NIX_PENDING_IMAGE_STORE_IDENTITY:-$(nix_image_store_identity)}"`),
  so "one identity per bootstrap invocation" is genuinely not true today, and
  there is more than one derivation point. Priority 1 is correctly placed.
- **All five preparation outputs exist and all five are exported** —
  `DX_NIX_VOLUME_ALREADY_MOUNTED`, `_ROOT`, `_DEVICE`, `_FS_TYPE`,
  `_MOUNT_OPTS`. The plan's description of them is exact.
- **The default-profile target behaves as described.**
  `DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET` is exported at `base-and-storage.sh:393`
  and silently re-derived at `:463`
  (`${DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET:-$(nix_image_default_profile_store_path …)}`).
- **The claim/lock coupling is real, and the plan identified it precisely.**
  `dx_lock_acquire` lazily populates `DXE_SELF_PROCESS_IDENTITY` as a side effect
  (`bin/lib/dx-host-util.sh:104-106`), and `dx_nix_volume_claim_acquire` consumes
  that variable at `bin/lib/dx-container.sh:215`. See A4 — this is worse than the
  plan claims.
- **The cleanup duplication is not exaggerated.** `dx_lock_release` appears at 8
  call sites inside `dx_nix_volume_claim_acquire` and 3 inside
  `dx_nix_volume_claim_release`.
- **Both cited gates exist and are runnable**: `tests/run-bash32-tests.sh` is
  present, and `rg` is installed.

The non-goals and invariants section is well judged. In particular, requiring
that any marker-helper consolidation be *typed by marker kind* is the right
constraint. The Nix volume root currently carries four distinct marker files
across the plan's three kinds — `.dx-owner-layout-v1` (ownership),
`.dx-durable-identity-v1` and `.dx-image-store-identity` (identity), and
`.dx-owner-set` (legacy compatibility) — and the first two are independent
migrations that deliberately do not supersede one another. A generic publisher
that let one be published as another would be a data-loss bug rather than a
style regression.

## Findings

### A1 — Blocking for Phase 4: the coverage ratchet is stale by ~330 basis points

`tests/run-coverage-linux.sh:67-68` enforces a monotonic floor read from
`tests/coverage/ratchet.env`. That file currently reads:

```text
scope_share_basis_points=1937
```

The tree measures **2267 bp** (`covered=100% scope_share=22.67%`). The commit at
`3adeecd` moved production logic into the covered scope and never re-measured the
floor, so the gate is carrying roughly 330 bp of slack it did not earn.

`ratchet.env`'s own commentary describes exactly this failure and why it matters:

> Re-measure this number against the finished tree before committing it -- a
> stale baseline is indistinguishable from a deliberately loosened one.

and, recording a previous instance of the same mistake:

> the committed gate was carrying 15 bp of slack it had not earned, and would
> have passed a genuine regression of ~18 scope lines in silence.

The present gap is an order of magnitude larger than the one that warranted that
note. This matters specifically for this plan because Phase 4 moves production
code between modules and test code between suites — the one operation that can
push production logic out of the declared scope. Running that phase against a
floor 330 bp below the real value means the gate cannot detect the regression the
phase is most likely to cause.

Re-baseline to the measured value, with rationale, before Phase 4 begins. Per the
same file's rule, lower it only for test dilution and never to make a run pass.

### A2 — Correction: Phase 2's compatibility adapter is already unnecessary

Phase 2 says to "keep `setup_nix_volume_impl` as a compatibility adapter until
callers migrate," and the target contract allows a compatibility wrapper "for
direct sourceable callers during migration."

That migration has already happened. `bootstrap.sh:15,18` calls
`prepare_nix_volume` and `populate_prepared_nix_volume` directly; the phase
global that used to steer a single `setup_nix_volume` entry point was removed
before `3adeecd`. The only remaining references to `setup_nix_volume` are:

- `tests/test_sourceable_coverage.sh` (several direct calls), and
- the function-existence list in `tests/test_section3_bootstrap.sh:25`,

plus two comments in `base-and-storage.sh:24` and `system.sh:22` that name it
descriptively.

There are no production callers. Phase 2 therefore does not need a migration
window, an adapter, or a deprecation gate: the adapter and the tests that exercise
it can be deleted outright as part of the phase. This makes Phase 2 materially
cheaper than planned and removes one of its two exit criteria.

### A3 — Correction: the Bash 3.2 invariant is host-only, and "no arrays" is wrong

The plan states "Preserve Bash 3.2 compatibility" as a global invariant, and the
acceptance criteria require that "no arrays, `mapfile`, namerefs, `local
var=$(...)` status traps, or Bash-4-only syntax are introduced."

`tests/run-bash32-tests.sh` shows what the repository actually enforces:

```sh
/bin/bash -n "$SCRIPT_DIR"/../bin/dx* "$SCRIPT_DIR"/../bin/lib/*.sh
/bin/bash "$SCRIPT_DIR/test_refactor_contracts.sh"
/bin/bash "$SCRIPT_DIR/test_section9_host_scripts.sh"
/bin/bash "$SCRIPT_DIR/test_section18_mount_git.sh"
/bin/bash "$SCRIPT_DIR/test_refactor_state_machines.sh"
```

Host scripts only. The guest bootstrap modules are not covered, and the guest runs
Bash 5. Two consequences:

1. **The constraint binds Phase 3 and not Phases 1, 2, or 4.** Phase 3 is host
   code (`bin/lib/dx-container.sh`); the other three are guest-side
   `base-and-storage.sh` work. Applying a 3.2 restriction to the guest phases
   restricts them for no reason.
2. **"No arrays" is incorrect even for host code.** Bash 3.2 supports indexed
   arrays; only associative arrays are Bash 4. The single `declare -A` in the tree
   is in `bootstrap/herdr-config.sh` — a guest file, correctly outside the gate. A
   reader following the acceptance criteria literally could try to "fix" it, or
   could avoid an indexed array in host code that would have been perfectly valid.

Restate the invariant as: host scripts under `bin/` must remain Bash 3.2 clean as
verified by `run-bash32-tests.sh`; guest bootstrap modules target the guest's Bash
5 and are exempt. Replace "no arrays" with "no associative arrays".

### A4 — Elevation: priority 3 is a latent `set -u` abort, not only a smell

The plan is framed as "deliberately a plan, not a claim that the current behavior
is defective." That is fair for priorities 1 and 2. Priority 3 is stronger than
that framing allows.

`bin/lib/dx-container.sh:215` writes the claim record with:

```bash
printf '%s\t%s\t%s\n' "$container_name" "$$" "$DXE_SELF_PROCESS_IDENTITY" > "$temporary" \
```

`DXE_SELF_PROCESS_IDENTITY` is used **without a `:-` default**, inside scripts
that run `set -euo pipefail`, on the host's main entry point — `dx-create-container`
and `dx-start-container` both acquire a claim on every `dx` invocation. The
variable is only ever populated as a side effect of `dx_lock_acquire`
(`dx-host-util.sh:104-106`).

This is safe today, and only for one reason: `dx_lock_acquire "$lock" … || return 1`
at `:188` forces an early return before `:215` whenever the lock is not held. The
correctness of a boot-critical write therefore rests on the ordering of two
statements 27 lines apart, with nothing declaring the dependency. Any reordering,
early-exit refactor, or new pre-lock validation that needs the identity converts
it into a hard unbound-variable abort.

The plan's fix — obtain the process identity explicitly in the claim code rather
than depending on the lock's side effect — is correct. The point of this finding
is that it should not be allowed to slip behind the Phase 4 file moves, and that
its test should assert the identity is written correctly when
`DXE_SELF_PROCESS_IDENTITY` is unset on entry, which is the case the current code
cannot survive.

### A5 — Improvement: Phase 4 is the weakest item in the set

Splitting `base-and-storage.sh` (695 lines) into three modules and
`tests/test_sourceable_coverage.sh` (1,450 lines) into module-focused suites is
the highest-risk and lowest-return item here. It touches the most code, changes no
behavior, and is the only phase that can silently break the coverage gate (A1).

At 695 lines, `base-and-storage.sh` is not obviously over-large for what it
does — staging, copy, verification, identity, roots, markers, and volume
lifecycle are genuinely coupled through the import transaction. The test file is
the stronger case: at 1,450 lines it is more than twice the size of the module it
covers.

Recommendation: defer Phase 4 until A1 is closed and Phases 1–3 have landed, then
reconsider it with the production split as an open question rather than a decided
one. The plan's own rule — that the aggregate coverage entry point runs all suites
in one pinned invocation, never once per module — is the right mitigation and
should be kept whichever way that question is resolved.

### A6 — Low: one live instance of the status-trap pattern

The plan warns against `local var=$(...)` masking command status.
`bootstrap/base-and-storage.sh:283` is the one live instance in the phase-1/2
target file:

```bash
local expected="$(id -u dx):$(id -g dx)"
```

Worth splitting the declaration from the assignment while that function is being
touched. Not a defect on its own — the surrounding code validates `expected`
against a strict pattern immediately afterwards — but it is the exact shape the
plan asks not to introduce, and leaving it in place while forbidding new ones
invites confusion.

## Recommended order

1. Re-baseline `tests/coverage/ratchet.env` to the measured 2267 bp with written
   rationale (A1). This is independent of the plan and should happen regardless.
2. Phase 0 and Phase 1 as written.
3. Phase 2, reduced per A2: no adapter, no migration window, delete
   `setup_nix_volume`/`setup_nix_volume_impl` and their tests with the globals.
4. Phase 3 as written, with the identity test from A4 and the invariant scoped
   per A3.
5. Re-evaluate Phase 4 (A5) after 1–3 have landed, rather than committing to the
   production-module split now.

Phase 5's timing helper is uncontroversial and can land whenever convenient; its
marker-consolidation half should stay behind Phase 1 as the plan already requires.
