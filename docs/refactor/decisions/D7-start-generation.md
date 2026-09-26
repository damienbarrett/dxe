# D7 — Which boot does a bootstrap edit take effect on?

**Proposed (awaiting review).** Not implemented. Written for `dx-start-plan.md`
(problem statement) and `checkout-consolidation-plan.md` Branch 9, Q4
(**resolved: A** — an edited start whose fresh publication fails or times out
must **fail**; a manual start or reboot with no host publisher must still
boot, bounded).

## Where this actually stands

Live characterisation on 2026-09-26 (`docs/evidence/20260926/start-generation-red.md`)
found the defect `dx-start-plan.md` describes — a guest booting the
*previous* generation after an edited start — **already fixed on `main`** by
two commits the plan predates: `ba49f39` (launcher logs its resolved
generation) and `a3ee4e3` (launcher waits for *this* boot's publication,
bounded fallback). Four repeated live trials across both start paths (retained-
volume recreate; in-place stop/start) show published, running and leased
generation identical on the first start, every time. `tests/test_bootstrap_publication.sh`
already pins both behaviours (24/24 passing, unmodified).

What is **not** implemented is Q4 itself: today's bounded fallback boots
whatever is `current` after `DX_BOOTSTRAP_PUBLISH_GRACE` (default 30s)
regardless of *why* no fresh `ready` arrived — a genuine no-publisher start
(must succeed) and an edited start whose publication is failing or unusually
slow (must fail, per Q4) are indistinguishable to the guest. This document
proposes closing that gap on top of the mechanism that already exists,
rather than replacing it.

## Candidate mechanisms

### 1. Guest waits for a host handshake bound to this boot, bounded fallback — **already implemented**

Protocol (`bin/lib/dx-ssh-common.sh`, `dx_bootstrap_launch_command`): on every
boot the launcher removes `$root/.dx-bootstrap-ready`, touches
`.dx-bootstrap-waiting`, then loops `sleep 1` until `.dx-bootstrap-ready`
reappears or `current` exists **and** `waited >= DX_BOOTSTRAP_PUBLISH_GRACE`
(30s default), at which point it falls back to `current` with a stderr
warning. `bin/dx-sync-bootstrap` sets `.dx-bootstrap-ready` on both outcomes
(publish and unchanged-skip) so an ordinary restart never stalls for the
grace. The launcher then names its resolved generation (`Using bootstrap
generation <id>`) before exec'ing it — the observable record this step's
`dx-status` change now also surfaces host-side.

Meets requirements 1, 2, 3, 5, 6 (live-verified) and observability (4, after
this step's `dx-status` change). Does **not** meet Q4: a slow-but-successful
publish that outlasts the guest's own 30s grace still falls back silently —
the guest resolves stale `current` before the host's write of a new `current`
+ `ready` lands, and `dx-sync-bootstrap` reports success regardless, because
its own success only means the *host* side of publication completed.

### 2. Host invalidates `current` while the container is alive

Unlink or rename `current` (e.g. in `dx-destroy-container`, before the
container actually stops) so the next boot's launcher has nothing to fall
back to and must wait for a fresh publish, or fail outright. Rejected:

- Strictly narrower than option 1. It only touches the destroy/recreate path;
  the plan's own open question notes it "does nothing for a host-initiated
  `container start` that skips `dx-destroy` entirely" — exactly the in-place
  `dx-stop-container`/`dx-start-container` path this step's trials 2 and 3
  exercised, which option 1 already handles.
- Directly breaks requirement 2 if applied any more broadly than that: a
  volume with `current` invalidated and no live publisher (reboot, runtime
  restart) has nothing to boot at all.
- Would require reintroducing exactly the risk option 1 removed: a window
  where the guest has no valid `current` and no publisher.

### 3. Option 1, plus a host-side confirmation deadline that turns the existing drift diagnostic into a start failure — **recommended**

Change nothing about the guest launcher. In `bin/dx-start-container`, after
`dx-sync-bootstrap` returns successfully (a real publish, not the unchanged-
content skip), poll for the guest's execution lease to name the
just-published generation, bounded by a short deadline (a few seconds — the
guest only needs to notice an already-set `.dx-bootstrap-ready` on its next
1-second poll tick and lease immediately; it does not wait out its own grace
in this branch, since `ready` is already present). Reuse
`dx_bootstrap_lease_generation` exactly as `dx-status` and the existing drift
check already do.

- **Match within the deadline:** proceed as today (success, no drift line).
- **No match, or a lease naming an older generation, once the deadline
  elapses:** this is precisely Q4's case — the host published, but the guest
  is provably not running it. Exit non-zero with a clear message ("published
  `<X>` but the guest is running `<Y>`; the guest must be restarted to pick it
  up") instead of a swallowed warning. The container itself is left running
  (nothing can un-boot it); the *start invocation* — the thing Q4 asks to fail
  — fails.
- **The unchanged-content skip path never enters this check**, so a no-op
  restart is never delayed or failed by it (requirement 3, no unbounded
  wait — the poll is itself short and bounded).
- **A start that never called `dx-sync-bootstrap`** (manual `container
  start`, reboot, runtime restart) never runs `dx-start-container` at all, so
  this check does not exist on that path — requirement 2 is untouched
  structurally, not by a special case.

## Requirements / Q4 mapping

| Req. | Option 1 (as shipped) | Option 3 (recommended) |
| --- | --- | --- |
| 1. Edited start runs edited code | Yes (live-verified) | Yes, unchanged |
| 2. No-publisher start still boots, bounded | Yes (live-verified) | Yes, unchanged (check doesn't run) |
| 3. No unbounded wait | Yes (30s grace) | Yes (grace unchanged; new poll is itself short and bounded) |
| 4. Observable, incl. dead guest | Yes, after this step's `dx-status` change | Same, plus the failure is now loud at the start itself |
| 5. Empty volume and many-retained-generation guests | Yes (first-boot has no fallback target, waits genuinely; retention untouched) | Same |
| 6. Atomic publication, lock, predecessor retention | Untouched | Untouched |
| Q4: fail on publish failure/timeout for an edited start | **No** — falls back silently | **Yes** |

## Failure matrix

| Scenario | Behaviour under option 3 |
| --- | --- |
| Edited start, publish succeeds promptly | Boots new generation; no drift; start succeeds |
| First boot, empty volume | No `current` to fall back to; genuine wait for first publish; unaffected by this change |
| No-change start | `dx-sync-bootstrap` skip path sets `ready`; new check does not run; start succeeds |
| Manual start / reboot, no publisher | Guest falls back after 30s grace, boots `current`, warns; `dx-start-container` never runs, so nothing to fail; still just works |
| Publication genuinely times out (lock contention, entrypoint never ready) | `dx-sync-bootstrap` itself already exits non-zero here (unguarded call under `set -e`); `dx-start-container` already fails today — unchanged |
| Publish succeeds host-side, but slower than the guest's fallback | **Closed by this proposal**: poll finds the stale lease, start fails loudly instead of warning |
| Dead guest (bootstrap died after leasing) | Lease still names the generation it died running; `dx-status` (this step) and `container logs` both show it; not this proposal's concern |
| Host crash mid-publication | Publication lock + atomic `current` swap (D5) guarantee no partial `current`; next start's guest sees either the old or the fully-new generation, never a torn one |

## Tests to add (option 3)

- `dx-start-container` fails (non-zero, message names both generations) when
  the post-sync lease poll never matches, using a fake `container exec` that
  never reports the new lease.
- Succeeds promptly when the lease matches within the first poll tick (no
  added delay on the common path).
- The unchanged-content skip and the no-publisher path are unaffected
  (extend the existing `test_bootstrap_publication.sh` fixtures rather than
  duplicating them).
- A genuinely transient one-tick delay (lease appears on the second poll, not
  the first) still succeeds — guards against the deadline being too tight and
  turning a healthy start into a false failure.

## Recommendation

Ship option 3. It adds a bounded host-side confirmation to the mechanism
already on `main`, changes no guest behaviour, and is the smallest change
that satisfies Q4 without weakening requirement 2. Implementing it is Step 2
of this branch; this step lands only the characterisation and the
observability increment.
