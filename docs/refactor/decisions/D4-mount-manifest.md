# D4 — What are the mount manifest codec and concurrency contract?

Implemented by [Phase 3](../checklists/phase-3.md), with a partial in-place fix in
[Phase 0.5](../checklists/phase-0.5.md).

This decision is **tiered**. D4-core removes the code-execution surface and is
mandatory. D4-hardening makes the manifest write-once under concurrent
invocation and gives legacy manifests a conversion path; it is deferrable, and
the boundary between them is a real stopping point.

The split matters because the two halves are wildly asymmetric in cost. The
defect that motivated this decision is one line — `dx-mount` *sources* a
user-writable identity file ([`bin/dx-mount`](../../../bin/dx-mount#L217-L228)).
D4-core fixes it completely. D4-hardening protects against two `dx-mount`
invocations racing on one developer's machine, and under
[D1](D1-coverage.md) every lock branch (acquire, timeout, reclaim, stale,
PID-reuse, symlink-refusal, ownership-refusal × attach/first-create/migrate/destroy)
needs its own test — plausibly more test code than the entire codec.

---

## D4-core (mandatory)

### Version-2 codec

Version 2 is data. Its first line is exactly `DX_MOUNT_MANIFEST_V2`; every
following line is `FIELD<TAB>UNWRAPPED_RFC4648_BASE64`. Each allowlisted field
appears exactly once in canonical registry order. Encoding removes base64 line
wrapping, so every valid POSIX path byte except NUL is representable without shell
escaping. A small adapter handles the documented macOS and GNU `base64` flags and
rejects non-canonical or undecodable input. Unknown, missing, duplicate,
malformed, or out-of-order records fail closed before any resource command runs.

### Legacy decoders

Versionless and version-1 readers accept only the exact assignment names and
the subset of Bash `printf %q` output produced by the supported writers:
backslash-escaped bytes and ANSI-C `$'...'` escapes. They reject substitutions,
expansions, redirects, additional shell tokens, and trailing commands. Golden
fixtures generated under macOS Bash 3.2 cover empty values, whitespace, quotes,
backslashes, newlines, non-ASCII paths, and every supported escape.

**No reader invokes `source`, `eval`, or a shell subprocess on manifest text.**
This is the whole point of the decision.

### Field validation

Every decoded field is validated by type:

- safe container and volume/image identifiers;
- absolute paths where required;
- positive, in-range port;
- exact known field names with duplicate/unknown-field rejection.

### Filesystem hygiene and publication

The identity directory is owned by the current user at mode 0700, new files are
mode 0600, and symlinked or unexpectedly owned state paths fail closed. The writer
stages in the same directory and publishes with an atomic `rename`, so an
interrupted write never leaves a partial authoritative manifest.

### Exit criteria for D4-core

- No persisted mount state is sourced or evaluated as code.
- Versionless legacy and version-1 manifests still attach/destroy according to
  the current contract, using only the bounded grammar above.
- An interrupted publication leaves either the old manifest or the complete new
  one, never a partial file.

---

## Stopping point

D4-core can ship without D4-hardening. What you give up by stopping here:

- concurrent `dx-mount` invocations on the same identity are not serialized, so
  first-create is atomic per-write but not semantically write-once under a race;
- legacy v0/v1 manifests remain readable but have no conversion path, so the
  [legacy-manifest removal gate](../migration-gates.md#legacy-mount-manifests)
  cannot be satisfied and both decoders stay indefinitely.

Neither is a safety regression against today's behavior; both are unfinished
cleanup. If you stop here, say so in the migration checklist so the retained
decoders are not mistaken for an oversight.

---

## D4-hardening (deferrable)

### Per-container lock

Attach, first-create, migration, and destroy use an atomic per-container lock
directory with a bounded wait and cleanup trap. Lock metadata records PID plus a
stable process-start identity available on the supported host; reclamation
requires both to prove that the original owner is gone, and age alone is
insufficient.

The writer rechecks absence after acquiring the lock, stages in the same
directory, and uses an atomic hard-link/no-replace publish that fails if the
target exists; a plain overwriting `mv` is not enough. Thus first-create atomic
publication and semantic write-once identity remain true under concurrent
invocations rather than only in single-process tests; the one permitted existing-file
replacement is the verified format-only migration below.

### Format migration

Format migration is explicit and preserves semantic identity. `dx-mount
--migrate-manifests` is a report-only dry run; adding `--apply` converts only a
legacy manifest that contains every canonical identity field and whose decoded
values match the currently resolved plan. Under the per-container lock it
re-reads the old file, stages and validates v2, and atomically replaces only the
encoding; interruption leaves the old authoritative file intact. An incomplete
v0/v1 manifest is not guessed or augmented from defaults: the command refuses
it and prints the exact destroy-and-recreate remediation.

### Audit

`dx-mount --audit-manifests` walks every mount identity file reachable from every
profile parsed through [D2](D2-config.md) and reports each one's format version,
completeness, and migration eligibility. It is what makes deleting the legacy
decoders a safe, evidence-backed step rather than a guess — see the
[legacy-manifest removal gate](../migration-gates.md#legacy-mount-manifests).

### Exit criteria for D4-hardening

- Concurrent first-attach/attach/destroy tests prove the manifest remains
  semantically write-once, complete, and authoritative, with bounded lock
  failure behavior; the only permitted replacement is a verified format-only
  legacy conversion.
- `--audit-manifests` reports format and migration eligibility across all local
  profiles, complete legacy records have an atomic conversion path, and
  incomplete records receive safe destroy/recreate remediation.
