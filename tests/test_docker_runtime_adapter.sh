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
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "did not report a compatible server version"
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

print_summary
exit_with_code
