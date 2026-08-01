# Phase 1b — Side-effect-free core

**Goal:** make the host code independently testable.
**Owns:** seam 1 (structural half).
**Decisions:** [D2](../decisions/D2-config.md),
[D6](../decisions/D6-command-boundaries.md).
**Depends on:** [Phase 1a](phase-1a.md) — so every commit below lands under CI.

Begin by converting [Phase 0](phase-0.md)'s [D2](../decisions/D2-config.md)
specifications into executable red tests for parser behavior, precedence/origins,
profile migration, and resolve-once behavior through every umbrella/child chain.
Add the [D6](../decisions/D6-command-boundaries.md) command-boundary red tests
beside them. Make these green in the same short series of commits as the items
below.

The process-identity half of D6 already landed in [Phase 0.5](phase-0.5.md). Do
not regress it while moving the code.

## Items

- [x] **1. Extract config into `bin/lib/dx-config.sh`** — root discovery, the
  canonical config field registry, defaults, origin tracking, retired-variable
  validation, and pure validators.

- [x] **2. Implement [D2](../decisions/D2-config.md)** with one non-evaluating
  parser shared by root `.env` and `dx-profile`. Reject unknown/duplicate fields
  and unsupported shell syntax with file/line diagnostics, migrate the three
  checked-in profiles ([`tests/profiles/`](../../../tests/profiles)), validate
  profile names before building paths, and document migration for
  gitignored/user-maintained files. `dx-profile` must export parsed values without
  sourcing the profile ([`bin/dx-profile`](../../../bin/dx-profile#L45-L49)). Update
  README/profile examples so profiles are passed through `dx-profile`, never
  advertised as shell-sourceable files.

- [x] **3. Make config initialization explicit and idempotent.** Resolve and record
  each field's origin once; export and validate the complete, versioned D2
  snapshot rather than trusting its boolean marker alone; and never reopen root
  `.env` for a valid resolved child. Make every umbrella initialize before its
  first observable output or child launch. Add a table-driven host contract for
  `dx`, `dx-destroy`, `dx-recreate`, `dx-factory-reset`, and `dx-mount -> dx`,
  proving every child observes the same values and origins.

- [x] **4. Remove `set -euo pipefail` from every file under `bin/lib/`**, leaving it
  to executable entrypoints. Assert per library that sourcing it leaves `$-`,
  `IFS`, traps, umask, working directory, stdout, and stderr unchanged.

- [x] **5. Move Apple Container functions into `dx-container.sh`** and replace
  import-time failure with `dx_require_container_cli`. Move runtime-process
  discovery and signalling with them, preserving the Phase 0.5 exact-identity
  behavior unchanged.

- [x] **6. Prefer `container ... list --quiet` or structured output** when
  supported, replacing the human-readable table parsing at
  [`dx-lib.sh`](../../../bin/dx-lib.sh#L85-L103). Keep capability detection or a
  documented minimum version rather than relying on table columns.

- [x] **7. Move pure helpers into `dx-host-util.sh`** — name/slug/port derivation,
  positive-integer validation, timeout calculation, and timezone detection.
  **This is a mechanical move**: `dx_slugify`, `dx_short_hash`, `dx_derived_name`,
  and `dx_derived_port` ([`bin/dx-lib.sh`](../../../bin/dx-lib.sh#L134-L179)) are
  already pure and side-effect free. The command-timeout primitive moves with its
  Phase 0.5 private-`mktemp` behavior intact.

- [x] **8. Centralize the SSH endpoint and base options in `dx-ssh-common.sh`.**
  Callers may append command-specific options such as `BatchMode` or
  `ExitOnForwardFailure`.

- [x] **9. Implement [D6](../decisions/D6-command-boundaries.md) across the
  inventoried host/guest command boundaries.** Replace `dx_bootstrap_launch_command`
  ([`bin/dx-lib.sh`](../../../bin/dx-lib.sh#L363-L365)) and the interpolated
  [`dx-migrate-persist`](../../../bin/dx-migrate-persist#L33-L57) programs with fixed
  shell bodies receiving positional arguments or validated environment fields.
  [`bin/dx-sync-bootstrap`](../../../bin/dx-sync-bootstrap#L65-L71) is the reference
  implementation — match its shape. Keep `dx-ssh <command>` as the intentional,
  documented user-command exception with one tested encoding.

- [x] **10. Keep `dx-lib.sh` as a short compatibility facade** while callers migrate
  one at a time. Its semantics are specified in
  [constraints](../constraints.md#the-dx-libsh-compatibility-facade): it sources
  the libraries and calls `dx_init_config`, but **not**
  `dx_require_container_cli`, so it no longer hard-exits when Apple Container is
  absent. Remove it only after no command or test depends on it.

## Exit gate

- A clean environment with no `container` command can run the complete
  non-live suite.
- Root `.env` and named profiles are parsed as data, D2 precedence is
  enforced, and a complete versioned parent snapshot survives every child in
  every orchestration chain unchanged; partial/stale markers fail closed.
- Every D6 boundary passes configuration as positional or validated
  environment data; no config value is interpolated into generated shell code.
- Sourcing any `bin/lib/*.sh` file performs no external mutation, does not exit
  because an optional command is absent, emits no output, and does not alter
  caller shell/control state.
- The Phase 0.5 exact-identity and private-timeout behaviors survived the move,
  proven by the same fixtures.
- The [D1](../decisions/D1-coverage.md) coverage ratchet is baselined against the
  new `bin/lib/` scope.
