# Bump disposition — execution record (backfilled)

**Backfilled 2026-08-31, after the fact.** The plan requires these fields to be
filled *before* the window opens, and they were not. This record describes what
actually happened, including that deviation, rather than presenting the fields
as though they had been agreed in advance.

## Identities

| Field | Value |
| --- | --- |
| Decision maker | Damien Barrett |
| Decision | Land with a digest-qualified alignment waiver; promote to the primary |
| Window | 2026-08-30 into 2026-08-31, a single continuous session |
| Evidence destination | this directory (outside both worktrees) |
| Previous `main` | `aeff59c` immediately pre-merge; `3ce623b` at session start |
| Previous primary lock | `34f29312a2da3447515d68c3c470fda7c63e9a2497c9fc3d1769c4f5f92b8b9b` |
| Previous primary generation | `20260823T191804Z-63317` |
| Raw lock commit | `84e84e9` (final rebase; earlier identities `286d3fc`, `8ff05d8`, `49e4643`, `4ccb57b` are historical) |
| Candidate tip / landed `main` | `27cce6f` |
| Landed lock | `ee4d64dcb658b5e01b1e916965fcc3900a33b3dfaa20da30a0b8995fd4a4b6f9` |
| Landing method | `git merge --ff-only`, asserted `main` SHA == candidate tip SHA |
| Primary generation after promotion | `20260831T012422Z-97852` |

## Rollback set

Ordered, newest first. Reverting the first two undoes the functional change;
the waiver commit must be reverted with them so the runbook does not record an
exception that no longer exists.

- `27cce6f` waiver out of draft
- `2ac4da4` waiver
- `84e84e9` raw lock

Recovery procedure: revert source first, then `./bin/dx-recreate` from the
rolled-back clean `main` with volumes retained, then prove the primary's
*running* generation carries `34f29312…` and rerun the health checks. Do not
garbage-collect during the acceptance window. A failed lock adoption must not
be escalated into a factory reset or salvage without a new decision.

## Deviations from the plan, recorded honestly

1. **The execution record was not filled before the window.** Gates were run,
   the tip was landed, and the primary was promoted before these fields existed.
   They are backfilled here.
2. **Gate order was inverted.** The plan sequences the land-or-park decision
   before the gates; in practice most gates ran first, at the user's explicit
   choice, and the decision followed.
3. **The freeze was invalidated repeatedly.** Each defect found during
   validation produced a commit, which moved the tip and required a rebase and
   a gate rerun. The final gate run was against `27cce6f` and only that tip.
4. **Evidence was collected in a session scratchpad first** and copied here
   afterwards, rather than being written to a declared destination from the
   start.

## Gate results — all against tip `27cce6f`

See `logs/`. Summary: Gate A 9/9 assertions; release-check, unit/static,
host-contract, Bash 3.2 all green; ShellCheck 0.10.0 zero findings repo-wide;
coverage `covered=100% scope_share=21.78%`; `nix flake check` all checks
passed; four aarch64-linux outputs built with the lock hash unchanged;
reused-volume canary 1045/0/9; fresh-volume canary 1045/0/9 after a factory
reset and cold rebuild.

Running-generation proof taken on four distinct boots: three on the canary
(`20260830T021223Z-84395`, `20260830T232037Z-83544`, `20260830T232623Z-18149`)
and one on the primary (`20260831T012422Z-97852`), each carrying `ee4d64dc…`.

## Acceptance

Primary promoted and accepted: bootstrap succeeded, three-fact proof passed,
`dx-status` healthy, live checks green (`dx` on aarch64, nix 2.34.8, core tools
present, `/persist` writable). Rollback evidence retained here until the
acceptance window closes.
