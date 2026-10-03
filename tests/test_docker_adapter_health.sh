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
# Fable D6 step 1: docker-ssh runtime adapter, health part -- runtime
# capability queries, dispatch routing itself, the destructive-plan-and-verify
# safety check, the diagnostics taxonomy, kcov coverage-closing cases, volume
# usage reporting, fail-closed capability checks, and the transcript-equality
# guard (WP8.3).
#
# Runnable standalone: bash tests/test_docker_adapter_health.sh
# (prints its own banner and its own Results line for just its own
# cases). tests/test_docker_runtime_adapter.sh sources this file, in
# order with its four siblings, as section 33's one registered entry;
# sourced that way, this file prints no banner of its own and defers
# print_summary/exit_with_code to the aggregate, so section 33 still
# reports one combined Results line for all 208 cases.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    test_section "Docker-ssh runtime adapter (Branch 11 / Phase 2) -- health"
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


# --- Runtime capability queries (DQ2/DQ3/DQ4/DQ8) --------------------------
(
    DX_RUNTIME=docker-ssh
    dx_runtime_capability direct_named_volume_mounts
)
[ "$?" -eq 0 ] && test_pass "capability: direct_named_volume_mounts is yes for docker-ssh" || test_fail "capability: direct_named_volume_mounts is yes for docker-ssh"
(
    DX_RUNTIME=docker-ssh
    dx_runtime_capability bind_mounts
)
[ "$?" -ne 0 ] && test_pass "capability: bind_mounts is no for docker-ssh (DQ8: dx-mount unsupported)" || test_fail "capability: bind_mounts is no for docker-ssh (DQ8: dx-mount unsupported)"
(
    DX_RUNTIME=docker-ssh
    dx_runtime_capability restart_policy
)
[ "$?" -eq 0 ] && test_pass "capability: restart_policy is yes for docker-ssh (unlike apple)" || test_fail "capability: restart_policy is yes for docker-ssh (unlike apple)"
(
    DX_RUNTIME=docker-ssh
    dx_runtime_capability host_filesystem_reclamation
)
[ "$?" -ne 0 ] && test_pass "capability: host_filesystem_reclamation is no for docker-ssh (DQ8: Apple-only)" || test_fail "capability: host_filesystem_reclamation is no for docker-ssh (DQ8: Apple-only)"
# Branch 11 / Phase 6 (qnap-dxe-plan.md Phase 6 item 4): the one neutral
# create-time health flag pre-authorised for this phase.
(
    DX_RUNTIME=docker-ssh
    dx_runtime_capability container_healthcheck
)
[ "$?" -eq 0 ] && test_pass "capability: container_healthcheck is yes for docker-ssh (unlike apple)" || test_fail "capability: container_healthcheck is yes for docker-ssh (unlike apple)"
(
    DX_RUNTIME=apple
    dx_runtime_capability container_healthcheck
)
# Exactly 1 ("recognized, answer is no"), not merely non-zero -- 2 means
# "unknown capability name" (dx_runtime_apple_capability's own error path),
# which would wrongly satisfy a looser "-ne 0" check even if this
# capability were never taught to the Apple adapter at all.
[ "$?" -eq 1 ] && test_pass "capability: container_healthcheck is no for apple (no HEALTHCHECK concept in container create)" || test_fail "capability: container_healthcheck is no for apple (no HEALTHCHECK concept in container create)"
(
    DX_RUNTIME=docker-ssh
    dx_runtime_capability bogus
)
[ "$?" -eq 2 ] && test_pass "capability: an unknown capability name is a distinct error, not a false negative" || test_fail "capability: an unknown capability name is a distinct error, not a false negative"

# --- Dispatch itself: DX_RUNTIME=docker-ssh reaches the docker adapter, not
# the Apple one, and vice versa (proves dx_runtime_dispatch's dynamic
# function-name construction actually selects the right adapter).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 0'
    fake_tool_write "$dir" container 'echo "apple adapter should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    dx_runtime_system_running
)
[ "$?" -eq 0 ] && test_pass "dispatch: DX_RUNTIME=docker-ssh never reaches the Apple adapter" || test_fail "dispatch: DX_RUNTIME=docker-ssh never reaches the Apple adapter"
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" ssh 'echo "docker adapter should never run" >&2; exit 99'
    fake_tool_write "$dir" container 'case "$*" in "system status") exit 0 ;; esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=apple
    dx_runtime_system_running
)
[ "$?" -eq 0 ] && test_pass "dispatch: DX_RUNTIME=apple never reaches the docker-ssh adapter" || test_fail "dispatch: DX_RUNTIME=apple never reaches the docker-ssh adapter"

# --- dx_runtime_docker_destructive_plan_and_verify (Branch 11 / Phase 6,
# item 7): the whole-operation ownership proof bin/dx-factory-reset and
# bin/dx-destroy-volumes both reach through bin/lib/dx-container.sh's
# runtime-neutral dx_destructive_plan_and_verify. Direct unit coverage of
# the docker-ssh function itself; the entrypoint-level, call-count-by-fake
# proof (the actual "zero delete calls on any mismatch" property) is
# further down, alongside the other dx-destroy-volumes/dx-destroy-container
# docker-ssh entrypoint tests.

# All resources correctly labelled: prints the plan for both, passes.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
# "$3" is only the name for the plain existence check (container/volume
# inspect NAME); the label query sends "inspect --format TEMPLATE NAME"
# instead, so NAME is $4 there -- matched against the whole argv ("$*")
# instead of a fixed position, so both shapes answer correctly (fakes
# cannot see Go templates -- this is the same pitfall, worked around the
# same way the coverage docs already note elsewhere in this file).
case "$1 $2" in
    "container inspect")
        case "$*" in *dx-qnap*) echo "true|1|dxe-fixture-nas.invalid__dx-qnap|container|x86_64-linux"; exit 0 ;; esac
        exit 1
        ;;
    "volume inspect")
        case "$*" in *dx-qnap-nix*) echo "true|1|dxe-fixture-nas.invalid__dx-qnap|nix|x86_64-linux"; exit 0 ;; esac
        exit 1
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_destructive_plan_and_verify "container:dx-qnap:container" "volume:dx-qnap-nix:nix" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "container dx-qnap: labels=true|1|dxe-fixture-nas.invalid__dx-qnap|container" \
        && printf '%s\n' "$out" | stdin_matches -F -- "volume dx-qnap-nix: labels=true|1|dxe-fixture-nas.invalid__dx-qnap|nix"
)
[ "$?" -eq 0 ] && test_pass "destructive_plan_and_verify: prints the plan and passes when every resource is correctly labelled" || test_fail "destructive_plan_and_verify: prints the plan and passes when every resource is correctly labelled"

# One of two resources mislabelled: the plan still names BOTH (printed in
# full before any failure is decided), and the function refuses overall.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect")
        case "$*" in *dx-qnap*) echo "true|1|dxe-fixture-nas.invalid__dx-qnap|container"; exit 0 ;; esac
        exit 1
        ;;
    "volume inspect")
        case "$*" in *dx-qnap-nix*) echo "<no value>|<no value>|<no value>|<no value>"; exit 0 ;; esac
        exit 1
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_destructive_plan_and_verify "container:dx-qnap:container" "volume:dx-qnap-nix:nix" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "container dx-qnap: labels=true|1|dxe-fixture-nas.invalid__dx-qnap|container" \
        && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "destructive_plan_and_verify: names every resource even when only one is mislabelled, and refuses" || test_fail "destructive_plan_and_verify: names every resource even when only one is mislabelled, and refuses"

# A resource that does not exist at all: named in the plan, never
# label-checked, and never counted as a failure on its own.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "volume inspect") exit 1 ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_destructive_plan_and_verify "volume:dx-qnap-bootstrap:bootstrap" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "does not exist"
)
[ "$?" -eq 0 ] && test_pass "destructive_plan_and_verify: a nonexistent resource is named but never label-checked or refused on its own" || test_fail "destructive_plan_and_verify: a nonexistent resource is named but never label-checked or refused on its own"

# Apple: unconditionally a no-op through the runtime-neutral wrapper
# (bin/lib/dx-container.sh's dx_destructive_plan_and_verify), regardless of
# arguments -- Apple has no DQ6 labels at all.
(
    DX_RUNTIME=apple
    dx_destructive_plan_and_verify "container:whatever:container"
)
[ "$?" -eq 0 ] && test_pass "destructive_plan_and_verify: unconditional no-op under DX_RUNTIME=apple" || test_fail "destructive_plan_and_verify: unconditional no-op under DX_RUNTIME=apple"

# exec: argv-verbatim AND stdin passthrough (piped and file-redirected),
# exit status unchanged under `set -o pipefail`, no intermediate cat/subshell
# -- the same explicit proof shape test_sourceable_coverage.sh uses for Apple.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/exec-argv.log"
    fake_tool_write "$dir" docker "
printf '%s\n' \"\$@\" > '$argv_log'
if [ \"\${1:-}\" = exec ]; then cat; fi
"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    export DXE_RUNTIME_DOCKER_BIN=docker
    set -o pipefail
    out="$(printf 'piped-stdin' | dx_runtime_exec -i dx-qnap cat)"
    rc=$?
    [ "$rc" -eq 0 ] && [ "$out" = piped-stdin ]
)
[ "$?" -eq 0 ] && test_pass "exec: piped stdin passes through unchanged" || test_fail "exec: piped stdin passes through unchanged"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "${1:-}" = exec ] && cat'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    export DXE_RUNTIME_DOCKER_BIN=docker
    src="$fixture/exec-src.txt"
    printf 'file-redirected-stdin' > "$src"
    out="$(dx_runtime_exec -i dx-qnap cat < "$src")"
    [ "$out" = file-redirected-stdin ]
)
[ "$?" -eq 0 ] && test_pass "exec: file-redirected stdin passes through unchanged" || test_fail "exec: file-redirected stdin passes through unchanged"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 17'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    export DXE_RUNTIME_DOCKER_BIN=docker
    set -o pipefail
    printf 'x' | dx_runtime_exec -i dx-qnap false >/dev/null
    [ "$?" -eq 17 ]
)
[ "$?" -eq 0 ] && test_pass "exec: exit status is preserved unchanged even under set -o pipefail" || test_fail "exec: exit status is preserved unchanged even under set -o pipefail"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/exec-argv2.log"
    fake_tool_write "$dir" docker "printf '%s\n' \"\$@\" > '$argv_log'"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_exec -i -u dx dx-qnap bash -lc 'echo hi'
    diff <(printf '%s\n' exec -i -u dx dx-qnap bash -lc 'echo hi') "$argv_log" >/dev/null
)
[ "$?" -eq 0 ] && test_pass "exec: argv is passed verbatim (-i -u dx NAME CMD...)" || test_fail "exec: argv is passed verbatim (-i -u dx NAME CMD...)"

# --- Diagnostics taxonomy (item 8) --------------------------------------

# The classifier itself: each named class from
# docs/refactor/docker-adapter-mapping.md section 7, plus an unrecognized
# failure still getting a generic (never silent) label.
(
    [ "$(dx_runtime_docker_classify_failure 'Permission denied (publickey).')" = "authentication failure" ] &&
    [ "$(dx_runtime_docker_classify_failure 'Host key verification failed.')" = "authentication failure" ] &&
    [ "$(dx_runtime_docker_classify_failure 'ssh: connect to host dxe-fixture-nas.invalid port 22: Connection refused')" = "connection loss" ] &&
    [ "$(dx_runtime_docker_classify_failure 'ssh: connect to host dxe-fixture-nas.invalid port 22: Operation timed out')" = "connection loss" ] &&
    [ "$(dx_runtime_docker_classify_failure 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?')" = "daemon restart or unreachable" ] &&
    [ "$(dx_runtime_docker_classify_failure 'bash: docker: command not found')" = "missing Docker access" ] &&
    [ "$(dx_runtime_docker_classify_failure 'something entirely unexpected')" = "remote command failure" ]
)
[ "$?" -eq 0 ] && test_pass "classify_failure: every named class, plus a generic fallback for the unrecognized case" || test_fail "classify_failure: every named class, plus a generic fallback for the unrecognized case"

# available: connection loss is named distinctly (a timeout-shaped ssh
# failure, not a generic "cannot reach").
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" ssh 'echo "ssh: connect to host dxe-fixture-nas.invalid port 22: Operation timed out" >&2; exit 255'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    out="$(dx_runtime_available 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "connection loss" && printf '%s\n' "$out" | stdin_matches -F -- "Operation timed out"
)
[ "$?" -eq 0 ] && test_pass "available: a connect-timeout failure is named 'connection loss', with the raw ssh text quoted" || test_fail "available: a connect-timeout failure is named 'connection loss', with the raw ssh text quoted"

# available: authentication failure is named distinctly.
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" ssh 'echo "Permission denied (publickey)." >&2; exit 255'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    out="$(dx_runtime_available 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "authentication failure"
)
[ "$?" -eq 0 ] && test_pass "available: a bad-key failure is named 'authentication failure'" || test_fail "available: a bad-key failure is named 'authentication failure'"

# available: engine incompatibility is named with the classified reason
# too (a daemon-restart-shaped docker-level failure this time, not ssh).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_GUEST_SYSTEM=x86_64-linux
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    out="$(dx_runtime_available 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "daemon restart or unreachable" && printf '%s\n' "$out" | stdin_matches -F -- "Is the docker daemon running?"
)
[ "$?" -eq 0 ] && test_pass "available: an unreachable daemon is named 'daemon restart or unreachable', with the raw docker text quoted" || test_fail "available: an unreachable daemon is named 'daemon restart or unreachable', with the raw docker text quoted"

# system_running: failure is silent (matches Apple's own boolean-check
# convention) but still records the classifiable reason for a caller that
# wants it.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "Cannot connect to the Docker daemon. Is the docker daemon running?" >&2; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_system_running
    rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$DXE_RUNTIME_DOCKER_LAST_FAILURE" | stdin_matches "Is the docker daemon running"
)
[ "$?" -eq 0 ] && test_pass "system_running: records a classifiable failure reason without printing anything itself (matches Apple's silent convention)" || test_fail "system_running: records a classifiable failure reason without printing anything itself (matches Apple's silent convention)"

# container_system_ensure_started: names the runtime, never says "Apple"
# for docker-ssh, and never says anything docker-ssh-specific for apple
# (byte-for-byte unchanged message).
(
    DX_RUNTIME=apple
    unset DX_SYSTEM_WAIT_TIMEOUT
    service_ready=false
    container_system_is_running() { [ "$service_ready" = true ]; }
    dx_runtime_system_start() { service_ready=true; }
    out="$(container_system_ensure_started 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && [ "$out" = "Apple container system is not running; starting it..." ]
)
[ "$?" -eq 0 ] && test_pass "container_system_ensure_started: apple's message is byte-for-byte unchanged" || test_fail "container_system_ensure_started: apple's message is byte-for-byte unchanged"
(
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    unset DX_SYSTEM_WAIT_TIMEOUT
    service_ready=false
    container_system_is_running() { [ "$service_ready" = true ]; }
    dx_runtime_system_start() { service_ready=true; }
    out="$(container_system_ensure_started 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "dxe-fixture-nas.invalid" && ! printf '%s\n' "$out" | stdin_matches "Apple"
)
[ "$?" -eq 0 ] && test_pass "container_system_ensure_started: docker-ssh's message never says 'Apple'" || test_fail "container_system_ensure_started: docker-ssh's message never says 'Apple'"

# Source-only callers need the default even without dx_init_config. Use the
# real wait loop with a fake sleep so a never-ready service stays bounded.
(
    DX_RUNTIME=apple
    unset DX_SYSTEM_WAIT_TIMEOUT
    container_system_is_running() { return 1; }
    dx_runtime_system_start() { return 0; }
    sleep_log="$fixture/service-wait-sleeps"
    fake_service_sleep() { printf '%s\n' "$1" >> "$sleep_log"; }
    DX_SLEEP=fake_service_sleep
    out="$(container_system_ensure_started 2>&1)"; rc=$?
    [ "$rc" -eq 1 ] && [ "$(wc -l < "$sleep_log" | tr -d ' ')" -eq 30 ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "did not become ready within 30s"
)
[ "$?" -eq 0 ] && test_pass "container_system_ensure_started: source-only default bounds a never-ready service" || test_fail "container_system_ensure_started: source-only default bounds a never-ready service"

# --- Coverage-closing cases (kcov gaps found by the full coverage
# checkpoint, tests/run-coverage-linux.sh -- each proves a distinct branch
# a prior test's fake happened never to exercise) ---------------------------

# discover_bin: the ssh round trip for bin discovery itself fails (distinct
# from host_reachable's own earlier, separate check).
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" ssh '
last=""; for a in "$@"; do last="$a"; done
case "$last" in
    true) exit 0 ;;
    *) exit 255 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    out="$(dx_runtime_docker_discover_bin 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "could not reach"
)
[ "$?" -eq 0 ] && test_pass "discover_bin: a failed ssh round trip is reported distinctly" || test_fail "discover_bin: a failed ssh round trip is reported distinctly"

# check_arch: the uname round trip itself fails.
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" ssh 'exit 255'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    out="$(dx_runtime_docker_check_arch 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "could not run 'uname -m'"
)
[ "$?" -eq 0 ] && test_pass "check_arch: a failed uname round trip is reported distinctly" || test_fail "check_arch: a failed uname round trip is reported distinctly"

# check_arch: aarch64 maps and matches successfully (every other case so
# far only ever exercised x86_64 or a mismatch/unsupported value).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" uname 'case "$1" in -m) echo aarch64 ;; esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_GUEST_SYSTEM=aarch64-linux
    dx_runtime_docker_check_arch
)
[ "$?" -eq 0 ] && test_pass "check_arch: aarch64 maps to aarch64-linux and matches" || test_fail "check_arch: aarch64 maps to aarch64-linux and matches"

# discover_daemon_id: the info round trip itself fails.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_discover_daemon_id 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "could not query Docker daemon info"
)
[ "$?" -eq 0 ] && test_pass "discover_daemon_id: a failed info round trip is reported distinctly" || test_fail "discover_daemon_id: a failed info round trip is reported distinctly"

# Astra F3 item 5: resource_owned (via container_delete) must keep "does
# not exist" (Docker's own "No such container" text) genuinely distinct
# from "could not be read" (any other inspect failure -- a connection
# drop, a daemon restart, ...) -- an inspect error must be reported as an
# error, never silently folded into "absent".
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "Error: No such container: dx-qnap" >&2; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_container_delete dx-qnap 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] \
        && printf '%s\n' "$out" | stdin_matches "does not exist" \
        && ! printf '%s\n' "$out" | stdin_matches "could not be read"
)
[ "$?" -eq 0 ] && test_pass "container_delete: a genuinely absent target is reported as 'does not exist'" || test_fail "container_delete: a genuinely absent target is reported as 'does not exist'"

# The SAME non-zero exit, but the inspect failed for a reason OTHER than
# Docker's own "No such container" text (a bare, uninformative failure
# here -- as ambiguous as a real connection drop) -- must NOT be reported
# as "does not exist": that would silently treat "we could not tell" as
# "safe, nothing there", which is exactly the conflation Astra F3 item 5
# flags. This also upgrades what was previously a single combined-wording
# case (pre-Astra-F3: "does not exist or its labels could not be read").
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_container_delete dx-qnap 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] \
        && printf '%s\n' "$out" | stdin_matches "could not be read" \
        && ! printf '%s\n' "$out" | stdin_matches "does not exist"
)
[ "$?" -eq 0 ] && test_pass "container_delete: an uninformative inspect failure is reported as 'could not be read', never mistaken for absence" || test_fail "container_delete: an uninformative inspect failure is reported as 'could not be read', never mistaken for absence"

# The same distinction for a volume, and for a more realistic connection-
# style failure (never Docker's own "No such volume" wording).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "Error: Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_volume_delete dx-qnap-nix 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] \
        && printf '%s\n' "$out" | stdin_matches "could not be read" \
        && printf '%s\n' "$out" | stdin_matches -F -- "Cannot connect to the Docker daemon" \
        && ! printf '%s\n' "$out" | stdin_matches "does not exist"
)
[ "$?" -eq 0 ] && test_pass "volume_delete: a connection-style inspect failure is reported as 'could not be read', quoting the real failure, never mistaken for absence" \
    || test_fail "volume_delete: a connection-style inspect failure is reported as 'could not be read', quoting the real failure, never mistaken for absence"

# base_image_ref: a FROM line with no reference, and with more than one
# whitespace-separated token, both refuse.
containerfile_empty="$fixture/context-empty-from"
mkdir -p "$containerfile_empty"
printf 'FROM \n' > "$containerfile_empty/Containerfile"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "docker should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_image_build -t dx-qnap-nixos "$containerfile_empty" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "does not name a single image reference"
)
[ "$?" -eq 0 ] && test_pass "image_build: refuses a FROM line with no reference" || test_fail "image_build: refuses a FROM line with no reference"

containerfile_multi_token="$fixture/context-multi-token-from"
mkdir -p "$containerfile_multi_token"
printf 'FROM alpine AS builder\n' > "$containerfile_multi_token/Containerfile"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "docker should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_image_build -t dx-qnap-nixos "$containerfile_multi_token" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "does not name a single image reference"
)
[ "$?" -eq 0 ] && test_pass "image_build: refuses a FROM line with more than one token (e.g. a build stage alias)" || test_fail "image_build: refuses a FROM line with more than one token (e.g. a build stage alias)"

# volume_role: persist and bootstrap roles (every earlier test only ever
# exercised nix).
(
    export DX_NIX_VOLUME=dx-qnap-nix DX_PERSIST_VOLUME=dx-qnap-persist DX_BOOTSTRAP_VOLUME=dx-qnap-bootstrap
    [ "$(dx_runtime_docker_volume_role dx-qnap-persist)" = persist ] &&
    [ "$(dx_runtime_docker_volume_role dx-qnap-bootstrap)" = bootstrap ]
)
[ "$?" -eq 0 ] && test_pass "volume_role: persist and bootstrap map correctly (not just nix)" || test_fail "volume_role: persist and bootstrap map correctly (not just nix)"

# lock_release: nothing to release at all (inspect fails outright).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_lock_release "" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "no lock 'dxe-lock-dxe-fixture-nas.invalid__dx-qnap' to release"
)
[ "$?" -eq 0 ] && test_pass "lock_release: refuses when there is no lock at all to release" || test_fail "lock_release: refuses when there is no lock at all to release"

# dx_runtime_apple_container_create: the same "unknown parameter" fail-
# closed proof the docker adapter already has, on the Apple side too.
(
    out="$(dx_runtime_apple_container_create --totally-unknown-flag value --name dx-host --image dx-nixos 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "unknown parameter"
)
[ "$?" -eq 0 ] && test_pass "apple container_create: fails closed on an unrecognized parameter too" || test_fail "apple container_create: fails closed on an unrecognized parameter too"

# --- dx_runtime_volume_usage (Branch 11 / Phase 3, Increment 5, item 5):
# capability-aware size report for bin/dx-reclaim.
# The fake below answers the way a real Docker CLI does (verified live on
# Container Station Docker 27.1.2, 2026-09-27): the volume formatter exposes
# `.Size` as a human-readable string and has NO `.UsageData` field, so a
# template asking for the API byte count gets only a template error on
# stderr and no size -- exactly how the original byte-count implementation
# failed live. The fake therefore answers only a template that asks for
# `.Size`.
out="$(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "system df")
        shift 2
        case "$*" in
            *dxe-p3-nix*"{{.Size}}"*) echo 4.835MB ;;
            *dxe-p3-nix*UsageData*) echo "template: :1:65: executing at <.UsageData.Size>: cannot evaluate field UsageData in type *formatter.volumeContext" >&2 ;;
        esac
        exit 0
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_usage dxe-p3-nix
)"
[ "$out" = 4.835MB ] && test_pass "volume_usage (docker-ssh): returns the matching volume's human-readable .Size from docker system df -v" || test_fail "volume_usage (docker-ssh): returns the matching volume's human-readable .Size from docker system df -v (got: $out)"
out="$(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "system df") shift 2; case "$*" in *dxe-p3-na*"{{.Size}}"*) echo N/A ;; esac; exit 0 ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_usage dxe-p3-na
)"
[ "$out" = unknown ] && test_pass "volume_usage (docker-ssh): 'unknown' when Docker reports the size as N/A" || test_fail "volume_usage (docker-ssh): 'unknown' when Docker reports the size as N/A (got: $out)"
out="$(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1 $2" = "system df" ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_usage dxe-p3-absent
)"
[ "$out" = unknown ] && test_pass "volume_usage (docker-ssh): 'unknown' when the volume is absent from the report" || test_fail "volume_usage (docker-ssh): 'unknown' when the volume is absent from the report (got: $out)"
out="$(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_usage dxe-p3-nix
)"
[ "$out" = unknown ] && test_pass "volume_usage (docker-ssh): 'unknown' when the query fails outright" || test_fail "volume_usage (docker-ssh): 'unknown' when the query fails outright (got: $out)"

# dx-reclaim under docker-ssh: skips fstrim entirely (DQ4: no fstrim
# against a Docker volume), printing one line saying so; a poisoned
# fstrim proves it is never reached. Volume usage still reports (via
# dx_runtime_volume_usage) and Nix GC still runs in the guest.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "container inspect") echo true; exit 0 ;;
    "system df") exit 0 ;;
esac
case "$1" in
    exec)
        shift
        case "$*" in
            *fstrim*) echo "fstrim must never run under docker-ssh" >&2; exit 99 ;;
            *nix-collect-garbage*) exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dxe-p3-nix DX_PERSIST_VOLUME=dxe-p3-persist \
        DX_NIX_MOUNT=/nix \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-reclaim" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$out" | stdin_matches -F -- 'Skipping filesystem trim'
)
[ "$?" -eq 0 ] && test_pass "dx-reclaim (docker-ssh): skips fstrim entirely, never reaching the guest fstrim call" || test_fail "dx-reclaim (docker-ssh): skips fstrim entirely, never reaching the guest fstrim call"

# --- Fail-closed capability checks (Branch 11 / Phase 5, item 7) ----------

# capability: raw_nix_disk is yes for apple, no for docker-ssh (DQ8).
(
    DX_RUNTIME=apple dx_runtime_capability raw_nix_disk
)
[ "$?" -eq 0 ] && test_pass "capability: raw_nix_disk is yes for apple" || test_fail "capability: raw_nix_disk is yes for apple"
(
    DX_RUNTIME=docker-ssh dx_runtime_capability raw_nix_disk
)
[ "$?" -ne 0 ] && test_pass "capability: raw_nix_disk is no for docker-ssh (DQ8: dx-nix-disk is Apple-only)" \
    || test_fail "capability: raw_nix_disk is no for docker-ssh (DQ8: dx-nix-disk is Apple-only)"

# bin/dx-nix-disk (apple): unaffected, still prepares the sparse image.
(
    nix_disk_home="$(mktemp -d "${TMPDIR:-/tmp}/dxe-nix-disk-apple.XXXXXX")"
    nix_disk_path="$nix_disk_home/nix-store.img"
    env HOME="$nix_disk_home" DX_RUNTIME=apple DX_NIX_DISK="$nix_disk_path" DX_NIX_DISK_SIZE=1M \
        "$BASE_DIR/bin/dx-nix-disk" >/dev/null 2>&1
    [ -f "$nix_disk_path" ]
)
[ "$?" -eq 0 ] && test_pass "bin/dx-nix-disk (apple): unaffected by the new capability check, still prepares the sparse image" \
    || test_fail "bin/dx-nix-disk (apple): unaffected by the new capability check, still prepares the sparse image"

# bin/dx-nix-disk (docker-ssh): refuses immediately, before any mutation --
# no directory created, no file written, not even the "already exists"
# check reached.
(
    nix_disk_home="$(mktemp -d "${TMPDIR:-/tmp}/dxe-nix-disk-docker.XXXXXX")"
    nix_disk_path="$nix_disk_home/does-not-exist-yet/nix-store.img"
    out="$(env HOME="$nix_disk_home" DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_NIX_STORAGE_MODE=direct-volume DX_NIX_DISK="$nix_disk_path" DX_NIX_DISK_SIZE=1M \
        "$BASE_DIR/bin/dx-nix-disk" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ ! -e "$nix_disk_path" ] && [ ! -d "$(dirname "$nix_disk_path")" ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "dx-nix-disk is Apple-only"
)
[ "$?" -eq 0 ] && test_pass "bin/dx-nix-disk (docker-ssh): refuses before any mutation (DQ8: raw_nix_disk unsupported)" \
    || test_fail "bin/dx-nix-disk (docker-ssh): refuses before any mutation (DQ8: raw_nix_disk unsupported)"

# bin/dx-mount (docker-ssh): refuses before dx_require_container_cli even
# runs -- a hard-failing fake ssh/docker would be reached if the guard
# were not first, proving the refusal really does come first.
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" ssh 'echo "ssh should never be called" >&2; exit 99'
    fake_tool_write "$dir" docker 'echo "docker should never be called" >&2; exit 99'
    mount_home="$(mktemp -d "${TMPDIR:-/tmp}/dxe-mount-docker.XXXXXX")"
    PATH="$dir:/usr/bin:/bin"
    out="$(env HOME="$mount_home" DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap-mount PATH="$PATH" \
        "$BASE_DIR/bin/dx-mount" "$mount_home" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "dx-mount is not supported under DX_RUNTIME=docker-ssh" \
        && ! printf '%s\n' "$out" | stdin_matches -F -- "should never be called"
)
[ "$?" -eq 0 ] && test_pass "bin/dx-mount (docker-ssh): refuses before dx_require_container_cli, never reaching ssh or docker (DQ8: bind_mounts unsupported)" \
    || test_fail "bin/dx-mount (docker-ssh): refuses before dx_require_container_cli, never reaching ssh or docker (DQ8: bind_mounts unsupported)"

# dx_runtime_docker_container_create: refuses a git: (bind mount) volume
# spec before any docker call, regardless of caller (decision 4 -- closes
# the DX_GIT_MOUNT_SOURCE-set-directly gap the design note flagged: this
# is the adapter-level backstop, not only bin/dx-mount's own guard above).
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" ssh 'echo "ssh should never be called" >&2; exit 99'
    fake_tool_write "$dir" docker 'echo "docker should never be called" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_GUEST_SYSTEM=x86_64-linux
    DXE_RUNTIME_DOCKER_BIN=docker
    git_src="$(mktemp -d "${TMPDIR:-/tmp}/dxe-git-src.XXXXXX")"
    out="$(dx_runtime_container_create --name dx-qnap --image dx-qnap-nixos \
        --volume "git:$git_src:/workspace:rw" --publish 2222:2222 --entrypoint-cmd 'echo hi' 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "bind_mounts capability" \
        && ! printf '%s\n' "$out" | stdin_matches -F -- "should never be called"
)
[ "$?" -eq 0 ] && test_pass "container_create (docker-ssh): refuses a git: (bind mount) volume spec before any docker call (decision 4)" \
    || test_fail "container_create (docker-ssh): refuses a git: (bind mount) volume spec before any docker call (decision 4)"

# The success-rendering side of that same check: bind_mounts capability
# stubbed to "yes" (unreachable in production -- docker-ssh always
# answers no -- but the rendering line the check guards must still be
# proven to work correctly if that answer ever changed).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/git-volume-success-argv.log"
    fake_tool_write "$dir" docker "
case \"\$1\" in
    create) shift; printf '%s\n' \"\$@\" > '$argv_log'; exit 0 ;;
    *) echo \"UNMATCHED: \$*\" >&2; exit 99 ;;
esac"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    DXE_RUNTIME_DOCKER_BIN=docker
    # shellcheck disable=SC2034
    # Read by dx_runtime_docker_guest_ssh_address (bin/lib/dx-runtime-docker.sh)
    # when it caches/returns the address -- genuinely consumed, dynamically,
    # by the container_create call below.
    DXE_RUNTIME_GUEST_SSH_ADDRESS="$(tailnet_fixture_addr 64 3 3)"
    git_src="$(mktemp -d "${TMPDIR:-/tmp}/dxe-git-src-ok.XXXXXX")"
    dx_runtime_docker_capability() { [ "$1" = bind_mounts ] && return 0 || return 1; }
    dx_runtime_container_create --name dx-qnap --image dx-qnap-nixos \
        --volume "git:$git_src:/workspace:rw" --publish 2222:2222 --entrypoint-cmd 'echo hi' >/dev/null 2>&1
    grep -qF -- "$git_src:/workspace:rw" "$argv_log"
)
[ "$?" -eq 0 ] && test_pass "container_create (docker-ssh): renders a git: (bind mount) volume when bind_mounts capability IS supported" \
    || test_fail "container_create (docker-ssh): renders a git: (bind mount) volume when bind_mounts capability IS supported"

# --- WP8.3 step 1: docker adapter transcript-equality guard ---------------
# (findings.md WP8.3; docs/reviews/2026-09-29-muse.md A2,
# docs/reviews/2026-09-29-fable.md #A7, docs/reviews/2026-09-29-astra.md R3).
# Before splitting this file into a transport/identity/lifecycle/lock seam
# behind one facade, this is the safety net: drive a representative set of
# adapter operations -- bin/daemon discovery, container exists/is_running/
# start/stop/kill, volume exists, exec, and the read-only lock status --
# against tests/lib/harness.sh's shared with_fake_runtime ssh/fake_respond
# fakes, capture the resulting ssh argv transcript, and assert it is
# byte-for-byte identical to the fixture committed at
# tests/fixtures/docker-adapter-transcript.txt. A structural split that
# moves code between files without changing what any function actually
# sends over ssh leaves this transcript unchanged; one that does changes
# it, and this one case goes red immediately, without needing every one of
# this file's other cases to independently notice the same regression.
#
# Response keys below are built from dx_runtime_docker_ssh_option_argv and
# dx_runtime_docker_quote_argv themselves -- the same functions the adapter
# calls -- rather than hand-quoted literals: with_fake_runtime's own fake
# matches on the UNQUOTED "$*" of its own argv (ssh's option flags, the
# remote host, then the one already-%q-quoted command-string argument), and
# a hand-typed key would have to reproduce, byte for byte, whichever
# backslash-escaping this host's bash (3.2) happens to choose for a given
# token. Using the adapter's own quoting function to build the key keeps
# this in sync automatically; a real quoting regression still shows up as a
# transcript byte mismatch below (harness.sh's own %q call that WRITES the
# transcript is independent of dx_runtime_docker_quote_argv), it just would
# not also break response matching in a way that could mask the mismatch
# behind a preflight failure instead.
#
# The one exception is the bin-discovery script (sent by
# dx_runtime_docker_ssh_raw, not ssh_exec -- one RAW, never-%q-quoted,
# multi-line string): a fake_respond match key cannot itself contain a
# newline (tests/lib/harness.sh's .responses-ssh file is one
# newline-delimited record per registered response), so that key is
# deliberately truncated to the text before the script's first embedded
# newline -- still a unique, valid prefix, since fake_respond's own match
# is "the call's whole argv starts with KEY".
(
    dxe_s33t_bin="/usr/local/bin/docker"
    dxe_s33t_container="dxe-transcript-demo"
    dxe_s33t_volume="dxe-transcript-vol"
    DX_RUNTIME=docker-ssh
    DX_REMOTE_HOST=dxe-transcript-host
    DX_CONTAINER_NAME=dxe-transcript-container
    DX_GUEST_SYSTEM=x86_64-linux
    DX_SSH_CONNECT_TIMEOUT=15
    export DX_RUNTIME DX_REMOTE_HOST DX_CONTAINER_NAME DX_GUEST_SYSTEM DX_SSH_CONNECT_TIMEOUT
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID DXE_RUNTIME_GUEST_SSH_ADDRESS
    rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/dxe/$DX_CONTAINER_NAME" 2>/dev/null || true

    with_fake_runtime ssh

    dxe_s33t_remote_key() {
        printf '%s' "$(dx_runtime_docker_ssh_option_argv | tr '\n' ' ')$DX_REMOTE_HOST $(dx_runtime_docker_quote_argv "$@")"
    }

    fake_respond ssh "$(dxe_s33t_remote_key)DXE_DOCKER_BIN=\"\"" "$dxe_s33t_bin"
    fake_respond ssh "$(dx_runtime_docker_ssh_option_argv | tr '\n' ' ')$DX_REMOTE_HOST true" ""
    fake_respond ssh "$(dxe_s33t_remote_key uname -m)" "x86_64"
    fake_respond ssh "$(dxe_s33t_remote_key "$dxe_s33t_bin" version --format '{{.Server.Version}}')" "27.3.1"
    fake_respond ssh "$(dxe_s33t_remote_key "$dxe_s33t_bin" info --format '{{.ID}}|{{.Name}}|{{.Architecture}}|{{.OperatingSystem}}')" "dxe-transcript-daemon|dxe-transcript|x86_64|linux"
    fake_respond ssh "$(dxe_s33t_remote_key "$dxe_s33t_bin" container inspect --format '{{.State.Running}}' "$dxe_s33t_container")" "true"
    # WP6.4 / Astra F3: start/stop/kill now run the owned-resource check
    # (bin/lib/dx-runtime-docker-identity.sh's dx_runtime_docker_container_owned)
    # BEFORE the real command -- one more "container inspect --format ..."
    # round trip per call, all three sharing this SAME key (identical
    # container name and format every time), proving this profile owns
    # dxe-transcript-demo so start/stop/kill each still reach the real verb.
    fake_respond ssh "$(dxe_s33t_remote_key "$dxe_s33t_bin" container inspect --format '{{index .Config.Labels "io.dxe.managed"}}|{{index .Config.Labels "io.dxe.schema"}}|{{index .Config.Labels "io.dxe.profile"}}|{{index .Config.Labels "io.dxe.role"}}|{{index .Config.Labels "io.dxe.system"}}' "$dxe_s33t_container")" "true|1|dxe-transcript-host__dxe-transcript-container|container|x86_64-linux"
    fake_respond ssh "$(dxe_s33t_remote_key "$dxe_s33t_bin" container inspect --format '{{index .Config.Labels "io.dxe.owner"}}|{{.Created}}' "$(dx_runtime_docker_lock_name)")" "owner-token|2026-09-30T00:00:00Z"

    # Drive: discover the docker binary, run the full daemon-discovery
    # preflight, then container exists/is_running/start/stop/kill (each of
    # the latter three now preceded by its own ownership-check inspect),
    # volume exists, exec, and the read-only lock status.
    dx_runtime_docker_discover_bin >/dev/null 2>&1
    dx_runtime_docker_available >/dev/null 2>&1
    dx_runtime_docker_container_exists "$dxe_s33t_container" >/dev/null 2>&1
    dx_runtime_docker_container_running "$dxe_s33t_container" >/dev/null 2>&1
    dx_runtime_docker_container_start "$dxe_s33t_container" >/dev/null 2>&1
    dx_runtime_docker_container_stop "$dxe_s33t_container" >/dev/null 2>&1
    dx_runtime_docker_container_kill "$dxe_s33t_container" >/dev/null 2>&1
    dx_runtime_docker_volume_exists "$dxe_s33t_volume" >/dev/null 2>&1
    dx_runtime_docker_exec -i "$dxe_s33t_container" true >/dev/null 2>&1
    dx_runtime_docker_lock_audit >/dev/null 2>&1

    cp "$FAKE_TRANSCRIPT" "$fixture/docker-adapter-transcript.actual"
)
dxe_s33t_expected="$(cat "$BASE_DIR/tests/fixtures/docker-adapter-transcript.txt" 2>/dev/null)"
dxe_s33t_actual="$(cat "$fixture/docker-adapter-transcript.actual" 2>/dev/null)"
if [ "$dxe_s33t_actual" = "$dxe_s33t_expected" ]; then
    test_pass "docker adapter transcript-equality guard: a representative operation set's ssh argv matches tests/fixtures/docker-adapter-transcript.txt byte-for-byte"
else
    test_fail "docker adapter transcript-equality guard: a representative operation set's ssh argv matches tests/fixtures/docker-adapter-transcript.txt byte-for-byte"
    echo "  --- expected (tests/fixtures/docker-adapter-transcript.txt) ---"
    printf '%s\n' "$dxe_s33t_expected" | sed 's/^/    /'
    echo "  --- actual ---"
    printf '%s\n' "$dxe_s33t_actual" | sed 's/^/    /'
fi


rm -rf "$fixture" 2>/dev/null || true

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    print_summary
    exit_with_code
fi
