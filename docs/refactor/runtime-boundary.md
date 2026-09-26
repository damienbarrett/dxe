# The runtime boundary

Branch 11 / Phase 1 (`qnap-dxe-plan.md` DQ2, "Keep one lifecycle model and
add runtime adapters"): a mechanical extraction of every raw Apple
`container` lifecycle invocation in the host scripts behind a narrow,
runtime-neutral contract, with an Apple adapter that preserves commands,
output, defaults, state, stdin passthrough, and exit status exactly. No
QNAP/Docker behaviour exists yet — that is Phase 2. See
`runtime-boundary-inventory.md` in this directory for the full call-by-call
mapping this extraction implements.

## Why

Before this branch, every lifecycle script called the `container` binary
directly. Adding a second runtime (Phase 2's remote Docker adapter for the
QNAP target) would otherwise mean either forking every entrypoint into
`dx-qnap-*` copies, or scattering `if [ "$DX_RUNTIME" = ... ]` branches
through each one. Neither shares the lifecycle model between targets. This
branch inserts one seam instead: entrypoints call `dx_runtime_<op>`, and
exactly one dispatch function per operation decides which adapter runs.

## Shape

```text
bin/lib/dx-runtime.sh          selection + the runtime-neutral contract
bin/lib/dx-runtime-apple.sh    the Apple implementation of every operation
```

`bin/lib/dx-runtime.sh` defines one `dx_runtime_<op>` function per
operation. Each is a one-line dispatch:

```sh
dx_runtime_exec() { dx_runtime_dispatch_ok && dx_runtime_apple_exec "$@"; }
```

`dx_runtime_dispatch_ok` checks `DX_RUNTIME` (resolved by
`bin/lib/dx-config.sh`'s registry, default `apple`) and rejects anything
else with a clear message — defence in depth on top of the registry's own
rejection during configuration resolution. Because a dispatch function is
a plain function call with no subshell or pipe of its own, stdin and exit
status pass through unchanged from caller to adapter to the real
`container` invocation; this is proven directly (piped, file-redirected,
and argv-verbatim) in `tests/test_sourceable_coverage.sh`.

`bin/lib/dx-runtime-apple.sh` defines one `dx_runtime_apple_<op>` function
per operation. Most are a direct, argument-for-argument passthrough:

```sh
dx_runtime_apple_container_delete() { container delete "$@"; }
```

Two operations keep the primary/fallback structure they already had before
this extraction (an older Apple Container CLI without `--quiet` falls back
to the tabular listing form): `dx_runtime_apple_container_list_names` and
`dx_runtime_apple_image_exists`. Nothing about that logic changed; it moved
here verbatim.

## Contract operations

Preflight / host identity, image (exists/build/list/delete), volume
(exists/create/delete), container (exists/running/list/create/start/stop/
kill/delete), exec (with stdin/user/TTY/captured-output), logs, export, an
ephemeral no-persistent-container run, and capability queries — the
complete list and their exact Apple implementations are in
`bin/lib/dx-runtime.sh`/`dx-runtime-apple.sh` themselves; the historical
call-by-call source mapping is in `runtime-boundary-inventory.md`.

Two additions beyond `qnap-dxe-plan.md` DQ2's literal enumeration:

- **`dx_runtime_run_ephemeral`** — `container run --rm` with no persistent
  container, used by `bin/dx-migrate-persist` to read and copy volume
  contents in isolation. Holds the bounded retry loop for Apple Container's
  own runtime-client-attach race (`no runtime client exists: container is
  stopped`) — that retry is specifically about the Apple CLI's own timing,
  so it lives in the adapter rather than the caller, and any future caller
  of "run" inherits it for free.
- **`dx_runtime_host_identity` / `dx_runtime_capability`** — defined per
  `qnap-dxe-plan.md` DQ2/DQ8 so Phase 2's Docker adapter has a shape to
  fill in, but not wired into any entrypoint yet: no command needs a host
  identity or capability answer while Apple is the only runtime. Apple's
  answers reflect what the existing entrypoints already do (direct named-
  volume mounts and bind mounts: yes; a restart policy flag: no, nothing
  sets one today; host filesystem reclamation: yes, `dx-reclaim`'s sparse-
  image trimming).

## What stayed outside the contract

`bin/dx-reclaim`'s host-side sparse-image size measurement (a direct host
filesystem read, never a `container` call) and all of `bin/dx-nix-disk`
(no `container` reference at all) are Apple-only host mechanics per
`qnap-dxe-plan.md` DQ8 ("Apple sparse-image and fstrim reporting is
unsupported on Docker"); they were never raw `container` calls and needed
no migration.

## Wrapper names preserved

`bin/lib/dx-container.sh`'s existing helper names
(`dx_require_container_cli`, `container_system_is_running`/
`ensure_started`, `dx_container_list_names`, `container_exists`,
`container_is_running`, `container_image_exists`, `container_ensure_volume`,
`container_stop_bounded`) are unchanged for every existing caller and test;
only their bodies now call the contract. `dx_container_list_names` calls
the Apple adapter directly rather than through `dx_runtime.sh`'s dispatch:
it is Apple-CLI-version fallback logic with no Docker equivalent to
dispatch to, not a contract-level operation.

## The audit

`tests/test_runtime_boundary_audit.sh` (Section 32) fails if any file under
`bin/` other than `bin/lib/dx-runtime-apple.sh` invokes a raw Apple
`container` lifecycle verb. `tests/` may still call `container` directly
(a fake `container` on `PATH`, or a live guest in the full tier) — the
audit only scans `bin/`. Its detector requires "container" to be
immediately followed by whitespace and a lifecycle verb, with a documented,
dated exception list for the handful of comments and operator-facing
messages that still match that shape; every exception names why it is
prose, not a call.

## What Phase 2 changes (and does not)

Phase 2 adds `bin/lib/dx-runtime-docker.sh` and a second branch inside each
`dx_runtime_<op>` dispatch function; `DX_RUNTIME=docker` stops being
rejected. No entrypoint, and no name in `bin/lib/dx-container.sh`'s wrapper
layer, needs to change again — that is the point of the seam this branch
inserted.
