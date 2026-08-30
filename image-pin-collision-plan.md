# Plan: volume-reusing image-pin bump

## Status

Open, **no design selected**. Created 2026-08-30 as the durable tracking
artifact split out of `bump-disposition-plan.md`. Owner: _unfilled_.

**Revisit trigger: no later than the next required image-pin change.** The
alignment waiver recorded in `bump-disposition-plan.md` expires into this item,
so it cannot stay open-ended.

This file records the blocker and the required safety properties only. No
mechanism has been chosen and nothing here is implemented on the lock-refresh
commit stack.

## The blocker

There is currently **no valid, volume-reusing pin-bump procedure**. The blocker
is a store-path *content* collision between image versions, observed directly on
2026-08-30 while bumping the isolated `dx-test` profile from `nixos/nix:2.34.7`
to `2.34.8` with its `/nix` volume retained: the same store path resolved to two
different content hashes. Recorded in `docs/release-maintenance.md`, "Bumping
the Nix image pin".

Until this is resolved, a pin-changing bump reaches the primary the same way the
base changeover did — full destroy-and-rebuild with salvage — and never via
`dx-recreate`.

## Not "collision quarantine"

An earlier framing named that strategy before one was chosen. Skipping a
same-name, different-content store path may violate the very content identity
the guest is meant to trust. Record properties, not a solution.

## Required safety properties

- no mismatched content may be executed;
- failure must remain **pre-remount** and recoverable;
- existing volumes must not be silently mutated into an ambiguous state;
- the fresh-volume path must remain valid.

## Definition of done

- one design selected against the four properties, with rejected alternatives
  and reasons recorded;
- a reproducer for the observed collision, and a behavioral test that the chosen
  design resolves it without executing mismatched content;
- the procedure documented in `docs/release-maintenance.md`, replacing the
  current "no valid procedure" text;
- the alignment waiver in `bump-disposition-plan.md` closed or re-scoped as part
  of the same change.
