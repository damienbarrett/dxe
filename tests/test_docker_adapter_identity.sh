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
# Fable D6 step 1: docker-ssh runtime adapter, identity part -- daemon/host
# identity discovery, DQ6 ownership labels and collision refusal, image_build,
# nix-volume claim scoping by daemon identity, identity-scoped local state,
# image_identity, the dx_container_list_names boundary-leak fix, and the
# daemon-id cache-write failure branch.
#
# Runnable standalone: bash tests/test_docker_adapter_identity.sh
# (prints its own banner and its own Results line for just its own
# cases). tests/test_docker_runtime_adapter.sh sources this file, in
# order with its four siblings, as section 33's one registered entry;
# sourced that way, this file prints no banner of its own and defers
# print_summary/exit_with_code to the aggregate, so section 33 still
# reports one combined Results line for all 208 cases.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    test_section "Docker-ssh runtime adapter (Branch 11 / Phase 2) -- identity"
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


# --- Queries (item 3) -------------------------------------------------------

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1 $2" = "image inspect" ] && [ "$3" = dx-qnap-nixos ] && exit 0; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_exists dx-qnap-nixos
)
[ "$?" -eq 0 ] && test_pass "image_exists: true for an image docker inspect finds" || test_fail "image_exists: true for an image docker inspect finds"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_list | grep -q "^dx-qnap-nixos[[:space:]]"
)
[ "$?" -eq 0 ] && test_pass "image_list: name-anchored first column (Repository and Tag are separate columns), name-prefixed grep still works" || test_fail "image_list: name-anchored first column (Repository and Tag are separate columns), name-prefixed grep still works"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = volume ] && [ "$2" = inspect ] && [ "$3" = dx-qnap-nix ] && exit 0; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_exists dx-qnap-nix
)
[ "$?" -eq 0 ] && test_pass "volume_exists: true for a volume docker inspect finds" || test_fail "volume_exists: true for a volume docker inspect finds"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_exists missing-volume
)
[ "$?" -ne 0 ] && test_pass "volume_exists: false for a volume docker inspect cannot find" || test_fail "volume_exists: false for a volume docker inspect cannot find"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$1" = container ] && [ "$2" = inspect ] && [ "$3" = dx-qnap ] && exit 0; exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_exists dx-qnap
)
[ "$?" -eq 0 ] && test_pass "container_exists: true for a container docker inspect finds" || test_fail "container_exists: true for a container docker inspect finds"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_exists missing-container
)
[ "$?" -ne 0 ] && test_pass "container_exists: false for a container docker inspect cannot find" || test_fail "container_exists: false for a container docker inspect cannot find"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$5" = dx-qnap ] && echo true'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_running dx-qnap
)
[ "$?" -eq 0 ] && test_pass "container_running: true when State.Running is true" || test_fail "container_running: true when State.Running is true"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '[ "$5" = dx-qnap ] && echo false'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_running dx-qnap
)
[ "$?" -ne 0 ] && test_pass "container_running: false when State.Running is false" || test_fail "container_running: false when State.Running is false"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_container_list -a | grep -q "^dx-qnap[[:space:]]"
)
[ "$?" -eq 0 ] && test_pass "container_list: -a passes through, name-anchored first column" || test_fail "container_list: -a passes through, name-anchored first column"

# --- DQ6 labels + collision refusal (item 5) --------------------------

# container_delete: label check passes (managed=true, matching profile,
# role=container), then the real rm/--force call happens.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker '
case "$1 $2" in
    "container inspect") echo "true|1|dxe-fixture-nas.invalid__dx-qnap|container|x86_64-linux" ;;
    *) [ "$1" = rm ] && [ "$2" = --force ] && [ "$3" = dx-qnap ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap DX_GUEST_SYSTEM=x86_64-linux
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
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
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix DX_GUEST_SYSTEM=x86_64-linux
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_volume_create dx-qnap-nix
    got="$(cat "$argv_log")"
    printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.role=nix" && printf '%s\n' "$got" | stdin_matches -F -- "io.dxe.profile=dxe-fixture-nas.invalid__dx-qnap" && printf '%s\n' "$got" | stdin_matches -F -- "dx-qnap-nix"
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
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix DX_GUEST_SYSTEM=x86_64-linux
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap
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
    "volume inspect") echo "true|1|dxe-fixture-nas.invalid__dx-qnap|nix|x86_64-linux" ;;
    *) [ "$1" = volume ] && [ "$2" = rm ] && [ "$3" = dx-qnap-nix ] && exit 0; echo "UNMATCHED: $*" >&2; exit 99 ;;
esac'
    PATH="$dir:/usr/bin:/bin"
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix DX_GUEST_SYSTEM=x86_64-linux
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
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_volume_delete some-other-volume 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "not one of the configured DXE volumes"
)
[ "$?" -eq 0 ] && test_pass "volume_delete: refuses an unrecognized volume name" || test_fail "volume_delete: refuses an unrecognized volume name"

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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    export DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_build -t dx-qnap-nixos "$containerfile_comments"
)
[ "$?" -eq 0 ] && test_pass "image_build: comments and blank lines around the one FROM line are not significant" || test_fail "image_build: comments and blank lines around the one FROM line are not significant"

(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "docker should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_image_build --bogus-shape 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches "only supports"
)
[ "$?" -eq 0 ] && test_pass "image_build: refuses an argv shape other than bin/dx-create-image's own" || test_fail "image_build: refuses an argv shape other than bin/dx-create-image's own"

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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    export DXE_RUNTIME_DOCKER_BIN=docker
    [ "$(dx_tunnel_key forward 8080)" = "forward:dx-qnap:8080:docker-ssh:dxe-fixture-nas.invalid:abc123def" ]
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
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap DX_BACKUP_DIR=/tmp/dxe-rtb-backups
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    [ "$(dx_backup_resolve_dir)" = "/tmp/dxe-rtb-backups/dx-qnap/docker-ssh_dxe-fixture-nas.invalid_abc123def" ]
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
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap-b DX_BACKUP_DIR=/tmp/dxe-rtb-backups
    unset DXE_RUNTIME_DOCKER_BIN DXE_RUNTIME_DOCKER_DAEMON_ID
    [ "$(dx_backup_resolve_dir dx-qnap-canary)" = "/tmp/dxe-rtb-backups/dx-qnap-canary/docker-ssh_dxe-fixture-nas.invalid_abc123def" ]
)
[ "$?" -eq 0 ] && test_pass "dx_backup_resolve_dir: an override argument replaces only the container-name segment; the identity segment still comes from the CURRENT profile" || test_fail "dx_backup_resolve_dir: an override argument replaces only the container-name segment; the identity segment still comes from the CURRENT profile"

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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_runtime_image_identity dx-qnap-nixos
)"
[ "$out" = sha256:abc123def456 ] && test_pass "image_identity (docker-ssh): returns docker image inspect's {{.Id}} verbatim" || test_fail "image_identity (docker-ssh): returns docker image inspect's {{.Id}} verbatim (got: $out)"
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'exit 1'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
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
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DXE_RUNTIME_DOCKER_BIN=docker
    dx_container_list_names false | grep -q -x -- dx-qnap-running
)
[ "$?" -eq 0 ] && test_pass "dx_container_list_names(false): docker-ssh's running-only form omits -a, never reaches the local Apple container binary" || test_fail "dx_container_list_names(false): docker-ssh's running-only form omits -a, never reaches the local Apple container binary"

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

# Direct-call battery: dx_runtime_docker_resource_owned's own defensive
# "unknown kind" arm. Every real caller passes a fixed literal kind
# (dx_runtime_docker_container_owned always passes "container",
# dx_runtime_docker_volume_owned always passes "volume"), so this branch is
# unreachable through either public wrapper -- call the shared function
# directly, exactly as it would be misused, to prove it fails closed rather
# than silently treating an unrecognized kind as owned.
(
    dir="$(new_tool_dir)"
    fake_qnap_ssh_write "$dir"
    fake_tool_write "$dir" docker 'echo "docker should never run" >&2; exit 99'
    PATH="$dir:/usr/bin:/bin"
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid
    export DXE_RUNTIME_DOCKER_BIN=docker
    out="$(dx_runtime_docker_resource_owned bogus-kind some-name container use 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches -F -- "dx_runtime_docker_resource_owned: unknown kind 'bogus-kind'"
)
[ "$?" -eq 0 ] && test_pass "dx_runtime_docker_resource_owned: refuses an unrecognized kind rather than guessing (direct call)" \
    || test_fail "dx_runtime_docker_resource_owned: refuses an unrecognized kind rather than guessing (direct call)"

rm -rf "$fixture" 2>/dev/null || true

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    print_summary
    exit_with_code
fi
