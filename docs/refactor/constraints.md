# Refactoring constraints and target shape

Part of the [refactor plan](../../refactor-plan.md).

## Invariants

Every phase must preserve these:

- Public command names, flags, default values, meaningful exit statuses, and
  documented output remain compatible unless a separate change is approved.
- macOS system Bash 3.2 remains supported; do not introduce associative arrays
  or newer Bash-only features.
- `dx-host`, its default key pair, and its default volumes can never be removed
  by a side-container cleanup path.
- Versionless legacy and version-1 mount identity files remain readable during
  a defined migration window.
- Configuration is resolved once. A child command cannot re-read root `.env`
  and replace an already-resolved parent or `dx-mount` value.
- A resolved child configuration is a complete, versioned, type-checked
  snapshot. A marker variable by itself never suppresses normal initialization.
- Values cross shell-command boundaries as positional arguments or validated
  environment data, not by interpolation into generated executable text.
- Existing active, stale, and orphan tunnel state remains discoverable during a
  state-layout migration.
- Before sending a signal, process-control code proves exact target identity;
  prefixes, a reused PID, or age alone are never sufficient.
- Locks and execution leases identify an owner by more than PID alone and cover
  the complete state transition, not only the final file write.
- Lifecycle order, idempotence, `/nix` and `/persist` ownership, SSH hardening,
  bootstrap retry timing, and profile isolation do not change accidentally.
- Refactoring commits do not regenerate `flake.lock` unless a Nix input change
  is intentionally in scope.
- Destructive and live tests use a non-default profile and resources.

## Target host-side shape

Use a few cohesive libraries, not a framework:

```text
bin/
  dx-lib.sh                  temporary compatibility facade during migration
  lib/
    dx-config.sh             registry, parser, precedence/origins, validation
    dx-host-util.sh          naming, hashing, ports, safe timeouts, timezone
    dx-container.sh          Apple Container preflight/query and runtime control
    dx-ssh-common.sh         common SSH endpoint/options
    dx-tunnel.sh             shared tunnel state machine
    dx-mount-plan.sh         pure mount/profile/manifest planning
  dx-forward                directional CLI wrapper
  dx-reverse                directional CLI wrapper
  dx-mount                  parse, plan, confirm/execute
```

Libraries must be safe to source: no command availability exit, service start,
filesystem mutation, config-file read, or `main` execution at import time.
Commands call explicit config-initialization and preflight functions before
they need configuration or an external capability.

Safe to source also means **libraries do not set shell options**. Today
[`bin/dx-lib.sh`](../../bin/dx-lib.sh#L2) applies `set -euo pipefail` to every
caller that sources it, which is why
[`tests/test_helpers.sh`](../../tests/test_helpers.sh#L4) has to re-declare its own
options afterwards and still cannot be sure they survive. In the target shape,
`set -euo pipefail` belongs to executable entrypoints in `bin/` only; files under
`bin/lib/` define namespaced functions and constants but do not alter caller
control state. Each library's tests assert that sourcing it leaves `$-`, `IFS`,
traps, umask, and the working directory unchanged and emits no output.

### The `dx-lib.sh` compatibility facade

During Phase 1b, `dx-lib.sh` remains as a short facade so callers migrate one at a
time. Its semantics are specified, not left to implementation time:

- it sources the `bin/lib/*.sh` libraries and calls `dx_init_config`;
- it **does not** call `dx_require_container_cli`, because Phase 1a's portability
  gate requires the non-live suite to run with no `container` binary present;
- it therefore no longer hard-exits when Apple Container is absent. That is a
  deliberate, documented behavior change for anyone sourcing `dx-lib.sh` directly;
  commands that need the runtime call `dx_require_container_cli` themselves.

The facade is removed once no command or test depends on it.

## Guest-side target shape

```text
container/.../
  bootstrap.sh                 explicit bootstrap_main orchestrator
  bootstrap/
    common.sh                  run-as-dx, validation, retry primitives
    base-and-storage.sh        essentials, bash link, /nix setup
    system.sh                  auth files, user, release, timezone, SSH
    persistence.sh             /persist, GitHub, tmux, AI credentials
    activation.sh              ownership, Home Manager, tool verification
  scripts/lib/
    dx-keyring.sh              shared D-Bus/keyring primitives
```

Published and mutable state are deliberately separate:

```text
/guest-bootstrap/
  generations/<generation-id>/    immutable payload + predecessor metadata
  current -> generations/<id>      atomically replaced pointer
  .locks/                           publication lock and execution leases
/persist/home/dx/.local/state/
  dx/keyring-address               raw validated D-Bus address
  dx-ai/generations/<id>/           immutable validated AI working flakes
  dx-ai/current -> generations/<id> atomically replaced pointer
```

The `.locks/`, predecessor-metadata, and lease elements belong to
[D5-hardening](decisions/D5-bootstrap-state.md#d5-hardening-deferrable); the
generation directories and atomic `current` pointer belong to D5-core.
