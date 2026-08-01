# Migration gates

Part of the [refactor plan](../../refactor-plan.md).

Every persisted-format change follows **read old + read new → write new → observe
migration window → remove old reader**. The removal step needs a *gate*, not an
elapsed time: the command that proves no old-format state remains is written down
in the same commit that introduces the legacy reader.

**None of these may be retired on age alone.** Record satisfaction with a date and
the command output in the checklist below.

---

## Legacy tunnel state

**Introduced by:** [Phase 2](checklists/phase-2.md) item 6.
**Covers:** `TMPDIR/dx-forward-*.sock` and `dx-reverse-*.sock`.

The legacy socket reader is deleted only when a `dx-status --tunnel-state` sweep
reports zero such entries across every local profile, on every machine that runs
this repository, recorded once with a date.

Sockets are per-boot state, so in practice this gate is satisfied one reboot after
the new writer ships — but it is satisfied by **observation, not assumption**.

- [ ] Satisfied on \_\_\_\_ (date), machines: \_\_\_\_

**Observed 2026-08-01 — NOT satisfied.** `./bin/dx-status --tunnel-state` on the
development host reports one legacy entry:

```text
forward container=dx-host port=8420 layout=legacy socket=$TMPDIR/dx-forward-dx-host-8420.sock
```

The legacy reader is load-bearing today and must be retained. Re-run the sweep
after the next reboot.

---

## Legacy mount manifests

**Introduced by:** [Phase 0.5](checklists/phase-0.5.md) item 3 and
[Phase 3](checklists/phase-3.md) item 4.
**Covers:** versionless and version-1 mount identity files.

Unlike tunnel sockets, mount manifests are durable on-disk state that can survive
indefinitely on a machine whose side containers are rarely touched, so this reader
cannot be retired on a schedule.

The v0 and v1 decoders are deleted only when `dx-mount --audit-manifests` reports
zero v0 and zero v1 manifests on every machine that runs this repository. Until
then the decoders stay, regardless of elapsed time.

Deleting them turns an old side container into an unattachable, undestroyable
resource — the audit is what makes that irreversible step safe.

**This gate is unsatisfiable without
[D4-hardening](decisions/D4-mount-manifest.md#d4-hardening-deferrable)**, which
provides both `--audit-manifests` and the `--migrate-manifests --apply` conversion
path. If Phase 3 stops after D4-core, record that the decoders are retained
deliberately rather than by oversight.

- [ ] Satisfied on \_\_\_\_ (date), machines: \_\_\_\_

**Observed 2026-08-01 — not yet satisfied, but now satisfiable.** D4-hardening
shipped, so `--audit-manifests` and `--migrate-manifests --apply` both exist; the
"unsatisfiable" caveat above no longer applies. `./bin/dx-mount
--audit-manifests` on the development host reports `No mount manifests found.`
— zero v0 and zero v1 records on this machine. The gate needs the same
observation on every other machine that runs this repository before the decoders
can be deleted.

---

## Flat bootstrap layout

**Introduced by:** [Phase 4](checklists/phase-4.md) item 11.
**Covers:** the flat `/guest-bootstrap` compatibility path.

Removed once every container that can be started from this repository has been
re-synced under the generation layout and reports a valid `current` pointer.

Because a stopped container keeps whatever payload it last received, **the check
is per-container, not per-machine**: the gate is satisfied when the default guest
and every named profile have each been started and re-synced at least once after
the new writer ships.

- [ ] Satisfied on \_\_\_\_ (date), containers: \_\_\_\_

**Observed 2026-08-01 — partially satisfied, gate NOT met.** Per-container:

| Container | Layout | Evidence |
| --- | --- | --- |
| `dx-test` | generations | `current -> generations/…`, predecessor retained across repeated publications |
| `dx-host` | flat | no `current` symlink; payload sits directly in `/guest-bootstrap` |

The generation writer is proven against a live container, but the gate is
per-container and `dx-host` has not been re-synced, so the flat compatibility
path remains load-bearing. Re-check after the default guest is re-synced.

---

## Old-base guards

**Introduced by:** pre-existing.
**Covers:** [`bootstrap.sh`](../../container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap.sh#L11-L29)
and [`bin/dx-start-container`](../../bin/dx-start-container#L21-L44).
**Removed by:** [Phase 6](checklists/phase-6.md) item 1.

Removed once the default guest, side containers, and named profiles have all moved
off the old base. The primary is already done —
[`plan.md`](../../plan.md#L64-L73) records the changeover completing on 2026-07-05
behind an `OLD_BASE_ABSENT` gate with the full suite green. The remaining inventory
is side containers and named profiles.

- [ ] Satisfied on \_\_\_\_ (date), inventory: \_\_\_\_

---

## Backout

Forward gates are only half the story. See
[reader-before-writer](risk-controls.md#reader-before-writer) for the rule that
makes each of these phases revertible, and the per-format backout commands.
