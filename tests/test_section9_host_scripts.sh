#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
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
ps() { printf '%s\n' '101 container-runtime-linux start --uuid dx-host-other' '102 container-runtime-linux start --uuid dx-host' 'bad malformed'; }
if [ "$(container_runtime_pids dx-host)" = 102 ]; then test_pass "runtime discovery matches exact --uuid argument/value pairs"; else test_fail "runtime discovery matches exact --uuid argument/value pairs"; fi
unset -f ps

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

source "$BASE_DIR/bin/dx-forward"
if [ "$(parse_all_forwards 5173 8000:8001)" = $'5173:5173\n8001:8000' ]; then test_pass "forward wrapper parses direction-specific mappings"; else test_fail "forward wrapper parses direction-specific mappings"; fi
if parse_all_forwards 80 >/dev/null 2>&1; then test_fail "forward wrapper rejects privileged host ports"; else test_pass "forward wrapper rejects privileged host ports"; fi
source "$BASE_DIR/bin/dx-reverse"
if [ "$(parse_all_reverses 5432 3000:13000)" = $'5432:5432\n13000:3000' ]; then test_pass "reverse wrapper parses direction-specific mappings"; else test_fail "reverse wrapper parses direction-specific mappings"; fi

assert_file_not_contains "$BASE_DIR/bin/dx-forward" 'DX_FORWARD_TEST_MODE' "forward has no production test seam"
assert_file_not_contains "$BASE_DIR/bin/dx-reverse" 'DX_REVERSE_TEST_MODE' "reverse has no production test seam"
assert_file_not_contains "$BASE_DIR/bin/dx-reclaim" 'df -h "\$@" | sed' "reclaim filesystem reporting does not require guest sed"
assert_file_contains_literal "$BASE_DIR/bin/dx-reclaim" 'export PATH="/nix/var/nix/profiles/per-user/root/profile/bin:$PATH"' "reclaim uses the GC-rooted essentials profile PATH"
if (
    # Sourcing dx-forward/dx-reverse above (for their parse_all_* helpers)
    # pulled in bin/lib/dx-config.sh, which resolved and exported the real
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

# --- D7 option 3: dx-start-container must tell a real publish from the
# unchanged-content skip using only dx-sync-bootstrap's own captured stdout,
# since that is the only distinction available without re-deriving the
# content digest itself (docs/refactor/decisions/D7-start-generation.md).
if published="$(dx_bootstrap_sync_published_generation 'Syncing bootstrap generation 20260926T045923Z-7438 from /src to dx-test:/guest-bootstrap...
Bootstrap generation 20260926T045923Z-7438 is ready.')" && [ "$published" = 20260926T045923Z-7438 ]; then
    test_pass "a real publish's generation id is parsed from dx-sync-bootstrap's own terminal message"
else
    test_fail "a real publish's generation id is parsed from dx-sync-bootstrap's own terminal message (got '${published:-}')"
fi
if dx_bootstrap_sync_published_generation 'Bootstrap content is unchanged; generation 20260926T045923Z-7438 stays current.' >/dev/null 2>&1; then
    test_fail "the unchanged-content skip message is never mistaken for a publish"
else
    test_pass "the unchanged-content skip message is never mistaken for a publish"
fi
if dx_bootstrap_sync_published_generation 'something unexpected happened' >/dev/null 2>&1; then
    test_fail "unrecognised sync output is never mistaken for a publish"
else
    test_pass "unrecognised sync output is never mistaken for a publish"
fi
if dx_bootstrap_sync_published_generation '' >/dev/null 2>&1; then
    test_fail "empty sync output is never mistaken for a publish"
else
    test_pass "empty sync output is never mistaken for a publish"
fi

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
                printf "Tools: fake\nPersist: fake\n"
                exit 0
                ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac'
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

print_summary
exit_with_code
