# D5 — Which bootstrap state is immutable, and where does mutable AI state live?

Implemented by [Phase 4](../checklists/phase-4.md); further decomposition in
[Phase 5](../checklists/phase-5.md).

This decision is **tiered**, for the same reason as [D4](D4-mount-manifest.md).
The defect that motivated it is that `dx-sync-bootstrap` deletes the current
payload before the replacement stream has succeeded
([`bin/dx-sync-bootstrap`](../../../bin/dx-sync-bootstrap#L65-L85)), and that
`dx-ai` writes inside the published payload. D5-core fixes both. D5-hardening
adds the lock/lease/GC machinery that keeps those guarantees under concurrent
sync and across restarts; it is deferrable.

---

## D5-core (mandatory)

### Published generations are immutable snapshots

Sync never edits an existing generation: it stages and validates a new
root-owned, read-only generation, atomically switches `current`, and retains the
previous generation. Concretely:

- transfer into a fresh same-filesystem generation/staging directory;
- validate required files and archive extraction;
- normalize root ownership and read-only/executable modes in staging;
- atomically switch `current` only after validation;
- retain the previous ready generation on any failure.

An interrupted transfer therefore leaves the prior payload runnable and not
falsely marked ready — which is the actual bug being fixed.

Remove the broad `chown -R dx:dx /guest-bootstrap`. Published generations remain
root-owned and readable/executable; only the explicit `/persist` state is
writable by `dx`.

### `dx-ai` writes under `/persist`, never the published payload

`dx-ai` never edits `/guest-bootstrap/current`. Its writable flakes live in
`/persist/home/dx/.local/state/dx-ai/generations/<id>`, selected through an
atomically replaced `current` symlink. An update stages a new generation from the
current published bootstrap, updates the structured Antigravity pin and
`flake.lock`, validates and installs from that staged generation, then switches
the symlink only after success. It does not attempt to rename a new directory over
a non-empty `flake/` directory. Failure retains the prior `current` generation.

Before any of this, move the Antigravity version, URL, and hash into
`pins/agy.json` and make the Nix derivation read that file, removing the
range-sensitive `sed` editing at
[`dx-ai.sh`](../../../container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/dx-ai.sh#L111-L142).

### Keyring state is data

Store only the validated D-Bus address in a mode 0600 file under
`/persist/home/dx/.local/state/dx/`, never an `export` command. The shared
`scripts/lib/dx-keyring.sh` is used from the bootstrap payload and installed by
Home Manager at `~/.local/lib/dx/dx-keyring.sh` for `dx-ai`. Bash, Fish, and
Nushell read the same raw address format. The legacy `.dx-keyring-env` line is
parsed once with an exact non-evaluating reader and then removed after successful
conversion.

Of the current consumers, only the Bash `.` at
[`home/shell.nix`](../../../container/aarch64-darwin-apple-container-dx-nixos-26.05/home/shell.nix#L10)
evaluates the file; Fish (`:49-50`) and Nushell (`:113`) already parse it. All
three move to the raw address format.

### Exit criteria for D5-core

- An injected transfer/extract/permission failure leaves the prior payload
  runnable and not falsely marked as the new ready version.
- Published generations are read-only and root-owned.
- `dx-ai` and every shell treat keyring state as data, use the packaged shared
  library where applicable, and execute no content from the legacy env file.
- A failed AI pin/lock update or pointer switch leaves the published bootstrap and
  `dx-ai/current` unchanged and usable; successful publication is one atomic
  symlink switch.

---

## Stopping point

D5-core can ship without D5-hardening. What you give up by stopping here:

- two concurrent syncs are not serialized;
- there is no execution lease, so garbage collection cannot prove a generation is
  in use and must therefore not run automatically — retain generations manually
  until the hardening lands;
- there is no recorded predecessor, so "the previous generation" is whatever
  retention policy you implement rather than an unambiguous recorded fact.

Stopping here is safe provided automatic collection stays off. Say so in the
migration checklist.

---

## D5-hardening (deferrable)

### Publication lock and execution leases

A publication lock serializes sync and garbage collection. Resolving `current` and
creating its execution lease occur in the same critical section, before bootstrap
can execute that generation. A lease records generation, guest boot ID, PID, and
process start time for the bootstrap/foreground-sshd process.

Collection verifies the complete identity, not `kill -0 PID` alone, and never
removes current, current's recorded predecessor, or a genuinely live leased
generation. A lease is not retired merely because it is old; a PID reused after
container restart is not mistaken for the prior owner. This is not hypothetical:
the bootstrap process is foreground PID 1, which a restarted container will
reissue.

### Predecessor metadata

Before publication, the staged generation records the old current as immutable
predecessor metadata, giving later collection an unambiguous "previous" without a
second pointer. Each immutable `dx-ai` generation likewise records its predecessor
ID, so the prior generation can be retained and recovered without trying to
atomically update two independent pointers. Collection retains the generation
named by current's predecessor metadata.

### Exit criteria for D5-hardening

- Concurrent sync and garbage-collection tests prove current, its recorded
  predecessor, and leased generations remain complete.
- Restart/PID-reuse tests reject stale leases.
- A failed AI publication leaves the retained predecessor generation usable.
