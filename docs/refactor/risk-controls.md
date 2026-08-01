# Risk controls and commit strategy

Part of the [refactor plan](../../refactor-plan.md).

## Commit strategy

- Land one phase as a short series of independently revertible commits.
- Add characterization tests before moving the implementation.
- Introduce a currently failing safety test only at the start of the phase that
  immediately fixes it. The suite stays green between phases; no file-level
  expected-failure suppression is permitted.
- Separate mechanical moves from behavior or state-format changes.
- For destructive work, resolve and print an immutable plan before execution.
- For bootstrap changes, validate in an isolated profile before touching the
  default guest.
- Do not combine this refactor with a Nix channel bump, package refresh, or
  Apple Container upgrade.

## Reader before writer

"Independently revertible commits" is not automatically true for the phases that
change a persisted format. Once the new-format **writer** has run, reverting to a
build that cannot read that format leaves unreadable state on disk. The forward
[migration gates](migration-gates.md) say nothing about going backwards.

**The rule: in every format change, the new-format reader lands in a strictly
earlier commit than the new-format writer.**

Reverting the writer commit alone then restores a build that still reads both the
old and the new format, so no state becomes unreadable. Reverting *both* is only
safe while no new-format state exists yet.

Applies to:

| Format | Reader commit | Writer commit | Backout |
| --- | --- | --- | --- |
| Tunnel state layout ([Phase 2](checklists/phase-2.md) item 6) | new + legacy socket discovery | new state dir and metadata writer | revert the writer commit; new-layout sockets remain discoverable and stoppable. Sockets are per-boot, so a reboot clears the rest. |
| Mount manifest v2 ([Phase 3](checklists/phase-3.md) item 4) | v2 decoder alongside the Phase 0.5 v0/v1 decoders | v2 encoder | revert the encoder commit; v2 manifests already on disk stay readable. Never revert past the v2 decoder while any v2 manifest exists. |
| Bootstrap generation layout ([Phase 4](checklists/phase-4.md) item 11) | `current`-pointer resolution + flat-layout fallback | staging/publish writer | revert the writer commit; the compatibility path still resolves an already-published generation. |

Write the backout command into the commit message of each writer commit, next to
the gate it registers.

## State transitions, not just file writes

Serialize state transitions, not just file writes. Per-resource locks and
same-filesystem atomic publication must cover the complete resolve/publish or
stage/validate/switch critical section, with bounded waits, stable owner
identity, PID-reuse tests, and cleanup tests.

This is the substance of
[D4-hardening](decisions/D4-mount-manifest.md#d4-hardening-deferrable) and
[D5-hardening](decisions/D5-bootstrap-state.md#d5-hardening-deferrable), both of
which are deferrable. What is **not** deferrable is same-filesystem atomic
publication — stage then `rename` — which is cheap, needs no lock, and is what
actually prevents a partial file from becoming authoritative.

## Process control

Parse exact process identity before signalling. Prefix matches, PID alone,
and elapsed age never authorize TERM/KILL or stale-lock/lease reclamation;
timeout bookkeeping lives in private temporary storage.
[Phase 0.5](checklists/phase-0.5.md) lands this early precisely so it is not
hostage to the restructuring, and [Phase 1b](checklists/phase-1b.md) must not
regress it while moving the code.

## Command text and configuration data

Keep them separate per [D6](decisions/D6-command-boundaries.md). Fixed programs
receive positional or validated environment data, and intentional user-command
execution remains explicit and separately tested.

## Published state is immutable

Never mutate a published bootstrap generation; optional tool updates publish
versioned `/persist` generations through an atomic pointer rather than replacing a
non-empty live directory.
