# D7 — Which boot does a bootstrap edit take effect on?

**Accepted (2026-09-26).** Implemented in Branch 9 Step 2 (commits `753322f`,
`dcbe6b2`, `6f78d24`, `2257631` on `fix/bootstrap-start-generation`). Replaces
`dx-start-plan.md` (removed; its lasting content — the six requirements, the
mechanism, and the operator remedy — is folded in below) and closes
`checkout-consolidation-plan.md` Branch 9, Q4 (**resolved: A** — an edited
start whose fresh publication fails or times out must **fail**; a manual
start or reboot with no host publisher must still boot, bounded).

## Requirements (from `dx-start-plan.md`, now the durable record)

A solution must satisfy all six, unchanged since the plan was drafted
2026-08-05:

1. A start that follows a bootstrap edit runs the edited code, without the
   operator knowing to start twice.
2. A start with **no** host sync — `container start` by hand, a host reboot,
   the runtime restarting a container — must still boot. It must not hang
   waiting for a publisher that will never arrive.
3. No unbounded wait: any new handshake needs a timeout and a defined
   fall-back (most plausibly "boot the existing `current`", which is today's
   behaviour).
4. The generation actually booted must be observable from the host, including
   after the guest has died — the case where it matters most and where
   `container exec` is unavailable.
5. It must hold for a guest whose bootstrap volume is empty (first bring-up)
   and for one carrying many retained generations.
6. Existing guarantees preserved: atomic publication, the publication lock,
   and predecessor retention for `dx-ai --recover`.

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

What Step 1 left open was Q4 itself: the bounded fallback above boots
whatever is `current` after `DX_BOOTSTRAP_PUBLISH_GRACE` (default 30s)
regardless of *why* no fresh `ready` arrived — a genuine no-publisher start
(must succeed) and an edited start whose publication is failing, unusually
slow, or simply never reaches a guest that was never restarted (must fail,
per Q4) are indistinguishable to the guest itself. Step 2 (below) closes that
gap on top of the mechanism that already exists, rather than replacing it.

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

### 3. Option 1, plus a host-side confirmation deadline that turns the existing drift diagnostic into a start failure — **implemented**

Change nothing about the guest launcher. In `bin/dx-start-container`, after
`dx-sync-bootstrap` returns successfully, `dx_bootstrap_sync_published_generation`
(`bin/lib/dx-container.sh`) tells a real publish from the unchanged-content
skip using only `dx-sync-bootstrap`'s own captured stdout — "Bootstrap
generation `<id>` is ready." vs "... stays current." — since that is the
only distinction available without re-deriving the content digest. For a
real publish, `dx_bootstrap_confirm_publication` polls the guest's execution
lease to name the just-published generation, bounded by
`DX_BOOTSTRAP_CONFIRM_TIMEOUT` (config-registry field, default **5s**,
following the `DX_BOOTSTRAP_WAIT_TIMEOUT` pattern exactly — a few seconds,
since the guest only needs to notice an already-set `.dx-bootstrap-ready` on
its next 1-second poll tick and lease immediately; it does not wait out its
own `DX_BOOTSTRAP_PUBLISH_GRACE` in this branch, since `ready` is already
present). Reuses `dx_bootstrap_lease_generation` exactly as `dx-status` and
the pre-existing drift check already do; the pre-existing diagnostic read is
also kept, so the confirm poll is skipped entirely when it already shows a
match (no added delay on the common path).

- **Match within the deadline:** proceed as today (success, no drift line).
- **No match, or a lease naming an older generation, once the deadline
  elapses:** this is precisely Q4's case — the host published, but the guest
  is provably not running it. `dx-start-container` exits non-zero with
  `Error: <container> published bootstrap generation <X>, but after waiting
  <N>s the guest is running <Y>.` plus the remedy (below), instead of a
  swallowed warning. The container itself is left running (nothing can
  un-boot it); the *start invocation* — the thing Q4 asks to fail — fails.
- **The unchanged-content skip path never enters this check**, so a no-op
  restart is never delayed or failed by it (requirement 3, no unbounded
  wait — the poll is itself short and bounded). `dx_bootstrap_report_drift`
  still runs on exactly this path, unchanged.
- **A start that never called `dx-sync-bootstrap`** (manual `container
  start`, reboot, runtime restart) never runs `dx-start-container` at all, so
  this check does not exist on that path — requirement 2 is untouched
  structurally, not by a special case.

### Operator remedy

When `dx-start-container` fails this way, the container is already running
the *old* generation and will not pick the new publish up on its own — the
guest only resolves `current` once, at boot. The fix is the same one
`dx_bootstrap_report_drift`'s old warning already named: restart it —
`./bin/dx-stop-container && ./bin/dx-start-container`. The second start's
sync sees unchanged content (the previous start already published it) and
takes the skip path, which sets `current` for the boot that's about to
happen; the freshly-started guest then resolves it on its own first wait, no
different from any other first-boot-after-edit start.

Live-verified (`dx-test`, 2026-09-26, no test stub involved): a publish
issued to an already-running, never-restarted guest failed the start exactly
as above, naming both generations; running the remedy then succeeded via the
unchanged-content skip, and `readlink current` / the execution lease matched
afterward.

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

## Tests added (option 3)

All in `tests/test_bootstrap_publication.sh`, driving the real
`bin/dx-start-container` end to end (against the file's existing
fake-`container`-maps-`exec`-to-local-execution trick, which also exercises
the real `bin/dx-sync-bootstrap`), plus parsing-level cases in
`tests/test_section9_host_scripts.sh` and config-validation cases in
`tests/test_refactor_state_machines.sh`:

- `dx-start-container` fails (non-zero, message names both generations, no
  partial side effects — the publication lock is not left held) when the
  post-sync lease poll never matches (no lease writer at all).
- Succeeds promptly when the lease matches within the first poll tick (no
  added delay on the common path).
- The unchanged-content skip is unaffected — no wait, even with a generously
  large bound configured (proves the confirm loop never runs on that path).
- A genuinely transient delay (the lease appears after one full 1-second
  poll cycle, not the first check) still succeeds — guards against the
  deadline being too tight, and against a poll loop that only checks once
  instead of actually polling.
- `DX_BOOTSTRAP_CONFIRM_TIMEOUT` is registered, defaults to 5, and rejects
  zero/non-numeric/empty like every other bounded wait.

## Recommendation — shipped

Option 3 shipped as Branch 9 Step 2. It adds a bounded host-side confirmation
to the mechanism already on `main`, changes no guest behaviour, and is the
smallest change that satisfies Q4 without weakening requirement 2. The
`DX_BOOTSTRAP_CONFIRM_TIMEOUT` default (5s) comes from a live measurement on
`dx-test`: three edited-start trials measured 0.22–0.36s between
`dx-start-container`'s return and the guest's execution lease naming the
just-published generation, so 5s gives roughly 15–25x headroom while staying
"a few seconds," well under the guest's own 30s `DX_BOOTSTRAP_PUBLISH_GRACE`.
