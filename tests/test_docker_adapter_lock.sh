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
# Fable D6 step 1: docker-ssh runtime adapter, lock part -- the remote
# per-profile lock, bin/dx-lock end to end, dx_lifecycle_lock_acquire/_release
# (Astra F4 / WP6.5), and entrypoints refusing to mutate while another
# controller holds the lock.
#
# Runnable standalone: bash tests/test_docker_adapter_lock.sh
# (prints its own banner and its own Results line for just its own
# cases). tests/test_docker_runtime_adapter.sh sources this file, in
# order with its four siblings, as section 33's one registered entry;
# sourced that way, this file prints no banner of its own and defers
# print_summary/exit_with_code to the aggregate, so section 33 still
# reports one combined Results line for all 208 cases.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    test_section "Docker-ssh runtime adapter (Branch 11 / Phase 2) -- lock"
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

# The lock container's base image is the Containerfile's pinned FROM
# reference (never $DX_IMAGE, which does not exist for a never-created
# profile), read from DX_CONTEXT_DIR -- which bin/lib/dx-config.sh always
# resolves for a real run. Direct-call scenarios below use this repository's
# own context directory; the missing-Containerfile scenario overrides it.
export DX_CONTEXT_DIR="$BASE_DIR/container/dx-nixos-26.05"
lock_base_ref="$(sed -n 's/^FROM //p' "$DX_CONTEXT_DIR/Containerfile")"

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


# --- Remote per-profile lock (item 6) --------------------------------------

# Acquire: succeeds, prints the owner token it just claimed.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = create ] && [ "$2" = --name ] && [ "$3" = dxe-lock-qnap-dxe__dx-qnap ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    owner="$(dx_runtime_docker_lock_acquire)"
    [ -n "$owner" ] && printf '%s\n' "$owner" | stdin_matches ":"
)
[ "$?" -eq 0 ] && test_pass "lock_acquire: succeeds and prints a non-empty owner token" || test_fail "lock_acquire: succeeds and prints a non-empty owner token"

# Acquire: the lock container carries io.dxe.system too (Branch 11 / Phase
# 4) -- proven via the shared dx_runtime_docker_label_flags helper, not a
# hand-duplicated label list.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/lock-acquire-argv.log"
    fake_tool_write "$dir" docker "
[ \"\$1\" = create ] || { echo UNMATCHED >&2; exit 99; }
shift
printf '%s\n' \"\$@\" > '$argv_log'
"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_docker_lock_acquire >/dev/null
    got="$(cat "$argv_log")"
    printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.system=x86_64-linux" \
        && printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.role=lock" \
        && printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.owner="
)
[ "$?" -eq 0 ] && test_pass "lock_acquire carries io.dxe.system alongside its existing DQ6 labels" || test_fail "lock_acquire carries io.dxe.system alongside its existing DQ6 labels"

# The lock container is never started, so it gets no hostname flag (only the
# guest container does; see test_docker_adapter_lifecycle.sh).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/lock-acquire-nohostname.log"
    fake_tool_write "$dir" docker "
[ \"\$1\" = create ] || { echo UNMATCHED >&2; exit 99; }
shift
printf '%s\n' \"\$@\" > '$argv_log'
"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_docker_lock_acquire >/dev/null
    [ -s "$argv_log" ] && ! stdin_matches -F -- "--hostname" < "$argv_log"
)
[ "$?" -eq 0 ] && test_pass "lock_acquire passes no --hostname (the lock container is never started)" || test_fail "lock_acquire passes no --hostname (the lock container is never started)"

# Acquire: fails (name conflict) when already held.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "Error: Conflict. The container name ... is already in use" >&2; exit 1'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_lock_acquire 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "may already be held"
)
[ "$?" -eq 0 ] && test_pass "lock_acquire: refuses when the lock is already held" || test_fail "lock_acquire: refuses when the lock is already held"

# Acquire: the lock's (never run) base image is the Containerfile's pinned
# base reference, never $DX_IMAGE -- the profile's own image is a local-only
# tag that does not exist (and cannot be pulled) before dx-create-image.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/lock-acquire-image.log"
    fake_tool_write "$dir" docker "
[ \"\$1\" = create ] || { echo UNMATCHED >&2; exit 99; }
printf '%s\\n' \"\${!#}\" > '$argv_log'
"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_docker_lock_acquire >/dev/null || exit 1
    [ -n "$lock_base_ref" ] && [ "$(cat "$argv_log")" = "$lock_base_ref" ] && [ "$(cat "$argv_log")" != dx-qnap-nixos ]
)
[ "$?" -eq 0 ] && test_pass "lock_acquire: the lock container uses the pinned base image reference, not DX_IMAGE" || test_fail "lock_acquire: the lock container uses the pinned base image reference, not DX_IMAGE"

# Acquire for a profile whose own image is absent on the remote daemon: the
# fake daemon only knows the pinned base image (create of any other image
# fails like a missing, un-pullable local tag), and the acquire succeeds.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker "
[ \"\$1\" = create ] || { echo UNMATCHED >&2; exit 99; }
[ \"\${!#}\" = '$lock_base_ref' ] && exit 0
echo \"Unable to find image '\${!#}' locally\" >&2; exit 1
"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-new DX_IMAGE=dx-new-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    owner="$(dx_runtime_docker_lock_acquire)" && [ -n "$owner" ]
)
[ "$?" -eq 0 ] && test_pass "lock_acquire: succeeds for a never-created profile whose DX_IMAGE is absent remotely" || test_fail "lock_acquire: succeeds for a never-created profile whose DX_IMAGE is absent remotely"

# Acquire: a pinned base reference that cannot be read is a configuration
# error (no guessing, no docker call at all), for a missing Containerfile
# and for an unset DX_CONTEXT_DIR alike.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/lock-acquire-noref.log"
    : > "$argv_log"
    fake_tool_write "$dir" docker "printf '%s\\n' \"\$*\" >> '$argv_log'; exit 0"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    empty_ctx="$fixture/empty-context"; mkdir -p "$empty_ctx"
    out="$(DX_CONTEXT_DIR="$empty_ctx" dx_runtime_docker_lock_acquire 2>&1)"; rc1=$?
    out2="$(unset DX_CONTEXT_DIR; dx_runtime_docker_lock_acquire 2>&1)"; rc2=$?
    [ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ] && [ ! -s "$argv_log" ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "no Containerfile in $empty_ctx" \
        && printf '%s\n' "$out2" | stdin_matches "DX_CONTEXT_DIR"
)
[ "$?" -eq 0 ] && test_pass "lock_acquire: an unreadable pinned base reference is a configuration error with no docker call" || test_fail "lock_acquire: an unreadable pinned base reference is a configuration error with no docker call"

# Acquire: held case still refuses and prints the owner metadata (directly,
# not only through dx_lifecycle_lock_acquire).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "create --name") echo "Error: Conflict. The container name ... is already in use" >&2; exit 1 ;;
    "container inspect") echo "ghost-host:7:8:20260101T000000Z|2026-01-01T00:00:00Z" ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_lock_acquire 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "held by ghost-host:7:8:20260101T000000Z since 2026-01-01T00:00:00Z"
)
[ "$?" -eq 0 ] && test_pass "lock_acquire: a held lock still refuses and prints the owner metadata" || test_fail "lock_acquire: a held lock still refuses and prints the owner metadata"

# dx for a never-created profile (fake docker that only knows the pinned base
# image; stub lifecycle children; real lifecycle-lock functions): the lock is
# acquired BEFORE dx-create-image (WP6.5) and the bring-up still runs
# dx-create-keys -> ... -> dx-start-container in order, then dx-ssh.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    flow_log="$fixture/dx-new-profile-flow.log"
    : > "$flow_log"
    fake_tool_write "$dir" docker "
case \"\$1\" in
    create)
        [ \"\${!#}\" = '$lock_base_ref' ] || { echo \"Unable to find image '\${!#}' locally\" >&2; exit 1; }
        printf 'lock-created\\n' >> '$flow_log'; exit 0 ;;
    container) echo \"true|qnap-dxe__dx-new|lock|\$DXE_LIFECYCLE_LOCK_OWNER\"; exit 0 ;;
    rm) printf 'lock-released\\n' >> '$flow_log'; exit 0 ;;
    *) echo \"UNMATCHED: \$*\" >&2; exit 99 ;;
esac
"
    children="$fixture/dx-new-profile-children"
    mkdir -p "$children"
    for child in dx-create-keys dx-create-image dx-create-volumes dx-create-container dx-start-container dx-wait-ssh dx-ssh; do
        printf '#!/bin/bash\nprintf "%%s\\n" "${0##*/}" >> "%s"\n' "$flow_log" > "$children/$child"
        chmod +x "$children/$child"
    done
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-new DX_IMAGE=dx-new-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_require_container_cli() { return 0; }
    container_system_is_running() { return 0; }
    container_is_running() { return 1; }
    dx_connect_or_bring_up "$children" >/dev/null 2>&1 || exit 1
    [ "$(tr '\n' ' ' < "$flow_log")" = "lock-created dx-create-keys dx-create-image dx-create-volumes dx-create-container dx-start-container dx-wait-ssh lock-released dx-ssh " ]
)
[ "$?" -eq 0 ] && test_pass "dx (docker-ssh, never-created profile): locks with the pinned base image, then runs dx-create-keys through dx-start-container in order" || test_fail "dx (docker-ssh, never-created profile): locks with the pinned base image, then runs dx-create-keys through dx-start-container in order"

# Audit: "not held" when absent.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    [ "$(dx_runtime_docker_lock_audit)" = "not held" ]
)
[ "$?" -eq 0 ] && test_pass "lock_audit: reports 'not held' when absent" || test_fail "lock_audit: reports 'not held' when absent"

# Audit: "held by ... since ..." when present. (owner|created -- 2 fields)
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1 $2" = "container inspect" ] && echo "somehost:123:456:20260927T000000Z|2026-09-27T00:00:00Z"'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_lock_audit)"
    printf '%s\n' "$out" | stdin_matches -F -- "held by somehost:123:456:20260927T000000Z since 2026-09-27T00:00:00Z"
)
[ "$?" -eq 0 ] && test_pass "lock_audit: reports the owner and creation time when held" || test_fail "lock_audit: reports the owner and creation time when held"

# Release: succeeds when profile/role labels match (no owner check
# requested). Release's own inspect format is 4 fields:
# managed|profile|role|owner (no schema -- distinct from
# dx_runtime_docker_container_labels' managed|schema|profile|role shape
# used elsewhere).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "true|qnap-dxe__dx-qnap|lock|owner-x" ;;
    *) [ "$1" = rm ] && [ "$2" = dxe-lock-qnap-dxe__dx-qnap ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_docker_lock_release ""
)
[ "$?" -eq 0 ] && test_pass "lock_release: succeeds when profile/role labels match" || test_fail "lock_release: succeeds when profile/role labels match"

# Release: refuses when labelled for a different profile.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "true|qnap-OTHER__dx-qnap|lock|owner-x" ;;
    *) echo "docker rm should never run" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_lock_release "" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "lock_release: refuses a lock labelled for a different profile" || test_fail "lock_release: refuses a lock labelled for a different profile"

# Release: refuses when an expected owner is given and does not match.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "true|qnap-dxe__dx-qnap|lock|owner-real" ;;
    *) echo "docker rm should never run" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_lock_release owner-expected-but-different 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "held by a different owner"
)
[ "$?" -eq 0 ] && test_pass "lock_release: refuses when the current owner does not match an expected one" || test_fail "lock_release: refuses when the current owner does not match an expected one"

# --- bin/dx-lock end to end --------------------------------------------

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    out="$(DX_RUNTIME=apple "$BASE_DIR/bin/dx-lock" status 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "only applies to DX_RUNTIME=docker-ssh"
)
[ "$?" -eq 0 ] && test_pass "bin/dx-lock refuses for DX_RUNTIME=apple" || test_fail "bin/dx-lock refuses for DX_RUNTIME=apple"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1" ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux" ;;
    "container inspect") exit 1 ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx-lock" status 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "not held"
)
[ "$?" -eq 0 ] && test_pass "bin/dx-lock status reports 'not held' end to end" || test_fail "bin/dx-lock status reports 'not held' end to end"

# unlock (no --force): only the audit query runs (owner|created, 2 fields)
# -- release is never reached, so the fake never needs to answer its
# 4-field shape here.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1" ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux" ;;
    "container inspect") echo "somehost:1:2:20260927T000000Z|2026-09-27T00:00:00Z" ;;
    *) echo "docker rm should never run without --force" >&2; exit 99 ;;
esac'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx-lock" unlock 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "Refusing to unlock without --force" && printf '%s\n' "$out" | stdin_matches -F -- "somehost:1:2:20260927T000000Z"
)
[ "$?" -eq 0 ] && test_pass "bin/dx-lock unlock without --force shows owner metadata and refuses" || test_fail "bin/dx-lock unlock without --force shows owner metadata and refuses"

# unlock --force: audit runs first (2-field shape), then release (4-field
# shape) -- the fake distinguishes them by which label keys appear in the
# requested --format string, since both are the same "container inspect"
# verb with a different --format argument.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1" ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux" ;;
    "container inspect")
        case "$*" in
            *"io.dxe.managed"*) echo "true|qnap-dxe__dx-qnap|lock|somehost:1:2:20260927T000000Z" ;;
            *) echo "somehost:1:2:20260927T000000Z|2026-09-27T00:00:00Z" ;;
        esac
        ;;
    *) [ "$1" = rm ] && [ "$2" = dxe-lock-qnap-dxe__dx-qnap ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx-lock" unlock --force 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "Lock released."
)
[ "$?" -eq 0 ] && test_pass "bin/dx-lock unlock --force removes the lock end to end" || test_fail "bin/dx-lock unlock --force removes the lock end to end"

# --- dx_lifecycle_lock_acquire/_release (Astra F4 / WP6.5) -----------------
#
# The operation-level boundary bin/lib/dx-container.sh exposes over the
# lock-container protocol above: no production caller acquired it before
# this. Apple's own local-lock dispatch is covered in
# tests/test_section9_host_scripts.sh (Apple has no remote daemon to
# exclude, so bin/dx-lock itself already refuses for DX_RUNTIME=apple).

# Direct call, lock free: acquire then release wraps around nothing else --
# exactly one create, then exactly one rm, and DXE_LIFECYCLE_LOCK_OWNER is
# set only in between.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/lifecycle-lock-direct.log"
    fake_tool_write "$dir" docker "
case \"\$1 \$2\" in
    \"create --name\") printf 'create\\n' >> '$argv_log'; exit 0 ;;
    \"container inspect\") echo \"true|qnap-dxe__dx-qnap|lock|\$DXE_LIFECYCLE_LOCK_OWNER\" ;;
    \"rm dxe-lock-qnap-dxe__dx-qnap\") printf 'rm\\n' >> '$argv_log'; exit 0 ;;
    *) echo \"UNMATCHED: \$*\" >&2; exit 99 ;;
esac
"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    [ -z "${DXE_LIFECYCLE_LOCK_OWNER:-}" ] || exit 1
    dx_lifecycle_lock_acquire || exit 1
    owner_while_held="$DXE_LIFECYCLE_LOCK_OWNER"
    dx_lifecycle_lock_release
    [ -n "$owner_while_held" ] && [ -z "${DXE_LIFECYCLE_LOCK_OWNER:-}" ] && [ "$(cat "$argv_log")" = $'create\nrm' ]
)
[ "$?" -eq 0 ] && test_pass "dx_lifecycle_lock_acquire/_release (docker-ssh): a direct call acquires then releases around itself" \
    || test_fail "dx_lifecycle_lock_acquire/_release (docker-ssh): a direct call acquires then releases around itself"

# Already held by another controller: refuses, reports the current owner
# and the remedy (dx-lock status / dx-lock unlock --force), and issues NO
# release call -- never silently stolen, whether the owner is live or its
# process is long gone (this fixture's own token names a PID this test
# never started).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/lifecycle-lock-held.log"
    fake_tool_write "$dir" docker "
case \"\$1 \$2\" in
    \"create --name\") printf 'create-attempt\\n' >> '$argv_log'; echo 'Error: Conflict. The container name ... is already in use' >&2; exit 1 ;;
    \"container inspect\") printf 'audit\\n' >> '$argv_log'; echo 'ghost-host:999999:1:20260101T000000Z|2026-01-01T00:00:00Z' ;;
    \"rm dxe-lock-qnap-dxe__dx-qnap\") printf 'rm\\n' >> '$argv_log'; exit 0 ;;
    *) echo \"UNMATCHED: \$*\" >&2; exit 99 ;;
esac
"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_lifecycle_lock_acquire 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ -z "${DXE_LIFECYCLE_LOCK_OWNER:-}" ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "ghost-host:999999:1:20260101T000000Z" \
        && printf '%s\n' "$out" | stdin_matches -F -- "dx-lock unlock --force" \
        && printf '%s\n' "$out" | stdin_matches -F -- "dx-lock status" \
        && [ "$(cat "$argv_log")" = $'create-attempt\naudit' ]
)
[ "$?" -eq 0 ] && test_pass "dx_lifecycle_lock_acquire (docker-ssh): an already-held (even interrupted) lock refuses, reports the owner and the remedy, and never releases it" \
    || test_fail "dx_lifecycle_lock_acquire (docker-ssh): an already-held (even interrupted) lock refuses, reports the owner and the remedy, and never releases it"

# Nested/inherited: DXE_LIFECYCLE_LOCK_OWNER already set (an orchestrator's
# own acquisition, inherited via the environment) means this call issues NO
# docker call at all -- neither on acquire nor on release, since local
# release responsibility (DXE_LIFECYCLE_LOCK_HELD) belongs only to whichever
# frame actually performed the acquire.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/lifecycle-lock-nested.log"
    fake_tool_write "$dir" docker "printf '%s\\n' \"\$*\" >> '$argv_log'; exit 99"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    export DXE_LIFECYCLE_LOCK_OWNER=inherited-owner-token
    dx_lifecycle_lock_acquire; acquire_rc=$?
    dx_lifecycle_lock_release; release_rc=$?
    [ "$acquire_rc" -eq 0 ] && [ "$release_rc" -eq 0 ] \
        && [ "$DXE_LIFECYCLE_LOCK_OWNER" = inherited-owner-token ] && [ ! -s "$argv_log" ]
)
[ "$?" -eq 0 ] && test_pass "dx_lifecycle_lock_acquire/_release (docker-ssh): an inherited owner token is a no-op, zero docker calls" \
    || test_fail "dx_lifecycle_lock_acquire/_release (docker-ssh): an inherited owner token is a no-op, zero docker calls"

# Real nested inheritance across a fork: the parent acquires (exported), a
# genuine forked child process inherits the owner token and issues no
# acquire/release call of its own, and only the parent's own release
# actually reaches docker -- exactly one create and one rm across the
# whole parent+child orchestration (bin/dx's own "acquires once, children
# inherit" shape, exercised here through a real process boundary rather
# than the single in-process check above).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/lifecycle-lock-fork.log"
    fake_tool_write "$dir" docker "
case \"\$1 \$2\" in
    \"create --name\") printf 'create\\n' >> '$argv_log'; exit 0 ;;
    \"container inspect\") echo \"true|qnap-dxe__dx-qnap|lock|\$DXE_LIFECYCLE_LOCK_OWNER\" ;;
    \"rm dxe-lock-qnap-dxe__dx-qnap\") printf 'rm\\n' >> '$argv_log'; exit 0 ;;
    *) echo \"UNMATCHED: \$*\" >&2; exit 99 ;;
esac
"
    export PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_lifecycle_lock_acquire || exit 1
    bash -c '
        source "$1"
        source "$2"
        dx_lifecycle_lock_acquire || exit 1
        dx_lifecycle_lock_release
    ' _ "$BASE_DIR/bin/lib/dx-host-util.sh" "$BASE_DIR/bin/lib/dx-container.sh"
    child_rc=$?
    dx_lifecycle_lock_release
    [ "$child_rc" -eq 0 ] && [ "$(cat "$argv_log")" = $'create\nrm' ]
)
[ "$?" -eq 0 ] && test_pass "dx_lifecycle_lock_acquire/_release (docker-ssh): a forked child inherits the owner token; only the parent's release reaches docker" \
    || test_fail "dx_lifecycle_lock_acquire/_release (docker-ssh): a forked child inherits the owner token; only the parent's release reaches docker"

# dx_lifecycle_lock_acquire's OTHER dispatch target: DX_RUNTIME=apple (the
# default), where it refuses through dx_runtime_lock_acquire's local
# mkdir-lock contention rather than any docker call at all (tests/
# test_section9_host_scripts.sh proves the same behaviour through the real
# bin/dx-stop-container entrypoint, but that suite is not one of
# tests/run-coverage-contracts.sh's dispatched suites, so kcov's gate never
# sees a case added there -- this file's own aggregate IS dispatched, so the
# direct call belongs here instead). A genuinely different, still-live
# process (a real bash -c child) holds the same profile's local Apple lock;
# dx_lifecycle_lock_acquire must refuse, reporting the profile's own remedy
# text, never silently stealing it.
(
    lock_home="$fixture/apple-lifecycle-lock-contend-home"
    export XDG_STATE_HOME="$lock_home/state"
    unset DX_RUNTIME
    export DX_CONTAINER_NAME=dxe-p33-apple-lifecycle-contend
    export DX_TUNNEL_LOCK_TIMEOUT=1
    ready="$fixture/apple-lifecycle-lock-contend-ready"; hold="$fixture/apple-lifecycle-lock-contend-hold"
    rm -f "$ready" "$hold"; : > "$hold"
    bash -c '
        source "$1"
        source "$2"
        dx_runtime_apple_lock_acquire >/dev/null
        : > "$3"
        while [ -e "$4" ]; do sleep 1; done
    ' _ "$BASE_DIR/bin/lib/dx-host-util.sh" "$BASE_DIR/bin/lib/dx-runtime-apple.sh" "$ready" "$hold" &
    holder_pid=$!
    for _ in $(seq 1 20); do [ -e "$ready" ] && break; sleep 1; done
    [ -e "$ready" ] || { rm -f "$hold"; wait "$holder_pid" 2>/dev/null || true; exit 1; }
    [ -z "${DXE_LIFECYCLE_LOCK_OWNER:-}" ] || exit 1
    rc=0; out="$(dx_lifecycle_lock_acquire 2>&1)" || rc=$?
    rm -f "$hold"
    wait "$holder_pid" 2>/dev/null || true
    [ "$rc" -ne 0 ] && [ -z "${DXE_LIFECYCLE_LOCK_OWNER:-}" ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "another local dx process already holds"
) && test_pass "dx_lifecycle_lock_acquire (apple, direct call): refuses while another live process holds the local lifecycle lock" \
    || test_fail "dx_lifecycle_lock_acquire (apple, direct call): refuses while another live process holds the local lifecycle lock"

# --- Entrypoints refuse while another controller holds the lock ------------
#
# Every mutating entrypoint below (Astra F4's own list) must refuse before
# its own first mutating runtime call once dx_lifecycle_lock_acquire cannot
# claim the lock -- proven here by making the lock's own "create" always
# report a conflict (a live-or-interrupted owner both look identical to
# this atomic primitive, so this one fixture covers both), and asserting
# the resulting argv_log -- every OTHER mutating verb this fixture's fake
# docker accepts -- stays completely empty.
#
# container_exists/image_exists are plain 0/1 flags: each entrypoint's own
# preflight questions still get a truthful answer, so the lock is
# unambiguously the reason it refuses, never an earlier unrelated guard.
dxe_wp65_write_lock_held_docker() {
    local dir="$1" argv_log="$2" container_exists="$3" image_exists="$4"
    fake_tool_write "$dir" docker "
case \"\$1 \$2\" in
    \"version --format\") echo 27.3.1 ;;
    \"info --format\") echo 'abc123def|qnap-fake|x86_64|linux' ;;
    # bin/dx's service-readiness probe: a read-only plain docker info.
    \"info \") exit 0 ;;
    \"container inspect\")
        case \"\$*\" in
            *dxe-lock-*) echo 'someone-else:1:2:20260101T000000Z|2026-01-01T00:00:00Z' ;;
            *) [ '$container_exists' = 1 ] && echo true || exit 1 ;;
        esac
        ;;
    \"image inspect\") [ '$image_exists' = 1 ] && exit 0 || exit 1 ;;
    \"create --name\")
        case \"\$*\" in
            *dxe-lock-*) echo 'Error: Conflict. The container name ... is already in use' >&2; exit 1 ;;
            *) printf 'MUTATE %s\\n' \"\$*\" >> '$argv_log'; exit 0 ;;
        esac
        ;;
    *) printf 'MUTATE %s\\n' \"\$*\" >> '$argv_log'; exit 0 ;;
esac
"
}

# dx-create-container: image exists, container absent -- would otherwise
# proceed straight to the real create.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/wp65-create-container-lock-held.log"
    dxe_wp65_write_lock_held_docker "$dir" "$argv_log" 0 1
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx-create-container" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ ! -s "$argv_log" ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "someone-else:1:2:20260101T000000Z"
)
[ "$?" -eq 0 ] && test_pass "dx-create-container (docker-ssh): refuses while the lifecycle lock is held, zero mutating calls" \
    || test_fail "dx-create-container (docker-ssh): refuses while the lifecycle lock is held, zero mutating calls"

# dx-start-container: container already exists -- would otherwise proceed
# to the nix claim and dx_runtime_container_start.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/wp65-start-container-lock-held.log"
    dxe_wp65_write_lock_held_docker "$dir" "$argv_log" 1 1
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx-start-container" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ ! -s "$argv_log" ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "someone-else:1:2:20260101T000000Z"
)
[ "$?" -eq 0 ] && test_pass "dx-start-container (docker-ssh): refuses while the lifecycle lock is held, zero mutating calls" \
    || test_fail "dx-start-container (docker-ssh): refuses while the lifecycle lock is held, zero mutating calls"

# dx-stop-container: the lock is acquired right after preflight, before
# container_stop_bounded ever asks whether the container exists.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/wp65-stop-container-lock-held.log"
    dxe_wp65_write_lock_held_docker "$dir" "$argv_log" 1 1
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx-stop-container" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ ! -s "$argv_log" ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "someone-else:1:2:20260101T000000Z"
)
[ "$?" -eq 0 ] && test_pass "dx-stop-container (docker-ssh): refuses while the lifecycle lock is held, zero mutating calls" \
    || test_fail "dx-stop-container (docker-ssh): refuses while the lifecycle lock is held, zero mutating calls"

# dx-destroy-container: container exists -- would otherwise proceed to
# container_is_running/stop/delete.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/wp65-destroy-container-lock-held.log"
    dxe_wp65_write_lock_held_docker "$dir" "$argv_log" 1 1
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx-destroy-container" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ ! -s "$argv_log" ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "someone-else:1:2:20260101T000000Z"
)
[ "$?" -eq 0 ] && test_pass "dx-destroy-container (docker-ssh): refuses while the lifecycle lock is held, zero mutating calls" \
    || test_fail "dx-destroy-container (docker-ssh): refuses while the lifecycle lock is held, zero mutating calls"

# dx-recreate: its own preflight+lock acquire runs before it ever forks
# bin/dx-destroy -- proven both by the empty argv_log (no docker mutation
# at all) and by dx-destroy-container/dx-destroy-image's own "does not
# exist"/"Removing" prose never appearing, since neither script ran.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/wp65-recreate-lock-held.log"
    dxe_wp65_write_lock_held_docker "$dir" "$argv_log" 0 1
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx-recreate" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ ! -s "$argv_log" ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "someone-else:1:2:20260101T000000Z" \
        && ! printf '%s\n' "$out" | stdin_matches -F -- "nothing to destroy" \
        && ! printf '%s\n' "$out" | stdin_matches -F -- "Removing container"
)
[ "$?" -eq 0 ] && test_pass "dx-recreate (docker-ssh): refuses while the lifecycle lock is held, before bin/dx-destroy ever runs" \
    || test_fail "dx-recreate (docker-ssh): refuses while the lifecycle lock is held, before bin/dx-destroy ever runs"

# dx: the lock is acquired right after preflight, before
# container_system_ensure_started or any of its child scripts
# (dx-create-keys/dx-create-image/.../dx-start-container) ever run.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/wp65-dx-lock-held.log"
    dxe_wp65_write_lock_held_docker "$dir" "$argv_log" 0 1
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && [ ! -s "$argv_log" ] \
        && printf '%s\n' "$out" | stdin_matches -F -- "someone-else:1:2:20260101T000000Z" \
        && ! printf '%s\n' "$out" | stdin_matches -F -- "Starting container" \
        && ! printf '%s\n' "$out" | stdin_matches -F -- "Generating SSH keypair"
)
[ "$?" -eq 0 ] && test_pass "dx (docker-ssh): refuses while the lifecycle lock is held, before any child script runs" \
    || test_fail "dx (docker-ssh): refuses while the lifecycle lock is held, before any child script runs"

# Direct-call battery: dx_runtime_docker_lock_path (bin/lib/dx-runtime.sh's
# dx_runtime_lock_path dispatch target for DX_RUNTIME=docker-ssh). No
# production caller ever reaches this: bin/lib/dx-container.sh's
# dx_lifecycle_lock_acquire only calls dx_runtime_lock_path in its Apple
# branch (the docker-ssh branch gets its owner token from
# dx_runtime_lock_acquire's own stdout instead) -- this function exists
# purely so the runtime dispatch has a docker-ssh target to resolve to at
# all, and always fails closed. Call it directly, as the dispatch would.
(
    out="$(dx_runtime_docker_lock_path 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "docker-ssh's lock lives in the remote lock container, not a local directory"
)
[ "$?" -eq 0 ] && test_pass "dx_runtime_docker_lock_path: always fails closed (direct call, no docker-ssh caller ever reaches it)" \
    || test_fail "dx_runtime_docker_lock_path: always fails closed (direct call, no docker-ssh caller ever reaches it)"

rm -rf "$fixture" 2>/dev/null || true

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    print_summary
    exit_with_code
fi
