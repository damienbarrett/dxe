# Runtime boundary inventory (Branch 11 / Phase 1, Increment 0)

Every raw Apple `container` lifecycle invocation under `bin/`, as it exists
today on `main` (`2acffa9`), with the `dx_runtime_<op>` contract operation
each is proposed to move behind. This is Increment 0: an inventory only, no
code changes. See `qnap-dxe-plan.md` DQ2 for the contract's design and
`### Phase 1` for the increment list this document starts.

Method: `grep -rnE` for the literal token `container` followed by a
lifecycle verb (`list|inspect|exec|run|create|start|stop|kill|delete|rm|
image|volume|logs|export|stats|system`) across `bin/` and `bin/lib/`,
manually checked line by line against the full file to exclude comments,
echoed diagnostic strings, and variable/function names (`container_exists`,
`$DX_CONTAINER_NAME`, etc.) that merely contain the substring. Existing
wrapper functions in `bin/lib/dx-container.sh` (`container_exists`,
`container_is_running`, `container_ensure_volume`, `container_stop_bounded`,
`dx_require_container_cli`, …) are **not** raw calls from their callers'
point of view; their own bodies are in scope and are listed under
`bin/lib/dx-container.sh` below. `tests/test_helpers.sh:178`'s
`requires_container` also calls `container list --quiet` directly; that is
inside `tests/` and is the approved exemption, not counted here.

## Summary by file

| File | Raw call sites |
| --- | --- |
| `bin/lib/dx-container.sh` | 13 |
| `bin/dx-put` | 8 |
| `bin/dx-status` | 8 |
| `bin/lib/dx-backup.sh` | 6 |
| `bin/dx-sync-bootstrap` | 6 |
| `bin/dx-get` | 5 |
| `bin/dx-start-container` | 3 |
| `bin/dx-reclaim` | 3 |
| `bin/dx-create-container` | 2 |
| `bin/dx-create-volumes` | 2 |
| `bin/dx-destroy-container` | 2 |
| `bin/dx-destroy-volumes` | 2 |
| `bin/dx-enter` | 2 |
| `bin/dx-gc` | 2 |
| `bin/dx-migrate-persist` | 2 |
| `bin/dx-create-image` | 1 |
| `bin/dx-destroy-image` | 1 |
| `bin/dx-export` | 1 |
| `bin/dx-wait-ssh` | 1 |
| **Total** | **70** |

19 files, 70 raw call *sites* (source lines). Some sites execute more than
once at runtime with different arguments (noted per row); counting those
separately, as the task brief's "~75" estimate appears to, lands in the
mid-70s. Files confirmed to have **zero** raw calls despite touching
containers only through the existing wrappers: `bin/dx`, `bin/dx-backup`,
`bin/dx-restore`, `bin/dx-stop-container`, `bin/dx-herdr`,
`bin/dx-factory-reset`, `bin/dx-mount`, `bin/dx-nix-disk`, `bin/dx-profile`,
`bin/dx-ssh`, `bin/dx-forward`, `bin/dx-reverse`, `bin/dx-create-keys`,
`bin/dx-destroy-keys`, and the other `bin/lib/*.sh` files
(`dx-host-util.sh`, `dx-mount-plan.sh`, `dx-ssh-common.sh`, `dx-tunnel.sh`,
`dx-config.sh`). `bin/dx-nix-disk` has no container references at all — it
manipulates the host-side sparse disk image directly.

## Proposed contract catalogue

Naming follows the existing wrapper style (`dx_runtime_<noun>_<verb>`).
Apple semantics are "move existing code verbatim"; nothing here changes
behaviour.

| Contract operation | Apple implementation (today's behaviour, unchanged) | Used by |
| --- | --- | --- |
| `dx_runtime_available` | `command -v container` | `dx_require_container_cli` (name kept) |
| `dx_runtime_system_running` | `container system status >/dev/null 2>&1` | `container_system_is_running` (name kept) |
| `dx_runtime_system_start` | `container system start` | `container_system_ensure_started` (name kept) |
| `dx_runtime_image_exists` | `container image list --quiet` (fallback: `container image list` + `awk`) | `container_image_exists` (name kept) |
| `dx_runtime_image_list` | `container image list` (raw text for human display) | `dx-status` |
| `dx_runtime_image_build` | `container build -t IMAGE CONTEXT` | `dx-create-image` |
| `dx_runtime_image_delete` | `container image rm IMAGE` | `dx-destroy-image` |
| `dx_runtime_volume_exists` | `container volume inspect VOL >/dev/null 2>&1` | `container_ensure_volume` (name kept), `dx-create-volumes`, `dx-destroy-volumes`, `dx-migrate-persist` |
| `dx_runtime_volume_create` | `container volume create VOL` | `container_ensure_volume` (name kept) |
| `dx_runtime_volume_delete` | `container volume rm VOL` | `dx-destroy-volumes` |
| `dx_runtime_container_exists` | `container list -a --quiet` (fallback: `container list -a` + `awk`) | `container_exists` (name kept) |
| `dx_runtime_container_running` | `container list --quiet` (fallback: `container list` + `awk`) | `container_is_running` (name kept) |
| `dx_runtime_container_list` | `container list [-a]` (raw text for human display) | `dx-status` |
| `dx_runtime_container_create` | `container create FLAGS... IMAGE -c CMD -- ARGS` | `dx-create-container` |
| `dx_runtime_container_start` | `container start NAME` | `dx-start-container` |
| `dx_runtime_container_stop` | `container stop --time GRACE NAME` (bounded by `run_with_timeout`) | `container_stop_bounded` (name kept) |
| `dx_runtime_container_kill` | `container kill NAME` (bounded by `run_with_timeout`) | `container_stop_bounded` (name kept) |
| `dx_runtime_container_delete` | `container delete [--force] NAME` (bounded by `run_with_timeout`) | `dx-destroy-container` |
| `dx_runtime_exec` | `container exec [-i] [-t] [-u USER] NAME CMD...` | `dx-sync-bootstrap`, `dx-start-container`, `dx-status`, `dx-gc`, `dx-reclaim`, `dx-get`, `dx-put`, `dx-enter`, `bin/lib/dx-backup.sh`, `dx_bootstrap_confirm_publication` |
| `dx_runtime_logs` | `container logs [-n N] NAME` | `dx-status`, `dx-wait-ssh` |
| `dx_runtime_export` | `container export NAME` (stdout stream) | `dx-export` |

Two operations are proposed **beyond** DQ2's literal minimum-set wording,
because an entrypoint uses them today (DQ2: "define ONLY operations an
entrypoint actually uses today plus the capability queries" — read as a
floor, not a ceiling). Flagged below for the coordinating session to
confirm before extraction:

- **`dx_runtime_run_ephemeral`** — `container run --rm --volume ... --entrypoint sh IMAGE -lc '...' -- ARGS`, captured stdout/stderr, retried on a known Apple CLI race (`no runtime client exists: container is stopped`). Used only by `bin/dx-migrate-persist` (`dx_migrate_container_run`, one code site, three call expressions). Not one of DQ2's enumerated verbs (image/volume/container exist·build·list·delete/create·start·stop·kill·delete, exec, logs/export) — `run` is Apple's one-shot create+start+attach+auto-remove, used here to run the image in isolation from any named container to read/write volumes during migration. Whether this belongs in the shared contract (with a defined-but-unsupported Docker capability answer) or stays as an Apple-only escape hatch documented in DQ8's style is a design call, not a mechanical one.
- **Host identity / capability queries** (`dx_runtime_host_identity`,
  `dx_runtime_capability {direct_named_volume_mounts, bind_mounts,
  restart_policy, host_filesystem_reclamation}`) — DQ2 lists these in the
  minimum set and DQ8 needs them for its per-command QNAP disposition
  table, but **no entrypoint calls them today**: Apple's runtime is always
  local (no remote-host identity check exists), and nothing branches on a
  capability today because Apple supports all of them unconditionally.
  Proposed: define the operation names now (Apple returns fixed/trivial
  answers — "local", "true" for every capability) so Phase 2's Docker
  adapter has a shape to fill in, per DQ2's "add runtime adapters" framing.
  This adds contract surface with no corresponding characterisation test
  possible today (nothing exercises it) — confirm this is wanted in Phase 1
  rather than deferred whole to Phase 2, where DQ8's table is actually used.

Not migrated, by design, per DQ8 (Apple-only, no runtime abstraction
applies): `bin/dx-reclaim`'s host-side sparse-image size measurement
(`du -sh` on `$DX_CONTAINER_VOLUME_DIR/$vol/volume.img`, a host filesystem
path, not a `container` invocation) and all of `bin/dx-nix-disk` (no
`container` calls at all). `dx-reclaim`'s guest-side reads
(`container exec ... du/df`, `fstrim`, `nix-collect-garbage`) DO move
behind `dx_runtime_exec` like any other exec call; only the host-side
sparse-image byte-counting stays untouched.

## Wrapper functions staying name-stable

Per the task's design note, these keep their names and signatures for every
existing caller; only their bodies move to call the new contract:

`dx_require_container_cli`, `container_system_is_running`,
`container_system_ensure_started`, `dx_container_list_names`,
`container_exists`, `container_is_running`, `container_image_exists`,
`container_ensure_volume`, `container_stop_bounded`. (`container_wait_stopped`,
`container_runtime_pids`, `container_runtime_identity_matches`,
`container_kill_runtime_process`, the bootstrap-lease/digest/drift helpers,
and the Nix-volume-claim helpers make no raw `container` calls themselves —
unchanged.)

## Detailed call-site table

Legend for the Flags column: `-i` = stdin attached/piped; `-u U` = exec as
user U (absent = image default user, i.e. root); `-t`/`-it` = TTY; `cap` =
output captured (command substitution or redirected to a file/variable);
`stream` = output goes straight to the terminal or a pipe, never captured;
`discard` = redirected to `/dev/null`, only exit status is used.

### `bin/lib/dx-container.sh`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 15 | `container system status` | discard | plain `&&`/`||` in caller | `dx_runtime_system_running` |
| 17 | `container system start` | stream | only called when not running | `dx_runtime_system_start` |
| 23 | `container list -a --quiet` | cap | primary path; falls through to 24 only if this fails | `dx_runtime_container_exists` (name query, all) |
| 24 | `container list -a` \| `awk` | stream→cap | fallback when `--quiet` unsupported (older Apple CLI) | `dx_runtime_container_exists` (name query, all) |
| 26 | `container list --quiet` | cap | primary path; falls through to 27 on failure | `dx_runtime_container_running` (name query, running) |
| 27 | `container list` \| `awk` | stream→cap | fallback | `dx_runtime_container_running` (name query, running) |
| 39 | `container image list --quiet` | cap | primary path; falls through to 43 | `dx_runtime_image_exists` |
| 43 | `container image list` \| `awk` | cap | fallback | `dx_runtime_image_exists` |
| 45 | `container volume inspect "$1"` | discard | `||` triggers create (next call) on failure | `dx_runtime_volume_exists` |
| 45 | `container volume create "$1"` | stream | runs only if inspect (above) failed | `dx_runtime_volume_create` |
| 113 | `container stop --time "$DX_STOP_GRACE_SECONDS" "$name"` | stream | `run_with_timeout "$DX_STOP_COMMAND_TIMEOUT"`; failure logged, not fatal (falls through to kill) | `dx_runtime_container_stop` |
| 116 | `container kill "$name"` | stream | `run_with_timeout "$DX_STOP_COMMAND_TIMEOUT"`; `|| true` (falls through to runtime-process kill) | `dx_runtime_container_kill` |
| 246 | `container exec "$name" sh -c '...' -- "$bootstrap_path"` | cap, discard stderr | inside a polling loop (`dx_bootstrap_confirm_publication`); `|| true` per attempt, bounded by `$timeout` | `dx_runtime_exec` |

### `bin/dx-create-container`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 71 | `container create "${CREATE_FLAGS[@]}" -e "DX_PUB_KEY=$DX_PUB_KEY" "$DX_IMAGE" -c "$BOOTSTRAP_LAUNCH_CMD" -- "$DX_BOOTSTRAP_PATH"` | stream | `set -e`; branch taken when `$DX_SSH_KEY_PUB` exists | `dx_runtime_container_create` |
| 74 | `container create "${CREATE_FLAGS[@]}" "$DX_IMAGE" -c "$BOOTSTRAP_LAUNCH_CMD" -- "$DX_BOOTSTRAP_PATH"` | stream | `set -e`; branch taken when pub key file is absent (warns first) | `dx_runtime_container_create` |

### `bin/dx-start-container`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 19 | `container start "$DX_CONTAINER_NAME"` | stream | `set -e`; only reached when not already running | `dx_runtime_container_start` |
| 31 | `container exec "$DX_CONTAINER_NAME" readlink "$DX_BOOTSTRAP_PATH/current"` | cap, discard stderr | `2>/dev/null \|\| true` — diagnostic only, never fails the start | `dx_runtime_exec` |
| 33 | `container exec "$DX_CONTAINER_NAME" sh -c 'ls -1 ... leases' -- "$DX_BOOTSTRAP_PATH"` | cap, discard stderr | `2>/dev/null \|\| true` — diagnostic only | `dx_runtime_exec` |

### `bin/dx-destroy-container`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 16 | `container delete --force "$DX_CONTAINER_NAME"` | stream | `run_with_timeout "$DX_DELETE_COMMAND_TIMEOUT"`; reached only when bounded stop failed | `dx_runtime_container_delete` (force) |
| 23 | `container delete "$DX_CONTAINER_NAME"` | stream | `run_with_timeout "$DX_DELETE_COMMAND_TIMEOUT"`; normal path after a clean stop | `dx_runtime_container_delete` |

### `bin/dx-create-image`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 14 | `container build -t "$DX_IMAGE" "$DX_CONTEXT_DIR"` | stream | `set -e`; only reached when image absent | `dx_runtime_image_build` |

### `bin/dx-create-volumes`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 15 | `container volume inspect "$legacy_volume"` | discard | part of a compound `&&`/`!` guard (legacy-volume-exists check) | `dx_runtime_volume_exists` |
| 16 | `container volume inspect "$DX_PERSIST_VOLUME"` | discard | same compound guard, negated (persist-volume-absent check) | `dx_runtime_volume_exists` |

### `bin/dx-destroy-image`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 14 | `container image rm "$DX_IMAGE"` | discard stdout | `set -e`; only reached when image exists | `dx_runtime_image_delete` |

### `bin/dx-destroy-volumes`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 24 | `container volume inspect "$vol"` | discard | inside existence-filter loop over configured volume names | `dx_runtime_volume_exists` |
| 61 | `container volume rm "$vol"` | stream | `if !` — explicit error message and `exit 1` on failure | `dx_runtime_volume_delete` |

### `bin/dx-enter`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 10 | `container exec -it "$DX_CONTAINER_NAME" bash -l` | `-i` `-t`, stream (interactive) | `set -e`; branch when no extra args given | `dx_runtime_exec` (tty) |
| 12 | `container exec -it "$DX_CONTAINER_NAME" bash -lc "$(printf "%q " "$@")"` | `-i` `-t`, stream (interactive) | `set -e`; branch when args given | `dx_runtime_exec` (tty) |

### `bin/dx-export`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 16 | `container export "$DX_CONTAINER_NAME" > "$EXPORT_FILE"` | stream (redirected to file) | `set -e`; only reached after existence check | `dx_runtime_export` |

### `bin/dx-gc`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 16 | `container exec -u dx "$DX_CONTAINER_NAME" bash -lc 'nix-collect-garbage --delete-older-than 14d'` | `-u dx`, stream | `set -e`; only reached when running | `dx_runtime_exec` |
| 19 | `container exec -u dx "$DX_CONTAINER_NAME" bash -lc 'nix-store --optimise'` | `-u dx`, stream | `set -e` | `dx_runtime_exec` |

### `bin/dx-get`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 17 | `container exec "$DX_CONTAINER_NAME" [ -e "$SOURCE" ]` | discard output, exit status only | `if !` — explicit error message and `exit 1` | `dx_runtime_exec` |
| 24 | `container exec "$DX_CONTAINER_NAME" [ -d "$SOURCE" ]` | discard output, exit status only | `if` sets `IS_DIR` | `dx_runtime_exec` |
| 39 | `container exec "$DX_CONTAINER_NAME" tar -C ... -cf - "$(basename "$SOURCE")" \| tar -xf - -C "$DEST"` | stream (piped to host `tar`, guest→host) | `set -e`; whole pipeline under `pipefail` | `dx_runtime_exec` |
| 43 | same, with `--strip-components=1` on host side | stream (piped, guest→host) | `set -e`/`pipefail` | `dx_runtime_exec` |
| 56 | `container exec "$DX_CONTAINER_NAME" cat "$SOURCE" > "$FINAL_DEST"` | stream (redirected to file, guest→host) | `set -e` | `dx_runtime_exec` |

### `bin/dx-migrate-persist`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 32 | `container run "$@"` (inside `dx_migrate_container_run`; `--rm --volume ... --entrypoint sh IMAGE -lc '...' -- ARGS`, called from 3 sites: L85 read sentinel, L94 list destination, L105 perform copy) | `-i`-less (batch), output captured to `$work_dir/{out,err}` files | Bounded retry loop (`DX_MIGRATE_RUN_MAX_ATTEMPTS`, default 5) on the exact Apple CLI race string `no runtime client exists: container is stopped`; any other error returns immediately with the original exit code | `dx_runtime_run_ephemeral` (proposed; see catalogue note) |
| 73 | `container volume inspect "$legacy_volume"` | discard | `if !` — early `exit 0` ("nothing to migrate") when absent | `dx_runtime_volume_exists` |

(Line 113's `echo "Legacy cleanup command: container volume rm $legacy_volume"` is a printed suggestion for the operator to run by hand, not an executed call — not counted.)

### `bin/dx-put`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 26 | `container exec "$DX_CONTAINER_NAME" bash -c '[ -d "$1" ] \|\| (mkdir -p "$1" && chown dx:dx "$1")' -- "$guest_dir"` | stream, no stdin | `set -e` (`dx_put_ensure_guest_dir` helper) | `dx_runtime_exec` |
| 36 | `container exec "$DX_CONTAINER_NAME" [ -d "$DEST" ]` | discard, exit status only | short-circuited `||` in an `if` (directory-branch test) | `dx_runtime_exec` |
| 45 | `container exec -i "$DX_CONTAINER_NAME" tar -xf - -C "$TARGET_DIR"` | `-i` (stdin = piped host `tar -cf -`, host→guest) | `set -e`/`pipefail` | `dx_runtime_exec` |
| 50 | `container exec -i "$DX_CONTAINER_NAME" tar -xf - -C "$DEST" --strip-components=1` | `-i` (stdin piped, host→guest) | `set -e`/`pipefail` | `dx_runtime_exec` |
| 52 | `container exec "$DX_CONTAINER_NAME" chown -R dx:dx "$FINAL_DEST"` | stream, no stdin | `set -e` | `dx_runtime_exec` |
| 56 | `container exec "$DX_CONTAINER_NAME" [ -d "$DEST" ]` | discard, exit status only | file-branch equivalent of line 36 | `dx_runtime_exec` |
| 65 | `container exec -i "$DX_CONTAINER_NAME" bash -c 'cat > "$1"' -- "$FINAL_DEST" < "$SOURCE"` | `-i` (stdin = **redirected from a host file**, not piped from a command) | `set -e` | `dx_runtime_exec` |
| 66 | `container exec "$DX_CONTAINER_NAME" chown dx:dx "$FINAL_DEST"` | stream, no stdin | `set -e` | `dx_runtime_exec` |

### `bin/dx-reclaim`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 30 | `container exec -u dx "$DX_CONTAINER_NAME" /usr/bin/bash -lc "$1"` (`run_in_guest` helper; called at L87 with `nix-collect-garbage -d`) | `-u dx`, stream | `set -e` | `dx_runtime_exec` |
| 41 | `container exec "$DX_CONTAINER_NAME" /usr/bin/bash -lc '...' bash "$DX_NIX_MOUNT" /persist` | root exec (no `-u`), stream | `set -e`; internal `exit $?` on `du`/`df` failure inside the guest script | `dx_runtime_exec` |
| 65 | `container exec "$DX_CONTAINER_NAME" /usr/bin/bash -lc '...' bash "$mount_path"` (`trim_mount` helper; called at L92/L93 for the Nix mount and `/persist`) | root exec (no `-u`), stream | `set -e`; guest script itself tolerates `fstrim` being unsupported | `dx_runtime_exec` |

### `bin/dx-status`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 42 | `container image list \| grep "^${DX_IMAGE}[[:space:]]"` | stream (piped to grep, displayed) | reached only when `container_image_exists` true | `dx_runtime_image_list` |
| 49 | `container list -a \| grep "^${DX_CONTAINER_NAME}[[:space:]]"` | stream (piped to grep, displayed) | reached only when `container_exists` true | `dx_runtime_container_list` (all) |
| 53 | `container logs -n 40 "$DX_CONTAINER_NAME" 2>&1 \| sed 's/^/  /'` | stream (displayed) | reached only when container exists but not running | `dx_runtime_logs` |
| 66 | `container exec "$DX_CONTAINER_NAME" readlink "$DX_BOOTSTRAP_PATH/current"` | cap, discard stderr | `2>/dev/null \|\| true` — diagnostic only | `dx_runtime_exec` |
| 68 | `container exec "$DX_CONTAINER_NAME" sh -c 'ls -1 ... leases' -- "$DX_BOOTSTRAP_PATH"` | cap, discard stderr | `2>/dev/null \|\| true` — diagnostic only | `dx_runtime_exec` |
| 86 | `container logs "$DX_CONTAINER_NAME" 2>/dev/null \|\| true` | cap | diagnostic only; reached when container exists but is not running | `dx_runtime_logs` |
| 107 | `container exec -u dx "$DX_CONTAINER_NAME" bash -lc "echo -n 'Tools: ' && ..."` | `-u dx`, stream | `set -e`; reached only when running | `dx_runtime_exec` |
| 110 | `container exec -u dx "$DX_CONTAINER_NAME" bash -lc "tmux ls 2>/dev/null"` | `-u dx`, stream | `\|\| echo "No active tmux sessions"` | `dx_runtime_exec` |

### `bin/dx-wait-ssh`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 62 | `container logs -n "$lines" "$DX_CONTAINER_NAME" 2>&1 \| sed 's/^/  /'` (inside `print_container_logs`, called with 5- and 80-line bounds from three call sites) | stream (displayed, or `>&2` at the caller) | `if !` wraps the pipeline; prints "(container logs unavailable)" on failure, never fatal | `dx_runtime_logs` |

### `bin/lib/dx-backup.sh`

| Line | Call | Flags | Error/timeout handling | Contract op |
| --- | --- | --- | --- | --- |
| 68 | `container exec -u dx "$container_name" "$(dx_backup_selector_path)" "$DX_BACKUP_GUEST_ROOT" "$@"` | `-u dx`, cap (function's stdout is the caller's capture) | caller (`dx-backup`) handles failure; stderr passes through | `dx_runtime_exec` |
| 106 | `... \| container exec -i -u dx "$container_name" tar -C "$DX_BACKUP_GUEST_ROOT" ... -T - -cf - \| tar -xf - -C "$backup_dir/current"` | `-i` `-u dx` (stdin piped path list, output piped to host `tar`, guest→host) | `set -e`/`pipefail` in `dx-backup` (source has no shebang options itself; caller sets them) | `dx_runtime_exec` |
| 198 | `container exec -u dx "$container_name" "$(dx_backup_selector_path)" --hash-paths ... > "$hashes"` | `-u dx`, cap (redirected to a file, not a variable) | caller handles failure | `dx_runtime_exec` |
| 254 | `container exec -u root "$container_name" sh -c 'root="$1"; shift; for d in "$@"; do mkdir -p ...; done' -- "$DX_BACKUP_GUEST_ROOT" "${dir_list[@]}"` | `-u root`, stream, no stdin | caller handles failure | `dx_runtime_exec` |
| 265 | `... \| container exec -i -u dx "$container_name" tar -xf - -C "$DX_BACKUP_GUEST_ROOT"` | `-i` `-u dx` (stdin piped from host `tar`, host→guest — reverse direction of line 106) | `set -e`/`pipefail` | `dx_runtime_exec` |
| 268 | `container exec -u root "$container_name" chown dx:dx "$DX_BACKUP_GUEST_ROOT/$path"` | `-u root`, stream, no stdin, inside a loop over restored paths | caller handles failure | `dx_runtime_exec` |

## Existing test fixture pattern (for Increment 1's characterisation tests)

`tests/lib/fake-tools.sh`'s `fake_tool_write` is the established way to drop
a fake executable on `PATH` (used today for `ssh`, and ad hoc for `container`
in `tests/test_section9_host_scripts.sh` — see its `fake_bin/container`,
`fake_dir` fixtures around lines 175, 230, 258, 285). No shared fake
`container` helper exists yet (unlike `fake_ssh_write`); Increment 1 should
consider adding one to `tests/lib/fake-tools.sh` given how many test files
will need one (`test_dx_backup.sh`, `test_dx_restore.sh`,
`test_bootstrap_publication.sh`, `test_section16_persist_storage.sh`,
`test_section23_herdr.sh`, `test_section9_host_scripts.sh` already hand-roll
one each). `tests/test_helpers.sh`'s `requires_container` (line 177-178) is
the one approved `tests/`-side raw call outside `dx-runtime-apple.sh`.

## Flagged for coordinating-session review

1. `dx_runtime_run_ephemeral` (dx-migrate-persist's `container run --rm`) —
   not one of DQ2's enumerated verbs; propose adding it to the contract as
   an Apple-specific ephemeral-run primitive. Confirm before Increment 2.
2. `dx_runtime_host_identity` and the four `dx_runtime_capability` queries
   (DQ2/DQ8) have no Phase-1 call site — Apple would return fixed/trivial
   answers with no characterisation test possible today. Confirm whether
   Phase 1 should still define and adapter-implement them (for Phase 2 to
   consume) or defer them entirely to Phase 2, where they are first used.
3. `dx-reclaim`'s host-side sparse-image size measurement and all of
   `dx-nix-disk` are proposed to stay outside the runtime contract entirely
   (they never call `container`); confirm this reading of DQ8 matches
   intent before the audit test (Increment 4) is written to allow it.

No call site was found that cannot be expressed in the contract without
changing behaviour, and no call site depends on Apple-only output
formatting the contract would need to expose beyond raw pass-through text
(`dx_runtime_image_list`/`dx_runtime_container_list`, already scoped as
"raw text for human display" above).
