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
# Fable D6 step 1: docker-ssh runtime adapter, transport part -- ssh
# transport: quote_argv, preflight/availability, the drift guard, guest SSH
# address discovery, known-hosts pinning, the dx-enter TTY rule, dx-put/dx-get
# (never the guest SSH), and dx-backup's exec discipline.
#
# Runnable standalone: bash tests/test_docker_adapter_transport.sh
# (prints its own banner and its own Results line for just its own
# cases). tests/test_docker_runtime_adapter.sh sources this file, in
# order with its four siblings, as section 33's one registered entry;
# sourced that way, this file prints no banner of its own and defers
# print_summary/exit_with_code to the aggregate, so section 33 still
# reports one combined Results line for all 208 cases.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    test_section "Docker-ssh runtime adapter (Branch 11 / Phase 2) -- transport"
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


# --- dx_runtime_docker_quote_argv: the single-remote-command-string quoting
# discipline that stands in for a real remote argv (docs/refactor/
# docker-adapter-mapping.md section 1). Every property the mapping doc's
# "add tests for tokens with spaces, single/double quotes, $, globs, and
# newlines" requirement asks for, proven by round-tripping through a real
# `eval` exactly the way a real remote login shell parses ssh's joined
# command string.
assert_roundtrip() {
    local label="$1"; shift
    local joined out
    joined="$(dx_runtime_docker_quote_argv "$@")"
    out="$(eval "printf '<%s>' $joined")"
    local expected="" a
    for a in "$@"; do expected="$expected<$a>"; done
    [ "$out" = "$expected" ] && test_pass "$label" || test_fail "$label (joined=[$joined] got=[$out] want=[$expected])"
}
assert_roundtrip "quoting round-trips a plain token" docker version
assert_roundtrip "quoting round-trips a token with spaces" "hello world"
assert_roundtrip "quoting round-trips a token with a single quote" "it's a test"
assert_roundtrip "quoting round-trips a token with a double quote" 'say "hi"'
assert_roundtrip "quoting round-trips a token with a dollar sign" 'price: $5'
assert_roundtrip "quoting round-trips a token with a glob character" '*.txt'
assert_roundtrip "quoting round-trips a token with an embedded newline" "$(printf 'line1\nline2')"
assert_roundtrip "quoting round-trips a token with a semicolon (no command injection)" 'a; rm -rf /'
assert_roundtrip "quoting round-trips a token with backticks (no command substitution)" 'a`id`b'
assert_roundtrip "quoting round-trips multiple tokens preserving boundaries" "one two" "three" "" "five"
assert_roundtrip "quoting round-trips an empty token" ""
assert_roundtrip "quoting round-trips a Go template format string verbatim" '{{.State.Running}}'
assert_roundtrip "quoting round-trips a docker --format with index()" '{{index .Config.Labels "io.dxe.role"}}'

# A planted injection attempt must never execute as a second command: the
# whole point of per-token quoting is that "$@" always reconstructs to
# EXACTLY the original argv, never fewer or extra shell words.
injection_marker="$fixture/injection-marker"
rm -f "$injection_marker"
joined="$(dx_runtime_docker_quote_argv "safe" "; touch $injection_marker #")"
eval "set -- $joined"
[ "$#" -eq 2 ] && [ "$1" = safe ] && [ "$2" = "; touch $injection_marker #" ] && [ ! -e "$injection_marker" ] \
    && test_pass "quoting never lets an embedded token execute as a second command" \
    || test_fail "quoting never lets an embedded token execute as a second command"

# --- Preflight (item 2) -----------------------------------------------------

# dx_runtime_docker_available: full chain success -- reachable, bin
# discovered via plain `command -v docker` on the fake PATH, uname -m
# matches DX_GUEST_SYSTEM, engine reports a version, daemon ID captured.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1" ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux" ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    dx_runtime_available
)
[ "$?" -eq 0 ] && test_pass "available: full preflight succeeds against a fake reachable host" || test_fail "available: full preflight succeeds against a fake reachable host"

# dx_runtime_docker_available: unreachable host (fake ssh exits non-zero for
# everything -- simulates a dead endpoint / connection loss).
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" ssh 'exit 255'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    out="$(dx_runtime_available 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "cannot reach"
)
[ "$?" -eq 0 ] && test_pass "available: refuses with a clear message when the host is unreachable" || test_fail "available: refuses with a clear message when the host is unreachable"

# dx_runtime_docker_available: docker CLI not found anywhere (neither plain
# PATH nor the qpkg glob) -- distinct "missing Docker access" message.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    PATH="$dir:/usr/bin:/bin"
    # The fake remote's PATH is the fixture directory alone (fake uname, no
    # docker): the controller's own PATH must not stand in for it here, or a
    # host that really has /usr/bin/docker (GitHub's ubuntu runners) makes
    # discovery succeed and this refusal never happens.
    export DXE_FAKE_SSH_REMOTE_PATH="$dir"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    out="$(dx_runtime_available 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "could not discover the Docker CLI"
)
[ "$?" -eq 0 ] && test_pass "available: refuses with a clear message when the Docker CLI cannot be discovered" || test_fail "available: refuses with a clear message when the Docker CLI cannot be discovered"

# dx_runtime_docker_available: bin discovery falls back to the qpkg glob
# when a bare `docker` is not on the remote PATH (Phase 0's confirmed real
# shape). The fake docker executable lives ONLY at the glob path, never as
# a bare PATH entry.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    # "fixturepool", never a real-shaped "<NAME>_DATA" pool/dataset name --
    # tests/test_section1_secrets.sh's generic leak scan flags that shape on
    # sight, fake or not (caught 2026-09-27 by that scan on this exact line).
    qpkg_dir="$dir/share/fixturepool/.qpkg/container-station/bin"
    mkdir -p "$qpkg_dir"
    fake_tool_write "$qpkg_dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1" ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux" ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    # Point the glob this test exercises at the fixture's own directory,
    # never a real /share, by overriding DX_RUNTIME_DOCKER_BIN_GLOB for the
    # duration of this one call -- a prefix assignment on a function call
    # is visible through every nested function it calls (verified: this is
    # ordinary bash dynamic scoping for simple commands naming a function,
    # not a subshell-scoped no-op), so dx_runtime_docker_discover_bin's own
    # read of $DX_RUNTIME_DOCKER_BIN_GLOB sees this override.
    PATH="$dir:/usr/bin:/bin"
    # Same remote-PATH discipline as the refusal test above, and the
    # discovered path is asserted outright: with a real docker on the
    # controller's PATH this used to pass for the wrong reason (discovery
    # took /usr/bin/docker and the glob was never exercised).
    export DXE_FAKE_SSH_REMOTE_PATH="$dir"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    DX_RUNTIME_DOCKER_BIN_GLOB="$dir/share/*/.qpkg/container-station/bin/docker" dx_runtime_available &&
        [ "$DXE_RUNTIME_DOCKER_BIN" = "$qpkg_dir/docker" ]
)
[ "$?" -eq 0 ] && test_pass "available: falls back to the qpkg glob when docker is not on the bare PATH" || test_fail "available: falls back to the qpkg glob when docker is not on the bare PATH"

# dx_runtime_docker_available: architecture mismatch refuses before any
# Docker call at all (DQ7) -- the fake docker would fail loudly (exit 99) if
# reached, proving the refusal happens first.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=aarch64-linux
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    out="$(dx_runtime_available 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "does not match configured DX_GUEST_SYSTEM"
)
[ "$?" -eq 0 ] && test_pass "available: refuses on an architecture mismatch before touching Docker" || test_fail "available: refuses on an architecture mismatch before touching Docker"

# dx_runtime_docker_available: unsupported architecture (e.g. 32-bit ARM;
# DQ7 "Unsupported for DXE. Stop the plan.").
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" uname 'case "$1" in -m) echo armv7l ;; esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    out="$(dx_runtime_available 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "unsupported architecture"
)
[ "$?" -eq 0 ] && test_pass "available: refuses an unsupported architecture" || test_fail "available: refuses an unsupported architecture"

# dx_runtime_docker_available: engine/CLI incompatible (docker version
# succeeds but reports no server version -- e.g. daemon unreachable/wrong
# API version).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "" ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    out="$(dx_runtime_available 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "failed or printed no server version"
)
[ "$?" -eq 0 ] && test_pass "available: refuses when the engine reports no compatible server version" || test_fail "available: refuses when the engine reports no compatible server version"

# dx_runtime_docker_available: daemon ID fallback when Docker's own .ID
# field is empty (older/newer Engine variance) -- derived from the other
# three fields instead of a second round trip.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1" ;;
    "info --format") echo "|qnap-fake|x86_64|linux" ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    dx_runtime_available >/dev/null 2>&1 && [ -n "$DXE_RUNTIME_DOCKER_DAEMON_ID" ]
)
[ "$?" -eq 0 ] && test_pass "available: falls back to a derived daemon ID when .ID is empty" || test_fail "available: falls back to a derived daemon ID when .ID is empty"

# Docker binary path and daemon ID are cached, not re-discovered, on a
# second call within the same process -- the fake ssh/docker would fail the
# second time if called again (a marker file counts invocations).
(
    dir="$(new_tool_dir)"
    call_log="$fixture/discover-calls.log"
    rm -f "$call_log"
    fake_tool_write "$dir" ssh "
echo called >> '$call_log'
last=\"\"; for a in \"\$@\"; do last=\"\$a\"; done
eval \"\$last\"
"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1" ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux" ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    dx_runtime_available >/dev/null 2>&1
    first_calls="$(wc -l < "$call_log" | tr -d ' ')"
    dx_runtime_docker_require_bin >/dev/null
    dx_runtime_docker_discover_daemon_id >/dev/null
    second_calls="$(wc -l < "$call_log" | tr -d ' ')"
    [ "$first_calls" = "$second_calls" ]
)
[ "$?" -eq 0 ] && test_pass "the discovered binary path and daemon ID are cached, never re-discovered in the same process" || test_fail "the discovered binary path and daemon ID are cached, never re-discovered in the same process"

# Exported so a child process inherits the cache instead of re-discovering.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1" ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux" ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    dx_runtime_available >/dev/null 2>&1
    bash -c '[ -n "$DXE_RUNTIME_DOCKER_BIN" ] && [ -n "$DXE_RUNTIME_DOCKER_DAEMON_ID" ]'
)
[ "$?" -eq 0 ] && test_pass "the cached binary path and daemon ID are exported for a child process" || test_fail "the cached binary path and daemon ID are exported for a child process"

# dx_runtime_system_running: live daemon-reachable check, true and false.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = info ] && [ "$#" -eq 1 ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    dx_runtime_system_running
)
[ "$?" -eq 0 ] && test_pass "system_running: true when the daemon answers" || test_fail "system_running: true when the daemon answers"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    dx_runtime_system_running
)
[ "$?" -ne 0 ] && test_pass "system_running: false when the daemon does not answer" || test_fail "system_running: false when the daemon does not answer"

# dx_runtime_system_start: always refuses, names the App Center UI, never
# invokes ssh/docker at all (a fake ssh that would fail loudly proves it).
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" ssh 'echo "ssh should never be called" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    out="$(dx_runtime_system_start 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "App Center" && ! printf '%s\n' "$out" | stdin_matches "ssh should never be called"
)
[ "$?" -eq 0 ] && test_pass "system_start: refuses without ever contacting the host" || test_fail "system_start: refuses without ever contacting the host"

# dx_runtime_host_identity: docker-ssh:<alias>:<daemon-id>.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "info --format") echo "abc123def|qnap-fake|x86_64|linux" ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    [ "$(dx_runtime_host_identity)" = "docker-ssh:qnap-dxe:abc123def" ]
)
[ "$?" -eq 0 ] && test_pass "host_identity: docker-ssh:<alias>:<daemon-id>" || test_fail "host_identity: docker-ssh:<alias>:<daemon-id>"

# Two different DX_REMOTE_HOST aliases (simulating two different QNAPs, or
# the same alias resolving to a different daemon) never collide.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "info --format") echo "aaa111|host-a|x86_64|linux" ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-a
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    id_a="$(dx_runtime_host_identity)"
    dir2="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir2"
    fake_tool_write "$dir2" docker '
case "$1 $2" in
    "info --format") echo "bbb222|host-b|x86_64|linux" ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir2:/usr/bin:/bin"
    DX_REMOTE_HOST=qnap-b
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    id_b="$(dx_runtime_host_identity)"
    [ "$id_a" != "$id_b" ]
)
[ "$?" -eq 0 ] && test_pass "host_identity: two different remote hosts never collide" || test_fail "host_identity: two different remote hosts never collide"

# --- Drift guard (Branch 11 / Phase 5, condition (a)): the "fresh production
# copy" of Phase 0's discovery snippets, and of test_section1_secrets.sh's
# Tailscale CGNAT-range pattern, must never silently diverge from what they
# were copied from. Both files are already sourced by this file's own top
# (dx-runtime-docker.sh via dx-runtime.sh, tests/qnap/lib/phase0-common.sh
# directly), so this proves behavioural equivalence by calling both
# generators with the SAME glob input and comparing their rendered output
# byte for byte -- not merely eyeballing the two source files.
(
    a="$(dxe_qnap_docker_discovery_remote_script)"
    b="$(dx_runtime_docker_bin_discovery_script)"
    [ "$a" = "$b" ]
)
[ "$?" -eq 0 ] && test_pass "drift guard: the Docker-path discovery script matches tests/qnap/lib/phase0-common.sh's own shape byte for byte" \
    || test_fail "drift guard: the Docker-path discovery script has drifted from tests/qnap/lib/phase0-common.sh"

(
    a="$(dxe_qnap_tailnet_addr_discovery_remote_script)"
    b="$(dx_runtime_docker_guest_ssh_address_discovery_script)"
    [ "$a" = "$b" ]
)
[ "$?" -eq 0 ] && test_pass "drift guard: the Tailscale-address discovery script matches tests/qnap/lib/phase0-common.sh's own shape byte for byte" \
    || test_fail "drift guard: the Tailscale-address discovery script has drifted from tests/qnap/lib/phase0-common.sh"

(
    secrets_pattern="$(sed -n "s/^TAILNET_IP_PATTERN='\(.*\)'\$/\1/p" "$BASE_DIR/tests/test_section1_secrets.sh")"
    [ -n "$secrets_pattern" ] && [ "$secrets_pattern" = "$DX_RUNTIME_DOCKER_TAILNET_ADDR_PATTERN" ]
)
[ "$?" -eq 0 ] && test_pass "drift guard: the guest-ssh-address validator's Tailscale-range regex matches tests/test_section1_secrets.sh's own pattern byte for byte" \
    || test_fail "drift guard: the guest-ssh-address validator's Tailscale-range regex has drifted from tests/test_section1_secrets.sh"

# --- dx_runtime_guest_ssh_address (Branch 11 / Phase 5, DQ5) ---------------

# Apple: a fixed constant, no ssh call at all.
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" ssh 'echo "ssh should never be called" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=apple
    [ "$(dx_runtime_guest_ssh_address)" = 127.0.0.1 ]
)
[ "$?" -eq 0 ] && test_pass "guest_ssh_address (apple): fixed 127.0.0.1, no ssh call at all" || test_fail "guest_ssh_address (apple): fixed 127.0.0.1, no ssh call at all"

# docker-ssh: discovers via the Tailscale qpkg CLI's own "ip -4" when it is
# on the remote's bare PATH.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" tailscale 'case "$*" in
    "ip -4") printf "%s.%s.%s.%s\n" 100 64 1 2 ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    unset DXE_RUNTIME_GUEST_SSH_ADDRESS
    [ "$(dx_runtime_guest_ssh_address)" = "$(tailnet_fixture_addr 64 1 2)" ]
)
[ "$?" -eq 0 ] && test_pass "guest_ssh_address (docker-ssh): discovers via the Tailscale CLI's 'ip -4' on the bare remote PATH" \
    || test_fail "guest_ssh_address (docker-ssh): discovers via the Tailscale CLI's 'ip -4' on the bare remote PATH"

# Falls back to the qpkg glob when tailscale is not on the bare PATH (same
# discipline as the Docker-path glob fallback test above): the fake
# tailscale executable lives ONLY at the glob path.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    qpkg_dir="$dir/share/fixturepool/.qpkg/Tailscale"
    mkdir -p "$qpkg_dir"
    fake_tool_write "$qpkg_dir" tailscale 'case "$*" in
    "ip -4") printf "%s.%s.%s.%s\n" 100 64 9 9 ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    link_coreutils_into "$dir" head
    PATH="$dir:/usr/bin:/bin"
    export DXE_FAKE_SSH_REMOTE_PATH="$dir"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    unset DXE_RUNTIME_GUEST_SSH_ADDRESS
    DX_RUNTIME_DOCKER_TAILSCALE_BIN_GLOB="$qpkg_dir/tailscale" dx_runtime_guest_ssh_address 2>/dev/null | grep -qx "$(tailnet_fixture_addr 64 9 9)"
)
[ "$?" -eq 0 ] && test_pass "guest_ssh_address (docker-ssh): falls back to the qpkg glob when tailscale is not on the bare PATH" \
    || test_fail "guest_ssh_address (docker-ssh): falls back to the qpkg glob when tailscale is not on the bare PATH"

# Falls back to reading the tailscale0 interface directly when the
# Tailscale CLI cannot be found at all (neither bare PATH nor the glob).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    export DXE_FAKE_SSH_REMOTE_PATH="$dir"
    fake_tool_write "$dir" ip 'case "$*" in
    "-4 addr show tailscale0") printf "    inet %s.%s.%s.%s/32 scope global tailscale0\n" 100 64 5 5 ;;
    *) exit 1 ;;
esac'
    link_coreutils_into "$dir" awk cut head
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    unset DXE_RUNTIME_GUEST_SSH_ADDRESS
    [ "$(dx_runtime_guest_ssh_address)" = "$(tailnet_fixture_addr 64 5 5)" ]
)
[ "$?" -eq 0 ] && test_pass "guest_ssh_address (docker-ssh): falls back to reading the tailscale0 interface when the Tailscale CLI cannot be found" \
    || test_fail "guest_ssh_address (docker-ssh): falls back to reading the tailscale0 interface when the Tailscale CLI cannot be found"

# Refuses (DQ5's exact wording) when neither path yields an address at all.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    export DXE_FAKE_SSH_REMOTE_PATH="$dir"
    fake_tool_write "$dir" ip 'exit 1'
    link_coreutils_into "$dir" awk cut head
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    unset DXE_RUNTIME_GUEST_SSH_ADDRESS
    out="$(dx_runtime_guest_ssh_address 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "the NAS has no Tailscale address; DQ5 forbids publishing on the LAN or 0.0.0.0."
)
[ "$?" -eq 0 ] && test_pass "guest_ssh_address (docker-ssh): refuses with DQ5's exact wording when no address is discovered" \
    || test_fail "guest_ssh_address (docker-ssh): refuses with DQ5's exact wording when no address is discovered"

# A distinct failure class: the ssh ROUND TRIP itself fails (connection
# refused/dead host), not merely a NOTFOUND/out-of-range answer.
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" ssh 'case "$*" in *DXE_TAILSCALE_BIN*) exit 255 ;; *) exit 0 ;; esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    unset DXE_RUNTIME_GUEST_SSH_ADDRESS
    out="$(dx_runtime_guest_ssh_address 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "could not reach qnap-dxe to discover its Tailscale address"
)
[ "$?" -eq 0 ] && test_pass "guest_ssh_address (docker-ssh): a failed ssh round trip during discovery is reported distinctly from NOTFOUND" \
    || test_fail "guest_ssh_address (docker-ssh): a failed ssh round trip during discovery is reported distinctly from NOTFOUND"

# Refuses a discovered value outside Tailscale's CGNAT range (DQ5: never the
# LAN) even though something was, in fact, discovered -- proven two ways, so
# this cannot pass merely because discovery silently failed and produced
# NOTFOUND instead (which refuses with the same wording, for a different
# reason): first, that the raw discovery round trip really did yield the
# planted LAN address; second, that the validated op still refuses it.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    export DXE_FAKE_SSH_REMOTE_PATH="$dir"
    fake_tool_write "$dir" tailscale 'case "$*" in
    "ip -4") echo "192.168.1.5" ;;
    *) exit 99 ;;
esac'
    link_coreutils_into "$dir" head
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    unset DXE_RUNTIME_GUEST_SSH_ADDRESS
    raw="$(dx_runtime_docker_ssh_raw "$(dx_runtime_docker_guest_ssh_address_discovery_script)" | tail -n1 | tr -d '\r')"
    out="$(dx_runtime_guest_ssh_address 2>&1)"; rc=$?
    [ "$raw" = 192.168.1.5 ] && [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "DQ5 forbids publishing on the LAN or 0.0.0.0."
)
[ "$?" -eq 0 ] && test_pass "guest_ssh_address (docker-ssh): refuses a discovered LAN address outside the Tailscale range" \
    || test_fail "guest_ssh_address (docker-ssh): refuses a discovered LAN address outside the Tailscale range"

# Cached, never re-discovered in the same process (same call-counting idiom
# as the Docker-bin/daemon-ID caching proof above).
(
    dir="$(new_tool_dir)"
    call_log="$fixture/guest-ssh-address-calls.log"
    rm -f "$call_log"
    # A private directory holding ONLY a `bash` symlink (never the real
    # bash's own directory, e.g. /usr/bin on GitHub's ubuntu runners --
    # that directory also ships a real /usr/bin/docker, which would leak
    # back into a fixture's deliberately bare DXE_FAKE_SSH_REMOTE_PATH and
    # defeat the very isolation this is meant to preserve; the same fix
    # tests/lib/fake-tools.sh's fake_qnap_ssh_write carries -- this ssh
    # fake is hand-rolled, not that shared one, so it needs its own copy).
    dxe_s33_bash_dir="$(fake_tool_dir_create "$fixture")"
    ln -s "$(command -v bash)" "$dxe_s33_bash_dir/bash"
    fake_tool_write "$dir" ssh "
echo called >> '$call_log'
# Append a bash-only directory (never the real bash's own directory --
# see the comment above this fixture): fake_tool_write now emits
# #!/usr/bin/env bash, so any nested fake this eval reaches on the
# restricted DXE_FAKE_SSH_REMOTE_PATH -- tailscale, below -- still needs
# bash resolvable via env.
if [ -n \"\${DXE_FAKE_SSH_REMOTE_PATH:-}\" ]; then PATH=\"\$DXE_FAKE_SSH_REMOTE_PATH:$dxe_s33_bash_dir\"; export PATH; fi
last=\"\"; for a in \"\$@\"; do last=\"\$a\"; done
eval \"\$last\"
"
    export DXE_FAKE_SSH_REMOTE_PATH="$dir"
    fake_tool_write "$dir" tailscale 'case "$*" in
    "ip -4") printf "%s.%s.%s.%s\n" 100 64 2 3 ;;
    *) exit 99 ;;
esac'
    link_coreutils_into "$dir" head
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    unset DXE_RUNTIME_GUEST_SSH_ADDRESS
    # The first call is a direct statement, never a "$(...)" substitution:
    # a command substitution forks a subshell, and the cache this proves is
    # an *exported variable* the function sets -- a change a subshell makes
    # can never propagate back to this parent shell, so reading the value
    # back through "$(...)" only works correctly once the cache already
    # lives here, in the same shell the two calls below both run in.
    dx_runtime_guest_ssh_address >/dev/null
    first_calls="$(wc -l < "$call_log" | tr -d ' ')"
    second_value="$(dx_runtime_guest_ssh_address)"
    second_calls="$(wc -l < "$call_log" | tr -d ' ')"
    [ "$second_value" = "$(tailnet_fixture_addr 64 2 3)" ] && [ "$first_calls" = "$second_calls" ]
)
[ "$?" -eq 0 ] && test_pass "guest_ssh_address (docker-ssh): cached, never re-discovered in the same process" \
    || test_fail "guest_ssh_address (docker-ssh): cached, never re-discovered in the same process"

# --- Known-hosts pinning for docker-ssh (Branch 11 / Phase 5, item 8;
# coordinating session's decision 5) -- dx_ssh_common_options -------------
#
# First-contact/mismatch/remedy behaviour is native OpenSSH semantics, not
# fakeable here (agreed explicitly, live-gate-only); what a fake CAN and
# must prove is the rendered options themselves: accept-new plus the
# per-profile file path for docker-ssh, today's exact options unchanged
# for Apple, never /dev/null for docker-ssh, and that the pin directory is
# created 0700 by the builder's own caller rather than left to ssh.

# Apple: byte-for-byte unchanged from before this phase.
(
    out="$(DX_RUNTIME=apple DX_SSH_KEY=/tmp/dxe-fixture-key DX_SSH_PORT=2222 DX_SSH_CONNECT_TIMEOUT=15 dx_ssh_common_options)"
    expected=$'-i\n/tmp/dxe-fixture-key\n-p\n2222\n-o\nStrictHostKeyChecking=no\n-o\nUserKnownHostsFile=/dev/null\n-o\nIdentitiesOnly=yes\n-o\nLogLevel=ERROR\n-o\nConnectTimeout=15'
    [ "$out" = "$expected" ]
)
[ "$?" -eq 0 ] && test_pass "dx_ssh_common_options (apple): today's exact options, byte for byte, unchanged" \
    || test_fail "dx_ssh_common_options (apple): today's exact options, byte for byte, unchanged"

# docker-ssh: accept-new, the per-profile known_hosts path, never /dev/null,
# and the pin directory exists at 0700 afterward. DXE_RUNTIME_DOCKER_DAEMON_ID
# is pre-seeded so dx_runtime_host_identity (the dispatch-level op
# dx_ssh_known_hosts_dir scopes by -- never the docker adapter's own
# dx_runtime_docker_profile_id directly, per Section 32's boundary audit)
# resolves without any real ssh/docker round trip. HOME is isolated to a
# fixture below before dx_ssh_common_options ever runs; the snapshot,
# taken in THIS outer, unisolated shell, proves that isolation actually
# held rather than just trusting it.
known_hosts_render_real_state_before="$(dx_real_ssh_known_hosts_snapshot)"
(
    home_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-known-hosts.XXXXXX")"
    unset XDG_STATE_HOME
    export HOME="$home_dir"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    # shellcheck disable=SC2034
    # Read by dx_ssh_common_options (bin/lib/dx-ssh-common.sh), a function
    # in a separately sourced file ShellCheck cannot trace into -- these
    # are genuinely consumed, dynamically, by that call below.
    DX_SSH_KEY=/tmp/dxe-fixture-key DX_SSH_PORT=2222 DX_SSH_CONNECT_TIMEOUT=15
    DXE_RUNTIME_DOCKER_DAEMON_ID=fixturedaemonid
    out="$(dx_ssh_common_options)"
    expected_dir="$home_dir/.local/state/dxe/dx-qnap/docker-ssh_qnap-dxe_fixturedaemonid"
    printf '%s\n' "$out" | stdin_matches -F -x "StrictHostKeyChecking=accept-new" \
        && printf '%s\n' "$out" | stdin_matches -F -x "UserKnownHostsFile=$expected_dir/known_hosts" \
        && ! printf '%s\n' "$out" | stdin_matches -F -x "UserKnownHostsFile=/dev/null" \
        && [ -d "$expected_dir" ] \
        && [ "$(dx_path_mode "$expected_dir")" = 700 ]
)
known_hosts_render_rc=$?
known_hosts_render_real_state_after="$(dx_real_ssh_known_hosts_snapshot)"
if [ "$known_hosts_render_rc" -eq 0 ] && [ "$known_hosts_render_real_state_before" = "$known_hosts_render_real_state_after" ]; then
    test_pass "dx_ssh_common_options (docker-ssh): accept-new, the per-profile known_hosts path, never /dev/null, directory 0700, never the real state directory"
else
    test_fail "dx_ssh_common_options (docker-ssh): accept-new, the per-profile known_hosts path, never /dev/null, directory 0700, never the real state directory"
fi

# Refuses a symlinked pin directory rather than following it.
known_hosts_symlink_real_state_before="$(dx_real_ssh_known_hosts_snapshot)"
(
    home_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-known-hosts-symlink.XXXXXX")"
    unset XDG_STATE_HOME
    export HOME="$home_dir"
    mkdir -p "$home_dir/.local/state/dxe/dx-qnap"
    elsewhere="$(mktemp -d "${TMPDIR:-/tmp}/dxe-known-hosts-elsewhere.XXXXXX")"
    ln -s "$elsewhere" "$home_dir/.local/state/dxe/dx-qnap/docker-ssh_qnap-dxe_fixturedaemonid"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    # shellcheck disable=SC2034
    # Read by dx_ssh_common_options (bin/lib/dx-ssh-common.sh), a function
    # in a separately sourced file ShellCheck cannot trace into -- these
    # are genuinely consumed, dynamically, by that call below.
    DX_SSH_KEY=/tmp/dxe-fixture-key DX_SSH_PORT=2222 DX_SSH_CONNECT_TIMEOUT=15
    DXE_RUNTIME_DOCKER_DAEMON_ID=fixturedaemonid
    out="$(dx_ssh_common_options 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "refusing symlinked SSH known-hosts directory"
)
known_hosts_symlink_rc=$?
known_hosts_symlink_real_state_after="$(dx_real_ssh_known_hosts_snapshot)"
if [ "$known_hosts_symlink_rc" -eq 0 ] && [ "$known_hosts_symlink_real_state_before" = "$known_hosts_symlink_real_state_after" ]; then
    test_pass "dx_ssh_common_options (docker-ssh): refuses a symlinked known-hosts pin directory, never touching the real state directory"
else
    test_fail "dx_ssh_common_options (docker-ssh): refuses a symlinked known-hosts pin directory, never touching the real state directory"
fi

# --- dx-enter TTY rule (Branch 11 / Phase 5, item 5; condition (b)) --------
#
# "docker exec -it" needs the OUTER ssh transport to force its own pty too
# (-tt, not a single -t); every other exec shape (bin/lib/dx-backup.sh's -i
# phase, bin/dx-sync-bootstrap, -u alone, bare) must never gain one, or a
# piped-stdin exec (Branch 17's discipline) breaks. Captures ssh's OWN
# argv (not just what reaches the fake docker) across four representative
# calls in one fixture, so the assertion is a property of the real ssh
# invocation, not merely of dx_runtime_docker_exec's own flags array.
(
    dir="$(new_tool_dir)"
    ssh_argv_log="$fixture/exec-tty-ssh-argv.log"
    : > "$ssh_argv_log"
    fake_tool_write "$dir" ssh "
printf '%s\n' \"\$@\" >> '$ssh_argv_log'
printf '\f\n' >> '$ssh_argv_log'
dx_fake_last=\"\"
for dx_fake_arg in \"\$@\"; do dx_fake_last=\"\$dx_fake_arg\"; done
eval \"\$dx_fake_last\"
"
    fake_tool_write "$dir" docker 'case "$1" in exec) exit 0 ;; *) echo "UNMATCHED: $*" >&2; exit 99 ;; esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_docker_exec -it dx-qnap bash -l >/dev/null 2>&1
    printf 'x' | dx_runtime_docker_exec -i dx-qnap sh -c 'cat' >/dev/null 2>&1
    dx_runtime_docker_exec -u dx dx-qnap true >/dev/null 2>&1
    dx_runtime_docker_exec dx-qnap true >/dev/null 2>&1
    tt_count="$(grep -c -x -- '-tt' "$ssh_argv_log")"
    [ "$tt_count" -eq 1 ]
)
[ "$?" -eq 0 ] && test_pass "dx_runtime_docker_exec: ssh gets -tt exactly once, only for the -it call, never for -i/-u/bare" \
    || test_fail "dx_runtime_docker_exec: ssh gets -tt exactly once, only for the -it call, never for -i/-u/bare"

# The real bin/dx-enter entrypoint (which always passes -it, whether or
# not its own invocation runs under a real terminal -- "dx-enter <cmd>"
# must work non-interactively too) drives the same -tt behaviour end to
# end, not only through a direct dx_runtime_docker_exec call.
(
    dir="$(new_tool_dir)"
    ssh_argv_log="$fixture/dx-enter-ssh-argv.log"
    : > "$ssh_argv_log"
    fake_tool_write "$dir" ssh "
printf '%s\n' \"\$@\" >> '$ssh_argv_log'
dx_fake_last=\"\"
for dx_fake_arg in \"\$@\"; do dx_fake_last=\"\$dx_fake_arg\"; done
eval \"\$dx_fake_last\"
"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
esac
case "$1" in exec) exit 0 ;; *) echo "UNMATCHED: $*" >&2; exit 99 ;; esac'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    "$BASE_DIR/bin/dx-enter" true </dev/null >/dev/null 2>&1
    grep -qx -- '-tt' "$ssh_argv_log"
)
[ "$?" -eq 0 ] && test_pass "bin/dx-enter (docker-ssh): drives ssh -tt end to end, including when run non-interactively" \
    || test_fail "bin/dx-enter (docker-ssh): drives ssh -tt end to end, including when run non-interactively"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = logs ] && [ "$2" = -n ] && [ "$3" = 40 ] && [ "$4" = dx-qnap ] && printf "line1\nline2\n"'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    [ "$(dx_runtime_logs -n 40 dx-qnap)" = "$(printf 'line1\nline2')" ]
)
[ "$?" -eq 0 ] && test_pass "logs: -n N NAME passthrough (Docker and Apple agree)" || test_fail "logs: -n N NAME passthrough (Docker and Apple agree)"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = export ] && [ "$2" = dx-qnap ] && printf "tarbytes"'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    [ "$(dx_runtime_export dx-qnap)" = tarbytes ]
)
[ "$?" -eq 0 ] && test_pass "export: passthrough stream" || test_fail "export: passthrough stream"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = run ] && [ "$2" = --rm ] && [ "$3" = dx-qnap-nixos ] && printf "ran"'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    [ "$(dx_runtime_run_ephemeral --rm dx-qnap-nixos)" = ran ]
)
[ "$?" -eq 0 ] && test_pass "run_ephemeral: passthrough, no Apple-specific retry loop" || test_fail "run_ephemeral: passthrough, no Apple-specific retry loop"

# --- bin/dx-put and bin/dx-get (docker-ssh): never dial the guest SSH
# endpoint directly (Branch 11 / Phase 5, coordinating session's decision on
# the design note's item 1) -----------------------------------------------
#
# Both go exclusively through dx_runtime_exec -- the management-plane
# contract (ssh ... "$DX_REMOTE_HOST" <docker> exec ...) -- never the guest's
# own direct SSH boundary (dx@<guest address>, bin/lib/dx-ssh-common.sh).
# This keeps that reading honest against a future change: a fake ssh here
# logs the COMPLETE argv of every invocation (not just the fake `docker`'s
# own understanding of it), and the assertion is a property of the raw ssh
# destination argument, independent of what dx_runtime_docker_ssh_raw's own
# code currently does.
(
    dir="$(new_tool_dir)"
    ssh_argv_log="$fixture/put-get-ssh-argv.log"
    : > "$ssh_argv_log"
    fake_tool_write "$dir" ssh "
printf '%s\n' \"\$@\" >> '$ssh_argv_log'
printf '\f\n' >> '$ssh_argv_log'
dx_fake_last=\"\"
for dx_fake_arg in \"\$@\"; do dx_fake_last=\"\$dx_fake_arg\"; done
eval \"\$dx_fake_last\"
"
    fake_tool_write "$dir" docker '
case "$1" in
    version) [ "$2" = --format ] && echo "27.3.1" ;;
    info)    [ "$2" = --format ] && echo "abc123def|qnap-fake|x86_64|linux" ;;
    exec)
        shift
        while :; do
            case "$1" in
                -i) shift ;;
                -u) shift 2 ;;
                *) break ;;
            esac
        done
        case "$*" in
            *"[ -e "*) exit 0 ;;
            *"[ -d "*) exit 1 ;;
            *"cat "*) printf "fake-file-contents" ;;
            *) exit 0 ;;
        esac
        ;;
    *) echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID DXE_RUNTIME_GUEST_SSH_ADDRESS
    put_source="$fixture/put-source.txt"
    printf 'fixture contents\n' > "$put_source"
    "$BASE_DIR/bin/dx-put" "$put_source" /persist/inbox/ >/dev/null 2>&1
    get_dest="$fixture/get-dest.txt"
    "$BASE_DIR/bin/dx-get" /persist/somefile "$get_dest" >/dev/null 2>&1
    [ -s "$ssh_argv_log" ] && ! grep -q '^dx@' "$ssh_argv_log" && grep -q -x "$DX_REMOTE_HOST" "$ssh_argv_log"
)
[ "$?" -eq 0 ] && test_pass "dx-put and dx-get (docker-ssh): every ssh call dials the management alias, never the guest SSH endpoint directly" \
    || test_fail "dx-put and dx-get (docker-ssh): every ssh call dials the management alias, never the guest SSH endpoint directly"

# --- bin/lib/dx-backup.sh's unidirectional exec discipline under
# docker-ssh (Branch 11 / Phase 3, Increment 6, item 6): Branch 17 found
# that an exec carrying both stdin and bulk stdout over one multiplexed
# channel can stall; dx-backup.sh's stdin phase and stream phase are two
# separate, unidirectional execs (this file's own module comment above
# dx_backup_ship_list_to_guest). Proves the discipline survives the
# adapter unchanged: the stdin phase renders `docker exec -i -u dx NAME
# sh -c ...`, the stream phase renders `docker exec -u dx NAME tar ...`
# with NO `-i` at all.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    bk_log="$dir/exec-argv.log"
    fake_tool_write "$dir" docker '
[ "$1" = exec ] || { echo "UNMATCHED: $*" >&2; exit 99; }
shift
printf "%s\n" "$@" >> "'"$bk_log"'"
case "$*" in *"sh -c"*) cat > /dev/null ;; esac
exit 0'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    host_list="$(mktemp "${TMPDIR:-/tmp}/dxe-bk-hostlist.XXXXXX")"
    printf 'persist/one\n' > "$host_list"
    dx_backup_ship_list_to_guest dx-qnap "$host_list" >/dev/null
    rm -f "$host_list"
    argv="$(tr '\n' ' ' < "$bk_log")"
    printf '%s\n' "$argv" | stdin_matches -F -- '-i -u dx dx-qnap sh -c'
)
[ "$?" -eq 0 ] && test_pass "dx-backup (docker-ssh): the stdin-shipping phase renders 'docker exec -i -u dx NAME sh -c ...'" || test_fail "dx-backup (docker-ssh): the stdin-shipping phase renders 'docker exec -i -u dx NAME sh -c ...'"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    bk_log="$dir/exec-argv.log"
    # dx_backup_fetch_paths issues THREE separate execs (ship, stream,
    # cleanup-rm); a form-feed record separator after each one (the same
    # convention tests/test_runtime_boundary_characterisation.sh's own
    # module comment documents) lets the assertion below isolate just the
    # tar-streaming invocation's own argv, not the whole call sequence.
    fake_tool_write "$dir" docker '
[ "$1" = exec ] || { echo "UNMATCHED: $*" >&2; exit 99; }
shift
printf "%s\n" "$@" >> "'"$bk_log"'"
printf "\f\n" >> "'"$bk_log"'"
tar -cf - -T /dev/null
exit 0'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    fetch_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-bk-fetch.XXXXXX")"
    fetch_lines="$fetch_dir/lines.tsv"
    printf 'persist/one\tabc\n' > "$fetch_lines"
    export DX_BACKUP_GUEST_ROOT=/persist
    dx_backup_fetch_paths dx-qnap "$fetch_dir" "$fetch_lines" >/dev/null 2>&1
    rm -rf "$fetch_dir"
    tar_block="$(awk -v RS='\f\n' '/(^|\n)tar(\n|$)/ { print; exit }' "$bk_log" | tr '\n' ' ')"
    printf '%s\n' "$tar_block" | stdin_matches -F -- '-u dx dx-qnap tar' \
        && ! printf '%s\n' " $tar_block " | stdin_matches -F -- ' -i '
)
[ "$?" -eq 0 ] && test_pass "dx-backup (docker-ssh): the tar-streaming phase renders 'docker exec -u dx NAME tar ...', no -i at all" || test_fail "dx-backup (docker-ssh): the tar-streaming phase renders 'docker exec -u dx NAME tar ...', no -i at all"


rm -rf "$fixture" 2>/dev/null || true

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    print_summary
    exit_with_code
fi
