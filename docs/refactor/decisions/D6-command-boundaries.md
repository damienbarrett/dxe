# D6 — How do values cross command and process boundaries safely?

Implemented by [Phase 0.5](../checklists/phase-0.5.md) (process identity) and
[Phase 1b](../checklists/phase-1b.md) (command boundaries).

## Resolution

Inventory every production `sh -c`, `sh -lc`, `bash -c`, and `bash -lc` boundary.
A fixed program may receive values through positional arguments after `--` or
through validated environment fields; **configuration is never interpolated into
generated executable text.** Intentional user-command execution, such as
`dx-ssh <command>`, remains an explicit public contract and uses one tested
transport rather than ad hoc quoting. The bootstrap launcher and persistence
migration use fixed command bodies and positional data.

## Reference implementation

The repository already contains the required shape.
[`bin/dx-sync-bootstrap`](../../../bin/dx-sync-bootstrap#L65-L71):

```sh
container exec "$DX_CONTAINER_NAME" sh -c '
set -eu
dest="$1"
mkdir -p "$dest"
…
' -- "$DX_BOOTSTRAP_PATH"
```

The program body is a fixed single-quoted literal; the path arrives as `$1` after
`--`. Nothing about the value can change the program. Every boundary converted
under this decision should end up looking like this — in particular
`dx_bootstrap_launch_command` ([`bin/dx-lib.sh`](../../../bin/dx-lib.sh#L363-L365)),
which currently interpolates `$DX_BOOTSTRAP_PATH` into the program text, and the
generated programs in
[`bin/dx-migrate-persist`](../../../bin/dx-migrate-persist#L33-L57).

## Process control follows the same separation

Runtime discovery parses an exact `--uuid` argument/value pair, not a substring of
a human-readable command line, and tests include prefix-colliding names. Today
[`container_runtime_pids`](../../../bin/dx-lib.sh#L272-L279) uses
`index($0, "--uuid " name)`, so a fallback stop for `dx-host` can select a process
whose UUID is `dx-host-other` — a name `--container` accepts, because
`dx_require_non_reserved_container_name` rejects only the exact string `dx-host`.

Timeout bookkeeping uses a private `mktemp` directory, never a predictable
shared-`TMPDIR` marker ([`bin/dx-lib.sh`](../../../bin/dx-lib.sh#L218-L255)).

Before TERM or KILL, code revalidates the target's stable process identity so PID
reuse cannot redirect a signal.

These two process-control fixes are small and independent of any file move, so
they land in [Phase 0.5](../checklists/phase-0.5.md) rather than waiting for the
library extraction. The rule that they must survive the move still applies: Phase
1b does not preserve an unsafe implementation merely because the move is
mechanical.
