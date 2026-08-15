# Problem — a guest boots the *previous* bootstrap generation

Drafted 2026-08-05. This is a problem statement only: it records the defect,
its mechanism, its evidence, and the constraint that rules out the obvious fix.
No solution is chosen here.

## Status

Open. Known informally as **L6** in `herdr-refactor.md`, where it was recorded
as a "workflow property … Documented — start twice". That classification is
wrong, and the cost is no longer hypothetical: it took down `dx-host` on
2026-08-04 and produced a silent, misleading failure.

Two claims in that earlier record are also incorrect and are corrected below:
the recommended diagnostic does not work, and the condition is not a race that
the host can occasionally win.

## Symptom

A bootstrap change is published, the guest is recreated, and the guest runs the
**old** code. Nothing reports this. The fix appears not to work.

On 2026-08-04 a `dx-recreate` on `dx-host` ended with the container `stopped`
and this as the final log output:

```
Configuring guest environment with Home Manager...
Nix store is not writable by dx.
Granting Nix ownership to dx...
Setting up D-Bus keyring service for credential persistence...
```

That ordering is only producible by the *pre-fix* `configure_guest`, which
called `setup_keyring_service` before `run_home_manager_activation`. The fix
that reorders them was in the working tree and had been published. The guest
ran the previous generation anyway, hit the old defect (a bare assignment under
`set -euo pipefail` whose command substitution fails, killing bootstrap with no
diagnostic), and died. A second `dx-start-container` booted the published
generation and reached "Guest bootstrap complete".

## Mechanism

Three facts compose:

1. **The host starts the container before it publishes.**
   `bin/dx-start-container:17` runs `container start`; `bin/dx-start-container:20`
   runs `dx-sync-bootstrap` afterwards.

2. **The guest does not wait when a payload already exists.** The entrypoint
   built by `dx_bootstrap_launch_command` waits at
   `bin/lib/dx-ssh-common.sh:199`:

   ```sh
   while [ ! -L "$root/current" ] && [ ! -f "$root/.dx-bootstrap-ready" ]; do sleep 1; done
   ```

   `current` is a symlink in the `dx-bootstrap` volume left by the last sync, so
   on any guest that has ever been synced the loop body never executes. The
   guest resolves `current`, takes a lease, and `exec`s that generation's
   `bootstrap.sh` immediately.

3. **The payload volume outlives the container.** `bin/dx-destroy-container`
   deletes only the container; `dx-recreate` is `dx-destroy` + `dx`, and
   `DX_BOOTSTRAP_VOLUME` (`dx-bootstrap`, mounted at `/guest-bootstrap` by
   `bin/dx-create-container:42`) is preserved along with `current` and every
   retained generation.

**This is not a race the host can win.** The guest performs no wait at all when
`current` exists, so the boot has already resolved its generation before
`dx-sync-bootstrap` can publish — and `dx-sync-bootstrap` cannot even begin
until `container exec` works, which requires the container to be running. The
ordering is structural, not timing-dependent. Publication is atomic and
correct; it is simply one boot too late.

The old generation is still fully present on disk (predecessor retention), so
it executes cleanly. There is no error to notice — only stale behaviour.

## Live evidence

Taken from the running `dx-host` on 2026-08-05, with no intervening recreate:

```
$ container exec dx-host sh -c 'ls -1 /guest-bootstrap/.locks/leases/; readlink /guest-bootstrap/current'
20260804T083310Z-59146.1                     ← lease held by PID 1: the code actually running
generations/20260804T084105Z-64118           ← what the next boot will use
```

The live guest is running a generation **two publications behind** `current`.
Both newer generations were published by ordinary `dx-start-container` runs.
Nothing in the guest, the logs, or any host command reports this divergence.

## Detection is currently broken

`herdr-refactor.md` recommends:

```
$ container logs dx-test | grep -oE 'generations/[0-9TZ-]+' | tail -2
```

**This produces no output.** The guest never logs its generation id — the only
launcher message is `Waiting for bootstrap payload in /guest-bootstrap...`
(`bin/lib/dx-ssh-common.sh:198`), and no bootstrap module echoes the resolved
generation. Verified against `dx-host`: zero matching lines.

The real observable is the lease file the launcher writes at
`$root/.locks/leases/<generation>.<pid>` (`bin/lib/dx-ssh-common.sh:209`),
which requires `container exec` into a *running* guest — so it is unavailable
in exactly the case that matters most, a guest whose bootstrap died.

## Blast radius

| Situation | Effect |
| --- | --- |
| `dx-recreate` / `dx` after editing anything under `container/.../bootstrap/` | Runs the previous generation. Always |
| Same, where the previous generation is boot-fatal | Guest dies; the fix for it is published but unused. This is the `dx-host` incident |
| `dx-start-container` on an unchanged tree | Harmless — old and new generations are identical |
| First-ever bring-up (no `current`) | Correct — the launcher genuinely waits |
| Recovery | A second start. Undocumented outside review files |

The develop-and-recreate loop is the one workflow that changes bootstrap code,
and it is the one workflow this defect always hits. It also compounds any
bootstrap-fatal bug into "the guest does not exist, and the reason looks like
the fix failed" — which has already produced one confidently wrong diagnosis
(L3's "bootstrap-delivery deadlock", recorded and retracted in
`herdr-refactor.md`).

## Why the obvious fix does not work

"Publish before starting" is unavailable. `dx-sync-bootstrap` streams the
payload through `container exec` (`bin/dx-sync-bootstrap:29`), which requires a
running container, and it deliberately waits for the guest's own handshake
(`.dx-bootstrap-waiting` / `.dx-bootstrap-ready` / `current`) before writing.
The delivery channel only exists once the thing that consumes it is already
running.

Any solution must therefore either make the guest wait for a publication
belonging to *this* boot, or give the host a way to invalidate `current` before
the guest reads it, or move delivery off `container exec` entirely.

## What a solution must satisfy

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
6. Existing guarantees preserved: atomic publication, the publication lock, and
   predecessor retention for `dx-ai --recover`.

## Non-goals

- Changing what a generation contains, or how `dx-ai` stages and publishes its
  own mutable generations under `/persist`.
- Retention policy for old generations.
- The pre-existing `dx-wait-ssh` false negative, which presents similarly
  (a healthy boot reported as failure) but is a separate single-sample defect.

## Open questions

1. Should the guest block on a *fresh* publication, or should the host
   invalidate `current` during `dx-destroy-container` while the container is
   still alive? The latter is cheaper but does nothing for a host-initiated
   `container start` that skips `dx-destroy` entirely.
2. Is the guest's boot id (already used for lock ownership in the launcher and
   in `dx-ai.sh`) the right token for "a publication belonging to this boot"?
3. Should the launcher simply log its resolved generation? That does not fix
   the defect but closes requirement 4 on its own, and is a one-line change —
   worth doing regardless of which direction the fix takes.

## Related

- `herdr-refactor.md` — L3 (the retracted deadlock diagnosis), L6 (this
  defect, previously under-rated), L7 (a second delivery-shaped trap: additions
  to the essentials profile never reach an existing guest), and the
  "Post-review corrections" section.
- `bin/dx-start-container`, `bin/dx-sync-bootstrap`, `bin/dx-create-container`,
  `dx_bootstrap_launch_command` in `bin/lib/dx-ssh-common.sh`.
