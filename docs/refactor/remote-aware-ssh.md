# Remote-aware SSH and user workflows (Branch 11 / Phase 5, Increment 0)

Branch `feat/qnap-remote-ssh` (`qnap-dxe-plan.md` "## Phase 5 — Make SSH and
user workflows remote-aware"). Written as a design document before any code
changes, per this task's Increment 0. Phase 5 makes the guest's SSH boundary
-- interactive SSH, command SSH, wait/status probes, forward/reverse tunnels,
`dx-enter`, `dx-export`, and the fail-closed capability checks Phase 2 left
open -- reach a QNAP guest directly on the NAS's Tailscale address (DQ5),
instead of assuming the controller's own loopback the way every one of these
today does. Phase 5 items 1-8 and their exit gate
(`qnap-dxe-plan.md` "## Phase 5") are the definition of done; item 9 (running
`tailscaled` inside the guest itself) is **deferred by user decision 2b**
until items 1-8 land, recorded in `qnap-dxe-plan.md` at Increment 7 with the
reason and DQ5's fallback wording; not started here.

Everything below is developed and characterised against fake `ssh`/`docker`/
`nc` boundaries only (`tests/lib/fake-tools.sh`, `DXE_FAKE_SSH_REMOTE_PATH`
pinned in every fake-management-ssh test per the standing incident note).
The NAS, `dx-test`, and `dx-host` are never touched by this branch; the
coordinating session runs both live gates after "READY FOR LIVE".

## 1. The new contract operation: `dx_runtime_guest_ssh_address`

**Why a new operation, not a config field.** The guest's own reachable
address is not something an operator sets (unlike `DX_REMOTE_HOST`, the
*management*-plane alias) -- it is discovered at run time from the NAS over
the existing management connection, exactly the way `DXE_RUNTIME_DOCKER_BIN`
(the Docker CLI's absolute path) and `DXE_RUNTIME_DOCKER_DAEMON_ID` already
are. It must never be persisted to any tracked file (DQ5, and the public-repo
rule), so it is process-local, cached, exported state -- not a
`DXE_CONFIG_FIELDS` registry entry.

**Dispatch.** Added to `bin/lib/dx-runtime.sh` alongside the other
preflight/identity operations:

```sh
dx_runtime_guest_ssh_address() { dx_runtime_dispatch guest_ssh_address "$@"; }
```

**Apple's implementation** (`bin/lib/dx-runtime-apple.sh`) is a fixed
constant, no discovery, matching every other Apple preflight/identity answer
in that file (`host_identity` returns `local` the same way):

```sh
dx_runtime_apple_guest_ssh_address() { printf '%s\n' 127.0.0.1; }
```

**Docker-ssh's implementation** (`bin/lib/dx-runtime-docker.sh`) reuses
Phase 0's proven discovery shape
(`tests/qnap/lib/phase0-common.sh`'s
`dxe_qnap_tailnet_addr_discovery_remote_script`: the Tailscale qpkg CLI's own
`ip -4` first, falling back to reading `tailscale0`'s assigned address
directly) -- reused, not duplicated, as a **fresh production copy** under
`bin/lib/`, for the same reason `DX_RUNTIME_DOCKER_BIN_GLOB`/
`dx_runtime_docker_bin_discovery_script` in that same file are already a
fresh copy of `tests/qnap/lib/phase0-common.sh`'s own Docker-path discovery
rather than a `source` of it: that file lives under `tests/`, this one under
`bin/lib/`, and `bin/` code cannot depend on `tests/` without inverting the
test/production dependency direction. One SSH round trip over the existing
management connection (`dx_runtime_docker_ssh_raw`), POSIX-sh, BusyBox/ash
safe, no bashisms -- matching every other remote snippet this file already
sends:

```sh
DX_RUNTIME_DOCKER_TAILSCALE_BIN_GLOB='/share/*/.qpkg/Tailscale/tailscale /share/*/.qpkg/Tailscale/bin/tailscale'

dx_runtime_docker_guest_ssh_address_discovery_script() {
    cat <<REMOTE
$(dx_qpkg_binary_discovery_snippet ...)   # same shape as the Docker-bin discovery above, tailscale instead of docker
DXE_TAILNET_ADDR=""
if [ -n "$DXE_TAILSCALE_BIN" ]; then DXE_TAILNET_ADDR="$("$DXE_TAILSCALE_BIN" ip -4 2>/dev/null | head -n1)"; fi
if [ -z "$DXE_TAILNET_ADDR" ]; then DXE_TAILNET_ADDR="$(ip -4 addr show tailscale0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"; fi
echo "${DXE_TAILNET_ADDR:-NOTFOUND}"
REMOTE
}
```

**Validation.** The discovered value must be a dotted-quad IPv4 address
inside the CGNAT `/10` block Tailscale assigns addresses from, never
loopback, never a LAN/private range, never `0.0.0.0` (DQ5, verbatim).
`tests/test_section1_secrets.sh` already defines the exact regex for this
range for its own (unrelated) leak-scan purpose:

```sh
TAILNET_IP_PATTERN='100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'
```

That file lives under `tests/`, so `bin/lib/dx-runtime-docker.sh` gets its
own fresh production copy of the same pattern (same non-sourcing reason as
the discovery script above), anchored (`^...$`) since this is validating a
whole captured value, not scanning free text for a leak. A discovered value
that is empty, `NOTFOUND`, or fails this validation refuses with:

> `Error: the NAS has no Tailscale address; DQ5 forbids publishing on the
> LAN or 0.0.0.0.`

**Caching.** One SSH round trip per process, cached exactly like
`DXE_RUNTIME_DOCKER_BIN`: `DXE_RUNTIME_GUEST_SSH_ADDRESS`, exported so a
child process inherits it and never re-discovers it. A test that wants to
skip real discovery pre-seeds this variable directly, the same way existing
`test_docker_runtime_adapter.sh` cases pre-seed `DXE_RUNTIME_DOCKER_BIN=docker`.
Never written to any tracked file, never logged verbatim in a way that could
leak into a committed fixture (tests use a placeholder value inside the
same CGNAT range, assembled so no test file's own source text is a
literal dotted quad either -- the same discipline
`test_section1_secrets.sh`'s own planted fixture already follows).

**Where this lands, mechanically:**

- `bin/lib/dx-runtime.sh` -- the dispatch function above.
- `bin/lib/dx-runtime-apple.sh` -- `dx_runtime_apple_guest_ssh_address`.
- `bin/lib/dx-runtime-docker.sh` -- discovery script, glob constant,
  validation regex, `dx_runtime_docker_guest_ssh_address` (discover once,
  cache, validate, refuse).
- `docs/refactor/runtime-boundary-inventory.md` -- a new row in the
  "Proposed contract catalogue" table (Preflight/identity family), matching
  the style already used for the Phase 3 additions
  (`dx_runtime_image_identity`, `dx_runtime_volume_usage`).
- `docs/refactor/docker-adapter-mapping.md` -- a new row in section 4's
  "Preflight / identity" table.
- `tests/test_docker_runtime_adapter.sh` (Section 33) -- direct unit
  characterisation: real discovery over a fake management ssh with
  `DXE_FAKE_SSH_REMOTE_PATH` pinned (proving no real `tailscale`/`docker`
  leaks in from a CI runner's own PATH, the exact Phase 2 incident this
  pinning exists for); the qpkg-glob fallback path; the refusal on
  `NOTFOUND`/empty/out-of-range; caching (a second call makes no further ssh
  round trip); Apple's fixed `127.0.0.1` answer with no ssh call at all.
- `tests/test_runtime_boundary_characterisation.sh` -- Apple byte-for-byte
  proof is unaffected in shape (see section 2 below) but gains the new
  `--publish` rendering's dependency on this op.

## 2. Publish rendering (item 1)

`bin/dx-create-container` (today, line ~85):

```sh
--publish "127.0.0.1:$DX_SSH_PORT:2222"
```

becomes runtime-neutral, no bind address at all:

```sh
--publish "$DX_SSH_PORT:2222"
```

Each adapter's own `container_create` renderer -- already the one place
DQ2 puts runtime-specific rendering -- prepends its own guest SSH address
to whatever spec it receives:

- **Apple** (`dx_runtime_apple_container_create`):
  `--publish) flags+=(-p "127.0.0.1:$2"); shift 2 ;;` -- a fixed literal
  prefix, not a call to the new op at all (Apple's own adapter never needs
  to ask; it already knows the answer is always loopback). This is what
  makes the characterisation's byte-for-byte expected argv
  (`-p 127.0.0.1:2222:2222` in
  `tests/test_runtime_boundary_characterisation.sh`) **unchanged** even
  though the value now arrives at the adapter one token shorter than
  before.
- **Docker-ssh** (`dx_runtime_docker_container_create`):
  `--publish) flags+=(-p "$(dx_runtime_docker_guest_ssh_address):$2"); shift 2 ;;`
  -- calls its own adapter function directly (not the dispatch-level
  `dx_runtime_guest_ssh_address`), matching how this same function already
  calls `dx_runtime_docker_require_bin` directly rather than through
  dispatch; a discovery/validation failure here propagates as a normal
  `container_create` failure (fail closed, no container created with a bad
  publish spec).

No change to `dx_runtime_container_create_parse_volume_spec` or any other
part of the runtime-neutral vocabulary in `bin/lib/dx-runtime.sh`; only the
one call site in `bin/dx-create-container` and the two adapters' own
`--publish` case arms change. The module comment in `bin/lib/dx-runtime.sh`
that today says *"left at '127.0.0.1:...' for docker-ssh too -- making the
guest SSH publish address remote-aware is qnap-dxe-plan.md Phase 5's job"*
and the matching comment in `bin/lib/dx-runtime-docker.sh` are updated to
describe the new behaviour instead of flagging it as future work.

## 3. The shared builder becomes remote-aware (items 1-3)

### 3.1 `dx_ssh_endpoint`

```sh
dx_ssh_endpoint() { printf '%s\n' "dx@$(dx_runtime_guest_ssh_address)"; }
```

Apple: `dx@127.0.0.1`, byte-identical to today. Docker-ssh: `dx@<discovered
tailnet address>`. This one change is what every other entry point below
inherits "for free", per DQ5's own text: *"The same shared SSH option
builder is still used by interactive SSH, command SSH, `dx-put`, `dx-get`,
`dx-forward`, `dx-reverse`, `dx-wait-ssh`, and Herdr... No helper gets a
one-off transport implementation."*

### 3.2 Exact list of dial sites that change

| File:line (today) | Today | Becomes |
| --- | --- | --- |
| `bin/lib/dx-ssh-common.sh:4` | `dx_ssh_endpoint() { printf '%s\n' dx@127.0.0.1; }` | calls `dx_runtime_guest_ssh_address` (section 3.1) |
| `bin/dx-wait-ssh` (`SSH_CHECK_OPTS` array + `dx@127.0.0.1` dial at the polling loop) | private 7-token array, hardcoded target | `dx_ssh_common_options` + one appended `-o BatchMode=yes` + `"$(dx_ssh_endpoint)"` (section 3.3) |
| `bin/lib/dx-tunnel.sh:108` (`dx_tunnel_control_active`, `-O check`) | `dx@127.0.0.1` | `"$(dx_ssh_endpoint)"` |
| `bin/lib/dx-tunnel.sh:223` (`dx_tunnel_start`, the `-f -N -M` master dial) | `dx@127.0.0.1`, plus its own inline `-i`/`IdentitiesOnly`/`ConnectTimeout` duplicating the shared builder | `"$(dx_ssh_endpoint)"`; the inline duplication is retired in favour of `dx_ssh_common_options` (section 3.4) |
| `bin/lib/dx-tunnel.sh:225` (`dx_tunnel_start`, cleanup on metadata-write failure, `-O exit`) | `dx@127.0.0.1` | `"$(dx_ssh_endpoint)"` |
| `bin/lib/dx-tunnel.sh:267` (`dx_tunnel_stop_socket_locked`, `-O exit`) | `dx@127.0.0.1` | `"$(dx_ssh_endpoint)"` |
| `bin/dx-status` (SSH section: `nc -z localhost "$DX_SSH_PORT"`) | hardcoded `localhost` | probes `dx_runtime_guest_ssh_address` (section 3.5) |

That is the **complete** set found by grepping `bin/` for `127\.0\.0\.1` and
`dx@` (repeated during this design pass); no other file hardcodes the guest
address.

**No code change, by design** (they already go through the shared
mechanisms above, or never dial the guest at all):

- `bin/dx-ssh` (both the interactive and the argument branch) and
  `bin/dx-herdr` (its probe/install/attach calls) already call
  `dx_ssh_endpoint`/`dx_ssh_common_options`/`dx_ssh_run_guest_command`/
  `dx_run_interactive_ssh` exclusively -- once section 3.1 changes, every
  one of these dials the correct endpoint with zero further edits. Proven,
  not assumed: Section 23's existing F10 test already asserts `dx-ssh` and
  `dx-herdr` have no private copy of the shared literals, so a
  characterisation test only needs to prove the *destination* they end up
  dialling, under a fake `ssh`, for each runtime.
- `bin/dx-put` and `bin/dx-get` never dial the guest's own SSH boundary at
  all -- they call `dx_runtime_exec`, which for `docker-ssh` is the
  **management**-plane connection (`ssh <DX_REMOTE_HOST> <docker> exec
  ...`, `bin/lib/dx-runtime-docker.sh`), a completely different connection
  from the guest's own direct SSH server this phase is making
  remote-aware. This is deliberate design from Phase 2, not a Phase 5 gap:
  `dx_runtime_exec` already dispatches correctly per runtime, and DQ5's
  guest-address work has nothing to add to it. Flagging this reading
  explicitly for the coordinating session's confirmation, since the task's
  own fact list groups `dx-put`/`dx-get` with `dx-ssh`/`dx-herdr` as
  "already go through it" -- this design note's reading is that "it" there
  means "the shared transport concept" (raw guest SSH for two of the four,
  the runtime-neutral exec contract for the other two), not that all four
  dial the same literal endpoint. If that reading is wrong, the fix is
  confined to bin/dx-put`/`bin/dx-get` only and does not change anything
  else in this section.

### 3.3 `dx-wait-ssh`

Replaces its own `SSH_CHECK_OPTS` array with the shared builder plus its
one distinctive addition (fail-fast, never prompt, even mid-poll-loop):

```sh
local ssh_opts=() opt
while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dx_ssh_common_options)"
ssh_opts+=(-o BatchMode=yes)
...
while ! ssh "${ssh_opts[@]}" "$(dx_ssh_endpoint)" "bash -lc 'true'" 2>"$PROBE_STDERR"; do
```

`BatchMode=yes` is kept as this caller's own one-line addition rather than
folded into `dx_ssh_common_options` itself, to avoid changing behaviour for
every other caller of the shared builder (interactive `dx-ssh`, `dx-herdr`,
tunnels) as a side effect of a readiness-probe-specific need. This is the
same pattern `dx_tunnel_start` already uses today for its own
`-o ExitOnForwardFailure=yes` (an addition on top of the shared options, not
a fork of them) -- not "a one-off transport implementation" (DQ5's
prohibition), just a caller-specific option appended to the one shared base.

`print_container_logs`/`print_probe_diagnosis` and the timeout/progress
logic are unchanged; only option construction and the dial target move.

### 3.4 `bin/lib/dx-tunnel.sh`

DQ5 explicitly lists `dx-forward`/`dx-reverse` among the shared builder's
callers, so this goes one step further than "just swap the hardcoded
address": `dx_tunnel_ssh_common` is rebuilt from `dx_ssh_common_options`
instead of its own separate 4-token literal list, retiring the duplicated
inline `-i "$DX_SSH_KEY" ... -o IdentitiesOnly=yes -o ConnectTimeout=...`
that `dx_tunnel_start` currently re-adds on top of it:

```sh
dx_tunnel_ssh_common() {
    DX_TUNNEL_SSH_OPTS=()
    local opt
    while IFS= read -r opt; do DX_TUNNEL_SSH_OPTS+=("$opt"); done <<<"$(dx_ssh_common_options)"
}
```

`dx_tunnel_start`'s dial becomes:

```sh
ssh -f -N -M -S "$socket" "$option" "$mapping" "${DX_TUNNEL_SSH_OPTS[@]}" -o ExitOnForwardFailure=yes "$(dx_ssh_endpoint)"
```

Net effect for Apple: the exact same 7 options plus `ExitOnForwardFailure`,
same as today, just assembled from one function instead of two plus an
inline literal -- no behaviour change, nothing for a live gate to catch.
Net effect for docker-ssh: forward/reverse tunnels now get the exact same
known-hosts pinning (section 4) as every other guest dial, instead of an
inconsistent, separately-hardcoded `StrictHostKeyChecking=no`. This
consolidation is this design note's own reading of DQ5's explicit text
("the same shared SSH option builder is still used by ... dx-forward,
dx-reverse") reconciled with the task's own point C wording, which mentions
only "dials the endpoint" for dx-tunnel.sh without spelling out the option
consolidation explicitly -- flagged here for confirmation, since it is a
slightly larger diff than the minimum "change the hardcoded address" read.
No test today pins the tunnel's literal ssh argv or option order (Section 19
is a live functional test, not a characterisation test), so this is safe to
land either way once confirmed.

**Local binds are untouched, by design (exit gate).** The `-L`/`-R` mapping
string itself, `127.0.0.1:$key_port:127.0.0.1:$peer_port`, does not change
at all: its first `127.0.0.1` is the controller-side bind address (must stay
loopback per the exit gate, "Forward and reverse tunnels still bind
controller loopback by default"), and its second `127.0.0.1` is the guest's
*own* loopback as resolved from inside the guest by the already-connected
SSH session -- unrelated to which address the outer `ssh` dialled to reach
the guest in the first place. Only the outer dial target changes.

### 3.5 `bin/dx-status`

Today: `nc -z localhost "$DX_SSH_PORT"` under a fixed
`--- SSH (localhost:$DX_SSH_PORT) ---` header, unconditionally. No test
today pins this literal text (confirmed by search), so this design unifies
the section across both runtimes on `dx_runtime_guest_ssh_address` rather
than keeping a `localhost`-only Apple special case:

```sh
dx_status_ssh_addr="$(dx_runtime_guest_ssh_address 2>&1)" || dx_status_ssh_addr=""
echo -e "\n--- SSH (${dx_status_ssh_addr:-unknown}:$DX_SSH_PORT) ---"
if [ -n "$dx_status_ssh_addr" ] && nc -z "$dx_status_ssh_addr" "$DX_SSH_PORT" 2>/dev/null; then
    echo "SSH Port $DX_SSH_PORT is OPEN on $dx_status_ssh_addr"
elif [ -n "$dx_status_ssh_addr" ]; then
    echo "SSH Port $DX_SSH_PORT is CLOSED on $dx_status_ssh_addr"
else
    echo "SSH address unavailable: $dx_status_ssh_addr_err_or_whatever_the_discovery_error_said"
fi
```

(Exact variable plumbing for the error message is an Increment 3 detail;
the important, settled shape is: address discovery failure is caught and
reported, never allowed to abort the whole script under `set -euo
pipefail` the way Finding 4/5's `set -e` deaths did in Phase 4.) For Apple
this prints `127.0.0.1` where it used to print `localhost` -- semantically
"loopback-equivalent" exactly as the task allows ("keep the visible Apple
text unchanged **if a test asserts it**"; none does) -- flagged here in
case the coordinating session would rather keep the literal word
`localhost` for Apple specifically; trivial to special-case if so.

**Existing test impact.** `tests/test_section9_host_scripts.sh`'s
docker-ssh `dx-status` fixture (the Finding 4/5 regression test, around line
851) does not today set `DXE_RUNTIME_GUEST_SSH_ADDRESS` or fake `nc`. Once
the SSH section calls the new op, that fixture needs
`DXE_RUNTIME_GUEST_SSH_ADDRESS` set to a placeholder in-range address
(assembled at runtime, never a literal dotted quad in source, matching
this file's own existing fixture conventions) added to
`run_docker_status`'s exports, plus a fake `nc` on `PATH` (a real `nc -z`
against a placeholder Tailscale address in a CI sandbox is not reliably
fast/deterministic) -- an Increment 3 test-maintenance item, not new
production risk.

## 4. Known-hosts pinning for docker-ssh (item 8)

`dx_ssh_common_options` becomes runtime-conditional. Apple's branch is
byte-for-byte unchanged; docker-ssh's branch swaps the two options that
today disable host-key verification entirely:

```sh
dx_ssh_common_options() {
    if [ "${DX_RUNTIME:-apple}" = docker-ssh ]; then
        dx_ssh_known_hosts_prepare || return 1
        printf '%s\n' \
            -i "$DX_SSH_KEY" -p "$DX_SSH_PORT" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$(dx_ssh_known_hosts_path)" \
            -o IdentitiesOnly=yes -o LogLevel=ERROR \
            -o ConnectTimeout="$DX_SSH_CONNECT_TIMEOUT"
    else
        printf '%s\n' \
            -i "$DX_SSH_KEY" -p "$DX_SSH_PORT" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes -o LogLevel=ERROR \
            -o ConnectTimeout="$DX_SSH_CONNECT_TIMEOUT"
    fi
}
```

**Layout**, exactly as the task settles it:
`${XDG_STATE_HOME:-$HOME/.local/state}/dxe/<profile-id>/known_hosts`, where
`<profile-id>` reuses `dx_runtime_docker_profile_id`'s existing
`<DX_REMOTE_HOST>__<DX_CONTAINER_NAME>` value (the same identity segment
Phase 2 item 7 already uses to scope tunnel/mount/backup local state --
reused, not a new naming scheme). Two new small helpers in
`bin/lib/dx-ssh-common.sh`:

```sh
dx_ssh_known_hosts_dir() { printf '%s/dxe/%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$(dx_runtime_docker_profile_id)"; }
dx_ssh_known_hosts_path() { printf '%s/known_hosts\n' "$(dx_ssh_known_hosts_dir)"; }
dx_ssh_known_hosts_prepare() {
    local dir; dir="$(dx_ssh_known_hosts_dir)"
    [ ! -L "$dir" ] || { echo "Error: refusing symlinked SSH known-hosts directory $dir." >&2; return 1; }
    if [ ! -e "$dir" ]; then mkdir -p "$dir" 2>/dev/null || [ -d "$dir" ] || return 1; fi
    [ ! -L "$dir" ] && [ -d "$dir" ] || { echo "Error: SSH known-hosts path is not a safe directory: $dir." >&2; return 1; }
    [ "$(dx_path_uid "$dir")" = "$(id -u)" ] || { echo "Error: SSH known-hosts directory is not owned by the current user: $dir." >&2; return 1; }
    chmod 0700 "$dir"
}
```

(`dx_path_uid` already exists in `bin/lib/dx-host-util.sh`, used by
`dx-tunnel.sh`'s own `dx_tunnel_prepare_state` for the identical
symlink/ownership safety shape -- reused, not duplicated, per the standing
"reuse existing helpers first" rule.) The file itself is never created
empty in advance; `ssh`'s own `accept-new` behaviour creates it (and
appends to it) on first successful connection.

**First contact / mismatch / remedy.** This is standard OpenSSH behaviour
once a real (non-`/dev/null`) known-hosts file and `accept-new` are in
place, not custom logic this branch writes: first connection to a
not-yet-known host records its key and proceeds; a later connection whose
presented key does not match the recorded one is refused by `ssh` itself,
and OpenSSH's own refusal message already names the known-hosts file, the
offending line, and the exact remedy
(`ssh-keygen -R '[<addr>]:<port>' -f <file>`) without any wrapping needed
here. `-o LogLevel=ERROR` (kept for both runtimes) does not suppress this:
host-key-mismatch is a security-critical warning OpenSSH always prints
regardless of `LogLevel`. **This is exactly the class of thing Phase 4's
evidence doc found fakes cannot see** (Go-template semantics there; real
OpenSSH host-key verification semantics here) -- a fake `ssh` can prove the
*rendered options* (`accept-new`, the per-profile path, never `/dev/null`
under docker-ssh) but not the real first-contact/mismatch/remedy behaviour
itself, which is a live-gate-only proof, explicitly listed in this task's
Validation section ("the pin's first/second contact").

**Apple is unaffected**: its branch of `dx_ssh_common_options` is
byte-for-byte what exists today, and Apple's guest is destroyed/recreated
constantly, so pinning its host key would be pure churn, not a real
guarantee -- consistent with `qnap-dxe-plan.md`'s existing text ("Before
production cutover, persist the guest's SSH host identity and stop using
`StrictHostKeyChecking=no` for the **QNAP** profile" -- QNAP-specific, by
design).

## 5. `dx-enter` through remote exec: the TTY rule (item 5)

Today, `dx_runtime_docker_exec` (`bin/lib/dx-runtime-docker.sh`) forwards
every flag straight through to the remote `docker exec` invocation but never
adds anything to the **outer** `ssh` call itself:

```sh
dx_runtime_docker_exec() {
    local bin
    bin="$(dx_runtime_docker_require_bin)" || return 1
    dx_runtime_docker_ssh_exec "$bin" exec "$@"
}
```

`bin/dx-enter` is the **only** caller that ever passes `-it`
(`dx_runtime_exec -it "$DX_CONTAINER_NAME" bash -l` /
`bash -lc "..."`) -- every other caller (`dx-gc`, `dx-reclaim`,
`dx-status`, `bin/lib/dx-backup.sh`, ...) passes `-i` alone, `-u USER`
alone, both, or neither, never `-t`/`-it`. `docker exec -it` requests a
pty from the *remote* Docker daemon, but the *SSH transport itself* also
needs `-t` (pty request on the ssh session) for that remote pty to be
usable end-to-end -- today nothing adds it, so `dx-enter` over `docker-ssh`
would attach to a docker-side pty through a non-pty ssh channel.

**Fix**, confined to `dx_runtime_docker_exec` (no other call site's shape
changes): parse only the *leading* flag tokens (name/user/tty flags always
precede the container name in every existing call, the same convention
`dx_runtime_apple_container_create`'s own `while case` flag parser already
follows), and force pty allocation on the ssh transport with `-tt` rather
than a single `-t` when one of them requests a TTY:

```sh
dx_runtime_docker_exec() {
    local bin flags=() tty=false
    bin="$(dx_runtime_docker_require_bin)" || return 1
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -it|-ti|-t) tty=true; flags+=("$1"); shift ;;
            -i)         flags+=("$1"); shift ;;
            -u)         flags+=("$1" "$2"); shift 2 ;;
            *) break ;;
        esac
    done
    if [ "$tty" = true ]; then
        local ssh_opts=() opt
        while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dx_runtime_docker_ssh_option_argv)"
        ssh_opts+=(-tt)
        ssh "${ssh_opts[@]}" "${DX_REMOTE_HOST:?}" "$(dx_runtime_docker_quote_argv "$bin" exec "${flags[@]}" "$@")"
    else
        dx_runtime_docker_ssh_exec "$bin" exec "${flags[@]}" "$@"
    fi
}
```

**Why `-tt` (force) and not a single `-t`.** OpenSSH's own manual is
explicit: a single `-t` requests a pty but does not force it when the ssh
client's own local stdin is not itself a real terminal; **multiple `-t`
options force tty allocation even if ssh has no local tty.** `dx-enter`
always passes `-it` regardless of whether *its own* invocation is run
under a real terminal or driven non-interactively (a script, a test
harness with piped stdin) -- exactly the "`dx-enter <cmd>` non-interactive
must work over docker-ssh" requirement. A single `-t` would make that
depend on the *ssh client's* local tty state, not on what the caller
actually asked docker for; `-tt` makes it unconditional, matching
`docker exec -it`'s own unconditional pty request. This is a fake-provable
argv fact (does the rendered ssh invocation contain `-tt` exactly when `-t`
or `-it` was requested, never otherwise) plus a live-gate fact (does a real
pty genuinely attach end-to-end) -- the argv half is this phase's job, the
live half is the coordinating session's.

**"Never otherwise" (Branch 17 discipline, preserved).** Every exec call
that is not `dx-enter` never passes `-t`/`-it`, so `tty` stays `false` and
the existing `dx_runtime_docker_ssh_exec "$bin" exec "$@"` path -- and its
existing stdin/exit-status passthrough proof -- is completely untouched.
`bin/lib/dx-backup.sh`'s unidirectional-exec split (Branch 17, section 6 of
`docker-adapter-mapping.md`) is unaffected: none of its calls request a
TTY.

## 6. Atomic `dx-export` (item 6)

`bin/dx-export` today:

```sh
dx_runtime_export "$DX_CONTAINER_NAME" > "$EXPORT_FILE"
```

A mid-stream failure or an interrupted run today leaves a truncated (or
zero-byte) `$EXPORT_FILE` in place, indistinguishable from a real complete
export. New shape: stream to a `.partial` sibling in the same directory,
verify it is non-empty, then rename into place; a trap removes the partial
on any exit path that is not the successful rename:

```sh
partial="$EXPORT_FILE.partial"
cleanup_partial() { rm -f "$partial"; }
trap cleanup_partial EXIT HUP INT TERM
dx_runtime_export "$DX_CONTAINER_NAME" > "$partial"
[ -s "$partial" ] || { echo "Error: export produced an empty archive." >&2; exit 1; }
mv "$partial" "$EXPORT_FILE"
trap - EXIT HUP INT TERM
```

The existing `container_exists` refusal (before touching any file at all)
is unchanged and still runs first, so
`tests/test_runtime_boundary_characterisation.sh`'s existing "refuses a
nonexistent container before touching the output file" proof needs no
change. `set -euo pipefail` already means `dx_runtime_export ... > "$partial"`
failing non-zero aborts the script before the `mv`, and the `EXIT` trap
still fires and removes the partial -- the same mechanism `bin/dx-mount`'s
`release_pending_claim`/`bin/dx-create-container`'s
`release_pending_claim` already use for "clean up on any exit path" today,
reused rather than a new idiom. Same behaviour on both runtimes: this file
never branches on `DX_RUNTIME` itself, since `dx_runtime_export` already
dispatches correctly.

New characterisation coverage (Increment 5): a fake `container`/`docker`
whose `export` verb writes partial bytes then exits non-zero -- proves no
final file and no leftover `.partial` after a failure; a signal sent to a
slow fake export mid-stream -- proves the trap cleans the partial on
interruption too, matching the Test Strategy's existing "stdin streaming
with producer failure ... short read, and connection loss" scope, applied
to the export direction.

## 7. Fail-closed capability checks (item 7)

### 7.1 `bin/dx-mount` -- `bind_mounts`

DQ8, verbatim: *"`dx-mount DIR`: Unsupported in the first QNAP release; fail
before runtime mutation because a controller path is not a remote bind
source."* `dx_runtime_docker_capability bind_mounts` already answers `no`
(Phase 2); nothing in `bin/dx-mount` asks it
(`docs/refactor/docker-adapter-mapping.md`'s "Flagged for review" item 4,
found during Phase 2, deferred to whoever owns `bin/dx-mount` -- this
phase). The capability query itself is a pure local table lookup, no
network round trip for either runtime, so it can refuse before
`dx_require_container_cli` is even reached:

```sh
dx_runtime_capability bind_mounts || fail "dx-mount is not supported under DX_RUNTIME=${DX_RUNTIME:-apple}: a controller-local directory is never a valid remote bind source (qnap-dxe-plan.md DQ8)."
dx_require_container_cli
```

placed as the first line of the file's final (create/attach) block, i.e.
after the `--print-env`/`--audit-manifests`/`--migrate-manifests`/
`--destroy`/`--print-destroy-plan` branches (none of which create a bind
mount; each already exits on its own). `fail()` is the helper already
defined at the top of `bin/dx-mount`.

**Scope note, flagged rather than acted on.** `DX_GIT_MOUNT_SOURCE` is a
plain registered config field (`bin/lib/dx-config.sh`), settable directly
by any profile or environment, and `bin/dx-create-container` itself adds
`--volume git:...` whenever it is non-empty, regardless of runtime -- so a
profile that sets `DX_GIT_MOUNT_SOURCE` directly and runs `./bin/dx`
(bypassing `bin/dx-mount` entirely) is not covered by this guard, and
`dx_runtime_docker_container_create`'s own `--volume` flag parsing does not
discriminate the `git` role from any other role before rendering it as a
literal Docker bind spec. This is a real gap one level broader than what
this task's design point G asks for (which names exactly `dx-mount`,
`dx-nix-disk`, and `dx-reclaim`'s trim skip); flagged here per "decisions
are not yours," not fixed, since fixing it would mean touching
`bin/dx-create-container`/`bin/lib/dx-runtime-docker.sh`'s volume handling,
outside what this design point authorises.

### 7.2 `bin/dx-nix-disk` -- new capability `raw_nix_disk`

DQ8, verbatim: *"`dx-nix-disk`: Apple-only; fail immediately with a clear
capability message."* A new capability, added to both adapters' fixed
tables and the dispatch:

- `dx_runtime_apple_capability`: `raw_nix_disk` returns true (alongside
  `direct_named_volume_mounts`, `bind_mounts`, `host_filesystem_reclamation`).
- `dx_runtime_docker_capability`: `raw_nix_disk` returns false (alongside
  `bind_mounts`, `host_filesystem_reclamation`).

`bin/dx-nix-disk` (which today makes no `dx_runtime_*` call of any kind --
it is pure host-filesystem `truncate`/`mkdir`) gains a guard as its first
executable check, before the existing "already exists, skipping" branch,
so the message is unconditional rather than only shown once a fresh disk
is actually attempted:

```sh
dx_runtime_capability raw_nix_disk || { echo "Error: dx-nix-disk is Apple-only: DX_RUNTIME=${DX_RUNTIME:-apple} has no raw_nix_disk capability (qnap-dxe-plan.md DQ8)." >&2; exit 1; }
```

Both new capability rows are added to `docs/refactor/docker-adapter-mapping.md`
section 4's capability table and `docs/refactor/runtime-boundary-inventory.md`'s
capability discussion, alongside the existing four.

### 7.3 `bin/dx-reclaim` -- no change

Phase 3 already made the trim skip capability-aware
(`dx_runtime_capability host_filesystem_reclamation`); item 7's mention of
"unsupported reclaim operations" is satisfied by what already exists.
Increment 6 adds no new code here, only a regression characterisation
confirming the existing skip message and behaviour are unchanged by
anything else in this phase.

## 8. How the live gate runs (once "READY FOR LIVE")

Per this task's Validation section and the standing rules: the coordinating
session runs the Apple `dx-test` live tier (unchanged scope, since nothing
here alters Apple's rendered argv or SSH options) and, on the NAS, a
disposable guest reached directly on its Tailscale address for: `dx-wait-ssh`
reaching the real guest; interactive and command SSH; `dx-put`/`dx-get`
(unaffected, but re-confirmed against the real management path); a
forward and a reverse tunnel including lock/socket cleanup; `dx-enter
<cmd>` non-interactively and (if a real terminal is available to the
session driving it) interactively; an atomic `dx-export` including an
interrupted run; both new refusals (`dx-mount` under `docker-ssh`,
`dx-nix-disk` under `docker-ssh`); the LAN-unreachability check (guest port
2222 closed from a LAN-only vantage point); and the known-hosts pin's first
contact followed by a deliberate mismatch to prove the refusal and remedy
text. The "from an external network" check stays the user's own, later
step (unchanged from the task). Every test file in this phase's touched set
runs both bare and under `./bin/dx-profile dx-test <file> --skip-integration`,
per Phase 4's lesson that the live-tier profile environment can change a
test's outcome (the Section 17/20 agy-pin finding).

## Summary of files touched (Increments 1-7)

`bin/lib/dx-runtime.sh`, `bin/lib/dx-runtime-apple.sh`,
`bin/lib/dx-runtime-docker.sh`, `bin/lib/dx-ssh-common.sh`,
`bin/lib/dx-tunnel.sh`, `bin/dx-wait-ssh`, `bin/dx-status`,
`bin/dx-create-container`, `bin/dx-export`, `bin/dx-mount`,
`bin/dx-nix-disk`; tests: `tests/test_docker_runtime_adapter.sh`,
`tests/test_runtime_boundary_characterisation.sh`,
`tests/test_section9_host_scripts.sh`, plus bash-3.2/ShellCheck/coverage
re-runs; docs: `docs/refactor/runtime-boundary.md`,
`docs/refactor/runtime-boundary-inventory.md`,
`docs/refactor/docker-adapter-mapping.md`, `docs/lifecycle.md`,
`qnap-dxe-plan.md`, `checkout-consolidation-plan.md`,
`tests/profiles/qnap-example.env`. No `.nix` file changes anywhere in this
phase.

## Flagged for coordinating-session review (summary)

Collected from the sections above, none blocking Increment 1's start:

1. `bin/dx-put`/`bin/dx-get` need no code change (section 3.2) -- confirm
   this reading of the task's fact list.
2. `bin/lib/dx-tunnel.sh`'s option-array consolidation onto
   `dx_ssh_common_options` (section 3.4) goes slightly beyond the task's
   literal "dials the endpoint" wording, justified by DQ5's explicit text;
   confirm.
3. `dx-status`'s Apple SSH-section text changes from the literal word
   `localhost` to `127.0.0.1` (section 3.5), since no test pins the former;
   confirm, or keep `localhost` as an Apple-only special case.
4. `DX_GIT_MOUNT_SOURCE` set directly (bypassing `bin/dx-mount`) is not
   covered by the new `bind_mounts` guard (section 7.1) -- out of this
   design point's authorised scope; flagged, not fixed.
5. The known-hosts mismatch/remedy message is native OpenSSH behaviour,
   provable only at the live gate, not by a fake `ssh` (section 4).
