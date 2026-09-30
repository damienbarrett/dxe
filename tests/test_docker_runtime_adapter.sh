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
test_section "Docker-ssh runtime adapter (Branch 11 / Phase 2)"

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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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

# --- Queries (item 3) -------------------------------------------------------

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1 $2" = "image inspect" ] && [ "$3" = dx-qnap-nixos ] && exit 0; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_exists dx-qnap-nixos
)
[ "$?" -eq 0 ] && test_pass "image_exists: true for an image docker inspect finds" || test_fail "image_exists: true for an image docker inspect finds"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_exists missing-image
)
[ "$?" -ne 0 ] && test_pass "image_exists: false for an image docker inspect cannot find" || test_fail "image_exists: false for an image docker inspect cannot find"

# image_list/container_list: raw text for human display, first column is
# still the resource NAME (not Docker's own default ID-first column order),
# so a caller's existing name-anchored grep keeps working under either
# runtime.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    # Repository and Tag must be SEPARATE columns, not joined by a colon:
    # a real NAS live gate found dx-status's `grep "^${DX_IMAGE}[[:space:]]"`
    # (bin/dx-status) silently matching nothing against
    # "dx-qnap-spike-nixos:latest ..." -- the bare name is never followed
    # by whitespace when Repository:Tag are one column -- which killed
    # dx-status outright under its own `set -e` right after the header
    # lines. Apple's `container image list` already prints NAME and TAG as
    # separate columns, which is why the identical grep works there; this
    # format string must give docker-ssh the same "bare name, then
    # whitespace" first-column shape. This fake also refuses (exit 99) any
    # other --format shape, so a regression back to a joined column, or any
    # other unexpected shape, fails loudly here instead of silently in
    # dx-status.
    fake_tool_write "$dir" docker '
[ "$1 $2" = "image ls" ] || { echo "UNMATCHED: $*" >&2; exit 99; }
case "$*" in
    *"{{.Repository}}:{{.Tag}}"*) echo "UNEXPECTED FORMAT (Repository:Tag joined): $*" >&2; exit 99 ;;
esac
echo "REPOSITORY	TAG	IMAGE ID	CREATED	SIZE"
echo "dx-qnap-nixos	latest	abc123	1 day ago	500MB"'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_list | grep -q "^dx-qnap-nixos[[:space:]]"
)
[ "$?" -eq 0 ] && test_pass "image_list: name-anchored first column (Repository and Tag are separate columns), name-prefixed grep still works" || test_fail "image_list: name-anchored first column (Repository and Tag are separate columns), name-prefixed grep still works"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = volume ] && [ "$2" = inspect ] && [ "$3" = dx-qnap-nix ] && exit 0; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_exists dx-qnap-nix
)
[ "$?" -eq 0 ] && test_pass "volume_exists: true for a volume docker inspect finds" || test_fail "volume_exists: true for a volume docker inspect finds"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_exists missing-volume
)
[ "$?" -ne 0 ] && test_pass "volume_exists: false for a volume docker inspect cannot find" || test_fail "volume_exists: false for a volume docker inspect cannot find"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = container ] && [ "$2" = inspect ] && [ "$3" = dx-qnap ] && exit 0; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_exists dx-qnap
)
[ "$?" -eq 0 ] && test_pass "container_exists: true for a container docker inspect finds" || test_fail "container_exists: true for a container docker inspect finds"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_exists missing-container
)
[ "$?" -ne 0 ] && test_pass "container_exists: false for a container docker inspect cannot find" || test_fail "container_exists: false for a container docker inspect cannot find"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$5" = dx-qnap ] && echo true'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_running dx-qnap
)
[ "$?" -eq 0 ] && test_pass "container_running: true when State.Running is true" || test_fail "container_running: true when State.Running is true"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$5" = dx-qnap ] && echo false'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_running dx-qnap
)
[ "$?" -ne 0 ] && test_pass "container_running: false when State.Running is false" || test_fail "container_running: false when State.Running is false"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_running absent-container
)
[ "$?" -ne 0 ] && test_pass "container_running: false when the container does not exist at all" || test_fail "container_running: false when the container does not exist at all"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
[ "$1" = ps ] || { echo "UNMATCHED: $*" >&2; exit 99; }
case "$*" in *"-a"*) ;; *) echo "expected -a to pass through" >&2; exit 98 ;; esac
echo "NAMES	IMAGE	STATUS"
echo "dx-qnap	dx-qnap-nixos	Up 2 hours"'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_list -a | grep -q "^dx-qnap[[:space:]]"
)
[ "$?" -eq 0 ] && test_pass "container_list: -a passes through, name-anchored first column" || test_fail "container_list: -a passes through, name-anchored first column"

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

# --- DQ6 labels + collision refusal (item 5) --------------------------

# container_delete: label check passes (managed=true, matching profile,
# role=container), then the real rm/--force call happens.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "true|1|qnap-dxe__dx-qnap|container|x86_64-linux" ;;
    *) [ "$1" = rm ] && [ "$2" = --force ] && [ "$3" = dx-qnap ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_delete --force dx-qnap
)
[ "$?" -eq 0 ] && test_pass "container_delete: label match -> Apple's 'delete' verb maps to Docker's 'rm', --force passes through" || test_fail "container_delete: label match -> Apple's 'delete' verb maps to Docker's 'rm', --force passes through"

# container_delete: refuses when the target is unlabelled (a collision, not
# an adoption candidate) -- the fake rm would fail loudly if ever reached.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "<no value>|<no value>|<no value>|<no value>" ;;
    *) echo "docker rm should never run" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_container_delete dx-qnap 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "container_delete: refuses an unlabelled same-named container (DQ6 collision)" || test_fail "container_delete: refuses an unlabelled same-named container (DQ6 collision)"

# container_delete: refuses when labelled for a DIFFERENT profile.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "true|1|qnap-OTHER__dx-qnap|container" ;;
    *) echo "docker rm should never run" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_container_delete dx-qnap 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "container_delete: refuses a container labelled for a different profile" || test_fail "container_delete: refuses a container labelled for a different profile"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = image ] && [ "$2" = rm ] && [ "$3" = dx-qnap-nixos ] && exit 0; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_delete dx-qnap-nixos
)
[ "$?" -eq 0 ] && test_pass "image_delete: passthrough (no label check possible -- images are never built, only pulled+tagged)" || test_fail "image_delete: passthrough (no label check possible -- images are never built, only pulled+tagged)"

# volume_create: role derived from the configured volume name, labels attached.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/volcreate-argv.log"
    fake_tool_write "$dir" docker "
[ \"\$1 \$2\" = 'volume create' ] || { echo UNMATCHED >&2; exit 99; }
shift 2
printf '%s\n' \"\$@\" > '$argv_log'
"
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_create dx-qnap-nix
    got="$(cat "$argv_log")"
    printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.role=nix" && printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.profile=qnap-dxe__dx-qnap" && printf '%s\n' "$got" | stdin_matches -F -- "dx-qnap-nix"
)
[ "$?" -eq 0 ] && test_pass "volume_create: role derived from the configured name, DQ6 labels attached" || test_fail "volume_create: role derived from the configured name, DQ6 labels attached"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/volcreate-system-argv.log"
    fake_tool_write "$dir" docker "
[ \"\$1 \$2\" = 'volume create' ] || { echo UNMATCHED >&2; exit 99; }
shift 2
printf '%s\n' \"\$@\" > '$argv_log'
"
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_create dx-qnap-nix
    printf '%s\n' "$(cat "$argv_log")" | stdin_matches -F -- "io.dxe.system=x86_64-linux"
)
[ "$?" -eq 0 ] && test_pass "volume_create carries the io.dxe.system label (Branch 11 / Phase 4)" || test_fail "volume_create carries the io.dxe.system label (Branch 11 / Phase 4)"

# volume_create: refuses a name that is not one of the three configured
# volumes rather than creating something unlabelled.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "docker should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_volume_create some-other-volume 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "not one of the configured DXE volumes"
)
[ "$?" -eq 0 ] && test_pass "volume_create: refuses an unrecognized volume name rather than creating it unlabelled" || test_fail "volume_create: refuses an unrecognized volume name rather than creating it unlabelled"

# volume_delete: label match succeeds.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "volume inspect") echo "true|1|qnap-dxe__dx-qnap|nix|x86_64-linux" ;;
    *) [ "$1" = volume ] && [ "$2" = rm ] && [ "$3" = dx-qnap-nix ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_delete dx-qnap-nix
)
[ "$?" -eq 0 ] && test_pass "volume_delete: label match -> passthrough" || test_fail "volume_delete: label match -> passthrough"

# volume_delete: refuses an unlabelled same-named volume.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "volume inspect") echo "<no value>|<no value>|<no value>|<no value>" ;;
    *) echo "docker volume rm should never run" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_volume_delete dx-qnap-nix 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "collision, not an adoption candidate"
)
[ "$?" -eq 0 ] && test_pass "volume_delete: refuses an unlabelled same-named volume (DQ6 collision)" || test_fail "volume_delete: refuses an unlabelled same-named volume (DQ6 collision)"

# volume_delete: refuses a name outside the three configured volumes.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "docker should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_volume_delete some-other-volume 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "not one of the configured DXE volumes"
)
[ "$?" -eq 0 ] && test_pass "volume_delete: refuses an unrecognized volume name" || test_fail "volume_delete: refuses an unrecognized volume name"

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
        case "$*" in *dx-qnap*) echo "true|1|qnap-dxe__dx-qnap|container|x86_64-linux"; exit 0 ;; esac
        exit 1
        ;;
    "volume inspect")
        case "$*" in *dx-qnap-nix*) echo "true|1|qnap-dxe__dx-qnap|nix|x86_64-linux"; exit 0 ;; esac
        exit 1
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_destructive_plan_and_verify "container:dx-qnap:container" "volume:dx-qnap-nix:nix" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "container dx-qnap: labels=true|1|qnap-dxe__dx-qnap|container" \
        && printf '%s\n' "$out" | stdin_matches -F -- "volume dx-qnap-nix: labels=true|1|qnap-dxe__dx-qnap|nix"
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
        case "$*" in *dx-qnap*) echo "true|1|qnap-dxe__dx-qnap|container"; exit 0 ;; esac
        exit 1
        ;;
    "volume inspect")
        case "$*" in *dx-qnap-nix*) echo "<no value>|<no value>|<no value>|<no value>"; exit 0 ;; esac
        exit 1
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_destructive_plan_and_verify "container:dx-qnap:container" "volume:dx-qnap-nix:nix" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "container dx-qnap: labels=true|1|qnap-dxe__dx-qnap|container" \
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
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_exec -i -u dx dx-qnap bash -lc 'echo hi'
    diff <(printf '%s\n' exec -i -u dx dx-qnap bash -lc 'echo hi') "$argv_log" >/dev/null
)
[ "$?" -eq 0 ] && test_pass "exec: argv is passed verbatim (-i -u dx NAME CMD...)" || test_fail "exec: argv is passed verbatim (-i -u dx NAME CMD...)"

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

# --- image_build: Containerfile FROM-line parsing + pull/tag (no remote
# build; qnap-dxe-plan.md Phase 0 outcome + the coordinating session's
# 2026-09-27 decision).
containerfile_root="$fixture/context-single"
mkdir -p "$containerfile_root"
printf 'FROM docker.io/library/debian@sha256:%040d\n' 1 > "$containerfile_root/Containerfile"
pinned_ref="$(sed -n 's/^FROM //p' "$containerfile_root/Containerfile")"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker "
case \"\$1 \$2\" in
    'pull $pinned_ref') exit 0 ;;
    'tag $pinned_ref') [ \"\$3\" = dx-qnap-nixos ] && exit 0 ;;
esac
echo UNMATCHED: \"\$*\" >&2
exit 99
"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_build -t dx-qnap-nixos "$containerfile_root"
)
[ "$?" -eq 0 ] && test_pass "image_build: single-FROM Containerfile pulls the pinned ref then tags it" || test_fail "image_build: single-FROM Containerfile pulls the pinned ref then tags it"

containerfile_multi="$fixture/context-multi"
mkdir -p "$containerfile_multi"
printf 'FROM docker.io/library/debian@sha256:%040d\nRUN echo hi\n' 2 > "$containerfile_multi/Containerfile"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "docker should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_image_build -t dx-qnap-nixos "$containerfile_multi" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "significant line"
)
[ "$?" -eq 0 ] && test_pass "image_build: fails closed on a Containerfile with more than one significant line" || test_fail "image_build: fails closed on a Containerfile with more than one significant line"

containerfile_norun="$fixture/context-norun"
mkdir -p "$containerfile_norun"
printf 'RUN echo hi\n' > "$containerfile_norun/Containerfile"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "docker should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_image_build -t dx-qnap-nixos "$containerfile_norun" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "not a FROM instruction"
)
[ "$?" -eq 0 ] && test_pass "image_build: fails closed when the only significant line is not FROM" || test_fail "image_build: fails closed when the only significant line is not FROM"

containerfile_comments="$fixture/context-comments"
mkdir -p "$containerfile_comments"
printf '# a comment\n\nFROM docker.io/library/debian@sha256:%040d\n' 3 > "$containerfile_comments/Containerfile"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = pull ] || [ "$1" = tag ] || { echo UNMATCHED >&2; exit 99; }; exit 0'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_build -t dx-qnap-nixos "$containerfile_comments"
)
[ "$?" -eq 0 ] && test_pass "image_build: comments and blank lines around the one FROM line are not significant" || test_fail "image_build: comments and blank lines around the one FROM line are not significant"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "docker should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_image_build --bogus-shape 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "only supports"
)
[ "$?" -eq 0 ] && test_pass "image_build: refuses an argv shape other than bin/dx-create-image's own" || test_fail "image_build: refuses an argv shape other than bin/dx-create-image's own"

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

# --- Nix-volume claim scoped by daemon identity (Astra F4 item 5) ---------
#
# dx_nix_volume_claim_dir used to be "$HOME/.dx-cache/nix-volume-claims"
# alone -- a bare volume name, with no daemon identity in the path at all --
# so two docker-ssh profiles pointed at DIFFERENT NASs (different
# DX_REMOTE_HOST/daemon id) but sharing the same $HOME and the same
# DX_NIX_VOLUME name would collide on the SAME local claim file, even
# though they can never actually contend for the same remote resource.
# dx_profile_state_segment (WP3.4) is now folded into the directory so two
# daemons stay independent; Apple's own claim path is unaffected (a plain
# runtime with only one local daemon, dx_profile_state_segment prints
# nothing for it -- proven separately in tests/test_section9_host_scripts.sh's
# pre-existing claim tests, still passing byte-for-byte).
(
    source "$BASE_DIR/bin/lib/dx-host-util.sh"
    export DX_TUNNEL_LOCK_TIMEOUT=1
    export DXE_SELF_PROCESS_IDENTITY="wp65-daemon-scope-$$"
    # container_exists is keyed on which container the test is currently
    # simulating as having actually been created (the same technique this
    # file's own pre-existing claim tests use in
    # tests/test_section9_host_scripts.sh), rather than on real live-process
    # identity matching, which DXE_SELF_PROCESS_IDENTITY's own artificial
    # value here does not satisfy.
    existing="containerA"
    container_exists() { [ "$existing" = "$1" ]; }
    claim_home="$fixture/wp65-daemon-claim-home"
    HOME="$claim_home"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=hostA DXE_RUNTIME_DOCKER_DAEMON_ID=daemonA
    export DX_RUNTIME DX_REMOTE_HOST DXE_RUNTIME_DOCKER_DAEMON_ID
    dx_nix_volume_claim_acquire shared-vol containerA
    rc1=$?
    dirA="$(dx_nix_volume_claim_dir)"
    DX_REMOTE_HOST=hostB DXE_RUNTIME_DOCKER_DAEMON_ID=daemonB
    # Same $HOME, same volume name, a DIFFERENT daemon -- must succeed
    # independently rather than colliding with hostA's own claim above.
    dx_nix_volume_claim_acquire shared-vol containerB
    rc2=$?
    dirB="$(dx_nix_volume_claim_dir)"
    DX_REMOTE_HOST=hostA DXE_RUNTIME_DOCKER_DAEMON_ID=daemonA
    # Back on hostA's own identity: a second, distinct container contending
    # for the SAME volume while containerA still (per the stub above)
    # exists is correctly refused -- proving hostA's own scope is a real
    # exclusion, not merely a no-op that let everything through.
    dx_nix_volume_claim_acquire shared-vol containerC
    rc3=$?
    [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$rc3" -ne 0 ] && [ -n "$dirA" ] && [ -n "$dirB" ] && [ "$dirA" != "$dirB" ]
)
[ "$?" -eq 0 ] && test_pass "dx_nix_volume_claim_dir (docker-ssh): scoped by daemon identity, so two daemons sharing \$HOME and a volume name never collide" \
    || test_fail "dx_nix_volume_claim_dir (docker-ssh): scoped by daemon identity, so two daemons sharing \$HOME and a volume name never collide"

# --- Identity-scoped local state (item 7) -----------------------------

# dx_tunnel_key: Apple's shape is byte-for-byte unchanged.
(
    DX_RUNTIME=apple DX_CONTAINER_NAME=dx-host
    [ "$(dx_tunnel_key forward 8080)" = "forward:dx-host:8080" ]
)
[ "$?" -eq 0 ] && test_pass "dx_tunnel_key: apple's key shape is unchanged (direction:container:port)" || test_fail "dx_tunnel_key: apple's key shape is unchanged (direction:container:port)"

# dx_tunnel_key: docker-ssh gains a fourth, identity segment.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1 $2" = "info --format" ] && echo "abc123def|qnap-fake|x86_64|linux"'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    export DXE_RUNTIME_DOCKER_BIN=docker
    [ "$(dx_tunnel_key forward 8080)" = "forward:dx-qnap:8080:docker-ssh:qnap-dxe:abc123def" ]
)
[ "$?" -eq 0 ] && test_pass "dx_tunnel_key: docker-ssh gains a runtime+daemon-ID segment" || test_fail "dx_tunnel_key: docker-ssh gains a runtime+daemon-ID segment"

# dx_tunnel_key: two different remote hosts (same container name) never
# collide -- the whole point of item 7.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1 $2" = "info --format" ] && echo "aaa111|host-a|x86_64|linux"'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-a DX_CONTAINER_NAME=dx-qnap
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    key_a="$(dx_tunnel_key forward 8080)"
    dir2="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir2"
    fake_tool_write "$dir2" docker '[ "$1 $2" = "info --format" ] && echo "bbb222|host-b|x86_64|linux"'
    PATH="$dir2:/usr/bin:/bin"
    DX_REMOTE_HOST=qnap-b
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    key_b="$(dx_tunnel_key forward 8080)"
    [ "$key_a" != "$key_b" ]
)
[ "$?" -eq 0 ] && test_pass "dx_tunnel_key: two different remote hosts with the same container name never collide" || test_fail "dx_tunnel_key: two different remote hosts with the same container name never collide"

# dx_backup_resolve_dir: Apple's shape is byte-for-byte unchanged.
(
    export DX_RUNTIME=apple DX_CONTAINER_NAME=dx-host DX_BACKUP_DIR=/tmp/dxe-rtb-backups
    [ "$(dx_backup_resolve_dir)" = "/tmp/dxe-rtb-backups/dx-host" ]
)
[ "$?" -eq 0 ] && test_pass "dx_backup_resolve_dir: apple's path is unchanged (BASE/container)" || test_fail "dx_backup_resolve_dir: apple's path is unchanged (BASE/container)"

# dx_backup_resolve_dir: docker-ssh gains a third, identity path segment
# (colons replaced with underscores for a cleaner directory name).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1 $2" = "info --format" ] && echo "abc123def|qnap-fake|x86_64|linux"'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_BACKUP_DIR=/tmp/dxe-rtb-backups
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    [ "$(dx_backup_resolve_dir)" = "/tmp/dxe-rtb-backups/dx-qnap/docker-ssh_qnap-dxe_abc123def" ]
)
[ "$?" -eq 0 ] && test_pass "dx_backup_resolve_dir: docker-ssh gains a runtime+daemon-ID path segment, never mixing two NASs' backups" || test_fail "dx_backup_resolve_dir: docker-ssh gains a runtime+daemon-ID path segment, never mixing two NASs' backups"

# dx_backup_resolve_dir: an explicit override argument (qnap-dxe-plan.md
# Phase 7 / docs/refactor/qnap-promotion.md section B -- dx-restore's
# --source-container=NAME) replaces ONLY the container-name segment; with
# no argument, both cases above already prove nothing changed. Apple's
# shape composes the override the same simple way.
(
    export DX_RUNTIME=apple DX_CONTAINER_NAME=dx-host DX_BACKUP_DIR=/tmp/dxe-rtb-backups
    [ "$(dx_backup_resolve_dir other-profile)" = "/tmp/dxe-rtb-backups/other-profile" ]
)
[ "$?" -eq 0 ] && test_pass "dx_backup_resolve_dir: an override argument replaces the container-name segment under apple too" || test_fail "dx_backup_resolve_dir: an override argument replaces the container-name segment under apple too"

# dx_backup_resolve_dir: under docker-ssh, an override argument replaces
# only the container-name segment -- the identity segment still always
# comes from the CURRENT profile's own DX_REMOTE_HOST/daemon, never the
# override, proving a cross-profile restore can only ever be same-NAS
# (docs/refactor/qnap-promotion.md section B2's "known limitation").
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1 $2" = "info --format" ] && echo "abc123def|qnap-fake|x86_64|linux"'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap-b DX_BACKUP_DIR=/tmp/dxe-rtb-backups
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    [ "$(dx_backup_resolve_dir dx-qnap-canary)" = "/tmp/dxe-rtb-backups/dx-qnap-canary/docker-ssh_qnap-dxe_abc123def" ]
)
[ "$?" -eq 0 ] && test_pass "dx_backup_resolve_dir: an override argument replaces only the container-name segment; the identity segment still comes from the CURRENT profile" || test_fail "dx_backup_resolve_dir: an override argument replaces only the container-name segment; the identity segment still comes from the CURRENT profile"

# --- Diagnostics taxonomy (item 8) --------------------------------------

# The classifier itself: each named class from
# docs/refactor/docker-adapter-mapping.md section 7, plus an unrecognized
# failure still getting a generic (never silent) label.
(
    [ "$(dx_runtime_docker_classify_failure 'Permission denied (publickey).')" = "authentication failure" ] &&
    [ "$(dx_runtime_docker_classify_failure 'Host key verification failed.')" = "authentication failure" ] &&
    [ "$(dx_runtime_docker_classify_failure 'ssh: connect to host qnap-dxe port 22: Connection refused')" = "connection loss" ] &&
    [ "$(dx_runtime_docker_classify_failure 'ssh: connect to host qnap-dxe port 22: Operation timed out')" = "connection loss" ] &&
    [ "$(dx_runtime_docker_classify_failure 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?')" = "daemon restart or unreachable" ] &&
    [ "$(dx_runtime_docker_classify_failure 'bash: docker: command not found')" = "missing Docker access" ] &&
    [ "$(dx_runtime_docker_classify_failure 'something entirely unexpected')" = "remote command failure" ]
)
[ "$?" -eq 0 ] && test_pass "classify_failure: every named class, plus a generic fallback for the unrecognized case" || test_fail "classify_failure: every named class, plus a generic fallback for the unrecognized case"

# available: connection loss is named distinctly (a timeout-shaped ssh
# failure, not a generic "cannot reach").
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" ssh 'echo "ssh: connect to host qnap-dxe port 22: Operation timed out" >&2; exit 255'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    container_system_is_running() { return 1; }
    dx_runtime_system_start() { :; }
    out="$(container_system_ensure_started 2>&1)"
    [ "$out" = "Apple container system is not running; starting it..." ]
)
[ "$?" -eq 0 ] && test_pass "container_system_ensure_started: apple's message is byte-for-byte unchanged" || test_fail "container_system_ensure_started: apple's message is byte-for-byte unchanged"
(
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    container_system_is_running() { return 1; }
    dx_runtime_system_start() { :; }
    out="$(container_system_ensure_started 2>&1)"
    printf '%s\n' "$out" | stdin_matches -F -- "qnap-dxe" && ! printf '%s\n' "$out" | stdin_matches "Apple"
)
[ "$?" -eq 0 ] && test_pass "container_system_ensure_started: docker-ssh's message never says 'Apple'" || test_fail "container_system_ensure_started: docker-ssh's message never says 'Apple'"

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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=aarch64-linux
    dx_runtime_docker_check_arch
)
[ "$?" -eq 0 ] && test_pass "check_arch: aarch64 maps to aarch64-linux and matches" || test_fail "check_arch: aarch64 maps to aarch64-linux and matches"

# discover_daemon_id: the info round trip itself fails.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_lock_release "" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "no lock 'dxe-lock-qnap-dxe__dx-qnap' to release"
)
[ "$?" -eq 0 ] && test_pass "lock_release: refuses when there is no lock at all to release" || test_fail "lock_release: refuses when there is no lock at all to release"

# dx_runtime_apple_container_create: the same "unknown parameter" fail-
# closed proof the docker adapter already has, on the Apple side too.
(
    out="$(dx_runtime_apple_container_create --totally-unknown-flag value --name dx-host --image dx-nixos 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "unknown parameter"
)
[ "$?" -eq 0 ] && test_pass "apple container_create: fails closed on an unrecognized parameter too" || test_fail "apple container_create: fails closed on an unrecognized parameter too"

# --- image_identity (Branch 11 / Phase 3, design point D amendment): the
# host's own stable per-image identity, used by bin/dx-create-container to
# forward DX_IMAGE_IDENTITY so the direct-volume guest can detect a plain
# image bump on a reused volume without needing to reach the image's own
# store (docs/refactor/direct-volume-storage.md section 5). Docker: a
# structured `--format '{{.Id}}'` query, the same shape
# tests/qnap/phase0-spike.sh already uses for its own base/tag digest
# comparison. Apple: `container image inspect` has no --format flag (real
# CLI, confirmed via --help), so the fake below reproduces its actual JSON
# shape (a top-level "id" field, distinct from the nested "digest" fields
# under configuration.descriptor and each variants[] entry) and the adapter
# extracts it without a JSON parser (bin/lib/dx-runtime-docker.sh's own
# module comment: "the Mac side has no guaranteed jq").
out="$(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1 $2 $3 $4" = "image inspect --format {{.Id}}" ] && [ "$5" = dx-qnap-nixos ] && echo sha256:abc123def456 || exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_identity dx-qnap-nixos
)"
[ "$out" = sha256:abc123def456 ] && test_pass "image_identity (docker-ssh): returns docker image inspect's {{.Id}} verbatim" || test_fail "image_identity (docker-ssh): returns docker image inspect's {{.Id}} verbatim (got: $out)"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_identity missing-image
)
[ "$?" -ne 0 ] && test_pass "image_identity (docker-ssh): fails closed when docker image inspect cannot find the image" || test_fail "image_identity (docker-ssh): fails closed when docker image inspect cannot find the image"

apple_image_inspect_json='[
  {
    "configuration" : {
      "descriptor" : {
        "digest" : "sha256:0000000000000000000000000000000000000000000000000000000000ff",
        "mediaType" : "application/vnd.oci.image.index.v1+json",
        "size" : 9218
      },
      "name" : "docker.io/library/dx-qnap-nixos:latest"
    },
    "id" : "deadbeef00112233445566778899aabbccddeeff0011223344556677889900aa",
    "variants" : [
      {
        "digest" : "sha256:1111111111111111111111111111111111111111111111111111111111ee"
      }
    ]
  }
]'
out="$(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" container "printf '%s\n' '$apple_image_inspect_json'"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=apple
    dx_runtime_image_identity dx-qnap-nixos
)"
[ "$out" = sha256:deadbeef00112233445566778899aabbccddeeff0011223344556677889900aa ] \
    && test_pass "image_identity (apple): extracts the top-level \"id\" field, not the nested \"digest\" fields, prefixed sha256:" \
    || test_fail "image_identity (apple): extracts the top-level \"id\" field, not the nested \"digest\" fields, prefixed sha256: (got: $out)"
(
    dir="$(new_tool_dir)"
    fake_tool_write "$dir" container 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=apple
    dx_runtime_image_identity missing-image
)
[ "$?" -ne 0 ] && test_pass "image_identity (apple): fails closed when container image inspect cannot find the image" || test_fail "image_identity (apple): fails closed when container image inspect cannot find the image"

# container_list (Branch 11 / Phase 4, design point E): the rendered
# `docker ps` --format string gains an io.dxe.system column so dx-status's
# docker-ssh output shows it, while staying column-1-anchored (bin/dx-status's
# `dx_runtime_container_list -a | grep "^${DX_CONTAINER_NAME}[[:space:]]"`
# keeps working unmodified).
#
# Finding 5 (NAS re-gate): `docker ps`/`ls` formats render `.Labels` as a
# comma-separated STRING, not a map -- only `docker inspect` exposes it as
# a map. A real Docker CLI (29.4.0, verified live 2026-09-28) rejects
# `index .Labels "io.dxe.system"` here with "failed to execute template:
# ... error calling index: cannot index slice/array with type string". The
# fakes cannot catch a Go-template error on their own, so this one
# reproduces that exact real failure whenever a ps/ls format still
# contains the wrong (map-style) shape, so a regression back to it fails
# loudly here instead of silently on the NAS. The correct field is
# `{{.Label "io.dxe.system"}}` (singular, a method -- not `index .Labels`).
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/list-format-argv.log"
    fake_tool_write "$dir" docker "
[ \"\$1\" = ps ] || { echo UNMATCHED >&2; exit 99; }
shift
printf '%s\n' \"\$@\" > '$argv_log'
for a in \"\$@\"; do
    case \"\$a\" in
        *'index .Labels'*)
            echo 'failed to execute template: template: :1:42: executing \"\" at <index .Labels \"io.dxe.system\">: error calling index: cannot index slice/array with type string' >&2
            exit 1
            ;;
    esac
done
"
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_list -a >/dev/null
    rc=$?
    got="$(cat "$argv_log" 2>/dev/null)"
    [ "$rc" -eq 0 ] \
        && printf '%s\n' "$got" | stdin_matches -F -- '{{.Label "io.dxe.system"}}' \
        && printf '%s\n' "$got" | stdin_matches -F -- '{{.Names}}'
)
[ "$?" -eq 0 ] && test_pass "container_list format includes the io.dxe.system column via .Label (ps/ls semantics), still starting with {{.Names}}" || test_fail "container_list format includes the io.dxe.system column via .Label (ps/ls semantics), still starting with {{.Names}}"

# --- dx_container_list_names boundary-leak fix (Branch 11 / Phase 3,
# Increment 4, docs/refactor/direct-volume-storage.md): bin/lib/dx-container.sh's
# dx_container_list_names used to call dx_runtime_apple_container_list_names
# DIRECTLY, unconditionally -- under DX_RUNTIME=docker-ssh this reached for
# the local Apple `container` binary instead of dispatching to the docker-ssh
# adapter. A poisoned `container` fake (fails loudly if ever invoked) proves
# it is never reached now that dx_container_list_names routes through
# dx_runtime_container_list.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" container 'echo "apple adapter should never run" >&2; exit 99'
    fake_tool_write "$dir" docker '
[ "$1" = ps ] || { echo "UNMATCHED: $*" >&2; exit 99; }
case "$*" in *"-a"*) ;; *) echo "expected -a to pass through" >&2; exit 98 ;; esac
echo "NAMES	IMAGE	STATUS"
echo "dx-qnap-all	dx-qnap-nixos	Up 2 hours"'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_container_list_names true | grep -q -x -- dx-qnap-all
)
[ "$?" -eq 0 ] && test_pass "dx_container_list_names(true): docker-ssh reaches the docker adapter, never the local Apple container binary" || test_fail "dx_container_list_names(true): docker-ssh reaches the docker adapter, never the local Apple container binary"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" container 'echo "apple adapter should never run" >&2; exit 99'
    fake_tool_write "$dir" docker '
[ "$1" = ps ] || { echo "UNMATCHED: $*" >&2; exit 99; }
case "$*" in *"-a"*) echo "expected no -a for the running-only form" >&2; exit 98 ;; esac
echo "NAMES	IMAGE	STATUS"
echo "dx-qnap-running	dx-qnap-nixos	Up 2 hours"'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_container_list_names false | grep -q -x -- dx-qnap-running
)
[ "$?" -eq 0 ] && test_pass "dx_container_list_names(false): docker-ssh's running-only form omits -a, never reaches the local Apple container binary" || test_fail "dx_container_list_names(false): docker-ssh's running-only form omits -a, never reaches the local Apple container binary"

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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_usage dxe-p3-na
)"
[ "$out" = unknown ] && test_pass "volume_usage (docker-ssh): 'unknown' when Docker reports the size as N/A" || test_fail "volume_usage (docker-ssh): 'unknown' when Docker reports the size as N/A (got: $out)"
out="$(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1 $2" = "system df" ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_usage dxe-p3-absent
)"
[ "$out" = unknown ] && test_pass "volume_usage (docker-ssh): 'unknown' when the volume is absent from the report" || test_fail "volume_usage (docker-ssh): 'unknown' when the volume is absent from the report (got: $out)"
out="$(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
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
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dxe-p3-nix DX_PERSIST_VOLUME=dxe-p3-persist \
        DX_NIX_MOUNT=/nix \
        PATH="$dir:/usr/bin:/bin" \
        "$BASE_DIR/bin/dx-reclaim" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$out" | stdin_matches -F -- 'Skipping filesystem trim'
)
[ "$?" -eq 0 ] && test_pass "dx-reclaim (docker-ssh): skips fstrim entirely, never reaching the guest fstrim call" || test_fail "dx-reclaim (docker-ssh): skips fstrim entirely, never reaching the guest fstrim call"

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
    out="$(env HOME="$nix_disk_home" DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_NIX_STORAGE_MODE=direct-volume DX_NIX_DISK="$nix_disk_path" DX_NIX_DISK_SIZE=1M \
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
    out="$(env HOME="$mount_home" DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-qnap-mount PATH="$PATH" \
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
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

# --- WP3.4 (Fable A1) daemon-id cache-write failure branch (CI kcov gate
# addendum, 2026-09-30): dx_runtime_docker_daemon_id_cache_write's own
# tmp-write/rename failure arm ("if ! printf ... || ! chmod ... || ! mv -f
# "$tmp" "$path"; then rm -f "$tmp"; return 1; fi") was uncovered -- every
# existing fixture only ever exercised the success path. mkdir/chmod on the
# cache DIRECTORY happen unconditionally a few lines above (so a read-only
# or missing-parent directory trips an EARLIER return, never this one); the
# one external command this function calls that this arm's own `!` guards
# and that a fixture can safely fake without disturbing mkdir/chmod/mktemp/
# rm is `mv` itself. A fake `mv` that always fails makes the real mktemp
# above it still create the tmp file, so the failure genuinely lands on the
# rename, exactly the condition being proven, and `rm -f "$tmp"` still runs
# for real afterward -- asserted here by requiring the cache directory be
# left with neither the tmp file nor a published host-identity file.
(
    dxe_s33cw_dir="$(new_tool_dir)"
    fake_tool_write "$dxe_s33cw_dir" mv 'echo "fake mv: refusing to rename" >&2; exit 1'
    PATH="$dxe_s33cw_dir:/usr/bin:/bin"
    DX_CONTAINER_NAME=dxe-cachewrite-fail-container
    unset XDG_STATE_HOME
    dxe_s33cw_target_dir="$HOME/.local/state/dxe/$DX_CONTAINER_NAME"
    rm -rf "$dxe_s33cw_target_dir" 2>/dev/null || true

    dxe_s33cw_rc=0
    dx_runtime_docker_daemon_id_cache_write "dxe-cachewrite-fail-daemon-id" >/dev/null 2>&1 || dxe_s33cw_rc=$?

    dxe_s33cw_leftover_tmp=""
    for dxe_s33cw_f in "$dxe_s33cw_target_dir"/.host-identity.*; do
        [ -e "$dxe_s33cw_f" ] && dxe_s33cw_leftover_tmp="$dxe_s33cw_f"
    done

    [ "$dxe_s33cw_rc" -ne 0 ] \
        && [ ! -e "$dxe_s33cw_target_dir/host-identity" ] \
        && [ -z "$dxe_s33cw_leftover_tmp" ]
)
[ "$?" -eq 0 ] && test_pass "dx_runtime_docker_daemon_id_cache_write: a failed rename returns non-zero, and leaves neither the published host-identity file nor its own tmp file behind" \
    || test_fail "dx_runtime_docker_daemon_id_cache_write: a failed rename returns non-zero, and leaves neither the published host-identity file nor its own tmp file behind"

print_summary
exit_with_code
