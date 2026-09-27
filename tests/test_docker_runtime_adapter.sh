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
source "$BASE_DIR/bin/lib/dx-tunnel.sh"
source "$BASE_DIR/bin/lib/dx-backup.sh"
test_section "Docker-ssh runtime adapter (Branch 11 / Phase 2)"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-docker-adapter.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

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
    printf '%s' "$dir"
}

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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    DX_RUNTIME_DOCKER_BIN_GLOB="$dir/share/*/.qpkg/container-station/bin/docker" dx_runtime_available
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
    fake_tool_write "$dir" docker '
[ "$1 $2" = "image ls" ] || { echo "UNMATCHED: $*" >&2; exit 99; }
echo "REPOSITORY:TAG	IMAGE ID	CREATED	SIZE"
echo "dx-qnap-nixos:latest	abc123	1 day ago	500MB"'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_list | grep -q "^dx-qnap-nixos:latest[[:space:]]"
)
[ "$?" -eq 0 ] && test_pass "image_list: name-anchored first column, name-prefixed grep still works" || test_fail "image_list: name-anchored first column, name-prefixed grep still works"

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
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    argv_log="$fixture/create-argv.log"
    fake_tool_write "$dir" docker "
[ \"\$1\" = create ] || { echo UNMATCHED >&2; exit 99; }
shift
printf '%s\n' \"\$@\" > '$argv_log'
"
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_create \
        --name dx-qnap --image dx-qnap-nixos \
        --volume nix:dx-qnap-nix:rw \
        --volume persist:dx-qnap-persist:/persist:rw \
        --volume bootstrap:dx-qnap-bootstrap:/guest-bootstrap:rw \
        --env HOST_TZ=UTC --memory 12G --cpus 4 --publish 127.0.0.1:2222:2222 \
        --restart-policy unless-stopped \
        --entrypoint-cmd 'echo hi' --entrypoint-arg /guest-bootstrap
    got="$(cat "$argv_log")"
    printf '%s\n' "$got" | stdin_matches -F -- "CAP_SYS_ADMIN" && test_fail "container_create never grants CAP_SYS_ADMIN (DQ4)" || test_pass "container_create never grants CAP_SYS_ADMIN (DQ4)"
    printf '%s\n' "$got" | stdin_matches -F -- "--cpus" && printf '%s\n' "$got" | stdin_matches -F -- "4" && test_pass "container_create renders --cpus N, never Docker's own -c (cpu-shares)" || test_fail "container_create renders --cpus N, never Docker's own -c (cpu-shares)"
    printf '%s\n' "$got" | stdin_matches -F -- "dx-qnap-nix:/nix:rw" && test_pass "container_create mounts the Nix volume directly at /nix (DQ4)" || test_fail "container_create mounts the Nix volume directly at /nix (DQ4)"
    printf '%s\n' "$got" | stdin_matches -F -- "dx-qnap-persist:/persist:rw" && test_pass "container_create mounts the persist volume at /persist" || test_fail "container_create mounts the persist volume at /persist"
    printf '%s\n' "$got" | stdin_matches -F -- "dx-qnap-bootstrap:/guest-bootstrap:rw" && test_pass "container_create mounts the bootstrap volume at its configured path" || test_fail "container_create mounts the bootstrap volume at its configured path"
    printf '%s\n' "$got" | stdin_matches -F -- "--restart" && printf '%s\n' "$got" | stdin_matches -F -- "unless-stopped" && test_pass "container_create renders --restart from DX_CONTAINER_RESTART_POLICY" || test_fail "container_create renders --restart from DX_CONTAINER_RESTART_POLICY"
    printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.managed=true" && printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.role=container" && printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.profile=qnap-dxe__dx-qnap" && test_pass "container_create carries the DQ6 labels" || test_fail "container_create carries the DQ6 labels"
    printf '%s\n' "$got" | stdin_matches -F -- "--name" && test_pass "container_create keeps --name" || test_fail "container_create keeps --name"
    printf '%s\n' "$got" | stdin_matches -F -- "-c
echo hi
--
/guest-bootstrap" && test_pass "container_create passes the post-image entrypoint argv through completely unexamined" || test_fail "container_create passes the post-image entrypoint argv through completely unexamined"
)

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

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = start ] && [ "$2" = dx-qnap ] && exit 0; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_start dx-qnap
)
[ "$?" -eq 0 ] && test_pass "container_start: passthrough" || test_fail "container_start: passthrough"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = stop ] && [ "$2" = --time ] && [ "$3" = 5 ] && [ "$4" = dx-qnap ] && exit 0; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_stop --time 5 dx-qnap
)
[ "$?" -eq 0 ] && test_pass "container_stop: --time N NAME passthrough (Docker and Apple agree)" || test_fail "container_stop: --time N NAME passthrough (Docker and Apple agree)"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = kill ] && [ "$2" = dx-qnap ] && exit 0; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_kill dx-qnap
)
[ "$?" -eq 0 ] && test_pass "container_kill: passthrough" || test_fail "container_kill: passthrough"

# --- DQ6 labels + collision refusal (item 5) --------------------------

# container_delete: label check passes (managed=true, matching profile,
# role=container), then the real rm/--force call happens.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "true|1|qnap-dxe__dx-qnap|container" ;;
    *) [ "$1" = rm ] && [ "$2" = --force ] && [ "$3" = dx-qnap ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap
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
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_create dx-qnap-nix
    got="$(cat "$argv_log")"
    printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.role=nix" && printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.profile=qnap-dxe__dx-qnap" && printf '%s\n' "$got" | stdin_matches -F -- "dx-qnap-nix"
)
[ "$?" -eq 0 ] && test_pass "volume_create: role derived from the configured name, DQ6 labels attached" || test_fail "volume_create: role derived from the configured name, DQ6 labels attached"

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
    "volume inspect") echo "true|1|qnap-dxe__dx-qnap|nix" ;;
    *) [ "$1" = volume ] && [ "$2" = rm ] && [ "$3" = dx-qnap-nix ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos
    export DXE_RUNTIME_DOCKER_BIN=docker
    owner="$(dx_runtime_docker_lock_acquire)"
    [ -n "$owner" ] && printf '%s\n' "$owner" | stdin_matches ":"
)
[ "$?" -eq 0 ] && test_pass "lock_acquire: succeeds and prints a non-empty owner token" || test_fail "lock_acquire: succeeds and prints a non-empty owner token"

# Acquire: fails (name conflict) when already held.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "Error: Conflict. The container name ... is already in use" >&2; exit 1'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos
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
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_CONTAINER_NAME=dx-qnap PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx-lock" status 2>&1)"; rc=$?
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
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_CONTAINER_NAME=dx-qnap PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx-lock" unlock 2>&1)"; rc=$?
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
    out="$(DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_GUEST_SYSTEM=x86_64-linux DX_CONTAINER_NAME=dx-qnap PATH="$dir:/usr/bin:/bin" "$BASE_DIR/bin/dx-lock" unlock --force 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "Lock released."
)
[ "$?" -eq 0 ] && test_pass "bin/dx-lock unlock --force removes the lock end to end" || test_fail "bin/dx-lock unlock --force removes the lock end to end"

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
    DX_RUNTIME=apple DX_CONTAINER_NAME=dx-host DX_BACKUP_DIR=/tmp/dxe-rtb-backups
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dx-qnap DX_BACKUP_DIR=/tmp/dxe-rtb-backups
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    [ "$(dx_backup_resolve_dir)" = "/tmp/dxe-rtb-backups/dx-qnap/docker-ssh_qnap-dxe_abc123def" ]
)
[ "$?" -eq 0 ] && test_pass "dx_backup_resolve_dir: docker-ssh gains a runtime+daemon-ID path segment, never mixing two NASs' backups" || test_fail "dx_backup_resolve_dir: docker-ssh gains a runtime+daemon-ID path segment, never mixing two NASs' backups"

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

print_summary
exit_with_code
