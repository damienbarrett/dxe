#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# WP1.6: the helper no longer sources production libraries; this suite's Apple
# lock cases need dx_lock_acquire/_release from dx-host-util.sh.
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
test_section "Section 9: Host Library And Command Contracts"

for script in "$BASE_DIR"/bin/dx*; do
    [ -f "$script" ] || continue
    case "$script" in */dx-lib.sh) continue ;; esac
    if grep -q '^set -euo pipefail$' "$script"; then test_pass "$(basename "$script") owns strict mode"; else test_fail "$(basename "$script") owns strict mode"; fi
    if bash -n "$script"; then :; else test_fail "$(basename "$script") passes bash syntax"; fi
done

for library in "$BASE_DIR"/bin/lib/*.sh; do
    if grep -q '^set -.*pipefail' "$library"; then test_fail "$(basename "$library") does not set caller shell options"; else test_pass "$(basename "$library") does not set caller shell options"; fi
    before_flags=$-; before_ifs=$IFS; before_pwd=$PWD; before_umask="$(umask)"; before_traps="$(trap -p)"
    # shellcheck source=/dev/null
    output="$(source "$library")"
    if [ -z "$output" ] && [ "$before_flags" = "$-" ] && [ "$before_ifs" = "$IFS" ] && [ "$before_pwd" = "$PWD" ] && [ "$before_umask" = "$(umask)" ] && [ "$before_traps" = "$(trap -p)" ]; then
        test_pass "$(basename "$library") is import-only"
    else test_fail "$(basename "$library") is import-only"; fi
done

source "$BASE_DIR/bin/lib/dx-config.sh"
config_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-host-config.XXXXXX")"
trap 'rm -rf "$config_fixture"' EXIT
printf '%s\n' 'DX_CONTAINER_NAME=from-data' 'DX_SSH_KEY=${DX_PROJECT_ROOT}/fixture-key' > "$config_fixture/good.env"
DX_PROJECT_ROOT=$config_fixture
if dx_parse_config_file "$config_fixture/good.env" && [ "$DXE_PARSED_DX_CONTAINER_NAME" = from-data ] && [ "$DXE_PARSED_DX_SSH_KEY" = "$config_fixture/fixture-key" ]; then test_pass "root/profile grammar is parsed as bounded data"; else test_fail "root/profile grammar is parsed as bounded data"; fi
for hostile in 'DX_CONTAINER_NAME=$(id)' 'DX_CONTAINER_NAME=$HOME' 'DX_CONTAINER_NAME="quoted"' 'UNKNOWN=value'; do
    printf '%s\n' "$hostile" > "$config_fixture/hostile.env"
    if dx_parse_config_file "$config_fixture/hostile.env" >/dev/null 2>&1; then test_fail "config rejects $hostile"; else test_pass "config rejects $hostile"; fi
done

(
    unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION
    HOME="$config_fixture"; dx_init_config "$BASE_DIR"
    dx_validate_config_snapshot "$BASE_DIR"
) && test_pass "complete versioned configuration snapshot validates" || test_fail "complete versioned configuration snapshot validates"
(
    DXE_CONFIG_RESOLVED=1 DXE_CONFIG_SNAPSHOT_VERSION=1 DX_PROJECT_ROOT="$BASE_DIR"
    export DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PROJECT_ROOT
    for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
    dx_validate_config_snapshot "$BASE_DIR"
) >/dev/null 2>&1 && test_fail "partial snapshot fails closed" || test_pass "partial snapshot fails closed"

source "$BASE_DIR/bin/lib/dx-container.sh"
# shellcheck source=/dev/null
source "$BASE_DIR/bin/lib/dx-bootstrap-sync.sh"
ps() { printf '%s\n' '101 container-runtime-linux start --uuid dx-host-other' '102 container-runtime-linux start --uuid dx-host' 'bad malformed'; }
if [ "$(container_runtime_pids dx-host)" = 102 ]; then test_pass "runtime discovery matches exact --uuid argument/value pairs"; else test_fail "runtime discovery matches exact --uuid argument/value pairs"; fi
unset -f ps

# Astra F3 / DQ6 (WP6.4): the owned-resource check's Apple counterpart.
# Apple Container attaches no per-object labels to anything it creates, so
# there is no foreign-resource concept for it to check -- unconditional
# success, not a placeholder for a future check (bin/lib/dx-runtime-apple.sh's
# own comment on dx_runtime_apple_container_owned/volume_owned spells out
# why). Exercised directly (the docker-ssh side of the same dispatch is
# already exhaustively covered, adapter and entrypoint level, in
# tests/test_docker_runtime_adapter.sh).
(
    unset DX_RUNTIME
    dx_runtime_apple_container_owned some-container some-verb \
        && dx_runtime_apple_volume_owned some-volume some-verb
) && test_pass "dx_runtime_apple_container_owned/volume_owned: unconditional success (Apple has no per-object labels)" \
    || test_fail "dx_runtime_apple_container_owned/volume_owned: unconditional success (Apple has no per-object labels)"
(
    unset DX_RUNTIME
    dx_runtime_container_owned dx-host create \
        && dx_runtime_volume_owned dx-nix adopt \
        && container_owned dx-host create
) && test_pass "dx_runtime_container_owned/volume_owned dispatch (and dx-container.sh's container_owned wrapper) reach Apple's unconditional-success implementation when DX_RUNTIME=apple (the default)" \
    || test_fail "dx_runtime_container_owned/volume_owned dispatch (and dx-container.sh's container_owned wrapper) reach Apple's unconditional-success implementation when DX_RUNTIME=apple (the default)"

# container_ensure_volume's ABSENT-volume branch (create, no ownership
# proof needed -- there is nothing to adopt) is unaffected under Apple: a
# fake `container` binary that only answers "volume inspect" (not found)
# and "volume create" proves the create path still runs exactly once, with
# no ownership check in front of it.
(
    dxe_p9_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-p9-apple-volume.XXXXXX")"
    trap 'rm -rf "$dxe_p9_dir"' EXIT
    cat > "$dxe_p9_dir/container" <<'FAKE_EOF'
#!/bin/bash
case "$1 $2" in
    "volume inspect") exit 1 ;;
    "volume create") exit 0 ;;
esac
echo "UNMATCHED: $*" >&2
exit 99
FAKE_EOF
    chmod 0755 "$dxe_p9_dir/container"
    unset DX_RUNTIME
    PATH="$dxe_p9_dir:/usr/bin:/bin" container_ensure_volume dxe-p9-apple-nix
)
[ "$?" -eq 0 ] && test_pass "container_ensure_volume (apple): an ABSENT volume still creates, unaffected by the new ownership check" \
    || test_fail "container_ensure_volume (apple): an ABSENT volume still creates, unaffected by the new ownership check"

# Host lifecycle claims live outside the mounted Nix filesystem and serialize
# ownership by volume name, even when profiles use separate identity dirs.
(
    source "$BASE_DIR/bin/lib/dx-host-util.sh"
    # Exported: these are environment inputs the sourced library reads inside
    # dx_nix_volume_claim_acquire, not local bookkeeping, so ShellCheck can't
    # see the consumer and flags them SC2034 without the export.
    export DX_TUNNEL_LOCK_TIMEOUT=1
    export DXE_SELF_PROCESS_IDENTITY="test-$$"
    HOME="$config_fixture/claim-home"
    existing="first"
    container_exists() { [ "$existing" = "$1" ]; }
    dx_nix_volume_claim_acquire shared-nix first
    ! dx_nix_volume_claim_acquire shared-nix second
    ! dx_nix_volume_claim_acquire shared-nix second
    existing=""
    dx_nix_volume_claim_acquire shared-nix second
    existing="second"
    ! dx_nix_volume_claim_acquire shared-nix first
    dx_nix_volume_claim_acquire shared-nix second
    existing=""
    printf 'stale\t999999\tdead-process\n' > "$HOME/.dx-cache/nix-volume-claims/stale-nix"
    dx_nix_volume_claim_acquire stale-nix third
    IFS="$(printf '\t')" read -r stale_owner _ < "$HOME/.dx-cache/nix-volume-claims/stale-nix"
    [ "$stale_owner" = third ]
    printf 'stale\t999999\tdead-process\nsecond\t999998\tdead-process\n' > "$HOME/.dx-cache/nix-volume-claims/multiline-nix"
    if dx_nix_volume_claim_acquire multiline-nix third; then exit 1; fi
    dx_nix_volume_claim_release shared-nix first
    IFS="$(printf '\t')" read -r shared_owner _ < "$HOME/.dx-cache/nix-volume-claims/shared-nix"
    [ "$shared_owner" = second ]
    dx_nix_volume_claim_release shared-nix second
    [ ! -e "$HOME/.dx-cache/nix-volume-claims/shared-nix" ]
) && test_pass "Nix-volume lifecycle claims reject running and stopped owners and recover stale claims" || test_fail "Nix-volume lifecycle claims reject running and stopped owners and recover stale claims"

# A create claim is a live reservation before `container create` makes the
# owner observable to `container_exists`. A second creator must not steal it;
# after the first process exits without creating anything, the next attempt
# safely reclaims that stale reservation.
(
    claim_home="$config_fixture/concurrent-claim-home"
    ready="$config_fixture/concurrent-claim-ready"
    hold="$config_fixture/concurrent-claim-hold"
    : > "$hold"
    HOME="$claim_home" DX_TUNNEL_LOCK_TIMEOUT=1 bash -c '
        source "$1"
        source "$2"
        container_exists() { return 1; }
        dx_nix_volume_claim_acquire concurrent-nix first
        : > "$3"
        while [ -e "$4" ]; do sleep 1; done
    ' _ "$BASE_DIR/bin/lib/dx-host-util.sh" "$BASE_DIR/bin/lib/dx-container.sh" "$ready" "$hold" &
    creator_pid=$!
    for _ in $(seq 1 10); do [ -e "$ready" ] && break; sleep 1; done
    [ -e "$ready" ]
    if HOME="$claim_home" DX_TUNNEL_LOCK_TIMEOUT=1 bash -c '
        source "$1"
        source "$2"
        container_exists() { return 1; }
        dx_nix_volume_claim_acquire concurrent-nix second
    ' _ "$BASE_DIR/bin/lib/dx-host-util.sh" "$BASE_DIR/bin/lib/dx-container.sh"; then
        exit 1
    fi
    rm -f "$hold"
    wait "$creator_pid"
    HOME="$claim_home" DX_TUNNEL_LOCK_TIMEOUT=1 bash -c '
        source "$1"
        source "$2"
        container_exists() { return 1; }
        dx_nix_volume_claim_acquire concurrent-nix second
    ' _ "$BASE_DIR/bin/lib/dx-host-util.sh" "$BASE_DIR/bin/lib/dx-container.sh"
    claim="$claim_home/.dx-cache/nix-volume-claims/concurrent-nix"
    IFS="$(printf '\t')" read -r owner _ < "$claim"
    [ "$owner" = second ]
) && test_pass "live create reservations cannot be stolen before container creation" || test_fail "live create reservations cannot be stolen before container creation"

# --- Apple lifecycle lock (Astra F4 / WP6.5) --------------------------------
#
# Apple Container is always local -- one controller, one daemon -- so there
# is no remote owner to exclude (bin/dx-lock itself already refuses outright
# for DX_RUNTIME=apple). dx_runtime_apple_lock_acquire/_release is the
# narrower local safety net: two invocations of dx/dx-create-container/...
# from THIS machine, against the SAME DX_CONTAINER_NAME, running at once.
# The docker-ssh half of dx_lifecycle_lock_acquire/_release (nested
# inheritance, the already-held refusal, first-run image guard, per-daemon
# claim scoping) is covered in tests/test_docker_runtime_adapter.sh; this
# covers Apple's own dispatch target and the local mkdir-lock contention it
# actually protects against.
(
    lock_home="$config_fixture/apple-lock-home"
    export XDG_STATE_HOME="$lock_home/state"
    unset DX_RUNTIME
    export DX_CONTAINER_NAME=dxe-p9-apple-lock
    export DX_TUNNEL_LOCK_TIMEOUT=1
    export DXE_SELF_PROCESS_IDENTITY="test-apple-lock-$$"
    # Not "owner=$(dx_runtime_apple_lock_acquire)": bin/lib/dx-host-util.sh's
    # own dx_lock_acquire sets DXE_HELD_LOCK as a plain (never exported)
    # shell variable, so capturing acquire's stdout through a command
    # substitution would fork it into existence only inside that
    # subshell -- gone before dx_runtime_apple_lock_release runs below in
    # THIS shell. A plain call keeps it here; the token itself is
    # deterministic (the lock path), fetched separately right after.
    dx_runtime_apple_lock_acquire >/dev/null; rc1=$?
    owner="$(dx_runtime_apple_lock_path)"
    [ "$rc1" -eq 0 ] && [ -n "$owner" ] && [ -d "$owner" ] || exit 1
    dx_runtime_apple_lock_release "$owner"; rc2=$?
    [ "$rc2" -eq 0 ] && [ ! -d "$owner" ]
) && test_pass "dx_runtime_apple_lock_acquire/_release: acquires and releases a local, profile-scoped lock directory" \
    || test_fail "dx_runtime_apple_lock_acquire/_release: acquires and releases a local, profile-scoped lock directory"

# A genuinely different, still-live process (a real bash -c child, not this
# same shell's own $$) holding the same profile's local lock is refused,
# never silently stolen -- the same "PID plus process start" reclaim logic
# bin/lib/dx-host-util.sh's own dx_lock_acquire already proves elsewhere in
# this suite, exercised here through the Apple lifecycle-lock entry point.
(
    lock_home="$config_fixture/apple-lock-contend-home"
    export XDG_STATE_HOME="$lock_home/state"
    unset DX_RUNTIME
    export DX_CONTAINER_NAME=dxe-p9-apple-lock-contend
    export DX_TUNNEL_LOCK_TIMEOUT=1
    ready="$config_fixture/apple-lock-ready"; hold="$config_fixture/apple-lock-hold"
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
    rc=0; out="$(dx_runtime_apple_lock_acquire 2>&1)" || rc=$?
    rm -f "$hold"
    wait "$holder_pid" 2>/dev/null || true
    [ "$rc" -ne 0 ]
) && test_pass "dx_runtime_apple_lock_acquire: refuses while another live process holds this profile's local lock" \
    || test_fail "dx_runtime_apple_lock_acquire: refuses while another live process holds this profile's local lock"

# dx_lifecycle_lock_acquire/_release dispatch to the Apple path by default
# (DX_RUNTIME unset/apple), acquiring/releasing the same local lock.
(
    lock_home="$config_fixture/apple-lifecycle-lock-home"
    export XDG_STATE_HOME="$lock_home/state"
    unset DX_RUNTIME
    export DX_CONTAINER_NAME=dxe-p9-apple-lifecycle
    export DX_TUNNEL_LOCK_TIMEOUT=1
    export DXE_SELF_PROCESS_IDENTITY="test-apple-lifecycle-$$"
    [ -z "${DXE_LIFECYCLE_LOCK_OWNER:-}" ] || exit 1
    dx_lifecycle_lock_acquire || exit 1
    owner="$DXE_LIFECYCLE_LOCK_OWNER"
    [ -n "$owner" ] && [ -d "$owner" ] || exit 1
    dx_lifecycle_lock_release
    [ -z "${DXE_LIFECYCLE_LOCK_OWNER:-}" ] && [ ! -d "$owner" ]
) && test_pass "dx_lifecycle_lock_acquire/_release (apple): acquires and releases the local profile lock around itself" \
    || test_fail "dx_lifecycle_lock_acquire/_release (apple): acquires and releases the local profile lock around itself"

# Nested/inherited: an owner token already present in the environment means
# neither call reaches the Apple lock functions at all.
(
    unset DX_RUNTIME
    export DX_CONTAINER_NAME=dxe-p9-apple-lifecycle-nested
    dx_runtime_apple_lock_acquire() { echo "MUST NOT BE CALLED (acquire)" >&2; return 1; }
    dx_runtime_apple_lock_release() { echo "MUST NOT BE CALLED (release)" >&2; return 1; }
    export DXE_LIFECYCLE_LOCK_OWNER=inherited-apple-token
    dx_lifecycle_lock_acquire; rc1=$?
    dx_lifecycle_lock_release; rc2=$?
    unset -f dx_runtime_apple_lock_acquire dx_runtime_apple_lock_release
    [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$DXE_LIFECYCLE_LOCK_OWNER" = inherited-apple-token ]
) && test_pass "dx_lifecycle_lock_acquire/_release (apple): an inherited owner token is a no-op" \
    || test_fail "dx_lifecycle_lock_acquire/_release (apple): an inherited owner token is a no-op"

# Entrypoint level: bin/dx-stop-container refuses while another live process
# holds this profile's local lock, issuing ZERO `container` calls (the
# preflight's own `command -v container` is not an invocation).
(
    ep_home="$config_fixture/apple-entrypoint-lock-home"
    ep_state="$ep_home/state"
    ep_tools="$(fake_tool_dir_create "$config_fixture")"
    ep_log="$config_fixture/apple-entrypoint-lock-calls.log"
    : > "$ep_log"
    fake_tool_write "$ep_tools" container 'printf "CALLED: %s\n" "$*" >> "$DXE_WP65_EP_LOG"; exit 1'
    export XDG_STATE_HOME="$ep_state" DX_CONTAINER_NAME=dxe-p9-apple-entrypoint DXE_WP65_EP_LOG="$ep_log"
    ready="$config_fixture/apple-entrypoint-lock-ready"; hold="$config_fixture/apple-entrypoint-lock-hold"
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
    rc=0; out="$(PATH="$ep_tools:/usr/bin:/bin" "$BASE_DIR/bin/dx-stop-container" 2>&1)" || rc=$?
    rm -f "$hold"
    wait "$holder_pid" 2>/dev/null || true
    [ "$rc" -ne 0 ] && [ ! -s "$ep_log" ] && printf '%s\n' "$out" | stdin_matches -F -- "lifecycle lock"
) && test_pass "dx-stop-container (apple): refuses while another live process holds the local lifecycle lock, zero container calls" \
    || test_fail "dx-stop-container (apple): refuses while another live process holds the local lifecycle lock, zero container calls"

source "$BASE_DIR/bin/dx-forward"
if dx_tunnel_cli_collect forward 5173 8000:8001 && [ "$(printf '%s\n' "${DX_TUNNEL_CLI_MAPPINGS[@]}")" = $'5173:5173\n8001:8000' ]; then test_pass "forward wrapper parses direction-specific mappings"; else test_fail "forward wrapper parses direction-specific mappings"; fi
if dx_tunnel_cli_collect forward 80 >/dev/null 2>&1; then test_fail "forward wrapper rejects privileged host ports"; else test_pass "forward wrapper rejects privileged host ports"; fi
source "$BASE_DIR/bin/dx-reverse"
if dx_tunnel_cli_collect reverse 5432 3000:13000 && [ "$(printf '%s\n' "${DX_TUNNEL_CLI_MAPPINGS[@]}")" = $'5432:5432\n13000:3000' ]; then test_pass "reverse wrapper parses direction-specific mappings"; else test_fail "reverse wrapper parses direction-specific mappings"; fi

assert_file_not_contains "$BASE_DIR/bin/dx-forward" 'DX_FORWARD_TEST_MODE' "forward has no production test seam"
assert_file_not_contains "$BASE_DIR/bin/dx-reverse" 'DX_REVERSE_TEST_MODE' "reverse has no production test seam"
assert_file_not_contains "$BASE_DIR/bin/dx-reclaim" 'df -h "\$@" | sed' "reclaim filesystem reporting does not require guest sed"
assert_file_contains_literal "$BASE_DIR/bin/dx-reclaim" 'export PATH="/nix/var/nix/profiles/per-user/root/profile/bin:$PATH"' "reclaim uses the GC-rooted essentials profile PATH"
if (
    # Sourcing dx-forward/dx-reverse above (for dx_tunnel_cli_collect,
    # bin/lib/dx-tunnel.sh -- WP8.3 step 5 merged the two entrypoints'
    # separate parse_all_forwards/parse_all_reverses helpers into this one
    # shared, direction-parameterized function) pulled in
    # bin/lib/dx-config.sh, which resolved and exported the real
    # DXE configuration snapshot into this shell: DXE_CONFIG_RESOLVED=1,
    # DXE_CONFIG_SNAPSHOT_VERSION, DX_PROJECT_ROOT, every DX_* field, and
    # every DXE_CONFIG_ORIGIN_* origin tag. dx_init_config honours an
    # inherited snapshot by design (that is what lets bin/dx-reclaim's own
    # exec of dx-lib.sh skip re-resolving), so without clearing it here,
    # dx-reclaim below would reuse the leaked snapshot -- built from the
    # developer's real $HOME -- instead of resolving fresh from the fixture
    # HOME set on its invocations, and this test would silently report the
    # real host's volumes instead of the fixture's. dx_config.sh also
    # refuses a *partial* snapshot (see the "partial snapshot fails closed"
    # case above), so every marker must go together: the two resolution
    # markers, DX_PROJECT_ROOT, and each field/origin pair.
    unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PROJECT_ROOT
    for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
    reclaim_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-reclaim.XXXXXX")"
    fake_bin="$reclaim_fixture/bin"
    guest_bin="$reclaim_fixture/guest-bin"
    mkdir -p "$fake_bin" "$guest_bin" "$reclaim_fixture/home"
    printf '%s\n' \
        '#!/bin/bash' \
        'case "${1:-}" in' \
        '  list) printf "%s\\n" dx-host ;;' \
        '  exec)' \
        '    shift' \
        '    if [ "${1:-}" = -u ]; then shift 2; fi' \
        '    shift' \
        '    shell="$1"; [ "$shell" = /usr/bin/bash ] || exit 91; shift 2' \
        '    script="$1"; shift' \
        '    case "$script" in nix-collect-garbage*) exit 0 ;; esac' \
        '    script="${script//\/nix\/var\/nix\/profiles\/per-user\/root\/profile\/bin/$RECLAIM_GUEST_PATH}"' \
        '    PATH="$RECLAIM_INHERITED_PATH" /bin/sh -c "$script" bash "$@"' \
        '    ;;' \
        '  *) exit 1 ;;' \
        'esac' > "$fake_bin/container"
    printf '%s\n' '#!/bin/sh' '[ "${RECLAIM_DF_FAIL:-}" = 1 ] && exit 37' 'printf "%s\\n" "Filesystem 1024-blocks Used Available Capacity Mounted on" "fake 100 20 80 20% /nix"' > "$guest_bin/df"
    printf '%s\n' '#!/bin/sh' 'printf "1.0M %s\\n" "$2"' > "$guest_bin/du"
    printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$*"' > "$guest_bin/fstrim"
    mkdir -p "$reclaim_fixture/no-profile"
    chmod +x "$fake_bin/container" "$guest_bin/df" "$guest_bin/du" "$guest_bin/fstrim"
    reclaim_output=""
    reclaim_status=0
    if reclaim_output="$(PATH="$fake_bin:/usr/bin:/bin" HOME="$reclaim_fixture/home" RECLAIM_GUEST_PATH="$guest_bin" RECLAIM_INHERITED_PATH="$reclaim_fixture/no-profile" DX_CONTAINER_NAME=dx-host "$BASE_DIR/bin/dx-reclaim" 2>&1)"; then
        reclaim_status=0
    else
        reclaim_status=$?
    fi
    df_failure_status=0
    if PATH="$fake_bin:/usr/bin:/bin" HOME="$reclaim_fixture/home" RECLAIM_GUEST_PATH="$guest_bin" RECLAIM_INHERITED_PATH="$reclaim_fixture/no-profile" RECLAIM_DF_FAIL=1 DX_CONTAINER_NAME=dx-host "$BASE_DIR/bin/dx-reclaim" >/dev/null 2>&1; then
        df_failure_status=0
    else
        df_failure_status=$?
    fi
    rm -rf "$reclaim_fixture"
    # printf ... | grep -q races the writer exactly as described in
    # stdin_matches's definition in test_helpers.sh: grep -q here can close
    # the pipe after its first match (the fixture df line appears twice, in
    # both the "Before" and "After" report_usage calls) while printf is
    # still writing the rest of $reclaim_output, so the writer takes
    # SIGPIPE and pipefail promotes that 141 to this whole check's status --
    # deterministically flipping an otherwise-passing assertion to fail.
    # stdin_matches drops -q so grep drains all of its input instead.
    [ "$reclaim_status" -eq 0 ] \
        && printf '%s\n' "$reclaim_output" | stdin_matches 'fake 100 20 80 20% /nix' \
        && [ "$df_failure_status" -eq 37 ] \
        && ! printf '%s\n' "$reclaim_output" | stdin_matches 'sed:.*not found'
); then
    test_pass "reclaim reports guest filesystems without a guest sed binary"
else
    test_fail "reclaim reports guest filesystems without a guest sed binary"
fi
assert_file_contains_literal "$BASE_DIR/bin/dx-wait-ssh" 'print_container_logs 5' "bootstrap progress shows several recent guest log lines"
assert_file_contains_literal "$BASE_DIR/bin/dx-wait-ssh" 'approximately' "bootstrap wait budget is rendered in human-readable minutes"

# --- dx-wait-ssh readiness probe under host contention ---
#
# The readiness probe is the one SSH client in the repo that used to invent its
# own connect budget: a hardcoded ConnectTimeout=2, against the configured
# DX_SSH_CONNECT_TIMEOUT (default 15) that dx-ssh-common.sh and dx-tunnel.sh
# both honour. OpenSSH's ConnectTimeout covers the banner exchange, not just
# the TCP connect, so on a loaded host sshd answers the TCP connect and then
# takes longer than 2s to send its banner. Every probe then dies with
# "Connection timed out during banner exchange" (guest side: "Broken pipe
# [preauth]"), and because the probe can never succeed, dx prints dots for its
# full ~91-minute budget while sshd is healthy and accepting logins throughout.
# Observed live 2026-09-07: host load average 55 on 10 cores, a real login took
# 92s, and the 2s probe failed 100% of the time.
if diag="$(
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    fake_tool_write "$fake_dir" container 'exit 0'
    fake_tool_write "$fake_dir" ssh 'for a in "$@"; do printf "%s\n" "$a"; done >> "$DX_FAKE_SSH_ARGV"; exit 0'
    export PATH="$fake_dir:$PATH"
    export DX_FAKE_SSH_ARGV="$fake_dir/argv"
    : > "$DX_FAKE_SSH_ARGV"
    : > "$fake_dir/ssh-key"
    out="$(DX_SSH_KEY="$fake_dir/ssh-key" DX_SSH_CONNECT_TIMEOUT=17 "$BASE_DIR/bin/dx-wait-ssh" 2>&1)"
    rc=$?
    argv="$(cat "$DX_FAKE_SSH_ARGV")"
    rm -rf "$fake_dir"
    printf 'rc=%s argv=[%s] out=%s' "$rc" "$(printf '%s' "$argv" | tr '\n' ' ')" "$out"
    [ "$rc" -eq 0 ] && printf '%s\n' "$argv" | grep -F -x -q 'ConnectTimeout=17'
)"; then
    test_pass "the readiness probe honours the configured DX_SSH_CONNECT_TIMEOUT"
else
    test_fail "the readiness probe honours the configured DX_SSH_CONNECT_TIMEOUT ($diag)"
fi

# A probe that never gets a banner is a *different* failure from one that is
# refused outright: the first means sshd is alive but something is starved.
# Timing out with nothing but dots and the tail of the guest log -- which shows
# healthy sshd activity -- is what made the live incident take an hour to
# recognise. Two faults produce it (a loaded host, and a guest wedged on its own
# vCPUs while the host is idle) and they have opposite remedies, so the report
# must name the banner-exchange failure and print the load average that tells
# them apart.
if diag="$(
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    fake_tool_write "$fake_dir" container 'case "${1:-}" in list) printf "%s\n" dx-host ;; esac; exit 0'
    fake_tool_write "$fake_dir" ssh 'echo "ssh: connect to host 127.0.0.1 port 2222: Connection timed out during banner exchange" >&2; exit 255'
    export PATH="$fake_dir:$PATH"
    : > "$fake_dir/ssh-key"
    out="$(DX_SSH_KEY="$fake_dir/ssh-key" DX_SSH_WAIT_TIMEOUT=2 DX_SSH_POLL_INTERVAL=1 DX_SSH_PROGRESS_INTERVAL=1 "$BASE_DIR/bin/dx-wait-ssh" 2>&1)"
    rc=$?
    rm -rf "$fake_dir"
    printf 'rc=%s out=%s' "$rc" "$out"
    [ "$rc" -ne 0 ] && printf '%s\n' "$out" | stdin_matches 'banner exchange' && printf '%s\n' "$out" | stdin_matches 'load'
)"; then
    test_pass "a probe that never completes the banner exchange is named as such, with the load average that discriminates the two causes"
else
    test_fail "a probe that never completes the banner exchange is named as such, with the load average that discriminates the two causes ($diag)"
fi
# Branch 11 / Phase 2: dx-create-container now calls dx_runtime_container_create
# with a runtime-neutral vocabulary (qnap-dxe-plan.md DQ2) instead of a raw
# Apple-flavoured argv; the bootstrap path still crosses as the entrypoint's
# own positional argument (--entrypoint-arg), never reinterpreted as one of
# create's own options -- each adapter renders its own "-- ARGS" shape from
# this same value (proven end to end in
# tests/test_runtime_boundary_characterisation.sh).
assert_file_contains_literal "$BASE_DIR/bin/dx-create-container" '--entrypoint-arg "$DX_BOOTSTRAP_PATH"' "bootstrap path crosses the launcher boundary positionally"

# --- P10: DX_NIX_DISK_SIZE reaches the guest via dx-create-container (plan.md) ---
#
# dx-create-container already forwards DX_GUEST_ACTIVATION_TIMEOUT and its
# siblings into the guest with -e "VAR=$VAR" in CREATE_FLAGS; DX_NIX_DISK_SIZE
# is the same shape of config-registry variable but was never added to that
# list, so an explicitly configured disk size could never reach the guest
# bootstrap's `truncate`. Drive the real script end to end with a fake
# `container` on PATH and read back the actual `container create` invocation,
# rather than grepping the script text for the variable's name.
if diag="$(
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    fake_tool_write "$fake_dir" container 'case "$1" in
    list) exit 0 ;;
    image)
        [ "${2:-}" = list ] && printf "%s\n" "$DX_IMAGE"
        [ "${2:-}" = inspect ] && printf "%s\n" "[{\"id\" : \"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\"}]"
        exit 0
        ;;
    create) printf "%s\n" "$@" >> "$DX_FAKE_CREATE_ARGV"; exit 0 ;;
    *) exit 0 ;;
esac'
    export PATH="$fake_dir:$PATH"
    export DX_FAKE_CREATE_ARGV="$fake_dir/create-argv.log"
    explicit_home="$fake_dir/home-explicit"; mkdir -p "$explicit_home"
    : > "$DX_FAKE_CREATE_ARGV"
    HOME="$explicit_home" DX_CONTAINER_NAME=dxe-p10-explicit DX_NIX_DISK_SIZE=200G "$BASE_DIR/bin/dx-create-container" >/dev/null 2>&1
    explicit_argv="$(cat "$DX_FAKE_CREATE_ARGV")"
    default_home="$fake_dir/home-default"; mkdir -p "$default_home"
    : > "$DX_FAKE_CREATE_ARGV"
    HOME="$default_home" DX_CONTAINER_NAME=dxe-p10-default "$BASE_DIR/bin/dx-create-container" >/dev/null 2>&1
    default_argv="$(cat "$DX_FAKE_CREATE_ARGV")"
    rm -rf "$fake_dir"
    printf 'explicit=[%s] default=[%s]' "$(printf '%s' "$explicit_argv" | tr '\n' ' ')" "$(printf '%s' "$default_argv" | tr '\n' ' ')"
    printf '%s\n' "$explicit_argv" | stdin_matches -F -- 'DX_NIX_DISK_SIZE=200G' \
        && printf '%s\n' "$default_argv" | stdin_matches -F -- 'DX_NIX_DISK_SIZE=64G'
)"; then
    test_pass "dx-create-container forwards DX_NIX_DISK_SIZE into the guest, defaulting to 64G"
else
    test_fail "dx-create-container forwards DX_NIX_DISK_SIZE into the guest, defaulting to 64G ($diag)"
fi
assert_file_contains_literal "$BASE_DIR/bin/dx-migrate-persist" "-- \"\$legacy_volume\" \"\$sentinel\"" "migration values cross fixed command boundaries positionally"

# --- dx-herdr contracts ---
# These are the host-contract (argument grammar / help) assertions for
# dx-herdr; Section 23 (test_section23_herdr.sh) owns Herdr-specific behaviour
# (fake-boundary probes, TOML seeding, live checks) so this coverage is not
# duplicated there. Neither of these calls needs `export PATH` or other
# process-global isolation, so they assert directly rather than inside a
# subshell (test_pass/test_fail increment counters local to the calling
# shell, and would be silently lost if this ran inside `( … )`).
out="$("$BASE_DIR/bin/dx-herdr" --help 2>&1)"
if echo "$out" | stdin_matches "Usage: dx-herdr"; then test_pass "dx-herdr --help prints usage"; else test_fail "dx-herdr --help prints usage"; fi
out="$("$BASE_DIR/bin/dx-herdr" -h 2>&1)"
if echo "$out" | stdin_matches "Usage: dx-herdr"; then test_pass "dx-herdr -h prints usage"; else test_fail "dx-herdr -h prints usage"; fi
set +e
out="$("$BASE_DIR/bin/dx-herdr" invalid_arg 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 64 ] && echo "$out" | stdin_matches "does not accept arguments"; then
    test_pass "dx-herdr rejects arguments in v1 (exit 64)"
else
    test_fail "dx-herdr rejects arguments in v1 (exit 64, got rc=$rc)"
fi
set +e
out="$("$BASE_DIR/bin/dx-herdr" --help trailing 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 64 ] && echo "$out" | stdin_matches "does not accept arguments"; then
    test_pass "dx-herdr rejects trailing arguments after --help (R6)"
else
    test_fail "dx-herdr rejects trailing arguments after --help (R6, got rc=$rc)"
fi

# --- dx-ssh-common.sh shared SSH boundary contracts (F3/F10/F12) ---
#
# These assertions cross a process boundary (a fake `ssh` on PATH, or a fresh
# subshell sourcing the library to override a function) so they follow the
# same idiom as Section 23: the subshell's last statement is the boolean
# being tested, and its exit status is what the parent branches on to call
# the real test_pass/test_fail.

# F3: exec discarded both the library's own EXIT trap and the top-level OSC
# trap bin/dx-ssh installs, so plain interactive `dx-ssh` lost its Apple
# Terminal colour restore, and dropping the `quiet` parameter's silencing of
# the library's own message reintroduced a duplicate "Connecting..." banner.
# Verify both are fixed together: the fake ssh below never emits any part of
# the OSC sequence itself, so its presence in the combined output can only
# come from dx-ssh-common.sh's own cleanup running after the "remote" session
# ends -- proving exec was removed and the trap actually fires.
if diag="$(
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    fake_ssh_write "$fake_dir" 'echo "REMOTE_SESSION_RAN"; exit 0'
    export PATH="$fake_dir:$PATH"
    osc=$'\033]110\033\\\033]111\033\\\033]104\033\\'

    # dx_key is gitignored, so the repo never ships one: depending on the
    # default key path passes only on a checkout where dx-create-keys has run,
    # and fails on a fresh clone, in CI, and in any git worktree. ssh is faked
    # here, so the guard only needs a file to exist.
    : > "$fake_dir/ssh-key"
    out="$(DX_SSH_KEY="$fake_dir/ssh-key" TERM_PROGRAM=Apple_Terminal "$BASE_DIR/bin/dx-ssh" 2>&1)"
    rc=$?
    rm -rf "$fake_dir"
    connects="$(printf '%s\n' "$out" | grep -c "Connecting to DX guest via SSH")"
    printf 'rc=%s connects=%s out=%s' "$rc" "$connects" "$out"
    # NOTE: a case/esac statement here (rather than [[ ... ]]) makes /bin/bash
    # 3.2 misparse this whole subshell -- its case-pattern `)` gets confused
    # with the closing `)"` of the enclosing "$( ... )", corrupting the
    # command substitution itself (reproduced directly against 3.2.57; not a
    # behavior of the code under test). [[ == glob ]] has no bare parens, so
    # it does not trip the same parser bug.
    [ "$rc" -eq 0 ] && [ "$connects" -eq 1 ] && [[ "$out" == *"REMOTE_SESSION_RAN"*"$osc"* ]]
)"; then
    test_pass "interactive dx-ssh prints the connect banner once and restores Apple Terminal colours after the session ends (F3)"
else
    test_fail "interactive dx-ssh prints the connect banner once and restores Apple Terminal colours after the session ends (F3) ($diag)"
fi

# F3: the function must stop claiming to exec, and no exec-into-ssh may
# remain anywhere in the shared library.
assert_file_not_contains "$BASE_DIR/bin/lib/dx-ssh-common.sh" 'exec ssh' "dx-ssh-common.sh no longer execs into ssh, which used to discard the cleanup trap (F3)"
if grep -q 'dx_run_interactive_ssh' "$BASE_DIR/bin/lib/dx-ssh-common.sh" && ! grep -q 'dx_exec_interactive_ssh' "$BASE_DIR/bin/lib/dx-ssh-common.sh"; then
    test_pass "the interactive SSH helper is renamed to stop claiming to exec (F3)"
else
    test_fail "the interactive SSH helper is renamed to stop claiming to exec (F3)"
fi

# F3: no caller ever passed quiet=true, so the dead parameter is deleted
# rather than kept dark.
assert_file_not_contains "$BASE_DIR/bin/lib/dx-ssh-common.sh" 'quiet' "the interactive SSH helper has no dead quiet parameter (F3)"

# F3: dx_get_host_timezone was looked up once at the top of dx-ssh and again
# inside the library for every interactive run. Source the library directly
# (in-process, so the override below actually takes effect) and count calls
# made by a single dx_run_interactive_ssh invocation.
if (
    source "$BASE_DIR/bin/lib/dx-host-util.sh"
    source "$BASE_DIR/bin/lib/dx-ssh-common.sh"
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    fake_ssh_write "$fake_dir" 'exit 0'
    export PATH="$fake_dir:$PATH"
    counter="$fake_dir/tz-calls"
    : > "$counter"
    dx_get_host_timezone() { printf 'x' >> "$counter"; printf '%s\n' UTC; }
    # A fixture key, not the developer's: see the note above.
    : > "$fake_dir/ssh-key"
    DX_SSH_KEY="$fake_dir/ssh-key" DX_SSH_PORT=2222 DX_SSH_CONNECT_TIMEOUT=1 dx_run_interactive_ssh "true" >/dev/null 2>&1
    calls="$(wc -c < "$counter" | tr -d ' ')"
    rm -rf "$fake_dir"
    [ "$calls" -eq 1 ]
); then
    test_pass "dx_run_interactive_ssh looks up the host timezone exactly once per call (F3)"
else
    test_fail "dx_run_interactive_ssh looks up the host timezone exactly once per call (F3)"
fi

# F10: the SSH options, guest PATH, SSL env, and workdir snippet must each
# have exactly one source of truth -- dx-ssh-common.sh -- rather than being
# hand-duplicated as literals in bin/dx-ssh and bin/dx-herdr.
files_containing() {
    local pattern="$1" count=0 f
    shift
    for f in "$@"; do
        grep -qF -- "$pattern" "$f" 2>/dev/null && count=$((count + 1))
    done
    printf '%s' "$count"
}
ssh_boundary_files=("$BASE_DIR/bin/dx-ssh" "$BASE_DIR/bin/dx-herdr" "$BASE_DIR/bin/lib/dx-ssh-common.sh")
for literal in 'IdentitiesOnly=yes' '.nix-profile/bin:/home/dx/.local/bin' 'NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt' "printf '%q'"; do
    n="$(files_containing "$literal" "${ssh_boundary_files[@]}")"
    if [ "$n" -eq 1 ]; then
        test_pass "SSH boundary literal '$literal' has a single source of truth (F10)"
    else
        test_fail "SSH boundary literal '$literal' has a single source of truth (F10), found in $n of 3 files"
    fi
done
assert_file_contains "$BASE_DIR/bin/dx-ssh" 'dx_ssh_common_options' "dx-ssh's argument branch reuses the shared SSH option source of truth (F10)"

# R4: a workdir comes from a mounted repository path, so apostrophes, spaces,
# leading dashes, and newlines are valid inputs. It must not be interpolated
# into the single-quoted remote bash program.
if (
    source "$BASE_DIR/bin/lib/dx-host-util.sh"
    source "$BASE_DIR/bin/lib/dx-ssh-common.sh"
    DX_GUEST_WORKDIR=$'/tmp/-dxe workdir with an apostrophe \' and\na newline'
    remote_cmd="$(dx_guest_bash_command UTC true)"
    printf '%s\n' "$remote_cmd" | bash -n \
        && printf '%s\n' "$remote_cmd" | stdin_matches 'DX_GUEST_WORKDIR_B64=' \
        && ! printf '%s\n' "$remote_cmd" | stdin_matches -F "$DX_GUEST_WORKDIR"
); then
    test_pass "shared SSH boundary transports complex workdirs without nested-quote breakage (R4)"
else
    test_fail "shared SSH boundary transports complex workdirs without nested-quote breakage (R4)"
fi

# R4, the other half of the same boundary: the *command body* is subject to
# exactly the defect R4 fixed for the workdir. It used to be interpolated
# straight into the single-quoted `bash -l -c '...'` program, so a body
# containing an apostrophe closed that quote and produced a syntax error on
# the guest instead of running. Every caller today passes an apostrophe-free
# literal, which is precisely why this stayed invisible; the contract is that
# the transport is opaque to the body's bytes, not that callers stay lucky.
if (
    source "$BASE_DIR/bin/lib/dx-host-util.sh"
    source "$BASE_DIR/bin/lib/dx-ssh-common.sh"
    DX_GUEST_WORKDIR=""
    body=$'echo it\'s fine && printf %s \'--\''
    remote_cmd="$(dx_guest_bash_command UTC "$body")"
    encoded="$(printf '%s\n' "$remote_cmd" | sed -n 's/.*DX_GUEST_CMD_B64=\([A-Za-z0-9+/=]*\).*/\1/p')"
    printf '%s\n' "$remote_cmd" | bash -n \
        && [ -n "$encoded" ] \
        && ! printf '%s\n' "$remote_cmd" | stdin_matches -F "it's fine" \
        && [ "$(printf '%s' "$encoded" | base64 -d)" = "$body" ]
); then
    test_pass "shared SSH boundary transports a command body opaquely, apostrophes included (R4)"
else
    test_fail "shared SSH boundary transports a command body opaquely, apostrophes included (R4)"
fi

# --- Branch 11 / Phase 5 (qnap-dxe-plan.md DQ5): every entry point built on
# this shared boundary dials dx_ssh_endpoint's resolved address. dx-ssh and
# dx-herdr need no code change of their own (they already call
# dx_ssh_run_guest_command/dx_run_interactive_ssh/dx_ssh_common_options
# exclusively, per F10 above), so this proves the underlying shared
# functions dial the correct destination directly, under both runtimes,
# rather than through each entrypoint script separately. The fake ssh below
# distinguishes the ONE call whose remote script is the Tailscale-address
# discovery snippet (evaluated for real, so a real "tailscale"/"head"
# resolve the planted address) from every other call (the actual guest
# dial, logged but never evaluated -- evaluating a real "bash -l -c" locally
# would source this host's own shell profile, which is not what this test
# is about) --------------------------------------------------------------
#
# This block drives dx_ssh_run_guest_command -> dx_ssh_common_options ->
# dx_ssh_known_hosts_prepare under DX_RUNTIME=docker-ssh, which creates a
# pin directory under "${XDG_STATE_HOME:-$HOME/.local/state}/dxe" -- so the
# inner fixture subshell gets its OWN HOME (never the real one) before it
# gets anywhere near that call, and the snapshot below (taken in THIS
# outer, unisolated shell) proves nothing landed under the real directory
# regardless.
endpoint_proof_real_state_before="$(dx_real_ssh_known_hosts_snapshot)"
(
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    fake_tool_write "$fake_dir" tailscale 'case "$*" in "ip -4") printf "%s.%s.%s.%s\n" 100 64 4 4 ;; *) exit 99 ;; esac'
    fake_tool_write "$fake_dir" ssh "
for a in \"\$@\"; do printf '%s\n' \"\$a\" >> '$fake_dir/argv'; done
printf '\f\n' >> '$fake_dir/argv'
dx_fake_last=\"\"
for dx_fake_arg in \"\$@\"; do dx_fake_last=\"\$dx_fake_arg\"; done
case \"\$dx_fake_last\" in
    *DXE_TAILSCALE_BIN*) eval \"\$dx_fake_last\" ;;
    *) exit 0 ;;
esac
"
    : > "$fake_dir/argv"
    : > "$fake_dir/ssh-key"
    (
        source "$BASE_DIR/bin/lib/dx-config.sh"
        source "$BASE_DIR/bin/lib/dx-host-util.sh"
        source "$BASE_DIR/bin/lib/dx-runtime.sh"
        source "$BASE_DIR/bin/lib/dx-ssh-common.sh"
        export PATH="$fake_dir:$PATH"
        endpoint_proof_home="$(mktemp -d "${TMPDIR:-/tmp}/dxe-endpoint-proof-home.XXXXXX")"
        export HOME="$endpoint_proof_home"
        unset XDG_STATE_HOME
        DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dxe-fixture-endpoint-proof
        # shellcheck disable=SC2034
        # Read by dx_ssh_common_options (bin/lib/dx-ssh-common.sh), a
        # function in a separately sourced file ShellCheck cannot trace
        # into -- these are genuinely consumed, dynamically, by the call
        # below (via dx_ssh_run_guest_command).
        DX_SSH_KEY="$fake_dir/ssh-key" DX_SSH_PORT=2222 DX_SSH_CONNECT_TIMEOUT=15
        # shellcheck disable=SC2034
        # Read by dx_runtime_docker_host_identity (bin/lib/dx-runtime-docker.sh)
        # to skip a real ssh round trip -- genuinely consumed, dynamically.
        DXE_RUNTIME_DOCKER_DAEMON_ID=fixturedaemonid
        unset DXE_RUNTIME_GUEST_SSH_ADDRESS
        dx_ssh_run_guest_command "true" >/dev/null 2>&1
    )
    grep -qx "dx@$(printf '%s.%s.%s.%s' 100 64 4 4)" "$fake_dir/argv"
)
endpoint_proof_rc=$?
endpoint_proof_real_state_after="$(dx_real_ssh_known_hosts_snapshot)"
if [ "$endpoint_proof_rc" -eq 0 ] && [ "$endpoint_proof_real_state_before" = "$endpoint_proof_real_state_after" ]; then
    test_pass "dx_ssh_run_guest_command (docker-ssh) dials dx@<discovered Tailscale address>, never dx@127.0.0.1, and never writes under the real SSH known-hosts state directory"
else
    test_fail "dx_ssh_run_guest_command (docker-ssh) dials dx@<discovered Tailscale address>, never dx@127.0.0.1, and never writes under the real SSH known-hosts state directory"
fi

# Regression guard (found by the coordinating session's Linux gates,
# 2026-09-28): dx_real_ssh_known_hosts_snapshot itself must never abort
# when the real state directory doesn't exist yet -- the normal state on a
# fresh runner/container/CI, before anything has ever pinned a known-hosts
# file there. `find` on an absent path exits 1; a naive snapshot function
# propagates that as the "$(...)" assignment's exit status, which this
# file's own `set -euo pipefail` (line 2) then turns into an abort right
# after the endpoint-proof block above -- exactly what broke this file's
# own unit-test run on a fresh Linux runner before the fix. Run inside a
# subshell so a regression here aborts only the subshell (reported as a
# normal test_fail), never this whole file the same way again.
(
    absent_state_home="$(mktemp -d "${TMPDIR:-/tmp}/dxe-known-hosts-absent-guard.XXXXXX")/does-not-exist"
    XDG_STATE_HOME="$absent_state_home"
    export XDG_STATE_HOME
    out="$(dx_real_ssh_known_hosts_snapshot)"
    [ -z "$out" ]
)
if [ "$?" -eq 0 ]; then
    test_pass "dx_real_ssh_known_hosts_snapshot returns 0 and prints nothing when the real state directory does not exist"
else
    test_fail "dx_real_ssh_known_hosts_snapshot returns 0 and prints nothing when the real state directory does not exist"
fi

# --- SIGPIPE contract: a match must survive `set -o pipefail` ---
#
# `writer | grep -q PATTERN` reports a *successful* match as a failure under
# pipefail: grep -q exits at the first match, the writer dies of SIGPIPE (141),
# and pipefail promotes that to the pipeline's status. It is a race, so it
# passed for months and then began failing deterministically after an unrelated
# environment change, taking 16 assertions across four sections with it.
#
# Asserting that the *broken* form fails would itself be environment-dependent,
# so this pins the property that matters: the helper returns 0 for a match whose
# input is large enough to have triggered the bug. The input is generated rather
# than fixed so the writer is still writing when a short-circuiting reader would
# already have exited. Verified against both BSD grep and GNU grep 3.11 -- GNU
# grep optimises `>/dev/null` output, so this is not a given on either.
if seq 1 200000 | sed '1s/^/MATCH/' | stdin_matches MATCH; then
    test_pass "a successful match survives pipefail on a long-running writer"
else
    test_fail "a successful match survives pipefail on a long-running writer"
fi

# --- Bootstrap generation drift (dx-start-plan.md) ---
#
# dx-start-container must start the container before it can sync, because the
# payload crosses `container exec`, which needs a running container. The guest's
# launcher proceeds the moment a `current` pointer exists, so a start that
# follows a bootstrap edit boots the *previous* generation and nothing says so.
# These cover the reporting half: the guest's running generation is read from
# the launcher's execution lease, and a mismatch against the published pointer
# is announced rather than left silent.
if [ "$(dx_bootstrap_lease_generation '20260815T044707Z-70118.1')" = 20260815T044707Z-70118 ]; then
    test_pass "running generation is read from the launcher's PID 1 lease"
else
    test_fail "running generation is read from the launcher's PID 1 lease"
fi
# Only PID 1's lease names the running code: it is the container entrypoint and
# execs that generation's bootstrap.sh. Other PIDs' leases must not be mistaken
# for it, whichever order the listing arrives in.
if [ "$(dx_bootstrap_lease_generation 'gen-a.4242
gen-b.1
gen-c.99')" = gen-b ]; then
    test_pass "a non-launcher lease is never mistaken for the running generation"
else
    test_fail "a non-launcher lease is never mistaken for the running generation"
fi
if dx_bootstrap_lease_generation 'gen-a.4242' >/dev/null 2>&1; then
    test_fail "an absent launcher lease reports no running generation"
else
    test_pass "an absent launcher lease reports no running generation"
fi
drift_out="$(dx_bootstrap_report_drift old-gen new-gen dx-probe 2>&1 >/dev/null || true)"
if printf '%s\n' "$drift_out" | stdin_matches -F old-gen \
    && printf '%s\n' "$drift_out" | stdin_matches -F new-gen \
    && printf '%s\n' "$drift_out" | stdin_matches -F dx-probe; then
    test_pass "a drifted guest is reported with both generations and the container"
else
    test_fail "a drifted guest is reported with both generations and the container (got '$drift_out')"
fi
# Silence is the contract for the ordinary case: an unchanged tree republishes
# an identical generation id only when nothing was edited, and a guest that has
# never been synced has no lease at all. Neither is a drift.
for pair in 'same-gen same-gen' ' new-gen' 'old-gen '; do
    set -- $pair
    quiet_out="$(dx_bootstrap_report_drift "${1:-}" "${2:-}" dx-probe 2>&1 >/dev/null || true)"
    if [ -z "$quiet_out" ]; then
        test_pass "no drift warning for '$pair'"
    else
        test_fail "no drift warning for '$pair' (got '$quiet_out')"
    fi
done

# --- D7 option 3 successor (WP5.1 / Fable A2): dx-start-container must tell a
# real publish from the unchanged-content skip from a structured result file
# dx-sync-bootstrap writes for it, not by pattern-matching its own prose on
# captured stdout -- that coupling broke the instant the prose was reworded,
# independent of what the sync actually did (docs/refactor/decisions/
# D7-start-generation.md; the fixture-driven Red case lives in section 22).
bootstrap_result_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-bootstrap-result.XXXXXX")"

result_roundtrip_file="$bootstrap_result_fixture/published"
outcome="" generation=""
if dx_bootstrap_sync_result_write "$result_roundtrip_file" published 20260926T045923Z-7438 \
    && dx_bootstrap_sync_result_read "$result_roundtrip_file" \
    && [ "$outcome" = published ] && [ "$generation" = 20260926T045923Z-7438 ]; then
    test_pass "a published outcome round-trips through write and read"
else
    test_fail "a published outcome round-trips through write and read (outcome='${outcome:-}', generation='${generation:-}')"
fi

result_roundtrip_file2="$bootstrap_result_fixture/unchanged"
outcome="" generation=""
if dx_bootstrap_sync_result_write "$result_roundtrip_file2" unchanged 20260815T044707Z-70118 \
    && dx_bootstrap_sync_result_read "$result_roundtrip_file2" \
    && [ "$outcome" = unchanged ] && [ "$generation" = 20260815T044707Z-70118 ]; then
    test_pass "an unchanged outcome round-trips through write and read"
else
    test_fail "an unchanged outcome round-trips through write and read (outcome='${outcome:-}', generation='${generation:-}')"
fi

# A second write to the same path replaces its content rather than appending
# to it (tmp + mv -f), which is the whole point of writing through a temp file.
outcome="" generation=""
if dx_bootstrap_sync_result_write "$result_roundtrip_file" unchanged replacement-generation \
    && dx_bootstrap_sync_result_read "$result_roundtrip_file" \
    && [ "$outcome" = unchanged ] && [ "$generation" = replacement-generation ] \
    && [ "$(wc -l < "$result_roundtrip_file" | tr -d ' ')" = 2 ]; then
    test_pass "a second write replaces the result file's content rather than appending to it"
else
    test_fail "a second write replaces the result file's content rather than appending to it"
fi

if dx_bootstrap_sync_result_write "$bootstrap_result_fixture/rejected" bogus-outcome some-gen; then
    test_fail "the writer refuses an outcome that is neither published nor unchanged"
else
    test_pass "the writer refuses an outcome that is neither published nor unchanged"
fi
if dx_bootstrap_sync_result_write "$bootstrap_result_fixture/rejected" published '../escape'; then
    test_fail "the writer refuses an unsafe generation id"
else
    test_pass "the writer refuses an unsafe generation id"
fi

if dx_bootstrap_sync_result_read "$bootstrap_result_fixture/does-not-exist" >/dev/null 2>&1; then
    test_fail "the reader refuses a missing result file"
else
    test_pass "the reader refuses a missing result file"
fi

ln -s published "$bootstrap_result_fixture/symlink"
if dx_bootstrap_sync_result_read "$bootstrap_result_fixture/symlink" >/dev/null 2>&1; then
    test_fail "the reader refuses a symlinked result file"
else
    test_pass "the reader refuses a symlinked result file"
fi

printf 'outcome=published\n' > "$bootstrap_result_fixture/truncated"
if dx_bootstrap_sync_result_read "$bootstrap_result_fixture/truncated" >/dev/null 2>&1; then
    test_fail "the reader refuses a result file truncated to one line"
else
    test_pass "the reader refuses a result file truncated to one line"
fi

printf 'outcome=published\ngeneration=gen-a\nextra-trailing-line\n' > "$bootstrap_result_fixture/toolong"
if dx_bootstrap_sync_result_read "$bootstrap_result_fixture/toolong" >/dev/null 2>&1; then
    test_fail "the reader refuses a result file with a trailing third line"
else
    test_pass "the reader refuses a result file with a trailing third line"
fi

printf 'outcome=bogus\ngeneration=gen-a\n' > "$bootstrap_result_fixture/badoutcome"
if dx_bootstrap_sync_result_read "$bootstrap_result_fixture/badoutcome" >/dev/null 2>&1; then
    test_fail "the reader refuses an outcome that is neither published nor unchanged"
else
    test_pass "the reader refuses an outcome that is neither published nor unchanged"
fi

printf 'outcome=published\nnot-a-generation-line\n' > "$bootstrap_result_fixture/badgenline"
if dx_bootstrap_sync_result_read "$bootstrap_result_fixture/badgenline" >/dev/null 2>&1; then
    test_fail "the reader refuses a second line without a generation= prefix"
else
    test_pass "the reader refuses a second line without a generation= prefix"
fi

printf 'outcome=published\ngeneration=../escape\n' > "$bootstrap_result_fixture/badgen"
if dx_bootstrap_sync_result_read "$bootstrap_result_fixture/badgen" >/dev/null 2>&1; then
    test_fail "the reader refuses an unsafe generation id"
else
    test_pass "the reader refuses an unsafe generation id"
fi

rm -rf "$bootstrap_result_fixture"

# F12: cleanup_osc used to be defined without a dx_ namespace, leaking into
# the caller's global namespace; and export TERM had no effect since the
# remote env prefix hardcodes TERM=xterm-256color.
if grep -qE '(^|[^a-zA-Z0-9_])cleanup_osc\(\)' "$BASE_DIR/bin/lib/dx-ssh-common.sh"; then
    test_fail "the OSC cleanup helper is dx_-namespaced rather than leaking a bare global (F12)"
else
    test_pass "the OSC cleanup helper is dx_-namespaced rather than leaking a bare global (F12)"
fi
assert_file_contains "$BASE_DIR/bin/lib/dx-ssh-common.sh" 'dx_ssh_cleanup_osc' "the OSC cleanup helper exists under the dx_ namespace (F12)"
assert_file_not_contains "$BASE_DIR/bin/lib/dx-ssh-common.sh" 'export TERM' "the shared SSH boundary no longer mutates the caller's TERM to no effect (F12)"

# The bootstrap payload digest decides whether a sync has anything to publish.
# It must be stable across runs, and must notice a content change *and* a
# rename -- a rename that hashed the same would leave the guest running code
# that no longer exists under that name.
digest_root="$config_fixture/digest"
mkdir -p "$digest_root/tree/sub"
printf 'one\n' > "$digest_root/tree/a.sh"
printf 'two\n' > "$digest_root/tree/sub/b.nix"
first="$(dx_bootstrap_content_digest "$digest_root/tree")"
second="$(dx_bootstrap_content_digest "$digest_root/tree")"
if [ -n "$first" ] && [ "$first" = "$second" ]; then
    test_pass "bootstrap content digest is stable across runs"
else
    test_fail "bootstrap content digest is stable across runs ($first vs $second)"
fi

printf 'changed\n' > "$digest_root/tree/sub/b.nix"
if [ "$(dx_bootstrap_content_digest "$digest_root/tree")" != "$first" ]; then
    test_pass "bootstrap content digest changes when a file's contents change"
else
    test_fail "bootstrap content digest changes when a file's contents change"
fi

printf 'two\n' > "$digest_root/tree/sub/b.nix"
mv "$digest_root/tree/a.sh" "$digest_root/tree/renamed.sh"
if [ "$(dx_bootstrap_content_digest "$digest_root/tree")" != "$first" ]; then
    test_pass "bootstrap content digest changes when a file is renamed"
else
    test_fail "bootstrap content digest changes when a file is renamed"
fi

# Modes are deliberately not content: the guest re-derives them by name when it
# publishes, so a mode difference must not force a pointless republication.
mv "$digest_root/tree/renamed.sh" "$digest_root/tree/a.sh"
chmod 0700 "$digest_root/tree/a.sh"
if [ "$(dx_bootstrap_content_digest "$digest_root/tree")" = "$first" ]; then
    test_pass "bootstrap content digest ignores file modes"
else
    test_fail "bootstrap content digest ignores file modes"
fi

if ! dx_bootstrap_content_digest "$digest_root/tree/a.sh" >/dev/null 2>&1; then
    test_pass "bootstrap content digest rejects a non-directory source"
else
    test_fail "bootstrap content digest rejects a non-directory source"
fi

# --- dx-status: the booted bootstrap generation must be observable from the
# host (requirement 4 of dx-start-plan.md), including after the guest has
# died -- exactly the case `container exec` cannot reach and `container logs`
# can. Drive the real dx-status with a fake `container` on PATH; this doubles
# as the fixture for the drift warning dx-start-container already prints, now
# surfaced without waiting for the next start.
#
# The fake answers every subcommand dx-status's existing sections already
# issue (image list, list -a/--quiet, logs, guest-environment exec) as well as
# the two new bootstrap-generation ones (exec readlink, exec sh -c ... --
# leases), so a scenario can drive only the DX_FAKE_* variables it cares about
# without dx-status's earlier sections aborting the run under `set -e`.
status_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-status-bootstrap.XXXXXX")"
fake_tool_write "$status_fixture/bin" container '
case "$1" in
    list)
        shift
        all=false
        quiet=false
        for a in "$@"; do
            [ "$a" = "-a" ] && all=true
            [ "$a" = "--quiet" ] && quiet=true
        done
        present=false
        if [ "$all" = true ]; then
            [ "${DX_FAKE_EXISTS:-1}" = 1 ] && present=true
        else
            [ "${DX_FAKE_RUNNING:-1}" = 1 ] && present=true
        fi
        if [ "$present" = true ]; then
            if [ "$quiet" = true ]; then
                printf "%s\n" "$DX_CONTAINER_NAME"
            else
                printf "%s\tfake-image\tlinux\tarm64\tfake-state\n" "$DX_CONTAINER_NAME"
            fi
        fi
        exit 0
        ;;
    image)
        if [ "${2:-}" = list ]; then
            quiet=false
            for a in "$@"; do [ "$a" = "--quiet" ] && quiet=true; done
            if [ "$quiet" = true ]; then
                printf "%s\n" "$DX_IMAGE"
            else
                printf "%s\tlatest\tfakeid\n" "$DX_IMAGE"
            fi
        fi
        exit 0
        ;;
    logs)
        shift
        lines=""
        if [ "${1:-}" = "-n" ]; then lines="$2"; shift 2; fi
        if [ -n "$lines" ]; then
            tail -n "$lines" "${DX_FAKE_LOG_FILE:-/dev/null}" 2>/dev/null
        else
            cat "${DX_FAKE_LOG_FILE:-/dev/null}" 2>/dev/null
        fi
        exit 0
        ;;
    exec)
        shift
        [ "${1:-}" = "-u" ] && shift 2
        shift
        case "${1:-}" in
            readlink)
                if [ -n "${DX_FAKE_CURRENT:-}" ]; then printf "%s\n" "$DX_FAKE_CURRENT"; exit 0; fi
                exit 1
                ;;
            sh)
                printf "%s" "${DX_FAKE_LEASES:-}"
                exit 0
                ;;
            bash)
                # Item 4 (fix/test-hardening): this used to answer every
                # "bash -lc ..." exec identically regardless of command,
                # which could never distinguish the new keyring check
                # (below) from the existing Tools/Persist and tmux checks.
                # Small, general fixture improvement: branch on a distinct
                # substring of each script body ("$3" here, the script
                # text) instead.
                case "${3:-}" in
                    *"tmux ls"*)
                        if [ -n "${DX_FAKE_TMUX:-}" ]; then printf "%s\n" "$DX_FAKE_TMUX"; exit 0; else exit 1; fi
                        ;;
                    *"dx-keyring"*)
                        if [ -n "${DX_FAKE_KEYRING:-}" ]; then printf "%s\n" "$DX_FAKE_KEYRING"; exit 0; else exit 1; fi
                        ;;
                    *)
                        printf "Tools: fake\nPersist: fake\n"
                        exit 0
                        ;;
                esac
                ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac'
# Branch 11 / Phase 6 (item 5): default CLOSED, matching what a real "nc -z
# 127.0.0.1 <port>" already did unmodified in every test above this one
# (nothing really listens on the configured port in this fixture) --
# opt-in OPEN via DX_FAKE_PORT_OPEN, deterministic either way.
fake_tool_write "$status_fixture/bin" nc '[ "${DX_FAKE_PORT_OPEN:-0}" = 1 ] && exit 0; exit 1'
trap 'rm -rf "$status_fixture"' EXIT

run_status() {
    (
        unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PROJECT_ROOT
        for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
        export PATH="$status_fixture/bin:/usr/bin:/bin"
        export HOME="$status_fixture/home"
        export DX_CONTAINER_NAME=dxe-status-fixture DX_IMAGE=dxe-status-fixture-image
        "$BASE_DIR/bin/dx-status"
    )
}

status_out="$(DX_FAKE_EXISTS=1 DX_FAKE_RUNNING=1 DX_FAKE_CURRENT=generations/gen-b DX_FAKE_LEASES='gen-a.1' run_status 2>&1)"
if printf '%s\n' "$status_out" | stdin_matches 'gen-a' && printf '%s\n' "$status_out" | stdin_matches 'gen-b' \
    && printf '%s\n' "$status_out" | stdin_matches 'is running bootstrap generation gen-a, but gen-b is now published'; then
    test_pass "dx-status reports a running guest's generation drift against the published one"
else
    test_fail "dx-status reports a running guest's generation drift against the published one (got: $status_out)"
fi

status_out="$(DX_FAKE_EXISTS=1 DX_FAKE_RUNNING=1 DX_FAKE_CURRENT=generations/gen-a DX_FAKE_LEASES='gen-a.1' run_status 2>&1)"
if printf '%s\n' "$status_out" | stdin_matches 'gen-a' && ! printf '%s\n' "$status_out" | stdin_matches 'is now published'; then
    test_pass "dx-status reports a running guest with no drift silently"
else
    test_fail "dx-status reports a running guest with no drift silently (got: $status_out)"
fi

log_file="$status_fixture/dead-guest.log"
{
    printf 'Waiting for bootstrap payload in /guest-bootstrap...\n'
    printf 'Using bootstrap generation gen-dead\n'
    i=0
    while [ "$i" -lt 60 ]; do printf 'noise line %s\n' "$i"; i=$((i + 1)); done
} > "$log_file"
status_out="$(DX_FAKE_EXISTS=1 DX_FAKE_RUNNING=0 DX_FAKE_LOG_FILE="$log_file" run_status 2>&1)"
if printf '%s\n' "$status_out" | stdin_matches 'gen-dead'; then
    test_pass "dx-status recovers the last booted generation from container logs for a guest that died, past a 40-line tail"
else
    test_fail "dx-status recovers the last booted generation from container logs for a guest that died, past a 40-line tail (got: $status_out)"
fi

status_out="$(DX_FAKE_EXISTS=1 DX_FAKE_RUNNING=0 DX_FAKE_LOG_FILE=/dev/null run_status 2>&1)"
if printf '%s\n' "$status_out" | stdin_matches 'no recorded boot generation'; then
    test_pass "dx-status says so, rather than claiming a generation, when a dead guest never recorded one"
else
    test_fail "dx-status says so, rather than claiming a generation, when a dead guest never recorded one (got: $status_out)"
fi

status_out="$(DX_FAKE_EXISTS=0 run_status 2>&1)"
if printf '%s\n' "$status_out" | sed -n '/--- Bootstrap Generation ---/,+1p' | stdin_matches 'Not found'; then
    test_pass "dx-status reports no bootstrap generation section for a container that does not exist"
else
    test_fail "dx-status reports no bootstrap generation section for a container that does not exist (got: $status_out)"
fi

# --- Branch 11 / Phase 6 (item 5): dx-status distinguishes "container
# running, port not open yet" from a bare, unqualified CLOSED line, by
# showing the most recent bootstrap-progress marker from the guest's own
# log -- the same log the dead-guest branch above already reads, just
# while the container is still alive. Real evidence (2026-09-28,
# docs/refactor/qnap-lifecycle.md's appendix): a restart can leave the
# guest boot itself fast while an operator's own readiness probe still
# fails for minutes under host contention, so this closes the ambiguity
# for the (rarer) case where the port itself has not opened yet either.
log_file="$status_fixture/still-booting.log"
{
    printf 'Waiting for bootstrap payload in /guest-bootstrap...\n'
    printf 'Using bootstrap generation gen-live\n'
    printf 'Bootstrap phase: essentials installation completed in 1s.\n'
} > "$log_file"
status_out="$(DX_FAKE_EXISTS=1 DX_FAKE_RUNNING=1 DX_FAKE_CURRENT=generations/gen-live DX_FAKE_LEASES='gen-live.1' DX_FAKE_LOG_FILE="$log_file" DX_FAKE_PORT_OPEN=0 run_status 2>&1)"
if printf '%s\n' "$status_out" | stdin_matches -F -- 'is CLOSED' \
    && printf '%s\n' "$status_out" | stdin_matches -F -- 'Still bootstrapping: Bootstrap phase: essentials installation completed in 1s.'; then
    test_pass "dx-status names the guest's last bootstrap-progress line while the container is running but SSH has not opened yet"
else
    test_fail "dx-status names the guest's last bootstrap-progress line while the container is running but SSH has not opened yet (got: $status_out)"
fi

# --- Item 4 (fix/test-hardening): dx-status has no "keyring: not running" -
# --- line for Branch 15's failure policy B warning path (guest reachable, -
# --- keyring not started). When the guest is reachable, show the         -
# --- keyring status the guest's own "dx-keyring status" reports (live /  -
# --- stale / absent), through dx_runtime_exec (so a docker-ssh profile   -
# --- gets the same line for free -- confirmed no dx-status-specific      -
# --- docker-ssh branch exists besides the unrelated Remote Lock section, -
# --- both already exercised via the same fake `container exec` fixture   -
# --- above). ---
status_out="$(DX_FAKE_EXISTS=1 DX_FAKE_RUNNING=1 DX_FAKE_KEYRING=live run_status 2>&1)"
if printf '%s\n' "$status_out" | stdin_matches -F -- 'keyring: live'; then
    test_pass "dx-status reports a live keyring"
else
    test_fail "dx-status reports a live keyring (got: $status_out)"
fi

status_out="$(DX_FAKE_EXISTS=1 DX_FAKE_RUNNING=1 DX_FAKE_KEYRING=stale run_status 2>&1)"
if printf '%s\n' "$status_out" | stdin_matches -F -- 'keyring: stale'; then
    test_pass "dx-status reports a stale keyring"
else
    test_fail "dx-status reports a stale keyring (got: $status_out)"
fi

status_out="$(DX_FAKE_EXISTS=1 DX_FAKE_RUNNING=1 DX_FAKE_KEYRING=absent run_status 2>&1)"
if printf '%s\n' "$status_out" | stdin_matches -F -- 'keyring: not running'; then
    test_pass "dx-status says \"keyring: not running\" for the not-started (absent) case"
else
    test_fail "dx-status says \"keyring: not running\" for the not-started (absent) case (got: $status_out)"
fi

# DX_FAKE_KEYRING unset entirely: the fixture's "dx-keyring" case then
# exits 1 (as it would for a guest where dx-keyring is not installed, or
# any other probe failure) -- dx-status must still say "not running", not
# abort under its own `set -euo pipefail`.
status_out="$(DX_FAKE_EXISTS=1 DX_FAKE_RUNNING=1 run_status 2>&1)"
if printf '%s\n' "$status_out" | stdin_matches -F -- 'keyring: not running'; then
    test_pass "dx-status says \"keyring: not running\" when the keyring probe itself fails/is unavailable"
else
    test_fail "dx-status says \"keyring: not running\" when the keyring probe itself fails/is unavailable (got: $status_out)"
fi

# --- dx-status (docker-ssh): a real NAS live gate found this dead --
# `image ls --format 'table {{.Repository}}:{{.Tag}}...'` joined the
# repository and tag into ONE column with a colon and no whitespace between
# them, so this script's own `dx_runtime_image_list | grep
# "^${DX_IMAGE}[[:space:]]"` above matched nothing, exited 1, and `set -e`
# killed the whole script silently right after the "=== DX Status ===" and
# "--- Image (...) ---" header lines (Apple's `container image list` prints
# NAME and TAG as separate columns, which is why the same grep already
# worked there -- see the Apple fixture above). Drives the real dx-status
# through the docker-ssh adapter with a fake `ssh`+`docker` on PATH, the
# same fixture shape tests/test_docker_runtime_adapter.sh (Section 33) uses
# for the adapter functions directly; this proves the fix at the actual
# host-script level, not only inside the adapter function's own unit test.
docker_status_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-status-docker-ssh.XXXXXX")"
fake_qnap_ssh_write "$docker_status_fixture"
# dx-status's docker-ssh path runs the full dx_runtime_docker_available
# preflight (host reachability, uname -m/DX_GUEST_SYSTEM arch check, engine
# compatibility, daemon identity) before its Image section ever queries
# anything, so this fake must answer every one of those calls too, not only
# image ls/inspect -- otherwise the preflight itself fails closed and the
# Image section this test cares about never runs at all.
fake_tool_write "$docker_status_fixture" uname 'case "$1" in -m) echo aarch64 ;; esac'
fake_tool_write "$docker_status_fixture" docker '
case "$1" in
    version) [ "$2" = --format ] && echo "27.0.0" ;;
    info)    [ "$2" = --format ] && echo "sha256:fake|qnap-dxe|aarch64|linux" ;;
    image)
        case "$2" in
            inspect) exit 0 ;;
            ls)
                # Faithful to dx_runtime_docker_image_list'"'"'s real --format
                # string: if Repository and Tag are still joined by a colon
                # (Finding 4, already fixed), render output the same
                # (broken) way a real `docker image ls` would -- one
                # combined column -- so this test only stays green when
                # production truly emits separate columns, not merely
                # because this fake ignores what format it was asked for.
                case "$*" in
                    *"{{.Repository}}:{{.Tag}}"*)
                        printf "REPOSITORY:TAG\tIMAGE ID\tCREATED\tSIZE\n"
                        printf "dx-qnap-spike-nixos:latest\tabc123\t1 day ago\t500MB\n"
                        ;;
                    *)
                        printf "REPOSITORY\tTAG\tIMAGE ID\tCREATED\tSIZE\n"
                        printf "dx-qnap-spike-nixos\tlatest\tabc123\t1 day ago\t500MB\n"
                        ;;
                esac
                ;;
            *) exit 1 ;;
        esac
        ;;
    container)
        case "$2" in
            inspect)
                shift 2
                if [ "$1" = --format ]; then
                    case "$2" in
                        *".State.Running"*) echo false ;;
                        # dx_runtime_docker_lock_audit'"'"'s label query on the
                        # (differently-named) lock container -- exit 1 makes
                        # it report "not held", the same fail-safe path a
                        # real absent lock container takes. Not this test'"'"'s
                        # concern; only here so it does not abort under
                        # set -e.
                        *) exit 1 ;;
                    esac
                else
                    exit 0
                fi
                ;;
            *) exit 1 ;;
        esac
        ;;
    ps)
        # Finding 5 (NAS re-gate): docker ps/ls render .Labels as a
        # comma-separated STRING, not a map. A real Docker CLI (29.4.0,
        # verified live 2026-09-28) rejects `index .Labels "io.dxe.system"`
        # here with exactly this error. Faithful to
        # dx_runtime_docker_container_list'"'"'s real --format string: if it
        # still contains the old (wrong) map-style shape, reproduce the
        # real failure instead of silently ignoring it, so this test only
        # stays green when production truly uses `.Label "..."` (a method,
        # not `index .Labels`).
        case "$*" in
            *"index .Labels"*)
                echo "failed to execute template: template: :1:42: executing \"\" at <index .Labels \"io.dxe.system\">: error calling index: cannot index slice/array with type string" >&2
                exit 1
                ;;
        esac
        printf "NAMES\tIMAGE\tSTATUS\tsystem\n"
        printf "dxe-status-fixture\tfake-image\tUp 1 second\tx86_64-linux\n"
        ;;
    logs) : ;;
    *) exit 1 ;;
esac'
run_docker_status() {
    (
        unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PROJECT_ROOT
        for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
        export PATH="$docker_status_fixture:/usr/bin:/bin"
        export HOME="$docker_status_fixture/home"
        # DX_NIX_STORAGE_MODE=direct-volume (WP4.3, Astra F10 / Muse C1):
        # dx_config_validate_cross_fields now requires it alongside
        # DX_RUNTIME=docker-ssh; unrelated to this fixture's own
        # Image/Container column-shape assertions.
        export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_NIX_STORAGE_MODE=direct-volume DXE_RUNTIME_DOCKER_BIN=docker
        export DX_CONTAINER_NAME=dxe-status-fixture DX_IMAGE=dx-qnap-spike-nixos
        "$BASE_DIR/bin/dx-status"
    )
}
set +e
docker_status_out="$(run_docker_status 2>&1)"
docker_status_rc=$?
set -e
# "abc123" (the fake IMAGE ID) only appears in the actual rendered table
# row, never in the "--- Image (...) ---" header itself -- the header
# alone would satisfy a weaker "does it mention the image name" check even
# while dx-status dies right after printing it, which is exactly the bug
# this test exists to catch. Likewise "x86_64-linux" (the fake io.dxe.system
# label value) only appears in the Container section's own rendered ps row
# (Finding 5), never in its "--- Container (...) ---" header. "--- SSH" is
# the section dx-status always prints unconditionally right after both,
# so its presence also proves the script ran to completion (exit 0) rather
# than aborting under set -e partway through either section.
if [ "$docker_status_rc" -eq 0 ] \
    && printf '%s\n' "$docker_status_out" | stdin_matches -F "abc123" \
    && printf '%s\n' "$docker_status_out" | stdin_matches -F -- "x86_64-linux" \
    && printf '%s\n' "$docker_status_out" | stdin_matches -F -- "--- SSH"; then
    test_pass "dx-status (docker-ssh) renders the Image and Container sections instead of dying silently on their column-shape mismatches"
else
    test_fail "dx-status (docker-ssh) renders the Image and Container sections instead of dying silently on their column-shape mismatches (rc=$docker_status_rc, got: $docker_status_out)"
fi

# Branch 11 / Phase 5 (DQ5): once the guest SSH address is known, the SSH
# section probes and prints THAT address, never "localhost" -- pre-seeded
# here to skip real Tailscale discovery (characterised directly against a
# fake management ssh in tests/test_docker_runtime_adapter.sh, Section 33);
# a real "nc -z <placeholder-tailscale-address> <port>" would not be fast
# or deterministic in a CI sandbox, so nc is faked too, in the SAME fixture
# directory as the docker-ssh case above.
# Assembled via printf, never a literal dotted quad in this file's own
# source text (same discipline as test_docker_runtime_adapter.sh's
# tailnet_fixture_addr), so this fixture can never trip
# test_section1_secrets.sh's Tailscale-range leak scan.
status_fixture_addr="$(printf '%s.%s.%s.%s' 100 64 1 2)"
fake_tool_write "$docker_status_fixture" nc "case \"\$*\" in
    \"-z $status_fixture_addr 2222\") exit 0 ;;
    *) exit 1 ;;
esac"
export DXE_RUNTIME_GUEST_SSH_ADDRESS="$status_fixture_addr"
set +e
docker_status_out2="$(run_docker_status 2>&1)"
docker_status_rc2=$?
set -e
unset DXE_RUNTIME_GUEST_SSH_ADDRESS
if [ "$docker_status_rc2" -eq 0 ] \
    && printf '%s\n' "$docker_status_out2" | stdin_matches -F -- "--- SSH ($status_fixture_addr:2222) ---" \
    && printf '%s\n' "$docker_status_out2" | stdin_matches -F -- "SSH Port 2222 is OPEN on $status_fixture_addr"; then
    test_pass "dx-status (docker-ssh) probes and prints the guest's actual discovered SSH address, never localhost"
else
    test_fail "dx-status (docker-ssh) probes and prints the guest's actual discovered SSH address (rc=$docker_status_rc2, got: $docker_status_out2)"
fi
rm -rf "$docker_status_fixture"

# --- Branch 11 / Phase 6 (item 5), docker-ssh: same third-state
# distinction as the Apple fixture above, plus the login-shell-probe case
# real evidence found -- sshd listening, login shell not answering for
# minutes under host contention (docs/refactor/qnap-lifecycle.md's
# appendix). Both through the existing SSH section; no new dx_runtime_*
# contract op -- a plain ssh call, the same shared option builder
# dx-wait-ssh's own poll loop uses.
thirdstate_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-status-thirdstate.XXXXXX")"
fake_tool_write "$thirdstate_fixture" uname 'case "$1" in -m) echo aarch64 ;; esac'
fake_tool_write "$thirdstate_fixture" docker '
case "$1" in
    version) [ "$2" = --format ] && echo "27.0.0" ;;
    info)    [ "$2" = --format ] && echo "sha256:fake|qnap-dxe|aarch64|linux" ;;
    image)
        case "$2" in
            inspect) exit 0 ;;
            ls)
                printf "REPOSITORY\tTAG\tIMAGE ID\tCREATED\tSIZE\n"
                printf "dx-qnap-thirdstate\tlatest\tabc123\t1 day ago\t500MB\n"
                ;;
            *) exit 1 ;;
        esac
        ;;
    container)
        case "$2" in
            inspect)
                shift 2
                if [ "$1" = --format ]; then
                    case "$2" in
                        *".State.Running"*)
                            if [ "${DX_FAKE_RUNNING3:-1}" = 1 ]; then echo true; else echo false; fi
                            ;;
                        *) exit 1 ;;
                    esac
                else
                    exit 0
                fi
                ;;
            *) exit 1 ;;
        esac
        ;;
    ps)
        printf "NAMES\tIMAGE\tSTATUS\tsystem\n"
        printf "dxe-status-fixture\tfake-image\tUp 1 second\tx86_64-linux\n"
        ;;
    logs)
        cat "${DX_FAKE_LOG_FILE:-/dev/null}" 2>/dev/null
        ;;
    exec)
        # Answers dx-status'"'"'s Guest Environment section (Tools/Persist,
        # tmux, keyring), reached whenever DX_FAKE_RUNNING3=1 -- not this
        # test'"'"'s own concern, only here so it does not abort under set -e.
        shift
        [ "${1:-}" = "-u" ] && shift 2
        shift
        printf "Tools: fake\nPersist: fake\n"
        exit 0
        ;;
    *) exit 1 ;;
esac'
# Distinct from fake_qnap_ssh_write (tests/lib/fake-tools.sh): that shared
# helper's eval-the-trailing-argument shape is reused verbatim for every
# OTHER call (management-plane docker/uname commands), but this fixture
# also needs to distinguish dx-status's new GUEST-plane login-shell probe
# ("bash -lc 'true'", the exact string bin/dx-wait-ssh's own probe already
# sends) from those, which the shared helper has no reason to know about.
fake_tool_write "$thirdstate_fixture" ssh '
dx_fake_last=""
for dx_fake_arg in "$@"; do dx_fake_last="$dx_fake_arg"; done
if [ "$dx_fake_last" = "bash -lc '"'"'true'"'"'" ]; then
    if [ "${DX_FAKE_LOGIN_OK:-1}" = 1 ]; then
        exit 0
    fi
    echo "kex_exchange_identification: Connection closed by remote host" >&2
    exit 255
fi
eval "$dx_fake_last"
'
fake_tool_write "$thirdstate_fixture" nc '[ "${DX_FAKE_PORT_OPEN3:-1}" = 1 ] && exit 0; exit 1'
run_thirdstate_status() {
    (
        unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PROJECT_ROOT
        for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
        export PATH="$thirdstate_fixture:/usr/bin:/bin"
        export HOME="$thirdstate_fixture/home"
        # DX_NIX_STORAGE_MODE=direct-volume (WP4.3, Astra F10 / Muse C1):
        # dx_config_validate_cross_fields now requires it alongside
        # DX_RUNTIME=docker-ssh; unrelated to this fixture's own
        # bootstrap-progress/login-shell assertions.
        export DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_NIX_STORAGE_MODE=direct-volume DXE_RUNTIME_DOCKER_BIN=docker
        export DX_CONTAINER_NAME=dxe-status-fixture DX_IMAGE=dx-qnap-thirdstate
        DXE_RUNTIME_GUEST_SSH_ADDRESS="$(printf '%s.%s.%s.%s' 100 64 1 3)"
        export DXE_RUNTIME_GUEST_SSH_ADDRESS
        "$BASE_DIR/bin/dx-status"
    )
}

thirdstate_log="$thirdstate_fixture/still-booting.log"
{
    printf 'Waiting for bootstrap payload in /guest-bootstrap...\n'
    printf 'Using bootstrap generation gen-live\n'
    printf 'Bootstrap phase: Nix volume prepare/mount completed in 0s.\n'
} > "$thirdstate_log"
set +e
status_out="$(DX_FAKE_RUNNING3=1 DX_FAKE_PORT_OPEN3=0 DX_FAKE_LOG_FILE="$thirdstate_log" run_thirdstate_status 2>&1)"
status_rc=$?
set -e
if [ "$status_rc" -eq 0 ] \
    && printf '%s\n' "$status_out" | stdin_matches -F -- 'is CLOSED' \
    && printf '%s\n' "$status_out" | stdin_matches -F -- 'Still bootstrapping: Bootstrap phase: Nix volume prepare/mount completed in 0s.'; then
    test_pass "dx-status (docker-ssh) names the last bootstrap-progress line while the port is still closed"
else
    test_fail "dx-status (docker-ssh) names the last bootstrap-progress line while the port is still closed (rc=$status_rc, got: $status_out)"
fi

set +e
status_out="$(DX_FAKE_RUNNING3=1 DX_FAKE_PORT_OPEN3=1 DX_FAKE_LOGIN_OK=0 run_thirdstate_status 2>&1)"
status_rc=$?
set -e
if [ "$status_rc" -eq 0 ] \
    && printf '%s\n' "$status_out" | stdin_matches -F -- 'is OPEN' \
    && printf '%s\n' "$status_out" | stdin_matches -F -- 'Login shell is not answering' \
    && printf '%s\n' "$status_out" | stdin_matches -F -- 'kex_exchange_identification'; then
    test_pass "dx-status (docker-ssh) reports the login-shell probe's own error when the port is open but the guest is not answering"
else
    test_fail "dx-status (docker-ssh) reports the login-shell probe's own error when the port is open but the guest is not answering (rc=$status_rc, got: $status_out)"
fi

set +e
status_out="$(DX_FAKE_RUNNING3=1 DX_FAKE_PORT_OPEN3=1 DX_FAKE_LOGIN_OK=1 run_thirdstate_status 2>&1)"
status_rc=$?
set -e
if [ "$status_rc" -eq 0 ] \
    && printf '%s\n' "$status_out" | stdin_matches -F -- 'is OPEN' \
    && ! printf '%s\n' "$status_out" | stdin_matches -F -- 'Login shell is not answering'; then
    test_pass "dx-status (docker-ssh) prints nothing extra when the login shell answers normally"
else
    test_fail "dx-status (docker-ssh) prints nothing extra when the login shell answers normally (rc=$status_rc, got: $status_out)"
fi
rm -rf "$thirdstate_fixture"

# --- dx-reset-nix-volume (Branch 12, store-trust-plan.md): the real,
# volume-scoped recovery path both store-trust refusals point at by name.
# Drives the real entrypoint with a fake `container` on PATH, the same
# pattern dx-status above uses. The fake answers exactly the calls
# container_exists/dx_runtime_volume_exists/dx_runtime_volume_delete render
# on the Apple adapter (list -a --quiet, volume inspect, volume rm).
reset_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-reset-nix-volume.XXXXXX")"
trap 'rm -rf "$reset_fixture"' EXIT
fake_tool_write "$reset_fixture/bin" container '
case "$1" in
    list)
        shift
        for a in "$@"; do [ "$a" = "-a" ] && all=true; done
        if [ "${all:-false}" = true ] && [ "${DX_FAKE_EXISTS:-0}" = 1 ]; then
            printf "%s\n" "$DX_CONTAINER_NAME"
        fi
        exit 0
        ;;
    volume)
        shift
        case "$1" in
            inspect)
                [ "${DX_FAKE_VOL_EXISTS:-1}" = 1 ] && [ "$2" = "$DX_NIX_VOLUME" ] && exit 0
                exit 1
                ;;
            rm)
                shift
                printf "%s\n" "$@" >> "${DX_FAKE_VOL_RM_LOG:-/dev/null}"
                [ "${DX_FAKE_VOL_RM_FAIL:-0}" = 1 ] && exit 1
                exit 0
                ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac'

run_reset() {
    (
        unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PROJECT_ROOT
        for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
        export PATH="$reset_fixture/bin:/usr/bin:/bin"
        export HOME="$reset_fixture/home-$$-$RANDOM"
        export DX_CONTAINER_NAME=dxe-reset-fixture DX_NIX_VOLUME=dxe-reset-fixture-nix
        export DX_PERSIST_VOLUME=dxe-reset-fixture-persist DX_BOOTSTRAP_VOLUME=dxe-reset-fixture-bootstrap
        "$BASE_DIR/bin/dx-reset-nix-volume"
    )
}

# 1. Container still exists: refuse, naming dx-destroy-container/dx-destroy
# by name, before any volume operation is attempted at all.
rm_log="$reset_fixture/rm-container-exists.log"
if out="$(DX_FAKE_EXISTS=1 DX_FAKE_VOL_RM_LOG="$rm_log" run_reset 2>&1)"; then
    test_fail "dx-reset-nix-volume: refuses while the container still exists"
else
    if printf '%s\n' "$out" | stdin_matches -F 'dx-destroy-container' \
        && printf '%s\n' "$out" | stdin_matches -F 'dx-destroy' \
        && [ ! -s "$rm_log" ]; then
        test_pass "dx-reset-nix-volume: refuses while the container still exists, naming dx-destroy-container/dx-destroy, before any volume operation"
    else
        test_fail "dx-reset-nix-volume: refuses while the container still exists, naming dx-destroy-container/dx-destroy, before any volume operation (out: $out; log: $(cat "$rm_log" 2>/dev/null))"
    fi
fi

# 2. Container absent, volume absent: a clean no-op, "nothing to reset".
rm_log="$reset_fixture/rm-nothing.log"
if out="$(DX_FAKE_EXISTS=0 DX_FAKE_VOL_EXISTS=0 DX_FAKE_VOL_RM_LOG="$rm_log" run_reset 2>&1)"; then
    if printf '%s\n' "$out" | stdin_matches -F 'nothing to reset' && [ ! -s "$rm_log" ]; then
        test_pass "dx-reset-nix-volume: container and volume both absent -> a clean no-op, no volume operation attempted"
    else
        test_fail "dx-reset-nix-volume: container and volume both absent -> a clean no-op, no volume operation attempted (out: $out; log: $(cat "$rm_log" 2>/dev/null))"
    fi
else
    test_fail "dx-reset-nix-volume: container and volume both absent -> a clean no-op (exit nonzero; out: $out)"
fi

# 3. Container absent, volume exists, delete succeeds: removes EXACTLY the
# Nix volume by name (never persist/bootstrap), prints the ./bin/dx next
# step, and releases a stale claim naming this exact container.
rm_log="$reset_fixture/rm-success.log"
claim_home="$reset_fixture/claim-home"
mkdir -p "$claim_home/.dx-cache/nix-volume-claims"
printf 'dxe-reset-fixture\t1\t1970-01-01\n' > "$claim_home/.dx-cache/nix-volume-claims/dxe-reset-fixture-nix"
if out="$(
    unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PROJECT_ROOT
    for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
    export PATH="$reset_fixture/bin:/usr/bin:/bin"
    export HOME="$claim_home"
    export DX_CONTAINER_NAME=dxe-reset-fixture DX_NIX_VOLUME=dxe-reset-fixture-nix
    export DX_PERSIST_VOLUME=dxe-reset-fixture-persist DX_BOOTSTRAP_VOLUME=dxe-reset-fixture-bootstrap
    DX_FAKE_EXISTS=0 DX_FAKE_VOL_EXISTS=1 DX_FAKE_VOL_RM_LOG="$rm_log" "$BASE_DIR/bin/dx-reset-nix-volume"
)"; then
    if [ "$(cat "$rm_log" 2>/dev/null)" = dxe-reset-fixture-nix ] \
        && printf '%s\n' "$out" | stdin_matches -F './bin/dx' \
        && [ ! -e "$claim_home/.dx-cache/nix-volume-claims/dxe-reset-fixture-nix" ]; then
        test_pass "dx-reset-nix-volume: removes exactly the Nix volume by name, releases a matching claim, and names the next step"
    else
        test_fail "dx-reset-nix-volume: removes exactly the Nix volume by name, releases a matching claim, and names the next step (out: $out; log: $(cat "$rm_log" 2>/dev/null); claim: $([ -e "$claim_home/.dx-cache/nix-volume-claims/dxe-reset-fixture-nix" ] && echo present || echo absent))"
    fi
else
    test_fail "dx-reset-nix-volume: removes exactly the Nix volume by name (exit nonzero; out: $out)"
fi

# 4. Container absent, volume exists, delete FAILS (the runtime reports the
# volume in use -- e.g. an orphaned referrer container): a clear, actionable
# refusal, never silently reported as success.
rm_log="$reset_fixture/rm-in-use.log"
if out="$(DX_FAKE_EXISTS=0 DX_FAKE_VOL_EXISTS=1 DX_FAKE_VOL_RM_FAIL=1 DX_FAKE_VOL_RM_LOG="$rm_log" run_reset 2>&1)"; then
    test_fail "dx-reset-nix-volume: reports a failed removal (volume in use) as an error, not a silent success"
else
    if printf '%s\n' "$out" | stdin_matches -F 'volume is in use' \
        || printf '%s\n' "$out" | stdin_matches -F 'in use'; then
        test_pass "dx-reset-nix-volume: reports a failed removal (volume in use) as an error"
    else
        test_fail "dx-reset-nix-volume: reports a failed removal (volume in use) as an error (out: $out)"
    fi
fi

# --- dx-factory-reset (Apple), Branch 11 / Phase 6 item 7: the new
# whole-operation ownership proof (bin/lib/dx-container.sh's
# dx_destructive_plan_and_verify) is a no-op under DX_RUNTIME=apple (Apple
# has no DQ6 labels at all) -- proven by running the real entrypoint with
# stdin closed and no --force, which the ORIGINAL script already refuses
# (unchanged message, unchanged exit code) before any subscript runs. No
# "Immutable plan" text appears, and nothing on PATH here answers a
# docker/ssh call at all, so a real container/ssh binary is never reached
# either way.
set +e
factory_reset_apple_out="$(
    unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PROJECT_ROOT
    for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
    HOME="$(mktemp -d "${TMPDIR:-/tmp}/dxe-factory-reset-apple.XXXXXX")"
    export HOME
    "$BASE_DIR/bin/dx-factory-reset" < /dev/null 2>&1
)"
factory_reset_apple_rc=$?
set -e
if [ "$factory_reset_apple_rc" -ne 0 ] \
    && printf '%s\n' "$factory_reset_apple_out" | stdin_matches -F -- "Refusing to factory-reset without --force when stdin is not a tty" \
    && ! printf '%s\n' "$factory_reset_apple_out" | stdin_matches -F -- "Immutable plan"; then
    test_pass "dx-factory-reset (apple): the new ownership-proof step is a no-op, unchanged refusal behaviour"
else
    test_fail "dx-factory-reset (apple): the new ownership-proof step is a no-op, unchanged refusal behaviour (rc=$factory_reset_apple_rc, got: $factory_reset_apple_out)"
fi

print_summary
exit_with_code
