#!/bin/bash
# No `-e`: many scenarios here deliberately capture a non-zero exit status
# from a dx_runtime_docker_* call (bare `out="$(...)"; rc=$?`, the same
# convention tests/test_runtime_boundary_characterisation.sh and
# tests/test_section16_persist_storage.sh use for the same reason).
set -uo pipefail

# Branch 11 / Phase 2 (qnap-dxe-plan.md Phase 2) -- the docker-ssh runtime
# adapter (bin/lib/dx-runtime-docker.sh), developed and tested entirely
# against a fake `ssh` (tests/lib/fake-tools.sh's fake_qnap_ssh_write) and
# fake `docker` executables. The real NAS is production and off-limits;
# nothing here ever contacts it. See docs/refactor/docker-adapter-mapping.md
# for the command-by-command design this file characterises.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"
# Branch 11 / Phase 5: needed directly by this file's own known-hosts
# pinning tests (dx_ssh_common_options, dx_ssh_known_hosts_prepare), and by
# bin/lib/dx-tunnel.sh's dial sites, exactly as bin/dx-lib.sh sources it.
source "$BASE_DIR/bin/lib/dx-ssh-common.sh"
source "$BASE_DIR/bin/lib/dx-tunnel.sh"
source "$BASE_DIR/bin/lib/dx-backup.sh"
# Branch 11 / Phase 5's drift guard (below) needs Phase 0's own discovery
# functions available for direct comparison against bin/lib/dx-runtime-docker.sh's
# fresh production copies of them; this is the only place in tests/ that
# needs both a production adapter and this file loaded together.
source "$SCRIPT_DIR/qnap/lib/phase0-common.sh"
#
# tier: unit
# bash32: yes
#
# Fable D6 step 1: docker-ssh runtime adapter, lifecycle part --
# container/image lifecycle (create/start/stop/kill/delete), the first-run
# image guard,
# dx-create-volumes/dx-destroy-container/dx-destroy-image/dx-migrate-persist
# run as real entrypoints through the adapter, dx-destroy-volumes, and
# dx-factory-reset.
#
# Runnable standalone: bash tests/test_docker_adapter_lifecycle.sh
# (prints its own banner and its own Results line for just its own
# cases). tests/test_docker_runtime_adapter.sh sources this file, in
# order with its four siblings, as section 33's one registered entry;
# sourced that way, this file prints no banner of its own and defers
# print_summary/exit_with_code to the aggregate, so section 33 still
# reports one combined Results line for all 208 cases.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    test_section "Docker-ssh runtime adapter (Branch 11 / Phase 2) -- lifecycle"
fi

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-docker-adapter.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

# WP3.4 (Fable A1): dx_runtime_docker_discover_daemon_id now persists a
# per-profile daemon-identity cache under
# "${XDG_STATE_HOME:-$HOME/.local/state}/dxe/$DX_CONTAINER_NAME/host-identity"
# on every successful discovery, so dx_runtime_host_identity can resolve
# the same identity (and therefore the same tunnel/backup/known-hosts
# paths) without dialling again. Give this file's own docker-ssh scenarios
# a private HOME (never the developer's real one -- the known-hosts
# pinning tests below already isolate HOME for the identical reason, and
# every scenario in this file that reaches a live discovery goes through
# new_tool_dir, below, which also clears this cache before each scenario
# so an earlier scenario's cached id can never mask a later scenario's own
# fixture failing to be exercised).
dxe_adapter_home="$fixture/home"
mkdir -p "$dxe_adapter_home"
unset XDG_STATE_HOME
export HOME="$dxe_adapter_home"

expect_ok() { local label="$1"; shift; if "$@"; then test_pass "$label"; else test_fail "$label"; fi; }
expect_reject() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then test_fail "$label"; else test_pass "$label"; fi; }

# Every fixture directory gets its own fake `uname` (x86_64, matching
# DX_GUEST_SYSTEM=x86_64-linux's default in these tests) so preflight's
# architecture check never falls through to this real Mac's own `uname -m`
# (which would report "arm64" -- Apple's own naming, and wrong even on the
# rare occasion this host happens to be aarch64, since Linux and Darwin
# spell the same architecture differently). A test that wants a different
# or missing answer overwrites this file afterward. PATH is always set to
# "$dir:/usr/bin:/bin" (never a bare "$dir:$PATH" prefix) so a real docker
# or uname installed on the developer's own Mac (Docker Desktop, OrbStack,
# ...) can never be found ahead of, or instead of, a fixture's own fakes.
new_tool_dir() {
    local dir
    dir="$(fake_tool_dir_create "$fixture")"
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    # WP3.4 (Fable A1): clear any daemon-identity cache a PRIOR scenario in
    # this file left on disk (under the private HOME set up above) before
    # a new scenario starts, so this scenario's own fake ssh/docker is
    # actually exercised rather than silently short-circuited by another
    # scenario's already-cached id. A real filesystem side effect, not a
    # shell-variable one, so it survives this function running inside the
    # "$(...)" command substitution every call site uses.
    rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/dxe" 2>/dev/null || true
    printf '%s' "$dir"
}

# Symlinks the REAL system awk/cut/head (resolved once via `command -v` on
# THIS host, never guessed at) into a fixture directory, so a test whose
# DXE_FAKE_SSH_REMOTE_PATH is pinned to that directory alone (excluding
# every real system PATH entry, per the standing "never let a real docker
# leak in from /usr/bin" incident) still has the plain, side-effect-free
# text tools bin/lib/dx-runtime-docker.sh's Tailscale-address discovery
# pipes through, without ever widening the remote PATH enough for a real
# `tailscale` (or `docker`) to be found instead of the fixture's own fake.
link_coreutils_into() {
    local dir="$1" tool real
    shift
    for tool in "$@"; do
        real="$(command -v "$tool")" || { echo "test setup: no real '$tool' found on this host" >&2; return 1; }
        ln -sf "$real" "$dir/$tool"
    done
}

# Assembles a placeholder Tailscale-range address (Branch 11 / Phase 5)
# from separate numeric parts, never as a literal dotted quad in this
# file's own source text -- the same discipline
# tests/test_section1_secrets.sh's own planted fixture already uses, so
# these fixtures can never trip that file's Tailscale-range leak scan.
tailnet_fixture_addr() { printf '%s.%s.%s.%s' 100 "$1" "$2" "$3"; }


# --- Lifecycle (item 4) -----------------------------------------------------

# container_create: renders bin/lib/dx-runtime.sh's runtime-neutral
# vocabulary into Docker's own create argv (qnap-dxe-plan.md DQ2/DQ4/DQ6).
#
# The rendering runs inside the subshell below, but every test_pass/
# test_fail call for it is deliberately OUTSIDE that subshell (F6's own
# lesson, tests/test_refactor_contracts.sh: a counter incremented inside a
# "( … )" subshell dies with it, so a real failure in one of these many
# assertions would print its red line but never flip the suite's own exit
# code) -- $got is read back from the argv log file, which does survive
# the subshell exiting, precisely so these ~10 assertions all count.
cc_argv_log="$fixture/create-argv.log"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" tailscale 'case "$*" in
    "ip -4") printf "%s.%s.%s.%s\n" 100 64 1 2 ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    fake_tool_write "$dir" docker "
[ \"\$1\" = create ] || { echo UNMATCHED >&2; exit 99; }
shift
printf '%s\n' \"\$@\" > '$cc_argv_log'
"
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    unset DXE_RUNTIME_GUEST_SSH_ADDRESS
    # --publish is the neutral "PORT:2222" spec (Branch 11 / Phase 5, DQ5):
    # no bind address at all -- the adapter itself prepends the discovered
    # guest SSH address (below) before rendering Docker's real -p flag.
    dx_runtime_container_create \
        --name dx-qnap --image dx-qnap-nixos \
        --volume nix:dx-qnap-nix:rw \
        --volume persist:dx-qnap-persist:/persist:rw \
        --volume bootstrap:dx-qnap-bootstrap:/guest-bootstrap:rw \
        --env HOST_TZ=UTC --memory 12G --cpus 4 --publish 2222:2222 \
        --restart-policy unless-stopped \
        --health-cmd 'ls /guest-bootstrap/.locks/leases/*' --health-interval 10s --health-retries 3 \
        --entrypoint-cmd 'echo hi' --entrypoint-arg /guest-bootstrap
)
got="$(cat "$cc_argv_log" 2>/dev/null)"
# A single fixed string, not a two-line "-p"/"<value>" pair: grep treats a
# pattern argument containing an embedded newline as MULTIPLE patterns
# (one per line), matching if EITHER one is found anywhere -- a bare "-p"
# line alone would already satisfy that, even rendered with no address at
# all, so it would not actually distinguish old and new behaviour. The
# composed value below is distinctive enough alone: nothing else in this
# argv could render "<tailnet addr>:2222:2222" except -p's own value.
# (Assembled via tailnet_fixture_addr, never a literal dotted quad, so
# this file's own source text can never match the leak scan it exists to
# satisfy.)
printf '%s\n' "$got" | stdin_matches -F -- "$(tailnet_fixture_addr 64 1 2):2222:2222" && test_pass "container_create (docker-ssh) renders --publish with the discovered guest SSH address, never loopback (DQ5)" \
    || test_fail "container_create (docker-ssh) renders --publish with the discovered guest SSH address (got: $got)"
printf '%s\n' "$got" | stdin_matches -F -- "CAP_SYS_ADMIN" && test_fail "container_create never grants CAP_SYS_ADMIN (DQ4)" || test_pass "container_create never grants CAP_SYS_ADMIN (DQ4)"
printf '%s\n' "$got" | stdin_matches -F -- "--cpus" && printf '%s\n' "$got" | stdin_matches -F -- "4" && test_pass "container_create renders --cpus N, never Docker's own -c (cpu-shares)" || test_fail "container_create renders --cpus N, never Docker's own -c (cpu-shares)"
printf '%s\n' "$got" | stdin_matches -F -- "dx-qnap-nix:/nix:rw" && test_pass "container_create mounts the Nix volume directly at /nix (DQ4)" || test_fail "container_create mounts the Nix volume directly at /nix (DQ4)"
printf '%s\n' "$got" | stdin_matches -F -- "dx-qnap-persist:/persist:rw" && test_pass "container_create mounts the persist volume at /persist" || test_fail "container_create mounts the persist volume at /persist"
printf '%s\n' "$got" | stdin_matches -F -- "dx-qnap-bootstrap:/guest-bootstrap:rw" && test_pass "container_create mounts the bootstrap volume at its configured path" || test_fail "container_create mounts the bootstrap volume at its configured path"
printf '%s\n' "$got" | stdin_matches -F -- "--restart" && printf '%s\n' "$got" | stdin_matches -F -- "unless-stopped" && test_pass "container_create renders --restart from DX_CONTAINER_RESTART_POLICY" || test_fail "container_create renders --restart from DX_CONTAINER_RESTART_POLICY"
# Branch 11 / Phase 6 (qnap-dxe-plan.md Phase 6 item 4): Docker's own flag
# names verbatim, no translation -- see bin/lib/dx-runtime.sh's vocabulary
# comment.
printf '%s\n' "$got" | stdin_matches -F -- "--health-cmd" && printf '%s\n' "$got" | stdin_matches -F -- "ls /guest-bootstrap/.locks/leases/*" && test_pass "container_create renders --health-cmd verbatim" || test_fail "container_create renders --health-cmd verbatim (got: $got)"
printf '%s\n' "$got" | stdin_matches -F -- "--health-interval" && printf '%s\n' "$got" | stdin_matches -F -- "10s" && test_pass "container_create renders --health-interval verbatim" || test_fail "container_create renders --health-interval verbatim (got: $got)"
printf '%s\n' "$got" | stdin_matches -F -- "--health-retries" && printf '%s\n' "$got" | stdin_matches -F -- "3" && test_pass "container_create renders --health-retries verbatim" || test_fail "container_create renders --health-retries verbatim (got: $got)"
printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.managed=true" && printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.role=container" && printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.profile=qnap-dxe__dx-qnap" && test_pass "container_create carries the DQ6 labels" || test_fail "container_create carries the DQ6 labels"
printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.system=x86_64-linux" && test_pass "container_create carries the io.dxe.system label (Branch 11 / Phase 4)" || test_fail "container_create carries the io.dxe.system label (Branch 11 / Phase 4)"
printf '%s\n' "$got" | stdin_matches -F -- "--name" && test_pass "container_create keeps --name" || test_fail "container_create keeps --name"
printf '%s\n' "$got" | stdin_matches -F -- "-c
echo hi
--
/guest-bootstrap" && test_pass "container_create passes the post-image entrypoint argv through completely unexamined" || test_fail "container_create passes the post-image entrypoint argv through completely unexamined"

# container_create: an unrecognized parameter fails closed rather than
# guessing (protects against a future bin/dx-create-container change that
# forgets to update both adapters).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "docker should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_container_create --totally-unknown-flag value --name dx-qnap --image dx-qnap-nixos 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "unknown parameter"
)
[ "$?" -eq 0 ] && test_pass "container_create fails closed on an unrecognized parameter rather than guessing" || test_fail "container_create fails closed on an unrecognized parameter rather than guessing"

# container_create: --publish refuses (DQ5) BEFORE any docker call at all
# when the guest SSH address cannot be discovered -- never a container
# created with a malformed or missing publish spec. The management ssh
# itself must keep working here (a hard-failing fake ssh would make the
# LATER "docker create" round trip fail too, passing this test for the
# wrong reason -- an unrelated transport failure, not specifically DQ5's
# refusal): no tailscale binary anywhere, no working "ip" either, so
# discovery genuinely runs and comes back NOTFOUND, and a real, working
# fake `docker create` sits ready to prove it was never reached.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    export DXE_FAKE_SSH_REMOTE_PATH="$dir"
    create_reached_log="$fixture/refuse-create-reached.log"
    rm -f "$create_reached_log"
    fake_tool_write "$dir" docker "
[ \"\$1\" = create ] && echo reached >> '$create_reached_log'
exit 0
"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    DXE_RUNTIME_DOCKER_BIN=docker
    unset DXE_RUNTIME_GUEST_SSH_ADDRESS
    out="$(dx_runtime_container_create --name dx-qnap --image dx-qnap-nixos --publish 2222:2222 --entrypoint-cmd 'echo hi' 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ ! -f "$create_reached_log" ] && printf '%s\n' "$out" | stdin_matches -F -- "DQ5 forbids publishing on the LAN or 0.0.0.0."
)
[ "$?" -eq 0 ] && test_pass "container_create (docker-ssh) refuses --publish before any docker call when the guest SSH address cannot be discovered (DQ5)" \
    || test_fail "container_create (docker-ssh) refuses --publish before any docker call when the guest SSH address cannot be discovered (DQ5)"

# container_create: an unrecognized --volume role also fails closed.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "docker should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_container_create --name dx-qnap --image dx-qnap-nixos --volume bogus:vol:rw 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "unrecognized --volume spec"
)
[ "$?" -eq 0 ] && test_pass "container_create fails closed on an unrecognized --volume role" || test_fail "container_create fails closed on an unrecognized --volume role"

# Astra F3's "writable attachment" checkpoint: container_create itself (not
# only container_ensure_volume's own adoption gate) refuses to mount an
# EXISTING but foreign/unlabelled nix volume rw into a new container --
# zero "docker create ... -v/--volume" call is ever reached, proven by the
# fake exiting loudly if "create" is ever invoked.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "volume inspect") echo "<no value>|<no value>|<no value>|<no value>|<no value>"; exit 0 ;;
esac
case "$1" in
    create) echo "docker create should never mount a foreign volume" >&2; exit 99 ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux DX_NIX_VOLUME=dx-qnap-nix
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_container_create --name dx-qnap --image dx-qnap-nixos \
        --volume "nix:dx-qnap-nix:rw" --entrypoint-cmd 'echo hi' 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "container_create (docker-ssh): refuses to attach an EXISTING foreign nix volume, zero docker create calls reached" \
    || test_fail "container_create (docker-ssh): refuses to attach an EXISTING foreign nix volume, zero docker create calls reached"

# The same "writable attachment" checkpoint, for the OTHER two configured
# named volumes (persist/bootstrap), which share the switch's default arm
# rather than the nix branch's own dedicated case label above.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "volume inspect") echo "<no value>|<no value>|<no value>|<no value>|<no value>"; exit 0 ;;
esac
case "$1" in
    create) echo "docker create should never mount a foreign volume" >&2; exit 99 ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux DX_PERSIST_VOLUME=dx-qnap-persist
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_container_create --name dx-qnap --image dx-qnap-nixos \
        --volume "persist:dx-qnap-persist:/persist:rw" --entrypoint-cmd 'echo hi' 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "container_create (docker-ssh): refuses to attach an EXISTING foreign persist/bootstrap volume, zero docker create calls reached" \
    || test_fail "container_create (docker-ssh): refuses to attach an EXISTING foreign persist/bootstrap volume, zero docker create calls reached"

# An ABSENT volume needs no ownership proof (nothing to adopt yet); the
# create proceeds normally.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "volume inspect") exit 1 ;;
esac
case "$1" in
    create) exit 0 ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux DX_NIX_VOLUME=dx-qnap-nix
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_create --name dx-qnap --image dx-qnap-nixos \
        --volume "nix:dx-qnap-nix:rw" --entrypoint-cmd 'echo hi'
)
[ "$?" -eq 0 ] && test_pass "container_create (docker-ssh): an ABSENT nix volume needs no ownership proof and the create still succeeds" \
    || test_fail "container_create (docker-ssh): an ABSENT nix volume needs no ownership proof and the create still succeeds"

# container_create: --name/--image are required.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "docker should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_container_create --image dx-qnap-nixos 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches -- "--name is required"
)
[ "$?" -eq 0 ] && test_pass "container_create refuses when --name is missing" || test_fail "container_create refuses when --name is missing"

# Astra F3: start/stop/kill now run the owned-resource check first, so
# even a plain passthrough scenario must fake a "container inspect
# --format ..." call proving ownership before the real verb -- the fakes
# below match on "$1 $2" (container/inspect), leaving the real verb
# matched on "$1" alone, same shape as the delete tests further down.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "true|1|qnap-dxe__dx-qnap|container|x86_64-linux" ;;
    *) [ "$1" = start ] && [ "$2" = dx-qnap ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_start dx-qnap
)
[ "$?" -eq 0 ] && test_pass "container_start: owned -> passthrough" || test_fail "container_start: owned -> passthrough"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "true|1|qnap-dxe__dx-qnap|container|x86_64-linux" ;;
    *) [ "$1" = stop ] && [ "$2" = --time ] && [ "$3" = 5 ] && [ "$4" = dx-qnap ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_stop --time 5 dx-qnap
)
[ "$?" -eq 0 ] && test_pass "container_stop: owned -> --time N NAME passthrough (Docker and Apple agree)" || test_fail "container_stop: owned -> --time N NAME passthrough (Docker and Apple agree)"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "true|1|qnap-dxe__dx-qnap|container|x86_64-linux" ;;
    *) [ "$1" = kill ] && [ "$2" = dx-qnap ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_kill dx-qnap
)
[ "$?" -eq 0 ] && test_pass "container_kill: owned -> passthrough" || test_fail "container_kill: owned -> passthrough"

# Astra F3 item 1: start/stop/kill against a FOREIGN or unlabelled running
# container issue ZERO real start/stop/kill calls -- only the ownership
# inspect is ever reached -- and each refuses non-zero, naming the
# ownership mismatch. Proven at the fake-transcript level (call count),
# not merely by exit status, exactly what the regression asks for.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    calls_log="$dir/mutating-calls.log"
    : > "$calls_log"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "false|||"; exit 0 ;;
esac
case "$1" in
    start|stop|kill) printf "%s\n" "$*" >> "'"$calls_log"'"; echo "docker $1 should never run on a foreign container" >&2; exit 99 ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    start_out="$(dx_runtime_container_start dx-qnap 2>&1)"; start_rc=$?
    stop_out="$(dx_runtime_container_stop dx-qnap 2>&1)"; stop_rc=$?
    kill_out="$(dx_runtime_container_kill dx-qnap 2>&1)"; kill_rc=$?
    [ "$start_rc" -ne 0 ] && [ "$stop_rc" -ne 0 ] && [ "$kill_rc" -ne 0 ] \
        && [ ! -s "$calls_log" ] \
        && printf '%s\n' "$start_out" | stdin_matches "collision, not an adoption candidate" \
        && printf '%s\n' "$stop_out" | stdin_matches "collision, not an adoption candidate" \
        && printf '%s\n' "$kill_out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "container_start/stop/kill: a foreign same-named container receives ZERO real start/stop/kill calls, refusing non-zero and naming the ownership mismatch" \
    || test_fail "container_start/stop/kill: a foreign same-named container receives ZERO real start/stop/kill calls, refusing non-zero and naming the ownership mismatch"

# --- First-run image guard (Astra F4 item 6) --------------------------------
#
# The lock container's own base image is $DX_IMAGE (never started, but
# `docker create` still requires it to exist); dx-create-container must
# therefore confirm the image exists BEFORE ever attempting to acquire the
# lock, or a plain first run (no image yet) would misreport a perfectly
# ordinary "run dx-create-image first" case as a locking failure. Proven by
# a fake docker that fails any "create --name dxe-lock-..." outright
# (it must never be reached at all) while answering "image inspect" as
# absent.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/wp65-create-container-no-image.log"
    fake_tool_write "$dir" docker "
case \"\$1 \$2\" in
    \"version --format\") echo 27.3.1 ;;
    \"info --format\") echo 'abc123def|qnap-fake|x86_64|linux' ;;
    \"container inspect\") exit 1 ;;
    \"image inspect\") exit 1 ;;
    *) printf '%s\\n' \"\$*\" >> '$argv_log'; exit 99 ;;
esac
"
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx-create-container" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ ! -s "$argv_log" ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "Image dx-qnap-nixos does not exist"
)
[ "$?" -eq 0 ] && test_pass "dx-create-container (docker-ssh): a missing image is refused before the lifecycle lock is ever attempted" \
    || test_fail "dx-create-container (docker-ssh): a missing image is refused before the lifecycle lock is ever attempted"

# --- Helpers through the adapter under DX_RUNTIME=docker-ssh (Branch 11 /
# Phase 3, Increment 4, item 4): bin/dx-create-volumes, bin/dx-destroy-container,
# bin/dx-destroy-image, and bin/dx-migrate-persist already went through the
# runtime-neutral contract in Phase 1 (no code change needed in any of
# them); this proves that contract renders correct, DQ6-labelled Docker
# argv end to end when actually invoked as entrypoints, not just at the
# adapter-function level Section 33 already covers elsewhere in this file.

# dx-create-volumes: every volume it ensures is created with DQ6 labels,
# the role resolved correctly for all three configured volumes.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    cv_log="$dir/create-argv.log"
    export DX_FAKE_ARGV_LOG="$cv_log"
    : > "$cv_log"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "volume inspect") exit 1 ;;
    "volume create")
        shift 2
        printf "%s\n" "$@" >> "$DX_FAKE_ARGV_LOG"
        exit 0
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap \
        DX_NIX_VOLUME=dxe-p3-nix DX_PERSIST_VOLUME=dxe-p3-persist DX_BOOTSTRAP_VOLUME=dxe-p3-bootstrap \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-create-volumes" >/dev/null 2>&1
    # One token per line (dx-create-container's own logging convention);
    # join with spaces so a role's --label token can be matched adjacent
    # to the volume name that follows it in the real argv.
    created="$(tr '\n' ' ' < "$cv_log")"
    # Branch 11 / Phase 4: io.dxe.role is followed by io.dxe.system now
    # (dx_runtime_docker_label_flags gained a fifth label), so the volume
    # name that used to sit directly after "role=<x>" now sits after the
    # system label instead -- deliberately updated, not a weakened check.
    printf '%s\n' "$created" | stdin_matches -F -- '--label io.dxe.role=nix --label io.dxe.system=x86_64-linux dxe-p3-nix' \
        && printf '%s\n' "$created" | stdin_matches -F -- '--label io.dxe.role=persist --label io.dxe.system=x86_64-linux dxe-p3-persist' \
        && printf '%s\n' "$created" | stdin_matches -F -- '--label io.dxe.role=bootstrap --label io.dxe.system=x86_64-linux dxe-p3-bootstrap' \
        && printf '%s\n' "$created" | stdin_matches -F -- 'io.dxe.managed=true'
)
[ "$?" -eq 0 ] && test_pass "dx-create-volumes (docker-ssh): all three volumes created with DQ6 labels and the correct role" || test_fail "dx-create-volumes (docker-ssh): all three volumes created with DQ6 labels and the correct role"

# dx-destroy-container: label check (container inspect) happens before the
# delete; a mismatched label refuses the delete as a collision, never an
# adoption candidate (DQ6).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "container inspect")
        case "$*" in
            *dxe-lock-*) echo "true|qnap-dxe__dx-qnap|lock|$DXE_LIFECYCLE_LOCK_OWNER"; exit 0 ;;
            *) echo "false|||"; exit 0 ;;
        esac
        ;;
    "create --name")
        case "$*" in
            *dxe-lock-*) exit 0 ;;
            *) echo "UNMATCHED CREATE: $*" >&2; exit 99 ;;
        esac
        ;;
esac
case "$1" in
    ps) echo "NAMES	IMAGE	STATUS"; echo "dx-qnap	dx-qnap-nixos	Exited"; exit 0 ;;
    rm)
        case "$*" in
            *dxe-lock-*) exit 0 ;;
            *) echo "docker rm should never run on a label mismatch" >&2; exit 99 ;;
        esac
        ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dxe-p3-nix \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-destroy-container" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "collision"
)
[ "$?" -eq 0 ] && test_pass "dx-destroy-container (docker-ssh): label check runs before delete, refusing a collision rather than deleting" || test_fail "dx-destroy-container (docker-ssh): label check runs before delete, refusing a collision rather than deleting"

# Astra F3 item 1: a foreign or unlabelled container that is RUNNING used
# to receive a real "docker stop" (and, on that failing, a real "docker
# kill") from container_stop_bounded's own fallback ladder BEFORE
# dx-destroy-container's delete step ever got a chance to refuse -- the
# adapter's own container_owned check (now run inside
# dx_runtime_docker_container_stop/kill/delete) closes this: every one of
# stop/kill/rm is refused before it ever reaches the fake, proven by call
# count (the fake exits 99 loudly if any of them is ever invoked), and the
# whole command exits non-zero naming the ownership mismatch.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    calls_log="$dir/mutating-calls.log"
    : > "$calls_log"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "container inspect")
        case "$*" in
            *dxe-lock-*) echo "true|qnap-dxe__dx-qnap|lock|$DXE_LIFECYCLE_LOCK_OWNER"; exit 0 ;;
            *"State.Running"*) echo "true"; exit 0 ;;
            *"Config.Labels"*) echo "false|||"; exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
    "create --name")
        case "$*" in
            *dxe-lock-*) exit 0 ;;
            *) echo "UNMATCHED CREATE: $*" >&2; exit 99 ;;
        esac
        ;;
esac
case "$1" in
    ps) echo "NAMES	IMAGE	STATUS"; echo "dx-qnap	dx-qnap-nixos	Up 2 hours"; exit 0 ;;
    rm)
        case "$*" in
            *dxe-lock-*) exit 0 ;;
            *) printf "%s\n" "$*" >> "'"$calls_log"'"; echo "docker rm should never run on a foreign RUNNING container" >&2; exit 99 ;;
        esac
        ;;
    stop|kill) printf "%s\n" "$*" >> "'"$calls_log"'"; echo "docker $1 should never run on a foreign RUNNING container" >&2; exit 99 ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dxe-p3-nix \
        DX_STOP_COMMAND_TIMEOUT=2 DX_STOP_GRACE_SECONDS=1 DX_STOP_WAIT_TIMEOUT=1 \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-destroy-container" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ ! -s "$calls_log" ] && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "dx-destroy-container (docker-ssh): a foreign RUNNING container receives ZERO stop/kill/rm calls, exiting non-zero and naming the ownership mismatch" \
    || test_fail "dx-destroy-container (docker-ssh): a foreign RUNNING container receives ZERO stop/kill/rm calls, exiting non-zero and naming the ownership mismatch"

# The same regression through bin/dx-stop-container's own path
# (container_stop_bounded, shared with dx-destroy-container above): zero
# stop/kill calls reach the fake, and the command exits non-zero.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    calls_log="$dir/mutating-calls.log"
    : > "$calls_log"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "container inspect")
        case "$*" in
            *dxe-lock-*) echo "true|qnap-dxe__dx-qnap|lock|$DXE_LIFECYCLE_LOCK_OWNER"; exit 0 ;;
            *"State.Running"*) echo "true"; exit 0 ;;
            *"Config.Labels"*) echo "false|||"; exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
    "create --name")
        case "$*" in
            *dxe-lock-*) exit 0 ;;
            *) echo "UNMATCHED CREATE: $*" >&2; exit 99 ;;
        esac
        ;;
esac
case "$1" in
    ps) echo "NAMES	IMAGE	STATUS"; echo "dx-qnap	dx-qnap-nixos	Up 2 hours"; exit 0 ;;
    rm)
        case "$*" in
            *dxe-lock-*) exit 0 ;;
            *) printf "%s\n" "$*" >> "'"$calls_log"'"; echo "docker rm should never run on a foreign RUNNING container" >&2; exit 99 ;;
        esac
        ;;
    stop|kill) printf "%s\n" "$*" >> "'"$calls_log"'"; echo "docker $1 should never run on a foreign RUNNING container" >&2; exit 99 ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap \
        DX_STOP_COMMAND_TIMEOUT=2 DX_STOP_GRACE_SECONDS=1 DX_STOP_WAIT_TIMEOUT=1 \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-stop-container" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ ! -s "$calls_log" ] && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "dx-stop-container (docker-ssh): a foreign RUNNING container receives ZERO stop/kill calls, exiting non-zero and naming the ownership mismatch" \
    || test_fail "dx-stop-container (docker-ssh): a foreign RUNNING container receives ZERO stop/kill calls, exiting non-zero and naming the ownership mismatch"

# Astra F3 item 2: an EXISTING container with foreign labels used to make
# dx-create-container return success unconditionally ("already exists;
# skipping create") without ever checking whether it was this profile's
# own. It must now fail instead.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "container inspect")
        case "$*" in
            *"--format"*) echo "true|1|qnap-OTHER__dx-qnap|container|x86_64-linux"; exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_NIX_VOLUME=dxe-p3-nix \
        DX_PERSIST_VOLUME=dxe-p3-persist DX_BOOTSTRAP_VOLUME=dxe-p3-bootstrap \
        DX_SSH_KEY_PUB=/nonexistent-pubkey \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-create-container" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] \
        && ! printf '%s\n' "$out" | stdin_matches -F -- "already exists; skipping create" \
        && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "dx-create-container (docker-ssh): an existing FOREIGN container fails rather than returning success" \
    || test_fail "dx-create-container (docker-ssh): an existing FOREIGN container fails rather than returning success"

# The correctly-labelled case is unaffected: still a plain, successful
# no-op ("already exists; skipping create").
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "container inspect")
        case "$*" in
            *"--format"*) echo "true|1|qnap-dxe__dx-qnap|container|x86_64-linux"; exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_NIX_VOLUME=dxe-p3-nix \
        DX_PERSIST_VOLUME=dxe-p3-persist DX_BOOTSTRAP_VOLUME=dxe-p3-bootstrap \
        DX_SSH_KEY_PUB=/nonexistent-pubkey \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-create-container" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "already exists; skipping create"
)
[ "$?" -eq 0 ] && test_pass "dx-create-container (docker-ssh): an existing OWNED container still succeeds as a no-op" \
    || test_fail "dx-create-container (docker-ssh): an existing OWNED container still succeeds as a no-op"

# Astra F3 item 3: an EXISTING volume with foreign or missing labels used
# to be accepted on existence alone (container_ensure_volume). It must now
# refuse to adopt it, naming the volume -- and since dx-create-volumes
# refuses before returning, no later "docker create ... -v/--mount" with
# that volume is ever reached (zero writable attachment).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "volume inspect")
        case "$*" in
            *"--format"*) echo "<no value>|<no value>|<no value>|<no value>|<no value>"; exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
esac
case "$1" in
    create) echo "docker create should never run for an un-adopted volume" >&2; exit 99 ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap \
        DX_NIX_VOLUME=dxe-p6-foreign-nix DX_PERSIST_VOLUME=dxe-p6-foreign-persist DX_BOOTSTRAP_VOLUME=dxe-p6-foreign-bootstrap \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-create-volumes" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] \
        && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate" \
        && printf '%s\n' "$out" | stdin_matches -F -- "dxe-p6-foreign-nix"
)
[ "$?" -eq 0 ] && test_pass "dx-create-volumes (docker-ssh): an existing volume with missing/foreign labels refuses to adopt it, naming the volume, with zero writable attachment" \
    || test_fail "dx-create-volumes (docker-ssh): an existing volume with missing/foreign labels refuses to adopt it, naming the volume, with zero writable attachment"

# Direct unit coverage of the same refusal at the function level
# (bin/lib/dx-container.sh's container_ensure_volume), independent of the
# entrypoint: an existing but foreign-labelled volume is never treated as
# "already there and fine."
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "volume inspect")
        case "$*" in
            *"--format"*) echo "true|1|qnap-OTHER__dx-qnap|nix|x86_64-linux"; exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux DX_NIX_VOLUME=dxe-p6-foreign-nix
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(container_ensure_volume dxe-p6-foreign-nix 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "container_ensure_volume: a foreign-labelled existing volume is refused, never silently adopted" \
    || test_fail "container_ensure_volume: a foreign-labelled existing volume is refused, never silently adopted"

# Astra F3 item 4: dx_runtime_docker_labels_owned (verify_labels' fixed
# successor) reads schema but must actually VALIDATE it -- an unknown
# future schema (999) is refused even though managed/profile/role all
# match. A plain 4-field response (no io.dxe.system at all, a resource
# labelled by an older adapter build before Phase 4 added that label) is
# used deliberately here rather than the current 5-field shape: bash's
# `read` assigns every FIELD BEYOND the last named variable to that last
# variable, rejoined by IFS, so a 5-field response fed into a would-be
# 4-variable reader corrupts "role" into "role|system" -- a confound this
# schema-specific case must not depend on. The refusal below is therefore
# attributable to schema alone (managed/profile/role are all otherwise a
# clean, exact match).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "true|999|qnap-dxe__dx-qnap|container" ;;
    *) echo "docker rm should never run on an unsupported schema" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_container_delete dx-qnap 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "labels_owned: refuses an unknown/unsupported schema (999) even when managed/profile/role all match" \
    || test_fail "labels_owned: refuses an unknown/unsupported schema (999) even when managed/profile/role all match"

# The same "an older/foreign labelling never carried io.dxe.system at all"
# shape (4 fields, same reasoning as above), this time isolating the
# system check: schema/managed/profile/role are all a clean exact match,
# so the refusal is attributable to the missing system label alone.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "true|1|qnap-dxe__dx-qnap|container" ;;
    *) echo "docker rm should never run without a matching io.dxe.system" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_container_delete dx-qnap 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "labels_owned: refuses a resource with no io.dxe.system label at all, even when managed/schema/profile/role all match" \
    || test_fail "labels_owned: refuses a resource with no io.dxe.system label at all, even when managed/schema/profile/role all match"

# Direct, precise unit coverage of the same io.dxe.system dimension, for a
# genuinely PRESENT but WRONG value (the fully realistic "built for the
# other guest architecture" case) -- calling the pure predicate directly
# sidesteps the read/field-count confound entirely, since there is no
# comparison against any prior parsing shape here at all.
(
    DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    dx_runtime_docker_labels_owned container "true|1|qnap-dxe__dx-qnap|container|aarch64-linux"
) && test_fail "labels_owned: a present but WRONG io.dxe.system (aarch64-linux vs configured x86_64-linux) must be refused" \
    || test_pass "labels_owned: a present but WRONG io.dxe.system (aarch64-linux vs configured x86_64-linux) must be refused"
(
    DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    dx_runtime_docker_labels_owned container "true|1|qnap-dxe__dx-qnap|container|x86_64-linux"
) && test_pass "labels_owned: a matching io.dxe.system, schema, profile and role together is owned" \
    || test_fail "labels_owned: a matching io.dxe.system, schema, profile and role together is owned"

# dx-reset-nix-volume (Branch 12, store-trust-plan.md): the same DQ6 label
# check dx-destroy-container/dx-destroy-volumes already go through
# (dx_runtime_volume_delete -> dx_runtime_docker_volume_delete's own
# verify-before-delete) applies here too, with no code of its own to prove
# it -- this is exactly what a new entrypoint reusing the existing
# runtime-neutral contract should look like. A volume that exists but is
# unlabelled/mislabelled refuses as a collision, never an adoption
# candidate; "volume rm" must never run.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "container inspect") exit 1 ;;
    "volume inspect") echo "false|||"; exit 0 ;;
esac
case "$1" in
    volume) [ "$2" = rm ] && { echo "docker volume rm should never run on a label mismatch" >&2; exit 99; } ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dxe-p3-nix \
        DX_PERSIST_VOLUME=dxe-p3-persist DX_BOOTSTRAP_VOLUME=dxe-p3-bootstrap \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-reset-nix-volume" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "collision"
)
[ "$?" -eq 0 ] && test_pass "dx-reset-nix-volume (docker-ssh): the existing DQ6 label check refuses an unlabelled/mislabelled volume as a collision, never deleting it" || test_fail "dx-reset-nix-volume (docker-ssh): the existing DQ6 label check refuses an unlabelled/mislabelled volume as a collision, never deleting it"

# The correctly-labelled case reaches the adapter and deletes exactly the
# Nix volume's own docker-ssh argv shape ("volume rm NAME"), proving the
# entrypoint end to end under docker-ssh, never touching persist/bootstrap.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    rn_log="$dir/volume-rm.log"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "container inspect") exit 1 ;;
    "volume inspect") echo "true|1|qnap-dxe__dx-qnap|nix|x86_64-linux"; exit 0 ;;
esac
case "$1" in
    volume)
        if [ "$2" = rm ]; then shift 2; printf "%s\n" "$@" >> "'"$rn_log"'"; exit 0; fi
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dxe-p3-nix \
        DX_PERSIST_VOLUME=dxe-p3-persist DX_BOOTSTRAP_VOLUME=dxe-p3-bootstrap \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-reset-nix-volume" 2>&1)"
    [ "$(cat "$rn_log" 2>/dev/null)" = dxe-p3-nix ] && printf '%s\n' "$out" | stdin_matches -F './bin/dx'
)
[ "$?" -eq 0 ] && test_pass "dx-reset-nix-volume (docker-ssh): a correctly-labelled volume is deleted by exact name, naming the ./bin/dx next step" || test_fail "dx-reset-nix-volume (docker-ssh): a correctly-labelled volume is deleted by exact name, naming the ./bin/dx next step"

# --- dx-destroy-volumes (docker-ssh), Branch 11 / Phase 6 item 7: the
# whole-operation ownership proof (bin/lib/dx-container.sh's
# dx_destructive_plan_and_verify) refuses the WHOLE destroy -- proven by
# CALL COUNT on the fake, not merely by exit status -- when even one of
# the three volumes fails its DQ6 label check, never a resource-by-
# resource partial destroy.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    rm_log="$dir/volume-rm-calls.log"
    : > "$rm_log"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "volume inspect")
        case "$*" in
            *dxe-p6-nix*) echo "true|1|qnap-dxe__dx-qnap|nix"; exit 0 ;;
            *dxe-p6-persist*) echo "<no value>|<no value>|<no value>|<no value>"; exit 0 ;;
            *dxe-p6-bootstrap*) echo "true|1|qnap-dxe__dx-qnap|bootstrap"; exit 0 ;;
        esac
        exit 1
        ;;
esac
case "$1" in
    volume) if [ "$2" = rm ]; then shift 2; printf "%s\n" "$@" >> "'"$rm_log"'"; exit 0; fi ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap \
        DX_NIX_VOLUME=dxe-p6-nix DX_PERSIST_VOLUME=dxe-p6-persist DX_BOOTSTRAP_VOLUME=dxe-p6-bootstrap \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-destroy-volumes" --force 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] \
        && [ ! -s "$rm_log" ] \
        && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate" \
        && printf '%s\n' "$out" | stdin_matches -F -- "dxe-p6-nix" \
        && printf '%s\n' "$out" | stdin_matches -F -- "dxe-p6-persist" \
        && printf '%s\n' "$out" | stdin_matches -F -- "dxe-p6-bootstrap"
)
[ "$?" -eq 0 ] && test_pass "dx-destroy-volumes (docker-ssh): refuses the WHOLE destroy with zero volume-rm calls when one of three volumes is mislabelled" || test_fail "dx-destroy-volumes (docker-ssh): refuses the WHOLE destroy with zero volume-rm calls when one of three volumes is mislabelled"

# All three correctly labelled: the plan passes, and exactly three
# "volume rm" calls are reached, one per configured volume.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    rm_log="$dir/volume-rm-calls.log"
    : > "$rm_log"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "volume inspect")
        case "$*" in
            *dxe-p6-nix*) echo "true|1|qnap-dxe__dx-qnap|nix|x86_64-linux"; exit 0 ;;
            *dxe-p6-persist*) echo "true|1|qnap-dxe__dx-qnap|persist|x86_64-linux"; exit 0 ;;
            *dxe-p6-bootstrap*) echo "true|1|qnap-dxe__dx-qnap|bootstrap|x86_64-linux"; exit 0 ;;
        esac
        exit 1
        ;;
esac
case "$1" in
    volume) if [ "$2" = rm ]; then shift 2; printf "%s\n" "$@" >> "'"$rm_log"'"; exit 0; fi ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap \
        DX_NIX_VOLUME=dxe-p6-nix DX_PERSIST_VOLUME=dxe-p6-persist DX_BOOTSTRAP_VOLUME=dxe-p6-bootstrap \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-destroy-volumes" --force 2>&1)"; rc=$?
    deleted="$(tr '\n' ' ' < "$rm_log")"
    [ "$rc" -eq 0 ] \
        && [ "$(wc -l < "$rm_log" | tr -d ' ')" -eq 3 ] \
        && printf '%s\n' "$deleted" | stdin_matches -F -- "dxe-p6-nix" \
        && printf '%s\n' "$deleted" | stdin_matches -F -- "dxe-p6-persist" \
        && printf '%s\n' "$deleted" | stdin_matches -F -- "dxe-p6-bootstrap"
)
[ "$?" -eq 0 ] && test_pass "dx-destroy-volumes (docker-ssh): all three volumes correctly labelled -> exactly three volume-rm calls" || test_fail "dx-destroy-volumes (docker-ssh): all three volumes correctly labelled -> exactly three volume-rm calls"

# --- dx-factory-reset (docker-ssh), Branch 11 / Phase 6 item 7: the same
# whole-operation proof, one level up -- a mislabelled CONTAINER refuses
# the entire factory reset before dx-destroy-container/dx-destroy-image/
# dx-destroy-volumes/dx-destroy-keys are even invoked, proven by call
# count: neither a container "rm" nor any "volume rm" is ever reached.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    rm_log="$dir/delete-calls.log"
    : > "$rm_log"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "container inspect")
        case "$*" in *dx-qnap*) echo "<no value>|<no value>|<no value>|<no value>"; exit 0 ;; esac
        exit 1
        ;;
    "volume inspect")
        case "$*" in
            *dxe-p6-nix*) echo "true|1|qnap-dxe__dx-qnap|nix"; exit 0 ;;
            *dxe-p6-persist*) echo "true|1|qnap-dxe__dx-qnap|persist"; exit 0 ;;
            *dxe-p6-bootstrap*) echo "true|1|qnap-dxe__dx-qnap|bootstrap"; exit 0 ;;
        esac
        exit 1
        ;;
esac
case "$1" in
    rm) printf "container %s\n" "$*" >> "'"$rm_log"'"; exit 0 ;;
    volume) if [ "$2" = rm ]; then printf "volume %s\n" "$*" >> "'"$rm_log"'"; exit 0; fi ;;
    image) if [ "$2" = rm ]; then printf "image %s\n" "$*" >> "'"$rm_log"'"; exit 0; fi ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos \
        DX_NIX_VOLUME=dxe-p6-nix DX_PERSIST_VOLUME=dxe-p6-persist DX_BOOTSTRAP_VOLUME=dxe-p6-bootstrap \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-factory-reset" --force 2>&1)"; rc=$?
    # The "Immutable plan" text and the per-resource plan lines come ONLY
    # from dx_destructive_plan_and_verify's own new whole-operation check --
    # never from dx-destroy-container's pre-existing per-resource check
    # alone, which would ALSO refuse on this same mislabelled container
    # (with the same "collision" text) without ever printing a plan at all.
    # Asserting the plan text specifically is what makes this genuinely
    # distinguish the new behaviour, since the volumes here are all
    # correctly labelled -- a red run against the old code proved this
    # (see the progress file's Increment 3 entry).
    [ "$rc" -ne 0 ] \
        && [ ! -s "$rm_log" ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "Immutable plan (docker-ssh ownership proof" \
        && printf '%s\n' "$out" | stdin_matches -F -- "container dx-qnap: labels=" \
        && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "dx-factory-reset (docker-ssh): refuses the WHOLE reset with zero delete calls when the container is mislabelled, before any sub-script runs" || test_fail "dx-factory-reset (docker-ssh): refuses the WHOLE reset with zero delete calls when the container is mislabelled, before any sub-script runs"

# dx-destroy-image: images are never labelled (docker tag cannot attach a
# label), so this is a plain passthrough once the image is confirmed to
# exist -- proves the entrypoint reaches the docker adapter at all.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    di_log="$dir/image-rm.log"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "image inspect") exit 0 ;;
esac
case "$1" in
    image)
        [ "$2" = rm ] && { shift 2; printf "%s\n" "$@" >> "'"$di_log"'"; exit 0; }
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_IMAGE=dxe-p3-image \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-destroy-image" >/dev/null 2>&1
    grep -qF -- dxe-p3-image "$di_log"
)
[ "$?" -eq 0 ] && test_pass "dx-destroy-image (docker-ssh): reaches the docker adapter and removes the confirmed image" || test_fail "dx-destroy-image (docker-ssh): reaches the docker adapter and removes the confirmed image"

# dx-migrate-persist: dx_runtime_run_ephemeral's argv (Apple's own flag
# vocabulary: --rm --volume NAME:TARGET:MODE --entrypoint sh IMAGE -lc
# SCRIPT -- ARGS) happens to be valid `docker run` syntax too -- asserted
# at the argv level (docs/refactor/direct-volume-storage.md's task file:
# "if a real incompatibility appears, STOP and report, do not redesign
# run_ephemeral"). The legacy volume exists and is empty of anything but
# the sentinel-check reads, so migration completes.
mp_dir="$(new_tool_dir)"
mp_log="$mp_dir/run-argv.log"
: > "$mp_log"
(
    dir="$mp_dir"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "container inspect") exit 1 ;;
    "volume inspect")
        [ "$3" = dxe-p3-legacy ] && exit 0
        [ "$3" = dxe-p3-persist ] && exit 1
        exit 1
        ;;
    "image inspect") exit 0 ;;
esac
case "$1" in
    run)
        shift
        printf "%s\n" "$@" >> "'"$mp_log"'"
        case "$*" in
            *"--volume dxe-p3-persist:/new:rw --entrypoint sh"*"cat"*) exit 0 ;;
            *"--volume dxe-p3-legacy:/old:ro"*) exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
    volume)
        [ "$2" = create ] && exit 0
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dxe-p3-image \
        DX_LEGACY_WORKSPACE_VOLUME=dxe-p3-legacy DX_PERSIST_VOLUME=dxe-p3-persist \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-migrate-persist" 2>&1)"; rc=$?
    argv="$(tr '\n' ' ' < "$mp_log")"
    [ "$rc" -eq 0 ] \
        && printf '%s\n' "$argv" | stdin_matches -F -- '--rm --volume dxe-p3-persist:/new:rw --entrypoint sh' \
        && printf '%s\n' "$argv" | stdin_matches -F -- '--volume dxe-p3-legacy:/old:ro --volume dxe-p3-persist:/new:rw --entrypoint sh'
)
[ "$?" -eq 0 ] && test_pass "dx-migrate-persist (docker-ssh): dx_runtime_run_ephemeral's Apple-flavoured argv is valid docker run syntax too" || test_fail "dx-migrate-persist (docker-ssh): dx_runtime_run_ephemeral's Apple-flavoured argv is valid docker run syntax too (argv: $(cat "$mp_log" 2>/dev/null))"


rm -rf "$fixture" 2>/dev/null || true

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    print_summary
    exit_with_code
fi
