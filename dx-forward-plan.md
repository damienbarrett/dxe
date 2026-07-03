# dx-forward Design History

Status: implemented. This file is retained as design history; `bin/dx-forward`,
`bin/dx-reverse`, their behavior tests, and `README.md` are the current sources
of truth.

## Goal

The work added a small host-side helper that exposes ports from the running
`dx-host` guest on macOS loopback addresses without recreating the container.

It supports the common browser workflow:

```text
guest 127.0.0.1:5173 -> host 127.0.0.1:5175
guest 127.0.0.1:8000 -> host 127.0.0.1:8000
guest 127.0.0.1:8001 -> host 127.0.0.1:8001
```

The helper uses SSH local forwarding (`ssh -L`), not container port
publishing and not an HTTP reverse proxy. SSH forwarding works after the
container is already running and avoids Chrome/macOS local-network behavior
around the container private IP.

## Implemented Interface

The implementation provides `bin/dx-forward`.

Supported forms:

```bash
./bin/dx-forward 5173
./bin/dx-forward 5173:5175
./bin/dx-forward 8000 8001 5173:5175
./bin/dx-forward --list
./bin/dx-forward --stop 8000
./bin/dx-forward --stop-all
```

Port argument semantics:

- `5173` means `host 127.0.0.1:5173 -> guest 127.0.0.1:5173`.
- `5173:5175` means `host 127.0.0.1:5175 -> guest 127.0.0.1:5173`.
- Bind host listeners to `127.0.0.1` by default, not `0.0.0.0`.

Print a URL for each opened forward:

```text
Forwarded http://127.0.0.1:5175 -> dx-host:5173
```

## Implemented Shape

The implementation uses the existing SSH config values from `bin/dx-lib.sh`:

- `DX_CONTAINER_NAME`
- `DX_SSH_PORT`
- `DX_SSH_KEY`
- `DX_SSH_CONNECT_TIMEOUT`

Each host port uses a dedicated background SSH master:

```bash
ssh -f -N -M \
  -S "$socket" \
  -L "127.0.0.1:${host_port}:127.0.0.1:${guest_port}" \
  -i "$DX_SSH_KEY" \
  -p "$DX_SSH_PORT" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o IdentitiesOnly=yes \
  -o LogLevel=ERROR \
  -o ConnectTimeout="$DX_SSH_CONNECT_TIMEOUT" \
  -o ExitOnForwardFailure=yes \
  dx@127.0.0.1
```

Control sockets are stored under a deterministic path:

```text
${TMPDIR:-/tmp}/dx-forward-${DX_CONTAINER_NAME}-${host_port}.sock
```

This makes forwards independent from the user's interactive `dx-ssh` shell and
allows clean stop/list behavior.

For each control socket, also write a small sidecar metadata file:

```text
${socket}.meta
```

The metadata records `container`, `host_port`, and `guest_port`. The control
socket remains the source of truth for whether a forward is active; the
metadata exists so `--list` can print the guest target and so re-running a
forward can distinguish "already active with the same target" from "host port
already managed by dx-forward but pointed at a different guest port." Cleanup
must remove both the socket and its metadata, including cases where OpenSSH has
already removed the socket while shutting down the master connection.

## Behavior Details

Preflight:

- Verify the SSH key exists.
- Verify the configured container exists and is running.
- Call `bin/dx-wait-ssh` so the error is clear if the guest is still
  bootstrapping.
- Validate that all ports are integers in `1..65535`.
- Reject privileged host ports below `1024` unless explicitly supported later.

Port conflicts:

- If the host port is already listening and it is not this helper's control
  socket, fail with a clear message.
- If the matching control socket already exists, check it with `ssh -S "$socket"
  -O check`.
- If the socket is stale, remove only the stale socket and retry.

Target service:

- Do not require the guest target port to be listening before creating the
  forward. It is useful to open the port first and start the web server later.
Stopping:

```bash
ssh -S "$socket" -O exit dx@127.0.0.1
```

`--stop 8000` stops the forward for host port `8000`. `--stop-all` stops all
state matching the configured container name.

Listing:

- Shows active helper-managed forwards by scanning helper socket and metadata
  state.
- Runs `ssh -S "$socket" -O check` for each socket.
- Includes `lsof` output when available so the user can see the listening host
  port.

## Multiple Ports

The implementation uses one SSH process per host port. That keeps
state simple and makes `--stop 8000` predictable.

A later optimization could group multiple `-L` forwards into one master
connection, but that makes partial stop/list behavior more complex.

## Tests

Static and behavioral tests in `tests/test_section9_host_scripts.sh` cover:

- `bin/dx-forward` exists.
- It sources `dx-lib.sh`.
- It uses `set -euo pipefail`.
- It uses `ssh -f -N -M`.
- It uses `ExitOnForwardFailure=yes`.
- It binds forwards to `127.0.0.1`.
- It supports `--list`, `--stop`, and `--stop-all`.
- It validates port arguments.

The helper is also syntax-checked:

```bash
bash -n bin/dx-forward
```

Manual live validation:

```bash
./bin/dx-forward 5173:5175
curl -I http://127.0.0.1:5175/

./bin/dx-forward 8000
./bin/dx-forward --list
./bin/dx-forward --stop 8000
```

## Documentation

`README.md` includes a "Forwarding guest web ports" section:

```bash
./bin/dx-forward 5173:5175
open http://127.0.0.1:5175/
```

The section distinguishes when to use each approach:

- Use `dx-forward` for browser access from macOS to a guest web server.
- Use direct `http://192.168.64.x:<port>` only as a diagnostic convenience.
- Use `dx-reverse`, which wraps SSH reverse forwarding (`ssh -R`), for
  guest-to-host access, not macOS-browser-to-guest access.

## Acceptance Criteria

- A running `dx-host` can expose guest ports without recreation.
- Multiple forwards can be active at once.
- Stopping one forward does not disturb the others.
- Re-running the same forward is idempotent or fails with a precise reason.
- Browser access uses `127.0.0.1`, avoiding the container private IP.
- Existing `dx`, `dx-ssh`, and lifecycle scripts keep their current behavior.
