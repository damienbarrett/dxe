# Start-generation defect (`dx-start-plan.md`) — live characterisation

Branch 9 Step 1 (`fix/bootstrap-start-generation`), against `main` at
`a96e67f`. Guest: `dx-test` (isolated profile, retained volumes). No code
change is committed as part of this record; the trivial trace edit described
below was reverted after each run.

## Result

**The defect as described in `dx-start-plan.md` does not reproduce on
current `main`.** A start that follows a bootstrap edit runs the edited code
on its *first* start, with no drift, in every one of four repeated trials
across both start paths. This is a change from the plan's drafted state
(2026-08-05): two commits already on `main`, both authored after the plan and
neither referenced by it, fixed the mechanism and the observability gap it
recorded:

- `ba49f39` "Make the booted bootstrap generation observable" (2026-08-15).
  Added the launcher line `Using bootstrap generation <id>` before it execs
  that generation's `bootstrap.sh`, and the host-side drift comparison in
  `dx-start-container` (`dx_bootstrap_report_drift`).
- `a3ee4e3` "Boot the generation published for this start, not the previous
  one" (2026-08-24). Changed the launcher's wait condition in
  `dx_bootstrap_launch_command` (`bin/lib/dx-ssh-common.sh`) from "wait until
  `current` exists" to "wait until `.dx-bootstrap-ready` is set for *this*
  boot", with a bounded fallback (`DX_BOOTSTRAP_PUBLISH_GRACE`, default 30s)
  for a start with no publisher.

Both commits are ancestors of `a96e67f` (`git merge-base --is-ancestor a3ee4e3
a96e67f` succeeds). `tests/test_bootstrap_publication.sh` already has passing
fixture tests pinning both behaviours ("the launcher runs the generation
published for this boot, not the previous boot's"; "an unsignalled start
falls back to the current generation after a bounded wait") — 24/24 passed
against unmodified `main`, no new regression test was needed for the core
defect.

**One important caveat, from `a3ee4e3`'s own commit message, confirmed by
reading `bin/dx-create-container`:** the launcher script is baked as literal
text into the container's entrypoint command by `container create`
(`bin/dx-create-container:71,74`, `-c "$BOOTSTRAP_LAUNCH_CMD"`), not read
fresh from the bootstrap volume on every start. A container created before
`a3ee4e3` keeps the *old* launcher — and therefore the defect — until it is
destroyed and recreated; `dx-stop-container`/`dx-start-container` alone does
not rebake it. Every container used in this characterisation was created (or
recreated) from this checkout, so all four trials necessarily have the fixed
launcher. This does not tell us the state of any container created earlier
and never recreated.

## Method

Trivial harmless edit, reverted after each trial: one `echo` line added
directly under `configure_guest`'s first line in
`container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap/activation.sh`:

```sh
echo "DXE-BRANCH9-CHARACTERISATION-TRACE-20260926[-REPn]"
```

Each trial changes the trace suffix so the content digest changes and a real
publish occurs. Two start paths, per the coordinating session's request:

- **Path (a) — retained-volume recreate**: `dx-destroy` (keeps volumes) ->
  `dx-create-image` -> `dx-create-container` -> `dx-start-container` ->
  `dx-wait-ssh`. Rebuilds and rebakes the launcher.
- **Path (b) — in-place restart**: `dx-stop-container` -> `dx-start-container`
  -> `dx-wait-ssh` on the already-existing container. Does not touch the
  entrypoint; only the bootstrap payload changes.

For each trial: capture `dx-start-container`'s own output (publish line,
any drift warning), then `container exec dx-test readlink /guest-bootstrap/current`,
the `.locks/leases` listing, and `container logs dx-test | grep -n "Using
bootstrap generation\|TRACE\|Warning:"`.

## Trials

| # | Path | Published generation | Lease (PID 1) | Drift warning | Trace present on first start |
| --- | --- | --- | --- | --- | --- |
| 1 | (a) destroy+recreate | `20260926T045411Z-61899` | `20260926T045411Z-61899.1` | none | yes (`-20260926`) |
| 2 | (b) stop/start | `20260926T045807Z-80777` | `20260926T045807Z-80777.1` | none | yes (`-REP2`) |
| 3 | (b) stop/start | `20260926T045842Z-83057` | `20260926T045842Z-83057.1` | none | yes (`-REP3`) |
| 4 | (a) destroy+recreate | `20260926T045923Z-7438`  | `20260926T045923Z-7438.1`  | none | yes (`-REP4`) |

In every trial, published == running == the just-edited generation, on the
first start after the edit. No trial required a second start. No drift
warning fired (there was nothing to warn about).

## Requirement 2 (no-publisher start must still work, bounded)

Separately, with generation `7438` (trial 4's payload) already current and
no edit pending: `container stop dx-test` then `container start dx-test`
directly (bypassing `dx-sync-bootstrap` entirely — the manual-start / reboot
/ "runtime restarts the container" case).

```
Waiting for bootstrap payload in /guest-bootstrap...
Warning: no publication signal after 30s; using the generation already current.
Using bootstrap generation 20260926T045923Z-7438
```

The guest reached "Guest bootstrap complete. Starting sshd in foreground."
and answered SSH normally. This confirms live the bounded fallback
(`DX_BOOTSTRAP_PUBLISH_GRACE`, default 30s) that requirement 2 needs, and that
it is not merely present in the fixture tests but actually fires and recovers
on real hardware.

## Note on `container logs`

`container logs <name>` returns only the current boot session's output, not
history across a `container start`/`stop` cycle — confirmed by line counts
(a fresh session's log started at line 1 after each restart, even though the
container itself was not recreated). This matters for the observability
increment (deliverable 2 of this step): the launcher's "Using bootstrap
generation" line, and any drift diagnostic derived from it, is only
recoverable from `container logs` for a guest that died and has **not yet
been restarted** — which is exactly the case that matters (the 2026-08-04
`dx-host` incident this plan records: a dead guest, inspected before the next
start).

## Disposition

This step (Step 1) does not change the publication/start protocol and does
not close `dx-start-plan.md` — see `docs/refactor/decisions/D7-start-generation.md`
for the design proposal and this finding, and the one-line pointer added to
`dx-start-plan.md`'s Status section. Whether to close the plan outright is
for the coordinating session to decide (Step 2).
