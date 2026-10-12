#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
# WP7.2: everything about the LIVE /persist migration suite
# (tests/test_persist_migrate_live.sh) that can be proven without a NAS:
#   - persist_migrate_live_guard (tests/lib/persist-migrate-live.sh) keeps
#     every WP7.1 refusal and adds its own (rollback volume, root comma, bulk
#     size, the inode floor, the production-inventory opt-in), one `Refusing:`
#     line each, with no command call at all;
#   - the read-only runners: persist_migrate_live_dir_read and
#     persist_migrate_live_volume_read start exactly one pinned read-only
#     container (the volume one only after its DQ6 check), or none;
#   - the inode preflight's two reads (docker info, df -P -i) and their
#     parsing (GNU and busybox df);
#   - the NAS-side interrupt: persist_migrate_live_interrupt's pinned ssh call
#     and refusals, and its NAS script (under sh and dash, against a recording
#     fake docker) killing exactly the one copy container (found by its WP6.4c
#     name), once the bulk file is part-way under its own name (rsync
#     --inplace), and nothing else;
#   - the controller-drop case (WP7.2b): the read-only copy-container watcher
#     (wrapper and NAS script under sh and dash: running and gone, bounded,
#     ps and inspect only), the process-group start and SIGKILL on real
#     processes of this suite's own (every refusal with kill stubbed), the
#     classifier against the product's own refusal lines, and the whole
#     orchestration against stand-ins: which command runs in which order,
#     with which deadline, and what stops it;
#   - the container scripts (LIST, RETIRED_ASIDE), run with only
#     the bare image's tools on PATH against temporary directories, the
#     partial-copy helpers on a real LIST, and the guest scripts (SEED,
#     CHANGES, CHECK) against a temporary /persist;
#   - the production-inventory runner: exactly the production profile's
#     fields minus DX_PROFILE_ROOT reach dx-persist-inventory, nothing of the
#     canary, and every refusal runs nothing;
#   - the live suite's own gates: it skips without --live or the opt-in,
#     refuses before any remote call, and with a failing NAS stops at the
#     read-only preflight.
# The scripts run real mv, mkdir, rm and chmod, but only inside the temporary
# directory this suite creates (checked before each run). The only processes
# it signals are its own stand-ins. No test here reaches a real host: every
# network tool is a fail-closed fake.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/fake-tools.sh
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
# shellcheck source=lib/persist-live.sh
source "$SCRIPT_DIR/lib/persist-live.sh"
# shellcheck source=lib/persist-migrate-live.sh
source "$SCRIPT_DIR/lib/persist-migrate-live.sh"

test_section "WP7.2: migration live-suite guard, runners, interrupt and scripts (no NAS)"

SCRATCH="$(persist_fixture_root_create)" || exit 1
case "$SCRATCH" in
    /*/dxe-persist-share.??????) : ;;
    *) echo "unexpected scratch path: $SCRATCH" >&2; exit 1 ;;
esac
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
SCRATCH="$(cd -P "$SCRATCH" && pwd -P)"
mkdir -p "$SCRATCH/tmp" "$SCRATCH/home" "$SCRATCH/profiles" "$SCRATCH/real-profiles"

has() { grep -Fq -- "$2" <<<"$1"; }
count_refusals() { grep -c '^Refusing: ' <<<"$1" || true; }
in_scratch() {
    case "$1" in
        "$SCRATCH"/*) return 0 ;;
    esac
    echo "refusing to touch a path outside the scratch area: $1" >&2
    return 1
}

# --- persist_migrate_live_guard -------------------------------------------------
# shellcheck disable=SC2034 # read by the guards and the helpers
canary_env() {
    DXE_PERSIST_LIVE_CANARY=dx-live-canary
    DX_CONTAINER_NAME=dx-live-canary
    DX_RUNTIME=docker-ssh
    DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DX_PERSIST_STORAGE=host-path
    DX_PERSIST_HOST_ROOT=/fixture/share
    DX_NIX_VOLUME=dx-live-canary-nix
    DX_PERSIST_VOLUME=dx-live-canary-persist
    DX_BOOTSTRAP_VOLUME=dx-live-canary-bootstrap
    DX_IMAGE=dx-live-canary-image
    DX_SSH_KEY=/fixture/keys/dx-live-canary_key
    DX_SSH_KEY_PUB=/fixture/keys/dx-live-canary_key.pub
    DX_SSH_PORT=2224
    DX_CONTAINER_RESTART_POLICY=no
    DX_USAGE_SERVICE=off
    DX_PERSIST_HOST_MOUNT_SENTINEL=dxe-fixture-sentinel
    unset DXE_PERSIST_LIVE_ROLLBACK_VOLUME DXE_PERSIST_LIVE_BULK_MIB DXE_PERSIST_LIVE_INVENTORY_REAL DXE_PERSIST_LIVE_CLEANUP_ONLY
    unset DXE_PERSIST_LIVE_MIN_FREE_INODES
}

# guard_run [NAME=VALUE | -NAME]... -- the guard's stderr, then rc=<status>.
# PATH holds no executable at all, so any command the guard ran would fail.
guard_run() {
    (
        canary_env
        for change in "$@"; do
            case "$change" in
                -*) unset "${change#-}" ;;
                *) printf -v "${change%%=*}" '%s' "${change#*=}" ;;
            esac
        done
        # shellcheck disable=SC2123 # deliberately no command search path at all
        PATH="$SCRATCH/no-commands"
        { persist_migrate_live_guard >/dev/null; } 2>&1
        echo "rc=$?"
    )
}

out="$(guard_run)"
if [ "$out" = rc=0 ]; then
    test_pass "the guard accepts a complete canary profile silently, with no command on PATH"
else test_fail "the guard accepts a complete canary profile silently (got: $out)"; fi

expect_one_refusal() {
    local description="$1" message="$2" result
    shift 2
    result="$(guard_run "$@")"
    if has "$result" "rc=1" && has "$result" "Refusing: $message" && [ "$(count_refusals "$result")" = 1 ]; then
        test_pass "guard refuses $description with one line"
    else
        test_fail "guard refuses $description with one line (got: $result)"
    fi
}

expect_one_refusal "a missing opt-in (WP7.1's rule)" "DXE_PERSIST_LIVE_CANARY must equal DX_CONTAINER_NAME (dx-live-canary)" -DXE_PERSIST_LIVE_CANARY
expect_one_refusal "a volume-mode profile (WP7.1's rule: the profile stays host-path)" "DX_PERSIST_STORAGE must be host-path (got 'volume')." DX_PERSIST_STORAGE=volume
expect_one_refusal "a non-canary image (WP7.1's rule)" 'DX_IMAGE=dx-qnap-nixos does not contain "canary"' DX_IMAGE=dx-qnap-nixos
expect_one_refusal "the default SSH port (WP7.1's rule)" "DX_SSH_PORT=2222 is the default guest port" DX_SSH_PORT=2222
expect_one_refusal "a share root holding a comma" "DX_PERSIST_HOST_ROOT=/fixture/share,ro holds a comma" DX_PERSIST_HOST_ROOT=/fixture/share,ro
expect_one_refusal "a production rollback volume" "the rollback volume 'dx-qnap-persist-rollback' is not a canary volume name" DXE_PERSIST_LIVE_ROLLBACK_VOLUME=dx-qnap-persist-rollback
expect_one_refusal "an upper-case rollback volume" "the rollback volume 'dx-live-Canary-rb' is not a canary volume name" DXE_PERSIST_LIVE_ROLLBACK_VOLUME=dx-live-Canary-rb
expect_one_refusal "a rollback volume with a dot" "the rollback volume 'dx-live-canary.rb' is not a canary volume name" DXE_PERSIST_LIVE_ROLLBACK_VOLUME=dx-live-canary.rb
expect_one_refusal "the persist volume as the rollback volume" "the rollback volume 'dx-live-canary-persist' is DX_PERSIST_VOLUME" DXE_PERSIST_LIVE_ROLLBACK_VOLUME=dx-live-canary-persist
expect_one_refusal "the nix volume as the rollback volume" "the rollback volume 'dx-live-canary-nix' is DX_NIX_VOLUME" DXE_PERSIST_LIVE_ROLLBACK_VOLUME=dx-live-canary-nix
expect_one_refusal "the bootstrap volume as the rollback volume" "the rollback volume 'dx-live-canary-bootstrap' is DX_BOOTSTRAP_VOLUME" DXE_PERSIST_LIVE_ROLLBACK_VOLUME=dx-live-canary-bootstrap
for mib in 0 63 064 16385 99999999 abc 2048x -1; do
    expect_one_refusal "DXE_PERSIST_LIVE_BULK_MIB=$mib" "DXE_PERSIST_LIVE_BULK_MIB=$mib is not a whole number from 64 to 16384." "DXE_PERSIST_LIVE_BULK_MIB=$mib"
done
for mib in 64 2048 16384; do
    result="$(guard_run "DXE_PERSIST_LIVE_BULK_MIB=$mib")"
    if [ "$result" = rc=0 ]; then test_pass "guard accepts DXE_PERSIST_LIVE_BULK_MIB=$mib"
    else test_fail "guard accepts DXE_PERSIST_LIVE_BULK_MIB=$mib (got: $result)"; fi
done
# The inode floor: never below what a fresh guest store takes (WP7.2b).
for inodes in 0 599999 0700000 100000000 999999999999 abc 7e5 -1 "700 000" 700000x; do
    expect_one_refusal "DXE_PERSIST_LIVE_MIN_FREE_INODES='$inodes'" \
        "DXE_PERSIST_LIVE_MIN_FREE_INODES=$inodes is not a whole number from 600000 to 99999999" "DXE_PERSIST_LIVE_MIN_FREE_INODES=$inodes"
done
for inodes in 600000 700000 99999999; do
    result="$(guard_run "DXE_PERSIST_LIVE_MIN_FREE_INODES=$inodes")"
    if [ "$result" = rc=0 ]; then test_pass "guard accepts DXE_PERSIST_LIVE_MIN_FREE_INODES=$inodes"
    else test_fail "guard accepts DXE_PERSIST_LIVE_MIN_FREE_INODES=$inodes (got: $result)"; fi
done
for real in dx-host dx-test dx-qnap-persist-canary "dx-qnap " qnap; do
    expect_one_refusal "DXE_PERSIST_LIVE_INVENTORY_REAL='$real'" "DXE_PERSIST_LIVE_INVENTORY_REAL=$real is not dx-qnap" "DXE_PERSIST_LIVE_INVENTORY_REAL=$real"
done
result="$(guard_run DXE_PERSIST_LIVE_INVENTORY_REAL=dx-qnap)"
if [ "$result" = rc=0 ]; then test_pass "guard accepts the production-inventory opt-in DXE_PERSIST_LIVE_INVENTORY_REAL=dx-qnap"
else test_fail "guard accepts DXE_PERSIST_LIVE_INVENTORY_REAL=dx-qnap (got: $result)"; fi
expect_one_refusal "the production inventory combined with cleanup-only" "DXE_PERSIST_LIVE_INVENTORY_REAL and DXE_PERSIST_LIVE_CLEANUP_ONLY=1 are separate runs" \
    DXE_PERSIST_LIVE_INVENTORY_REAL=dx-qnap DXE_PERSIST_LIVE_CLEANUP_ONLY=1
result="$(guard_run DX_PERSIST_VOLUME=dx-qnap-persist)"
if has "$result" "rc=1" && has "$result" 'Refusing: DX_PERSIST_VOLUME=dx-qnap-persist does not contain "canary"' \
    && has "$result" "Refusing: the rollback volume 'dx-qnap-persist-rollback' is not a canary volume name" && [ "$(count_refusals "$result")" = 2 ]; then
    test_pass "a production persist volume is refused twice: itself (WP7.1) and the rollback name derived from it"
else test_fail "a production persist volume is refused twice (got: $result)"; fi
result="$(guard_run DXE_PERSIST_LIVE_CANARY=dx-qnap DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix \
    DX_PERSIST_VOLUME=dx-qnap-persist DX_BOOTSTRAP_VOLUME=dx-qnap-bootstrap DX_IMAGE=dx-qnap-nixos \
    DX_SSH_KEY=/fixture/keys/qnap DX_SSH_KEY_PUB=/fixture/keys/qnap.pub DX_SSH_PORT=2222 \
    DX_CONTAINER_RESTART_POLICY=unless-stopped DX_USAGE_SERVICE=on DX_PERSIST_STORAGE=volume)"
if has "$result" "rc=1" && [ "$(count_refusals "$result")" = 13 ]; then
    test_pass "a production-shaped profile is refused on every rule it breaks (13 lines)"
else test_fail "a production-shaped profile is refused on every rule it breaks (got $(count_refusals "$result"): $result)"; fi

# shellcheck disable=SC2034 # read by the two functions under test
(
    canary_env
    [ "$(persist_migrate_live_rollback_volume)" = dx-live-canary-persist-rollback ] || exit 1
    DXE_PERSIST_LIVE_ROLLBACK_VOLUME=dx-live-canary-rb
    [ "$(persist_migrate_live_rollback_volume)" = dx-live-canary-rb ] || exit 1
    [ "$(persist_migrate_live_bulk_mib)" = 2048 ] || exit 1
    DXE_PERSIST_LIVE_BULK_MIB=128
    [ "$(persist_migrate_live_bulk_mib)" = 128 ] || exit 1
    [ "$(persist_migrate_live_min_free_inodes)" = 700000 ] || exit 1
    DXE_PERSIST_LIVE_MIN_FREE_INODES=650000
    [ "$(persist_migrate_live_min_free_inodes)" = 650000 ]
) && test_pass "the rollback volume defaults to <DX_PERSIST_VOLUME>-rollback, the bulk size to 2048 MiB and the inode floor to 700000; each can be set" \
  || test_fail "the rollback volume, bulk size and inode floor defaults and overrides"

# --- recording runners ------------------------------------------------------------
# record_call FUNCTION [NAME=VALUE]... -- ARG...: runs FUNCTION over canary_env
# with a dxe_runtime_call that records each call (one argv word per line, a
# "--call--" line between calls), fails the calls named in FAIL_CALLS (and
# only the very first call when FAIL_FIRST_CALL=1) and
# prints CALL_ANSWER (when set) as each call's answer. PATH holds no command
# at all, or only RECORD_PATH (the text tools a runner parses with).
record_call() {
    local fn="$1" rc
    shift
    rm -f "$SCRATCH/calls" "$SCRATCH/call.err"
    (
        canary_env
        while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
            printf -v "${1%%=*}" '%s' "${1#*=}"
            shift
        done
        shift
        dxe_runtime_call() {
            printf '%s\n' "$@" >>"$SCRATCH/calls"
            printf -- '--call--\n' >>"$SCRATCH/calls"
            case " ${FAIL_CALLS:-} " in *" $1 "*) return 7 ;; esac
            local line n=0
            while IFS= read -r line; do [ "$line" != --call-- ] || n=$((n + 1)); done <"$SCRATCH/calls"
            if [ "${FAIL_FIRST_CALL:-}" = 1 ] && [ "$n" = 1 ]; then return 7; fi
            [ -z "${CALL_ANSWER+x}" ] || printf '%s\n' "$CALL_ANSWER"
            return 0
        }
        # shellcheck disable=SC2123 # no command search path: the runners make only the recorded call
        PATH="${RECORD_PATH:-$SCRATCH/no-commands}"
        "$fn" "$@" 2>"$SCRATCH/call.err"
    )
    rc=$?
    echo "rc=$rc"
}
calls() { cat "$SCRATCH/calls" 2>/dev/null; }
call_lines() { printf '%s\n' "$@"; printf -- '--call--\n'; }

expected="$(call_lines dx_runtime_run_ephemeral --rm --network none --user 0:0 --pull never --label dxe.role=persist-live \
    --mount type=bind,source=/fixture/share/dxe/dx-live-canary,target=/canary,readonly --entrypoint bash dx-live-canary-image \
    -c 'the script' bash /canary persist/dxe-live-seed)"
out="$(record_call persist_migrate_live_dir_read -- 'the script' persist/dxe-live-seed)"
if [ "$out" = rc=0 ] && [ "$(calls)" = "$expected" ]; then
    test_pass "dir_read: one root container, bash, the canary directory bound read-only, no -i"
else test_fail "dir_read: pinned argv (got $out: $(calls | tr '\n' ' '))"; fi
for change in DX_PERSIST_HOST_ROOT=/fixture/a,b DX_PERSIST_HOST_ROOT=/fixture/../etc DX_CONTAINER_NAME=dx-qnap DX_PERSIST_HOST_ROOT=/; do
    out="$(record_call persist_migrate_live_dir_read "$change" -- 'the script' persist)"
    if [ "$out" = rc=2 ] && [ -z "$(calls)" ] && grep -q '^Refusing: persist_migrate_live_dir_read' "$SCRATCH/call.err"; then
        test_pass "dir_read refuses ($change) with no container started"
    else test_fail "dir_read refuses ($change) with no container started (got $out: $(calls | tr '\n' ' '))"; fi
done

expected="$(call_lines dx_runtime_volume_owned dx-live-canary-persist "read (live suite)"; call_lines dx_runtime_run_ephemeral --rm --network none \
    --user 0:0 --pull never --label dxe.role=persist-live -v dx-live-canary-persist:/v:ro --entrypoint bash dx-live-canary-image \
    -c 'the script' bash /v dxe-live-seed)"
out="$(record_call persist_migrate_live_volume_read -- dx-live-canary-persist 'the script' dxe-live-seed)"
if [ "$out" = rc=0 ] && [ "$(calls)" = "$expected" ]; then
    test_pass "volume_read: the DQ6 check, then one container with the volume mounted :ro"
else test_fail "volume_read: pinned calls (got $out: $(calls | tr '\n' ' '))"; fi
out="$(FAIL_CALLS=dx_runtime_volume_owned record_call persist_migrate_live_volume_read -- dx-live-canary-persist 'the script' dxe-live-seed)"
if [ "$out" = rc=7 ] && [ "$(calls)" = "$(call_lines dx_runtime_volume_owned dx-live-canary-persist "read (live suite)")" ]; then
    test_pass "volume_read: a failed DQ6 check (an absent volume included) stops before any container"
else test_fail "volume_read: a failed DQ6 check stops before any container (got $out: $(calls | tr '\n' ' '))"; fi
expected="$(call_lines dx_runtime_volume_owned dx-live-canary-persist-rollback "read (live suite)")"
out="$(record_call persist_migrate_live_volume_read DX_PERSIST_VOLUME=dx-live-canary-persist-rollback -- dx-live-canary-persist-rollback 'the script' x)"
if [ "$out" = rc=0 ] && [ "$(calls | sed -n '1,3p')" = "$(printf '%s\n' "$expected" | sed -n '1,3p')" ] && has "$(calls)" "dx-live-canary-persist-rollback:/v:ro"; then
    test_pass "volume_read reads the rollback volume once it is the configured persist volume"
else test_fail "volume_read reads the configured rollback volume (got $out: $(calls | tr '\n' ' '))"; fi
for refusal in "dx-live-canary-persist-rollback" "dx-qnap-persist DX_PERSIST_VOLUME=dx-qnap-persist" \
    "dx-live-canary-nix DX_PERSIST_VOLUME=dx-live-canary-nix" "dx-live-canary-bootstrap DX_PERSIST_VOLUME=dx-live-canary-bootstrap" \
    "dx-live-canary-persist DX_IMAGE=dx-qnap-nixos" "/var/lib/x DX_PERSIST_VOLUME=/var/lib/x"; do
    volume="${refusal%% *}"
    change=""
    [ "$volume" = "$refusal" ] || change="${refusal#* }"
    if [ -n "$change" ]; then
        out="$(record_call persist_migrate_live_volume_read "$change" -- "$volume" 'the script' x)"
    else
        out="$(record_call persist_migrate_live_volume_read -- "$volume" 'the script' x)"
    fi
    if [ "$out" = rc=2 ] && [ -z "$(calls)" ] && grep -q '^Refusing: persist_migrate_live_volume_read' "$SCRATCH/call.err"; then
        test_pass "volume_read refuses ($refusal) with no call"
    else test_fail "volume_read refuses ($refusal) with no call (got $out: $(calls | tr '\n' ' '))"; fi
done

expected="$(call_lines dx_runtime_docker_ssh_exec sh -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" dxe-live-interrupt /nas/bin/docker \
    dxe-persist-copy-dxe-fixture-nas.invalid__dx-live-canary dx-live-canary-persist /fixture/real/dxe/dx-live-canary/persist dxe-live-bulk dxe-live-blob.bin 900 2147483648)"
out="$(record_call persist_migrate_live_interrupt -- /nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 900 2147483648)"
if [ "$out" = rc=0 ] && [ "$(calls)" = "$expected" ]; then
    test_pass "interrupt: one NAS-shell call running the watcher with the copy container name (WP6.4c), volume, canonical leaf and the bulk file's full size"
else test_fail "interrupt: pinned call (got $out: $(calls | sed -n '1,3p' | tr '\n' ' '))"; fi
for refusal in "docker /fixture/real/dxe/dx-live-canary/persist 900 2147483648" "/nas/my docker /fixture/real/dxe/dx-live-canary/persist 900 2147483648" \
    "/nas/bin/docker /fixture/real/dxe/dx-other-canary/persist 900 2147483648" "/nas/bin/docker /fixture/real/dxe/dx-live-canary 900 2147483648" \
    "/nas/bin/docker /fixture/a,b/dxe/dx-live-canary/persist 900 2147483648" "/nas/bin/docker /fixture/../dxe/dx-live-canary/persist 900 2147483648" \
    "/nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 9 2147483648" "/nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 3601 2147483648" \
    "/nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 0900 2147483648" "/nas/bin/docker /fixture/real/dxe/dx-live-canary/persist x 2147483648" \
    "/nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 900 0" "/nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 900 x" \
    "/nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 900"; do
    # shellcheck disable=SC2086 # three or four words on purpose (the docker path with a blank is the one case of five)
    case "$refusal" in
        "/nas/my docker "*) out="$(record_call persist_migrate_live_interrupt -- "/nas/my docker" /fixture/real/dxe/dx-live-canary/persist 900 2147483648)" ;;
        *) out="$(record_call persist_migrate_live_interrupt -- $refusal)" ;;
    esac
    if [ "$out" = rc=2 ] && [ -z "$(calls)" ] && grep -q '^Refusing: persist_migrate_live_interrupt' "$SCRATCH/call.err"; then
        test_pass "interrupt refuses ($refusal) with nothing run on the NAS"
    else test_fail "interrupt refuses ($refusal) with nothing run (got $out: $(calls | sed -n '1p'))"; fi
done
for change in DX_IMAGE=dx-qnap-nixos DX_PERSIST_VOLUME=dx-qnap-persist DX_CONTAINER_NAME=dx-qnap \
    "DX_REMOTE_HOST=dxe-fixture-nas.invalid host" "DX_REMOTE_HOST=dxe-fixture-nas.invalid;id" DX_REMOTE_HOST=dx.invalid@dxe-fixture-nas.invalid DX_REMOTE_HOST=; do
    out="$(record_call persist_migrate_live_interrupt "$change" -- /nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 900 2147483648)"
    if [ "$out" = rc=2 ] && [ -z "$(calls)" ] && [ "$(grep -c '^Refusing: ' "$SCRATCH/call.err")" = 1 ]; then
        test_pass "interrupt refuses $change with one line and nothing run on the NAS"
    else test_fail "interrupt refuses $change (got $out: $(cat "$SCRATCH/call.err"))"; fi
done

# --- the inode preflight's reads (WP7.2b) --------------------------------------------
# Only text tools on PATH: the reads parse their answer, and make no other call.
TEXT_TOOLS="$SCRATCH/text-tools"
mkdir -p "$TEXT_TOOLS"
for tool in awk tr; do ln -s "$(command -v "$tool")" "$TEXT_TOOLS/$tool"; done
RECORD_PATH="$TEXT_TOOLS"
out="$(CALL_ANSWER=$'/share/fixture/docker\r' record_call persist_migrate_live_docker_root --)"
if [ "$out" = "$(printf '/share/fixture/docker\nrc=0')" ] \
    && [ "$(calls)" = "$(call_lines dx_runtime_docker_cli info --format '{{.DockerRootDir}}')" ]; then
    test_pass "docker_root: one read-only docker info call; prints the Docker data root (CR dropped)"
else test_fail "docker_root: pinned call and answer (got $out: $(calls | tr '\n' ' '))"; fi
out="$(CALL_ANSWER=$'WARNING: something\n/share/fixture/docker\n' record_call persist_migrate_live_docker_root --)"
if [ "$out" = "$(printf '/share/fixture/docker\nrc=0')" ]; then
    test_pass "docker_root takes the answer's last non-empty line"
else test_fail "docker_root takes the last non-empty line (got $out)"; fi
for answer in "" "relative/docker" "/" "/share//docker" "/share/../docker"; do
    out="$(CALL_ANSWER="$answer" record_call persist_migrate_live_docker_root --)"
    if [ "$out" = rc=1 ] && grep -q '^Refusing: persist_migrate_live_docker_root' "$SCRATCH/call.err"; then
        test_pass "docker_root refuses the answer '$answer' (status 1, one line)"
    else test_fail "docker_root refuses the answer '$answer' (got $out)"; fi
done
out="$(FAIL_CALLS=dx_runtime_docker_cli record_call persist_migrate_live_docker_root --)"
if [ "$out" = rc=7 ]; then test_pass "docker_root passes a failed docker info call's status on"
else test_fail "docker_root passes a failed call's status on (got $out)"; fi

DF_GNU=$'Filesystem      Inodes   IUsed IFree IUse% Mounted on\n/dev/mapper/cachedev 1638400 1638357 43 100% /share/fixture'
DF_BUSYBOX=$'Filesystem           Inodes      Used Available Capacity Mounted on\n/dev/mapper/cachedev   1638400    938357    700043  57% /share/fixture'
out="$(CALL_ANSWER="$DF_GNU" record_call persist_migrate_live_inodes -- /share/fixture/docker)"
if [ "$out" = "$(printf '1638400 1638357 43\nrc=0')" ] && [ "$(calls)" = "$(call_lines dx_runtime_docker_ssh_exec df -P -i /share/fixture/docker)" ]; then
    test_pass "inodes: one read-only df -P -i call on the NAS; prints total, used and free (GNU df)"
else test_fail "inodes: pinned call and answer (got $out: $(calls | tr '\n' ' '))"; fi
out="$(CALL_ANSWER="$DF_BUSYBOX" record_call persist_migrate_live_inodes -- /share/fixture/docker)"
if [ "$out" = "$(printf '1638400 938357 700043\nrc=0')" ]; then
    test_pass "inodes parses busybox df -P -i too"
else test_fail "inodes parses busybox df (got $out)"; fi
for root in "" relative / "/a//b" "/a/./b"; do
    out="$(record_call persist_migrate_live_inodes -- "$root")"
    if [ "$out" = rc=2 ] && [ -z "$(calls)" ] && grep -q '^Refusing: persist_migrate_live_inodes' "$SCRATCH/call.err"; then
        test_pass "inodes refuses the root '$root' with nothing run on the NAS"
    else test_fail "inodes refuses the root '$root' (got $out: $(calls | tr '\n' ' '))"; fi
done
DF_BOTH="$(call_lines dx_runtime_docker_ssh_exec df -P -i /share/fixture/docker; call_lines dx_runtime_docker_ssh_exec df -i /share/fixture/docker)"
out="$(FAIL_FIRST_CALL=1 CALL_ANSWER="$DF_GNU" record_call persist_migrate_live_inodes -- /share/fixture/docker)"
if [ "$out" = "$(printf '1638400 1638357 43\nrc=0')" ] && [ "$(calls)" = "$DF_BOTH" ]; then
    test_pass "inodes falls back to a plain df -i (one more read-only call) only when df -P -i fails"
else test_fail "inodes falls back to df -i (got $out: $(calls | tr '\n' ' '))"; fi
out="$(FAIL_CALLS=dx_runtime_docker_ssh_exec record_call persist_migrate_live_inodes -- /share/fixture/docker)"
both="$(calls)"
out2="$(CALL_ANSWER="df: /share/fixture/docker: No such file or directory" record_call persist_migrate_live_inodes -- /share/fixture/docker)"
if [ "$out" = rc=1 ] && [ "$both" = "$DF_BOTH" ] && [ "$out2" = rc=1 ]; then
    test_pass "inodes fails (status 1, no numbers) when both df calls fail or the answer has no data line"
else test_fail "inodes fails on a failed or unparsable df ($out / $out2)"; fi
df_parse() { printf '%s\n' "$1" | persist_migrate_live_df_inodes; echo "rc=$?"; }
if [ "$(df_parse "$(printf '%s\n%s' "$DF_GNU" "/dev/sdb 10 5 5 50% /other")")" = rc=1 ] \
    && [ "$(df_parse $'Filesystem Inodes IUsed IFree IUse% Mounted on\nzpool 0 0 0 - /share/fixture')" = rc=1 ] \
    && [ "$(df_parse $'Filesystem Inodes IUsed IFree IUse% Mounted on\n/dev/x 1638400 - 43 100% /share/fixture')" = rc=1 ] \
    && [ "$(df_parse $'Filesystem Inodes IUsed IFree IUse% Mounted on\n/dev/x 1638400 1638357 43 100% /share/fixture\r')" = "$(printf '1638400 1638357 43\nrc=0')" ] \
    && [ "$(df_parse '')" = rc=1 ]; then
    test_pass "df_inodes refuses two data lines, a zero total, a non-number and an empty answer, and drops a CR"
else test_fail "df_inodes refusals"; fi

RECORD_PATH=""

# --- the controller-drop wrappers (WP7.2b) -----------------------------------------------
out="$(record_call persist_migrate_live_copy_name -- copy)"
out2="$(record_call persist_migrate_live_copy_name -- verify)"
if [ "$out" = "$(printf 'dxe-persist-copy-dxe-fixture-nas.invalid__dx-live-canary\nrc=0')" ] \
    && [ "$out2" = "$(printf 'dxe-persist-verify-dxe-fixture-nas.invalid__dx-live-canary\nrc=0')" ] && [ -z "$(calls)" ]; then
    test_pass "copy_name: WP6.4c's dxe-persist-copy-/dxe-persist-verify-<DX_REMOTE_HOST>__<DX_CONTAINER_NAME>, with no call"
else test_fail "copy_name ($out / $out2)"; fi
for refusal in "|lock" "|" "DX_REMOTE_HOST=dxe-fixture-nas.invalid;id|copy" "DX_REMOTE_HOST=|copy" "DX_REMOTE_HOST=dx.invalid@dxe-fixture-nas.invalid|verify" "DX_CONTAINER_NAME=dx-qnap|copy"; do
    change="${refusal%%|*}"
    if [ -n "$change" ]; then
        out="$(record_call persist_migrate_live_copy_name "$change" -- "${refusal#*|}")"
    else
        out="$(record_call persist_migrate_live_copy_name -- "${refusal#*|}")"
    fi
    if [ "$out" = rc=2 ] && grep -q '^Refusing: persist_migrate_live_copy_name' "$SCRATCH/call.err"; then
        test_pass "copy_name refuses ($refusal)"
    else test_fail "copy_name refuses ($refusal) (got $out)"; fi
done

expected="$(call_lines dx_runtime_docker_ssh_exec sh -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_COPY_WATCH" dxe-live-copy-watch /nas/bin/docker running \
    dxe-persist-copy-dxe-fixture-nas.invalid__dx-live-canary dxe-persist-verify-dxe-fixture-nas.invalid__dx-live-canary 900)"
out="$(record_call persist_migrate_live_copy_watch -- /nas/bin/docker running 900)"
if [ "$out" = rc=0 ] && [ "$(calls)" = "$expected" ]; then
    test_pass "copy_watch: one NAS-shell call running the read-only watcher with both WP6.4c names and the deadline"
else test_fail "copy_watch: pinned call (got $out: $(calls | sed -n '1,4p' | tr '\n' ' '))"; fi
out="$(record_call persist_migrate_live_copy_watch -- /nas/bin/docker gone 0)"
if [ "$out" = rc=0 ] && [ "$(calls | sed -n '7p;10p')" = "$(printf 'gone\n0')" ]; then
    test_pass "copy_watch passes the gone mode and a deadline of 0 (one look)"
else test_fail "copy_watch gone 0 (got $out: $(calls | tr '\n' ' '))"; fi
for refusal in "docker running 900" "/nas/bin/docker kill 900" "/nas/bin/docker running 3601" "/nas/bin/docker running 0900" \
    "/nas/bin/docker running -1" "/nas/bin/docker running x" "/nas/bin/docker running" "/nas/bin/docker"; do
    # shellcheck disable=SC2086 # the words of each case, on purpose
    out="$(record_call persist_migrate_live_copy_watch -- $refusal)"
    if [ "$out" = rc=2 ] && [ -z "$(calls)" ] && grep -q '^Refusing: persist_migrate_live_copy_watch' "$SCRATCH/call.err"; then
        test_pass "copy_watch refuses ($refusal) with nothing run on the NAS"
    else test_fail "copy_watch refuses ($refusal) (got $out: $(calls | sed -n '1p'))"; fi
done
for change in DX_CONTAINER_NAME=dx-qnap "DX_REMOTE_HOST=dxe-fixture-nas.invalid host"; do
    out="$(record_call persist_migrate_live_copy_watch "$change" -- /nas/bin/docker running 900)"
    if [ "$out" = rc=2 ] && [ -z "$(calls)" ]; then
        test_pass "copy_watch refuses $change with nothing run on the NAS"
    else test_fail "copy_watch refuses $change (got $out)"; fi
done

# --- script shape -----------------------------------------------------------------
for name in SCRIPT_LIST SCRIPT_RETIRED_ASIDE NAS_SCRIPT_INTERRUPT NAS_SCRIPT_COPY_WATCH; do
    var="PERSIST_MIGRATE_LIVE_$name"
    case "${!var}" in
        *"
"* | *"'"*) test_fail "$var is one line with no single quote (the NAS transport %q-quotes argv)" ;;
        *) test_pass "$var is one line with no single quote" ;;
    esac
done
case "$PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE" in
    "$PERSIST_LIVE_SCRIPT_PRELUDE"*) test_pass "PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE starts in the canary directory (WP7.1's prelude)" ;;
    *) test_fail "PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE starts in the canary directory (WP7.1's prelude)" ;;
esac
for name in GUEST_SEED GUEST_CHANGES GUEST_CHECK; do
    var="PERSIST_MIGRATE_LIVE_$name"
    case "${!var}" in
        *"'"*) test_fail "$var holds no single quote" ;;
        *) test_pass "$var holds no single quote" ;;
    esac
done

# The bare image (nixos/nix) has no sed and no awk. The container scripts run
# here with a PATH holding only links to the tools that image has.
BARE_TOOLS="$SCRATCH/bare-tools"
mkdir -p "$BARE_TOOLS"
for tool in ls grep stat mktemp find du df sort head cksum cat mv rm mkdir chmod ln rmdir readlink printf echo test; do
    tool_path="$(command -v "$tool" 2>/dev/null)"
    case "$tool_path" in /*) ln -s "$tool_path" "$BARE_TOOLS/$tool" ;; *) : ;; esac
done
for tool in sed awk tr cut; do
    if [ -e "$BARE_TOOLS/$tool" ]; then echo "bare tool dir must not hold $tool" >&2; exit 1; fi
done
BASH_BIN="$(command -v bash)"
SHELLS="sh"
if command -v dash >/dev/null 2>&1; then SHELLS="sh dash"; fi

# --- guest scripts on a temporary /persist ------------------------------------------
GUEST="$SCRATCH/guest/persist"
mkdir -p "$GUEST"
guest_run() { "$BASH_BIN" -c "$1" "$2" "$GUEST" "${@:3}"; }
check_state() { guest_run "$PERSIST_MIGRATE_LIVE_GUEST_CHECK" dxe-live-check "$1" tok-1 tok-2 "${2:-no}" 1048576; }
checks_ok() { [ "$1" = 0 ] && grep -Eq '^checks=[0-9]+ bad=0$' <<<"$2" && ! grep -q '^bad ' <<<"$2"; }

seed_out="$(guest_run "$PERSIST_MIGRATE_LIVE_GUEST_SEED" dxe-live-seed tok-1 1)"
seed_rc=$?
SOCKET="$(sed -n 's/^seeded=ok socket=\([a-z]*\) .*/\1/p' <<<"$seed_out")"
if [ "$seed_rc" = 0 ] && grep -Eq '^seeded=ok socket=(yes|no) bulk_bytes=1048576$' <<<"$seed_out" \
    && [ "$(wc -c <"$GUEST/dxe-live-bulk/dxe-live-blob.bin" | tr -d ' ')" = 1048576 ]; then
    test_pass "SEED builds the tree and a 1 MiB bulk file and reports socket=$SOCKET"
else test_fail "SEED builds the tree (rc $seed_rc: $seed_out)"; fi
out="$(check_state seeded "$SOCKET")"
rc=$?
if checks_ok "$rc" "$out"; then
    test_pass "CHECK seeded passes on the fresh seed ($(sed -n 's/^checks=\([0-9]*\).*/\1/p' <<<"$out") checks)"
else test_fail "CHECK seeded passes on the fresh seed (rc $rc: $(grep '^bad ' <<<"$out" | tr '\n' ' '))"; fi
out="$(check_state migrated "$SOCKET")"
rc=$?
if [ "$rc" != 0 ] && has "$out" "bad apple-top-dropped" && has "$out" "bad apple-deep-dropped" && [ "$(grep -c '^bad ' <<<"$out")" = 2 ]; then
    test_pass "CHECK migrated fails on the seed exactly on the two ._* files"
else test_fail "CHECK migrated fails exactly on the two ._* files (rc $rc: $(grep '^bad ' <<<"$out" | tr '\n' ' '))"; fi
out="$(guest_run "$PERSIST_MIGRATE_LIVE_GUEST_SEED" dxe-live-seed tok-1 1 2>&1)"
rc=$?
if [ "$rc" = 1 ] && has "$out" "already exists"; then
    test_pass "SEED refuses to seed over an existing tree"
else test_fail "SEED refuses to seed over an existing tree (rc $rc)"; fi
out="$(guest_run "$PERSIST_MIGRATE_LIVE_GUEST_SEED" dxe-live-seed tok-1 1x 2>&1)"
rc=$?
if [ "$rc" = 2 ]; then test_pass "SEED refuses a bad size"; else test_fail "SEED refuses a bad size (rc $rc)"; fi
out="$(guest_run "$PERSIST_MIGRATE_LIVE_GUEST_CHECK" dxe-live-check bogus tok-1 tok-2 no 1 2>&1)"
rc=$?
if [ "$rc" = 2 ]; then test_pass "CHECK refuses an unknown state"; else test_fail "CHECK refuses an unknown state (rc $rc)"; fi

# --- LIST (bash, bare tools only) ------------------------------------------------------
# A socket of our own (the seed's tmux may be missing here): perl is in the
# Linux coverage image and on macOS.
SOCK_MADE=no
if command -v perl >/dev/null 2>&1 && (cd "$GUEST/dxe-live-seed" && perl -MSocket -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $ARGV[0], Listen => 1) or exit 1' listing.sock) 2>/dev/null \
    && [ -S "$GUEST/dxe-live-seed/listing.sock" ]; then
    SOCK_MADE=yes
fi
list_run() { PATH="$BARE_TOOLS" "$BASH_BIN" -c "$PERSIST_MIGRATE_LIVE_SCRIPT_LIST" bash "$1" "$2"; }
LIST1="$(list_run "$SCRATCH/guest" persist/dxe-live-seed)"
list_rc=$?
LIST2="$(list_run "$SCRATCH/guest" persist/dxe-live-seed)"
record_of() { LV_P="$2" awk -F'\t' '$NF == ENVIRON["LV_P"]' <<<"$1"; }
records_n="$(($(printf '%s\n' "$LIST1" | wc -l) - 1))"
if [ "$list_rc" = 0 ] && [ "$LIST1" = "$LIST2" ] && [ "$(printf '%s\n' "$LIST1" | sed -n '$p')" = "$(printf 'end\t%s' "$records_n")" ]; then
    test_pass "LIST runs with only the bare image's tools, is deterministic and ends with end<TAB><records> ($records_n)"
else test_fail "LIST runs with only the bare image's tools (rc $list_rc; last: $(printf '%s\n' "$LIST1" | sed -n '$p'))"; fi
if [ "$(printf '%s\n' "$LIST1" | sed -n '1p' | awk -F'\t' '{ print $1 "|" $NF }')" = "d|." ] \
    && [ "$(printf '%s\n' "$LIST1" | sed '$d' | awk -F'\t' '{ print $NF }' | LC_ALL=C sort -c 2>&1; echo $?)" = 0 ]; then
    test_pass "LIST starts with the subtree root and is in bytewise path order"
else test_fail "LIST starts with the subtree root and is in bytewise path order"; fi
fields() { record_of "$LIST1" "$1" | awk -F'\t' -v cols="$2" 'BEGIN { n = split(cols, c, ",") } { s = ""; for (i = 1; i <= n; i++) s = s (i > 1 ? "|" : "") $c[i]; print s }'; }
crc_of() { cksum <"$1" | awk '{ print $1 }'; }
size_of() { wc -c <"$1" | tr -d ' '; }
ok_fields=true
check_fields() {
    local got
    got="$(fields "$1" "$2")"
    [ "$got" = "$3" ] || { ok_fields=false; echo "  $1 [$2]: got [$got], expected [$3]"; }
}
S="$GUEST/dxe-live-seed"
check_fields ./fifo 1,4,6,7,8,9 "p|-|1|-|-|-"
check_fields ./dangling 1,4,7,8,9 "l|14|-|-|does-not-exist"
check_fields ./link-to-dir 1,9 "l|nested"
check_fields ./hardlink-a 1,4,6,7,8 "f|6|3|$(crc_of "$S/hardlink-a")|./hardlink-a"
check_fields ./hardlink-b 6,8 "3|./hardlink-a"
check_fields ./nested/hardlink-c 6,8 "3|./hardlink-a"
check_fields ./app-state.txt 6,8 "1|-"
check_fields ./private 1,2,4,6 "d|700|-|-"
check_fields ./private/key 2,7 "600|$(crc_of "$S/private/key")"
check_fields ./empty-file 1,4 "f|0"
check_fields "./odd names/new\\nline" 1,4 "f|4"
check_fields "./odd names/tab\\tname" 1 "f"
check_fields "./odd names/back\\\\slash" 1 "f"
check_fields "./odd names/quote'single" 1 "f"
check_fields "./odd names/-leading-dash" 1 "f"
check_fields ./._dxe-live-meta 1 "f"
if [ "$SOCK_MADE" = yes ]; then check_fields ./listing.sock 1,4,7 "s|-|-"; fi
if $ok_fields; then
    test_pass "LIST records type, mode, size, links, checksum, hard-link group and target, and escapes odd names (newline, TAB, backslash)"
else test_fail "LIST records each entry's fields (see the lines above)"; fi
if [ "$(record_of "$LIST1" ./run.sh | awk -F'\t' '{ print $2 }')" = 755 ] && [ -n "$(record_of "$LIST1" ./run.sh | awk -F'\t' '$5 ~ /^[0-9]+$/')" ] \
    && [ "$(record_of "$LIST1" ./run.sh | awk -F'\t' '{ print $3 }')" = "$(stat -c %u:%g "$S/run.sh" 2>/dev/null || stat -f %u:%g "$S/run.sh")" ]; then
    test_pass "LIST records the numeric owner and the mtime in seconds"
else test_fail "LIST records the numeric owner and the mtime ($(record_of "$LIST1" ./run.sh))"; fi

# The listing helpers the suite compares with.
L="$SCRATCH/listing"
printf '%s\n' "$LIST1" >"$L.full"
sed '$d' "$L.full" >"$L.cut"
{ sed '1d' "$L.full"; } >"$L.short"
: >"$L.empty"
printf 'end\t0\n' >"$L.zero"
if persist_migrate_live_listing_ok "$L.full" && ! persist_migrate_live_listing_ok "$L.cut" && ! persist_migrate_live_listing_ok "$L.short" \
    && ! persist_migrate_live_listing_ok "$L.empty" && ! persist_migrate_live_listing_ok "$L.zero" && ! persist_migrate_live_listing_ok "$L.missing"; then
    test_pass "listing_ok accepts a complete listing only (not cut short, not a record short, not empty, not missing)"
else test_fail "listing_ok accepts a complete listing only"; fi
if [ "$(persist_migrate_live_records "$L.full")" = "$(printf '%s\n' "$LIST1" | sed '$d')" ] \
    && [ "$(( $(persist_migrate_live_records "$L.full" | wc -l) - $(persist_migrate_live_records_without_apple "$L.full" | wc -l) ))" = 2 ] \
    && ! persist_migrate_live_records_without_apple "$L.full" | awk -F'\t' '{ print $NF }' | grep -Fq '/._'; then
    test_pass "records_without_apple drops exactly the seed's two ._* records"
else test_fail "records_without_apple drops exactly the two ._* records"; fi
printf 'f\t1\t2\t3\t4\t5\t6\t-\t-\t%s\n' ./a._b ./x/.._y ./._z ./d/._e/f ./d/._e ./.dxe-live-blob.bin.Ab12Cd >"$L.synthetic"
printf 'end\t6\n' >>"$L.synthetic"
if [ "$(persist_migrate_live_records_without_apple "$L.synthetic" | awk -F'\t' '{ print $NF }' | tr '\n' ' ')" = "./a._b ./x/.._y ./.dxe-live-blob.bin.Ab12Cd " ]; then
    test_pass "records_without_apple drops a ._* name at any depth (and all below it), and nothing else"
else test_fail "records_without_apple drops ._* names at any depth only (got: $(persist_migrate_live_records_without_apple "$L.synthetic" | awk -F'\t' '{ print $NF }' | tr '\n' ' '))"; fi

# Each single change shows in exactly the records it touches.
list_diff() { diff <(printf '%s\n' "$LIST1") <(list_run "$SCRATCH/guest" persist/dxe-live-seed) | grep -c '^[<>]' || true; }
printf 'beta\n' >"$S/nested/modified.txt"
touch -r "$S/app-state.txt" "$S/nested/modified.txt" "$S/nested"
d_content="$(list_diff)"
chmod 0640 "$S/run.sh"
d_mode="$(($(list_diff) - d_content))"
mv "$S/to-rename.txt" "$S/renamed.txt"
d_rename="$(list_diff)"
if [ "$d_content" -ge 2 ] && [ "$d_mode" = 2 ] && [ "$d_rename" -gt "$((d_content + d_mode))" ]; then
    test_pass "LIST tells a content change, a mode change and a rename apart from an unchanged tree"
else test_fail "LIST detects a content change ($d_content), a mode change ($d_mode) and a rename ($d_rename)"; fi
mv "$S/renamed.txt" "$S/to-rename.txt"
chmod 0755 "$S/run.sh"
printf 'before\n' >"$S/nested/modified.txt"

out="$(list_run "$SCRATCH/guest" ../guest 2>&1)"
rc=$?
list_run "$SCRATCH/guest" /etc >/dev/null 2>&1
rc2=$?
list_run "$SCRATCH/guest" persist/no-such-tree >/dev/null 2>&1
rc3=$?
if [ "$rc" = 2 ] && [ "$rc2" = 2 ] && [ "$rc3" != 0 ]; then
    test_pass "LIST refuses a subtree with .. or an absolute one, and fails on a missing one"
else test_fail "LIST refuses bad subtrees (rc $rc/$rc2/$rc3)"; fi
mkdir -p "$S/locked/inner"
chmod 000 "$S/locked"
out="$(list_run "$SCRATCH/guest" persist/dxe-live-seed 2>&1)"
rc=$?
chmod 0755 "$S/locked"
rmdir "$S/locked/inner" "$S/locked"
if [ "$(id -u)" = 0 ]; then
    echo "  (LIST read-error case: running as root, which reads a mode-000 directory; not asserted)"
elif [ "$rc" != 0 ]; then
    test_pass "LIST fails (non-zero) when part of the tree cannot be read, never a partial listing"
else test_fail "LIST fails when part of the tree cannot be read (rc $rc)"; fi
[ "$SOCK_MADE" = no ] || rm -f "$S/listing.sock"

# --- CHANGES and the later CHECK states -------------------------------------------------
# Stand in for the migration's ._* drop, then the guest's changes.
rm -f "$S/._dxe-live-meta" "$S/nested/deeper/._deep-meta"
out="$(check_state migrated "$SOCKET")"
rc=$?
if checks_ok "$rc" "$out"; then test_pass "CHECK migrated passes once the two ._* files are gone"
else test_fail "CHECK migrated passes once the ._* files are gone (rc $rc: $(grep '^bad ' <<<"$out" | tr '\n' ' '))"; fi
out="$(guest_run "$PERSIST_MIGRATE_LIVE_GUEST_CHANGES" dxe-live-changes tok-2)"
rc=$?
if [ "$rc" = 0 ] && [ "$out" = changed=ok ] && [ ! -e "$S/hardlink-b" ] && [ ! -e "$S/nested/to-delete.txt" ] \
    && [ "$(cat "$S/renamed.txt")" = "to rename" ] && [ -f "$S/dir-renamed/inner/file.txt" ] && [ -f "$S/._rollback-meta" ]; then
    test_pass "CHANGES writes, overwrites, deletes a file and a hard link, renames a file and a directory, and drops in a ._* file"
else test_fail "CHANGES makes its changes (rc $rc: $out)"; fi
out="$(check_state changed-dir "$SOCKET")"
rc=$?
if checks_ok "$rc" "$out"; then test_pass "CHECK changed-dir passes after the changes"
else test_fail "CHECK changed-dir passes after the changes (rc $rc: $(grep '^bad ' <<<"$out" | tr '\n' ' '))"; fi
out="$(check_state changed-volume "$SOCKET")"
rc=$?
if [ "$rc" != 0 ] && [ "$(grep '^bad ' <<<"$out")" = "bad apple-new-dropped" ]; then
    test_pass "CHECK changed-volume fails while the new ._* file is there, on that check alone"
else test_fail "CHECK changed-volume fails only on the new ._* file (rc $rc: $(grep '^bad ' <<<"$out" | tr '\n' ' '))"; fi
rm -f "$S/._rollback-meta"
out="$(check_state changed-volume "$SOCKET")"
rc=$?
if checks_ok "$rc" "$out"; then test_pass "CHECK changed-volume passes once the rollback dropped it"
else test_fail "CHECK changed-volume passes once the ._* file is gone (rc $rc)"; fi
out="$(check_state seeded "$SOCKET")"
rc=$?
if [ "$rc" != 0 ] && has "$out" "bad hardlink-count" && has "$out" "bad to-delete-present" && has "$out" "bad modified-before"; then
    test_pass "CHECK seeded fails after the changes (it tells the states apart)"
else test_fail "CHECK seeded fails after the changes (rc $rc)"; fi
out="$(guest_run "$PERSIST_MIGRATE_LIVE_GUEST_CHANGES" dxe-live-changes tok-2 2>&1)"
rc=$?
if [ "$rc" != 0 ]; then test_pass "CHANGES fails instead of guessing when its sources are gone (a second run)"
else test_fail "CHANGES fails when its sources are gone (rc $rc)"; fi

# --- RETIRED_ASIDE (sh/dash, bare tools) and the partial-copy helpers ----------------------------
CASE_N=0
CANARY=""
new_canary() {
    local base
    CASE_N=$((CASE_N + 1))
    base="$SCRATCH/case-$CASE_N"
    mkdir -p "$base/canary/persist/dxe-live-bulk" "$base/outside"
    printf 'schema=1\nguest=dx-live-canary\nstate=%s\nsource-volume=dx-live-canary-persist\ncreated-at=2026-10-12T01:02:03Z\n' "${1:-ready}" \
        >"$base/canary/persist/.dxe-persist-dir"
    printf 'blob\n' >"$base/canary/persist/dxe-live-bulk/dxe-live-blob.bin"
    printf 'keep\n' >"$base/outside/keep.txt"
    CANARY="$base/canary"
}
run_script() {
    local shell="$1" canary="$2" script="$3"
    shift 3
    case "$canary" in
        "$SCRATCH"/case-*/canary) : ;;
        *) echo "refusing to run a script outside the scratch area: $canary" >&2; return 99 ;;
    esac
    PATH="$BARE_TOOLS" "$(command -v "$shell")" -c "$script" sh "$canary" "$@"
}
outside_ok() { [ "$(cat "${1%/canary}/outside/keep.txt")" = keep ] && [ "$(ls -A "${1%/canary}/outside")" = keep.txt ]; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# The partial-copy helpers, on a real LIST of a bulk directory: the blob part-way
# under its own name (rsync --inplace), next to one rsync temp file of it and
# names that only look like one.
new_canary
c="$CANARY"
b="$c/persist/dxe-live-bulk"
printf 'part' >"$b/dxe-live-blob.bin"
printf 'partial\n' >"$b/.dxe-live-blob.bin.Ab12Cd"
printf 'other\n' >"$b/.dxe-live-blob.bin.toolong7"
printf 'other\n' >"$b/.other-file.Ab12Cd"
ln -s dxe-live-blob.bin "$b/.dxe-live-blob.bin.SyMlNk"
PATH="$BARE_TOOLS" "$BASH_BIN" -c "$PERSIST_MIGRATE_LIVE_SCRIPT_LIST" bash "$c" persist/dxe-live-bulk >"$SCRATCH/partial.list"
rec="$(LV_P=./dxe-live-blob.bin awk -F'\t' '$NF == ENVIRON["LV_P"]' "$SCRATCH/partial.list")"
if persist_migrate_live_listing_ok "$SCRATCH/partial.list" && persist_migrate_live_partial_record "$rec" 4096 \
    && ! persist_migrate_live_partial_record "$rec" 4 && ! persist_migrate_live_partial_record "$rec" 3 && ! persist_migrate_live_partial_record "" 4096 \
    && ! persist_migrate_live_partial_record "$(LV_P=./.dxe-live-blob.bin.SyMlNk awk -F'\t' '$NF == ENVIRON["LV_P"]' "$SCRATCH/partial.list")" 4096 \
    && ! persist_migrate_live_partial_record "$(LV_P=. awk -F'\t' '$NF == ENVIRON["LV_P"]' "$SCRATCH/partial.list")" 4096; then
    test_pass "partial_record: a regular file below its full size only (not at or above it, not missing, not a symlink, not a directory)"
else test_fail "partial_record: a regular file below its full size only (record: $rec)"; fi
if [ "$(persist_migrate_live_temp_count "$SCRATCH/partial.list")" = 1 ]; then
    test_pass "temp_count counts exactly rsync's regular temp file of the blob (not a longer name, another file's, or a symlink)"
else test_fail "temp_count counts exactly the temp file (got $(persist_migrate_live_temp_count "$SCRATCH/partial.list"))"; fi
rm -f "$b/.dxe-live-blob.bin.Ab12Cd"
PATH="$BARE_TOOLS" "$BASH_BIN" -c "$PERSIST_MIGRATE_LIVE_SCRIPT_LIST" bash "$c" persist/dxe-live-bulk >"$SCRATCH/partial.list"
if [ "$(persist_migrate_live_temp_count "$SCRATCH/partial.list")" = 0 ]; then
    test_pass "temp_count is 0 once no temp file is there"
else test_fail "temp_count is 0 with no temp file"; fi

for sh_name in $SHELLS; do
    new_canary retired
    c="$CANARY"
    out="$(run_script "$sh_name" "$c" "$PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE" dx-live-canary 20261012T010203Z 2>&1)"
    rc=$?
    if [ "$rc" = 0 ] && [ ! -e "$c/persist" ] && [ -f "$c/persist.retired-20261012T010203Z/.dxe-persist-dir" ] \
        && [ "$(cat "$c/persist.retired-20261012T010203Z/dxe-live-bulk/dxe-live-blob.bin")" = blob ] && outside_ok "$c" \
        && [ "$(ls -A "$c")" = persist.retired-20261012T010203Z ]; then
        test_pass "[$sh_name] RETIRED_ASIDE moves a retired leaf to persist.retired-<stamp> and deletes nothing"
    else test_fail "[$sh_name] RETIRED_ASIDE moves a retired leaf (rc $rc: $out)"; fi
    for state in ready copying; do
        new_canary "$state"
        c="$CANARY"
        run_script "$sh_name" "$c" "$PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE" dx-live-canary 20261012T010203Z >/dev/null 2>&1
        rc=$?
        if [ "$rc" = 1 ] && [ -f "$c/persist/.dxe-persist-dir" ] && [ "$(ls -A "$c")" = persist ]; then
            test_pass "[$sh_name] RETIRED_ASIDE leaves a $state leaf where it is"
        else test_fail "[$sh_name] RETIRED_ASIDE leaves a $state leaf where it is (rc $rc)"; fi
    done
    new_canary retired
    c="$CANARY"
    run_script "$sh_name" "$c" "$PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE" dx-other-canary 20261012T010203Z >/dev/null 2>&1
    rc_other=$?
    printf 'guest=dx-other-canary\n' >>"$c/persist/.dxe-persist-dir"
    run_script "$sh_name" "$c" "$PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE" dx-live-canary 20261012T010203Z >/dev/null 2>&1
    rc_two=$?
    run_script "$sh_name" "$c" "$PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE" dx-live-canary 2026-10-12 >/dev/null 2>&1
    rc_stamp=$?
    if [ "$rc_other" = 1 ] && [ "$rc_two" = 1 ] && [ "$rc_stamp" = 2 ] && [ "$(ls -A "$c")" = persist ]; then
        test_pass "[$sh_name] RETIRED_ASIDE refuses another guest's marker, a marker naming two guests and a bad stamp"
    else test_fail "[$sh_name] RETIRED_ASIDE refusals ($rc_other/$rc_two/$rc_stamp)"; fi
    new_canary retired
    c="$CANARY"
    mkdir "$c/persist.retired-20261012T010203Z"
    run_script "$sh_name" "$c" "$PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE" dx-live-canary 20261012T010203Z >/dev/null 2>&1
    rc_taken=$?
    mv "$c/persist" "$c/real-leaf"
    ln -s real-leaf "$c/persist"
    run_script "$sh_name" "$c" "$PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE" dx-live-canary 20261012T010204Z >/dev/null 2>&1
    rc_link=$?
    if [ "$rc_taken" = 1 ] && [ "$rc_link" = 1 ] && [ -L "$c/persist" ] && [ -d "$c/real-leaf" ] && [ -z "$(ls -A "$c/persist.retired-20261012T010203Z")" ]; then
        test_pass "[$sh_name] RETIRED_ASIDE refuses a taken target name and a symlinked leaf"
    else test_fail "[$sh_name] RETIRED_ASIDE refuses a taken target and a symlink ($rc_taken/$rc_link)"; fi
done

# --- the NAS-side interrupt watcher (sh/dash, fake docker) ----------------------------------
# The fake docker answers from a state directory and records every call:
#   started            exists once the "copy" has started (ps lists candidates)
#   ids                the candidate ids ps prints once started
#   inspect-<id>       what --format "{{.Path}}|..." prints for <id>
#   running-<id>       exists while <id> runs ({{.State.Running}} -> true)
#   exists-<id>        exists until <id> is removed (plain inspect)
#   no-kill            makes `kill` fail
#   keep-after-kill    keeps exists-<id> after a kill (--rm never removes it)
# The fake sleep counts its calls; on call 2 the copy starts, on call 4 the
# blob appears part-way under its own name (BLOB_AT overrides; BLOB_BYTES is
# its content, default the 7 bytes "partial", of a full size FULL, default
# 4096), so the watcher must wait for both. The copy runs rsync --inplace
# (WP6.4c): there is no temp file, the blob itself grows.
WATCH="$SCRATCH/watch"
mkdir -p "$WATCH/bin"
cat >"$WATCH/bin/docker" <<'EOF'
#!/bin/sh
st="$WATCH_STATE"
printf '%s\n' "$*" >>"$st/calls"
case "$1" in
    ps)
        [ -e "$st/started" ] || exit 0
        cat "$st/ids" ;;
    inspect)
        if [ "$2" = --format ]; then
            case "$3" in
                *.State.Running*) [ -e "$st/exists-$4" ] || exit 1; if [ -e "$st/running-$4" ]; then echo true; else echo false; fi ;;
                *) [ -e "$st/inspect-$4" ] || exit 1; cat "$st/inspect-$4" ;;
            esac
        else
            [ -e "$st/exists-$2" ]
        fi ;;
    kill)
        [ ! -e "$st/no-kill" ] || exit 1
        rm -f "$st/running-$2"
        [ -e "$st/keep-after-kill" ] || rm -f "$st/exists-$2" ;;
    *) exit 9 ;;
esac
EOF
cat >"$WATCH/bin/sleep" <<'EOF'
#!/bin/sh
st="$WATCH_STATE"
n=$(cat "$st/sleeps" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$st/sleeps"
[ "$n" -lt 2 ] || : >"$st/started"
if [ "$n" -ge "${BLOB_AT:-4}" ] && [ -n "${BLOB_FILE:-}" ]; then printf "%s" "${BLOB_BYTES-partial}" >"$BLOB_FILE"; fi
exit 0
EOF
chmod +x "$WATCH/bin/docker" "$WATCH/bin/sleep"
ln -s "$(command -v date)" "$WATCH/bin/date"
# A NAS whose sleep takes whole seconds only (QTS's may): this fake sleep
# refuses a fraction, logs every call, starts the copy on its first accepted
# call and makes the blob appear part-way on its third.
mkdir -p "$WATCH/bin-int"
ln -s "$WATCH/bin/docker" "$WATCH/bin-int/docker"
ln -s "$(command -v date)" "$WATCH/bin-int/date"
cat >"$WATCH/bin-int/sleep" <<'EOF'
#!/bin/sh
st="$WATCH_STATE"
case "$1" in *.*) printf "rejected %s\n" "$1" >>"$st/sleep-log"; echo "sleep: invalid number $1" >&2; exit 1 ;; esac
printf "%s\n" "$1" >>"$st/sleep-log"
n=$(cat "$st/sleeps" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$st/sleeps"
: >"$st/started"
if [ "$n" -ge 3 ] && [ -n "${BLOB_FILE:-}" ]; then printf "%s" partial >"$BLOB_FILE"; fi
exit 0
EOF
chmod +x "$WATCH/bin-int/sleep"
RSYNC_BIN="$PERSIST_MIGRATE_LIVE_RSYNC_BIN"
LEAF="$SCRATCH/watch-share/dxe/dx-live-canary/persist"
BULK="$LEAF/dxe-live-bulk"
COPY_NAME=dxe-persist-copy-dxe-fixture-nas.invalid__dx-live-canary
COPY_ID=aaaaaaaaaaaa1111111111111111111111111111111111111111111111111111
INV_ID=bbbbbbbbbbbb2222222222222222222222222222222222222222222222222222
OTHER_ID=cccccccccccc3333333333333333333333333333333333333333333333333333
SECOND_ID=dddddddddddd4444444444444444444444444444444444444444444444444444

# watch_setup NAME: a fresh state directory with the three usual candidates,
# and no blob, temp file or link in the bulk directory.
watch_setup() {
    WS="$WATCH/state-$1"
    mkdir -p "$WS"
    in_scratch "$WS" || exit 1
    mkdir -p "$BULK"
    in_scratch "$BULK" || exit 1
    rm -f "$BULK/dxe-live-blob.bin" "$BULK/elsewhere-partial" "$BULK/".dxe-live-blob.bin.*
    printf '%s\n%s\n%s\n' "$INV_ID" "$OTHER_ID" "$COPY_ID" >"$WS/ids"
    printf '%s|-aH --numeric-ids --inplace --modify-window=-1 -A -X --exclude=/.dxe-persist-dir --exclude=._* /src/ /dst/ |/nix=/x;/dst=%s;/src=/var/lib/docker/volumes/v/_data;\n' "$RSYNC_BIN" "$LEAF" >"$WS/inspect-$COPY_ID"
    printf 'sh|-c script sh /v |/v=/var/lib/docker/volumes/v/_data;\n' >"$WS/inspect-$INV_ID"
    printf '%s|-aH --numeric-ids --inplace --modify-window=-1 --exclude=/.dxe-persist-dir --exclude=._* /src/ /dst/ |/dst=%s/elsewhere;/src=/y;\n' "$RSYNC_BIN" "$LEAF" >"$WS/inspect-$OTHER_ID"
    for id in "$COPY_ID" "$INV_ID" "$OTHER_ID"; do : >"$WS/running-$id"; : >"$WS/exists-$id"; done
}
watch_run() {
    local shell="$1" deadline="$2"
    WATCH_STATE="$WS" BLOB_FILE="${BLOB_FILE-$BULK/dxe-live-blob.bin}" PATH="${WATCH_BIN:-$WATCH/bin}:$BARE_TOOLS" \
        "$(command -v "$shell")" -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" dxe-live-interrupt "$WATCH/bin/docker" \
        "$COPY_NAME" dx-live-canary-persist "${WATCH_LEAF:-$LEAF}" dxe-live-bulk dxe-live-blob.bin "$deadline" "${FULL:-4096}"
}
kills() { grep -c '^kill ' "$WS/calls" 2>/dev/null || true; }
# no_trigger LABEL: the copy ended (not running) and nothing in the bulk
# directory counted as the blob part-way: status 3, nothing killed.
no_trigger() {
    if [ "$rc" = 3 ] && [ "$(kills)" = 0 ]; then test_pass "$1: status 3 and nothing killed"
    else test_fail "$1 (rc $rc, kills $(kills))"; fi
}

for sh_name in $SHELLS; do
    watch_setup "happy-$sh_name"
    out="$(watch_run "$sh_name" 60 2>"$WS/err")"
    rc=$?
    expected="$(printf 'copy=%s\ninterrupted=%s bytes=7\ngone=%s' "${COPY_ID:0:12}" "${COPY_ID:0:12}" "${COPY_ID:0:12}")"
    if [ "$rc" = 0 ] && [ "$out" = "$expected" ] && [ "$(kills)" = 1 ] && grep -qx "kill $COPY_ID" "$WS/calls" \
        && [ -e "$WS/running-$INV_ID" ] && [ -e "$WS/running-$OTHER_ID" ] && [ "$(cat "$WS/sleeps")" -ge 4 ]; then
        test_pass "[$sh_name] the watcher waits for the copy and for the blob part-way under its own name, then kills exactly the one copy container (not the inventory, not another destination's rsync)"
    else test_fail "[$sh_name] the watcher kills exactly the copy container (rc $rc: $out; $(tr '\n' ' ' <"$WS/err"))"; fi
    if grep -Fqx "ps -q --no-trunc --filter name=^/$COPY_NAME\$ --filter volume=dx-live-canary-persist --filter status=running" "$WS/calls" \
        && awk '$1 != "ps" && $1 != "inspect" && $1 != "kill" { bad = 1 } END { exit bad }' "$WS/calls"; then
        test_pass "[$sh_name] the watcher only lists (the copy container's name, volume, running), inspects and kills"
    else test_fail "[$sh_name] the watcher's docker calls ($(sort -u "$WS/calls" | cut -c1-60 | tr '\n' ' '))"; fi

    watch_setup "two-$sh_name"
    printf '%s\n' "$SECOND_ID" >>"$WS/ids"
    cp "$WS/inspect-$COPY_ID" "$WS/inspect-$SECOND_ID"
    : >"$WS/running-$SECOND_ID"
    : >"$WS/exists-$SECOND_ID"
    watch_run "$sh_name" 60 >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 6 ] && [ "$(kills)" = 0 ]; then
        test_pass "[$sh_name] two matching copy containers: status 6 and nothing killed"
    else test_fail "[$sh_name] two matching copy containers (rc $rc, kills $(kills))"; fi

    watch_setup "none-$sh_name"
    : >"$WS/started"
    printf '%s\n%s\n' "$INV_ID" "$OTHER_ID" >"$WS/ids"
    watch_run "$sh_name" 0 >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 2 ] && [ "$(kills)" = 0 ]; then
        test_pass "[$sh_name] no copy container before the deadline: status 2 and nothing killed"
    else test_fail "[$sh_name] no copy container before the deadline (rc $rc, kills $(kills))"; fi

    watch_setup "ended-$sh_name"
    rm -f "$WS/running-$COPY_ID"
    BLOB_FILE="" watch_run "$sh_name" 60 >/dev/null 2>&1
    rc=$?
    no_trigger "[$sh_name] the copy ends before the blob is seen part-way"

    watch_setup "symlink-$sh_name"
    printf partial >"$BULK/elsewhere-partial"
    ln -s elsewhere-partial "$BULK/dxe-live-blob.bin"
    rm -f "$WS/running-$COPY_ID"
    BLOB_FILE="" watch_run "$sh_name" 60 >/dev/null 2>&1
    rc=$?
    rm -f "$BULK/dxe-live-blob.bin" "$BULK/elsewhere-partial"
    no_trigger "[$sh_name] a symlink at the blob's name is no trigger"

    watch_setup "empty-$sh_name"
    rm -f "$WS/running-$COPY_ID"
    BLOB_BYTES="" watch_run "$sh_name" 60 >/dev/null 2>&1
    rc=$?
    no_trigger "[$sh_name] an empty blob (rsync has only created it) is no trigger"

    watch_setup "complete-$sh_name"
    rm -f "$WS/running-$COPY_ID"
    FULL=7 watch_run "$sh_name" 60 >/dev/null 2>&1
    rc=$?
    no_trigger "[$sh_name] a blob already at its full size is no trigger"

    watch_setup "tempfile-$sh_name"
    printf partial >"$BULK/.dxe-live-blob.bin.Zz9Yy8"
    rm -f "$WS/running-$COPY_ID"
    BLOB_FILE="" watch_run "$sh_name" 60 >/dev/null 2>&1
    rc=$?
    rm -f "$BULK/.dxe-live-blob.bin.Zz9Yy8"
    no_trigger "[$sh_name] an rsync temp file of the blob is no trigger (the copy runs --inplace)"

    watch_setup "unreadable-$sh_name"
    chmod 000 "$BULK"
    BLOB_FILE="" watch_run "$sh_name" 60 >/dev/null 2>&1
    rc=$?
    chmod 0755 "$BULK"
    if [ "$(id -u)" = 0 ]; then
        echo "  (watcher unreadable-directory case: running as root, which lists a mode-000 directory; not asserted)"
    elif [ "$rc" = 7 ] && [ "$(kills)" = 0 ]; then
        test_pass "[$sh_name] a destination this account cannot list is status 7 and nothing killed"
    else test_fail "[$sh_name] a destination this account cannot list (rc $rc, kills $(kills))"; fi

    watch_setup "nokill-$sh_name"
    : >"$WS/no-kill"
    watch_run "$sh_name" 60 >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 4 ]; then test_pass "[$sh_name] a failed docker kill is status 4"
    else test_fail "[$sh_name] a failed docker kill is status 4 (rc $rc)"; fi

    watch_setup "stays-$sh_name"
    : >"$WS/started"
    : >"$WS/keep-after-kill"
    BLOB_AT=1 watch_run "$sh_name" 0 >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 5 ] && [ "$(kills)" = 1 ]; then test_pass "[$sh_name] a killed container that does not go away is status 5"
    else test_fail "[$sh_name] a killed container that does not go away (rc $rc, kills $(kills))"; fi

    watch_setup "elsewhere-$sh_name"
    : >"$WS/started"
    WATCH_LEAF="$SCRATCH/watch-share/dxe/dx-live-canary/other/persist" watch_run "$sh_name" 0 >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 2 ] && [ "$(kills)" = 0 ]; then
        test_pass "[$sh_name] a copy into another destination is never a match"
    else test_fail "[$sh_name] a copy into another destination is never a match (rc $rc)"; fi

    watch_setup "intsleep-$sh_name"
    WATCH_BIN="$WATCH/bin-int" watch_run "$sh_name" 5 >"$WS/out" 2>"$WS/err"
    rc=$?
    accepted="$(grep -vc '^rejected ' "$WS/sleep-log" 2>/dev/null || true)"
    whole="$(awk '$0 == "1" { n++ } END { print n + 0 }' "$WS/sleep-log" 2>/dev/null)"
    running_checks="$(awk '$1 == "inspect" && $3 ~ /State\.Running/ { n++ } END { print n + 0 }' "$WS/calls" 2>/dev/null)"
    if [ "$rc" = 0 ] && [ "$(kills)" = 1 ] && grep -qx 'rejected 0.05' "$WS/sleep-log" && [ "$accepted" = 3 ] && [ "$whole" = 3 ] \
        && [ "$running_checks" -ge 1 ] && [ "$running_checks" -lt "$accepted" ]; then
        test_pass "[$sh_name] with a sleep that takes whole seconds only, the watcher sleeps 1 s between polls (no busy loop) and still kills the copy"
    else test_fail "[$sh_name] whole-second sleep: no busy loop (rc $rc, kills $(kills), sleeps $(tr '\n' ' ' <"$WS/sleep-log" 2>/dev/null), running checks $running_checks; $(tr '\n' ' ' <"$WS/err"))"; fi

    watch_setup "noinplace-$sh_name"
    printf '%s|-aH --numeric-ids -A -X --exclude=/.dxe-persist-dir --exclude=._* /src/ /dst/ |/nix=/x;/dst=%s;/src=/var/lib/docker/volumes/v/_data;\n' "$RSYNC_BIN" "$LEAF" >"$WS/inspect-$COPY_ID"
    watch_run "$sh_name" 60 >"$WS/out" 2>"$WS/err"
    rc=$?
    if [ "$rc" = 8 ] && [ "$(kills)" = 0 ] && grep -q 'without --inplace' "$WS/err"; then
        test_pass "[$sh_name] a copy whose rsync runs without --inplace (no WP6.4c) is status 8 and nothing killed"
    else test_fail "[$sh_name] a copy without --inplace (rc $rc, kills $(kills); $(tr '\n' ' ' <"$WS/err"))"; fi

    watch_setup "args-$sh_name"
    rc_list=""
    for bad in "relative-docker" "deadline" "dst" "full" "name"; do
        case "$bad" in
            relative-docker) WATCH_STATE="$WS" PATH="$WATCH/bin:$BARE_TOOLS" "$(command -v "$sh_name")" -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" x docker "$COPY_NAME" v "$LEAF" b f 60 4096 >/dev/null 2>&1 ;;
            deadline) WATCH_STATE="$WS" PATH="$WATCH/bin:$BARE_TOOLS" "$(command -v "$sh_name")" -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" x "$WATCH/bin/docker" "$COPY_NAME" v "$LEAF" b f 6x 4096 >/dev/null 2>&1 ;;
            dst) WATCH_STATE="$WS" PATH="$WATCH/bin:$BARE_TOOLS" "$(command -v "$sh_name")" -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" x "$WATCH/bin/docker" "$COPY_NAME" v /fixture/x b f 60 4096 >/dev/null 2>&1 ;;
            full) WATCH_STATE="$WS" PATH="$WATCH/bin:$BARE_TOOLS" "$(command -v "$sh_name")" -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" x "$WATCH/bin/docker" "$COPY_NAME" v "$LEAF" b f 60 0 >/dev/null 2>&1 ;;
            name) WATCH_STATE="$WS" PATH="$WATCH/bin:$BARE_TOOLS" "$(command -v "$sh_name")" -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" x "$WATCH/bin/docker" dx-live-canary-image v "$LEAF" b f 60 4096 >/dev/null 2>&1 ;;
        esac
        rc_list="$rc_list$?"
    done
    if [ "$rc_list" = 11111 ] && [ ! -e "$WS/calls" ]; then
        test_pass "[$sh_name] the watcher refuses a relative docker path, a bad deadline, a bad destination, a bad full size and a name other than the copy container's before any docker call"
    else test_fail "[$sh_name] the watcher's argument checks ($rc_list)"; fi
done

# --- the read-only copy-container watcher (sh/dash, fake docker) ------------------------------------
# The fake docker answers from a state directory and records every call:
#   started        ps --filter status=running lists running-ids once it exists
#   running-ids    the ids that answer to the copy container's name, running
#   inspect        what the labels|mounts --format prints
#   exists-<name>  `ps -a -q --filter name=^/<name>$` answers id-<name> while it exists
#   ps-fails       makes every ps fail
# The fake sleep logs its argument; on call START_AT (default 2) the copy
# starts, and on call GONE_AT (default 2) every exists-* file goes away.
CW="$SCRATCH/copy-watch"
mkdir -p "$CW/bin"
cat >"$CW/bin/docker" <<'FAKE'
#!/bin/sh
st="$WATCH_STATE"
printf '%s\n' "$*" >>"$st/calls"
case "$1" in
    ps)
        [ ! -e "$st/ps-fails" ] || exit 1
        name=""
        for a in "$@"; do case "$a" in name=^/*) name=${a#name=^/}; name=${name%\$} ;; esac; done
        case " $* " in
            *" status=running "*) [ -e "$st/started" ] || exit 0; cat "$st/running-ids" ;;
            *) [ ! -e "$st/exists-$name" ] || echo "id-$name" ;;
        esac ;;
    inspect) [ -e "$st/inspect" ] || exit 1; [ "$4" != "*" ] || exit 1; cat "$st/inspect" ;;
    *) exit 9 ;;
esac
FAKE
cat >"$CW/bin/sleep" <<'FAKE'
#!/bin/sh
st="$WATCH_STATE"
printf '%s\n' "$1" >>"$st/sleep-log"
n=$(grep -c . "$st/sleep-log")
[ "$n" -lt "${START_AT:-2}" ] || : >"$st/started"
if [ "$n" -ge "${GONE_AT:-2}" ]; then rm -f "$st"/exists-*; fi
exit 0
FAKE
chmod +x "$CW/bin/docker" "$CW/bin/sleep"
ln -s "$(command -v date)" "$CW/bin/date"
CW_COPY=dxe-persist-copy-dxe-fixture-nas.invalid__dx-live-canary
CW_VERIFY=dxe-persist-verify-dxe-fixture-nas.invalid__dx-live-canary
CW_LABELS="io.dxe.managed=true;io.dxe.profile=dxe-fixture-nas.invalid__dx-live-canary;io.dxe.role=persist-copy;io.dxe.schema=1;"
CW_MOUNTS="/nix=/var/lib/docker/volumes/n/_data;/dst=$LEAF;/src=/var/lib/docker/volumes/v/_data;"
CW_N=0
cw_setup() {
    CW_N=$((CW_N + 1))
    WS="$CW/state-$CW_N"
    mkdir -p "$WS"
    in_scratch "$WS" || exit 1
    printf '%s\n' "$COPY_ID" >"$WS/running-ids"
    printf '%s|%s\n' "$CW_LABELS" "$CW_MOUNTS" >"$WS/inspect"
}
cw_run() {
    local shell="$1" mode="$2" deadline="$3"
    (cd "$WS" && WATCH_STATE="$WS" PATH="$CW/bin:$BARE_TOOLS" "$(command -v "$shell")" -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_COPY_WATCH" \
        dxe-live-copy-watch "$CW/bin/docker" "$mode" "$CW_COPY" "$CW_VERIFY" "$deadline")
}
cw_read_only() { awk '$1 != "ps" && $1 != "inspect" { bad = 1 } END { exit bad }' "$WS/calls" 2>/dev/null; }
cw_sleeps() { if [ -e "$WS/sleep-log" ]; then grep -c . "$WS/sleep-log"; else echo 0; fi; }
cw_whole_seconds() { [ ! -e "$WS/sleep-log" ] || ! grep -qvx 1 "$WS/sleep-log"; }

for sh_name in $SHELLS; do
    cw_setup
    out="$(cw_run "$sh_name" running 60 2>"$WS/err")"
    rc=$?
    expected="$(printf 'copy=%s\nlabels=%s\nmounts=%s' "$COPY_ID" "$CW_LABELS" "$CW_MOUNTS")"
    if [ "$rc" = 0 ] && [ "$out" = "$expected" ] && [ "$(cw_sleeps)" -ge 1 ] && cw_whole_seconds \
        && grep -Fqx "ps -q --no-trunc --filter name=^/$CW_COPY\$ --filter status=running" "$WS/calls" \
        && grep -Fqx "inspect --format {{range \$k, \$v := .Config.Labels}}{{\$k}}={{\$v}};{{end}}|{{range .Mounts}}{{.Destination}}={{.Source}};{{end}} $COPY_ID" "$WS/calls" \
        && cw_read_only; then
        test_pass "[$sh_name] copy-watch running: waits (sleep 1) for the one running container with the copy container's name, then prints its id, labels and mounts; ps and inspect only"
    else test_fail "[$sh_name] copy-watch running (rc $rc: $out; $(tr '\n' ' ' <"$WS/err"); calls: $(sort -u "$WS/calls" 2>/dev/null | cut -c1-70 | tr '\n' ' '))"; fi

    cw_setup
    cw_run "$sh_name" running 0 >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 2 ] && [ "$(cw_sleeps)" = 0 ] && [ "$(grep -c '^ps ' "$WS/calls")" = 1 ]; then
        test_pass "[$sh_name] copy-watch running with deadline 0: one look, no sleep; none running is status 2"
    else test_fail "[$sh_name] copy-watch running 0 (rc $rc, sleeps $(cw_sleeps))"; fi

    cw_setup
    : >"$WS/started"
    printf '%s\n%s\n' "$COPY_ID" "$SECOND_ID" >"$WS/running-ids"
    cw_run "$sh_name" running 60 >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 6 ] && ! grep -q '^inspect' "$WS/calls"; then
        test_pass "[$sh_name] copy-watch running: two answers to the name are status 6, with no inspect"
    else test_fail "[$sh_name] copy-watch running with two answers (rc $rc)"; fi

    cw_setup
    : >"$WS/ps-fails"
    cw_run "$sh_name" running 60 >/dev/null 2>&1
    rc=$?
    cw_run "$sh_name" gone 60 >/dev/null 2>&1
    rc2=$?
    if [ "$rc" = 4 ] && [ "$rc2" = 4 ]; then test_pass "[$sh_name] copy-watch: a failing docker ps is status 4 in both modes"
    else test_fail "[$sh_name] copy-watch with a failing ps ($rc/$rc2)"; fi

    cw_setup
    : >"$WS/started"
    : >"$WS/a-file"
    : >"$WS/b-file"
    printf '*\n' >"$WS/running-ids"
    cw_run "$sh_name" running 60 >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 4 ] && grep -Fq '{{end}} *' "$WS/calls"; then
        test_pass "[$sh_name] copy-watch never globs a word (set -f): an id of * stays one literal word"
    else test_fail "[$sh_name] copy-watch globbed a word (rc $rc)"; fi

    cw_setup
    : >"$WS/exists-$CW_COPY"
    : >"$WS/exists-$CW_VERIFY"
    out="$(cw_run "$sh_name" gone 60 2>"$WS/err")"
    rc=$?
    if [ "$rc" = 0 ] && [ "$out" = "gone=$CW_COPY $CW_VERIFY" ] && [ "$(cw_sleeps)" -ge 1 ] && cw_whole_seconds \
        && grep -Fqx "ps -a -q --no-trunc --filter name=^/$CW_COPY\$" "$WS/calls" && grep -Fqx "ps -a -q --no-trunc --filter name=^/$CW_VERIFY\$" "$WS/calls" \
        && cw_read_only; then
        test_pass "[$sh_name] copy-watch gone: waits (sleep 1) until neither the copy nor the verify container exists; ps only"
    else test_fail "[$sh_name] copy-watch gone (rc $rc: $out; $(tr '\n' ' ' <"$WS/err"))"; fi

    cw_setup
    : >"$WS/exists-$CW_VERIFY"
    cw_run "$sh_name" gone 0 >/dev/null 2>&1
    rc=$?
    cw_setup
    : >"$WS/exists-$CW_COPY"
    cw_run "$sh_name" gone 0 >/dev/null 2>&1
    rc2=$?
    cw_setup
    out="$(cw_run "$sh_name" gone 0 2>/dev/null)"
    rc3=$?
    if [ "$rc" = 2 ] && [ "$rc2" = 2 ] && [ "$rc3" = 0 ] && [ "$out" = "gone=$CW_COPY $CW_VERIFY" ]; then
        test_pass "[$sh_name] copy-watch gone 0: a verify or a copy container still there is status 2; none is gone at once"
    else test_fail "[$sh_name] copy-watch gone 0 ($rc/$rc2/$rc3)"; fi

    cw_setup
    rc_list=""
    for bad in "docker running $CW_COPY $CW_VERIFY 60" "$CW/bin/docker kill $CW_COPY $CW_VERIFY 60" \
        "$CW/bin/docker running dx-qnap $CW_VERIFY 60" "$CW/bin/docker running $CW_COPY dx-qnap 60" \
        "$CW/bin/docker running $CW_COPY $CW_VERIFY 6x" "$CW/bin/docker running $CW_COPY $CW_VERIFY"; do
        # shellcheck disable=SC2086 # the words of each case, on purpose
        (cd "$WS" && WATCH_STATE="$WS" PATH="$CW/bin:$BARE_TOOLS" "$(command -v "$sh_name")" -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_COPY_WATCH" x $bad) >/dev/null 2>&1
        rc_list="$rc_list$?"
    done
    if [ "$rc_list" = 111111 ] && [ ! -e "$WS/calls" ]; then
        test_pass "[$sh_name] copy-watch refuses a relative docker path, another mode, other container names and a bad or missing deadline before any docker call"
    else test_fail "[$sh_name] copy-watch argument checks ($rc_list)"; fi
done

# --- the controller-drop helpers (pure; WP7.2b) -----------------------------------------------
P_ID=dxe-fixture-nas.invalid__dx-live-canary
if persist_migrate_live_labels_ok "$CW_LABELS" "$P_ID" persist-copy \
    && ! persist_migrate_live_labels_ok "$CW_LABELS" "$P_ID" persist-verify \
    && ! persist_migrate_live_labels_ok "$CW_LABELS" "dxe-fixture-nas.invalid__dx-qnap" persist-copy \
    && ! persist_migrate_live_labels_ok "io.dxe.profile=$P_ID;io.dxe.role=persist-copy;" "$P_ID" persist-copy \
    && ! persist_migrate_live_labels_ok "io.dxe.managed=true;io.dxe.profile=$P_ID-x;io.dxe.role=persist-copy;" "$P_ID" persist-copy \
    && ! persist_migrate_live_labels_ok "io.dxe.managed=true;io.dxe.profile=$P_ID;io.dxe.role=persist-copy-x;" "$P_ID" persist-copy \
    && ! persist_migrate_live_labels_ok "" "$P_ID" persist-copy; then
    test_pass "labels_ok: managed, this profile id and the role, each as a whole entry (no prefix match)"
else test_fail "labels_ok"; fi
if persist_migrate_live_mount_ok "$CW_MOUNTS" /dst "$LEAF" && ! persist_migrate_live_mount_ok "$CW_MOUNTS" /dst "$LEAF/x" \
    && ! persist_migrate_live_mount_ok "$CW_MOUNTS" /dst "${LEAF%/persist}" && ! persist_migrate_live_mount_ok "$CW_MOUNTS" /src "$LEAF" \
    && ! persist_migrate_live_mount_ok "" /dst "$LEAF"; then
    test_pass "mount_ok: exactly DESTINATION=SOURCE as a whole entry"
else test_fail "mount_ok"; fi
printf 'held by fixture-host:4321:17:20261012T010203Z since 2026-10-12T01:02:03.456Z\nLock released.\n' >"$SCRATCH/lock.out"
printf 'not held\n' >"$SCRATCH/lock-free.out"
if persist_migrate_live_lock_owner_is "$SCRATCH/lock.out" 4321 && ! persist_migrate_live_lock_owner_is "$SCRATCH/lock.out" 432 \
    && ! persist_migrate_live_lock_owner_is "$SCRATCH/lock.out" 43210 && ! persist_migrate_live_lock_owner_is "$SCRATCH/lock.out" 17 \
    && ! persist_migrate_live_lock_owner_is "$SCRATCH/lock-free.out" 4321 && ! persist_migrate_live_lock_owner_is "$SCRATCH/missing.out" 4321; then
    test_pass "lock_owner_is: the owner token's pid field is exactly PID (not a prefix, not the random part, not a free lock)"
else test_fail "lock_owner_is"; fi
if [ "$(persist_migrate_live_drop_bulk_hint 2048 15)" = 8192 ] && [ "$(persist_migrate_live_drop_bulk_hint 2048 29)" = 5120 ] \
    && [ "$(persist_migrate_live_drop_bulk_hint 2048 1)" = 16384 ] && [ "$(persist_migrate_live_drop_bulk_hint 2048 0)" = 16384 ] \
    && [ "$(persist_migrate_live_drop_bulk_hint 64 60)" = 1024 ]; then
    test_pass "drop_bulk_hint: the bulk size for a 60 s copy at the measured rate, in whole GiB, at most 16384"
else test_fail "drop_bulk_hint ($(persist_migrate_live_drop_bulk_hint 2048 15) $(persist_migrate_live_drop_bulk_hint 2048 29))"; fi

# The classifier against the product's OWN refusal lines (WP6.4c's
# dx_persist_copy_containers_none, with its container listing stubbed).
# product_refusal FILE: the product's stderr into FILE (PR_NAME, PR_STATE).
product_refusal() {
    (
        # shellcheck source=../bin/dx-lib.sh
        source "$BASE_DIR/bin/dx-lib.sh" >/dev/null 2>&1 || exit 2
        # shellcheck disable=SC2034 # read by the product's refusal line
        DX_REMOTE_HOST=dxe-fixture-nas.invalid
        dx_runtime_host_copy_containers() { printf '%s %s\n' "$PR_NAME" "$PR_STATE"; }
        dx_persist_copy_containers_none dx-persist-migrate
    ) >/dev/null 2>"$1"
}
classify() { persist_migrate_live_drop_classify "$1" "$2" "$CW_COPY" "$CW_VERIFY"; }
PR_NAME="$CW_COPY" PR_STATE=running product_refusal "$SCRATCH/err.copy-running"
PR_NAME="$CW_VERIFY" PR_STATE=running product_refusal "$SCRATCH/err.verify-running"
PR_NAME="$CW_COPY" PR_STATE=exited product_refusal "$SCRATCH/err.copy-exited"
PR_NAME="$CW_VERIFY" PR_STATE=removing product_refusal "$SCRATCH/err.verify-removing"
PR_NAME=dxe-persist-copy-dxe-fixture-nas.invalid__dx-other-canary PR_STATE=running product_refusal "$SCRATCH/err.other-running"
printf 'Error: the copy into /fixture/real/dxe/dx-live-canary/persist stopped before it finished (rsync exit 125); its marker stays copying, so the guest cannot start on it. Run dx-persist-migrate again to resume the copy.\n' >"$SCRATCH/err.conflict"
sed 's/exit 125/exit 137/' "$SCRATCH/err.conflict" >"$SCRATCH/err.killed"
{ cat "$SCRATCH/err.copy-running"; cat "$SCRATCH/err.copy-running"; } >"$SCRATCH/err.two"
printf "Error: could not acquire the remote lock 'dxe-lock-x' (it may already be held -- run 'dx-lock status' to see by whom).\nError: refusing to proceed: another controller may already hold this profile's lifecycle lock (see above).\n" >"$SCRATCH/err.lock"
: >"$SCRATCH/err.none"
if [ "$(grep -c '^Error:' "$SCRATCH/err.copy-running")" = 1 ] && grep -Fq "$CW_COPY" "$SCRATCH/err.copy-running" \
    && [ "$(classify 1 "$SCRATCH/err.copy-running")" = "refused-running $CW_COPY" ] \
    && [ "$(classify 1 "$SCRATCH/err.verify-running")" = "refused-running $CW_VERIFY" ] \
    && [ "$(classify 1 "$SCRATCH/err.copy-exited")" = "refused-left exited" ] \
    && [ "$(classify 1 "$SCRATCH/err.verify-removing")" = "refused-left removing" ]; then
    test_pass "drop_classify reads the product's own refusal lines: running (copy or verify container) and left in another state"
else test_fail "drop_classify on the product's refusals ($(classify 1 "$SCRATCH/err.copy-running") / $(classify 1 "$SCRATCH/err.copy-exited"); line: $(cat "$SCRATCH/err.copy-running"))"; fi
if [ "$(classify 0 "$SCRATCH/err.none")" = completed ] && [ "$(classify 1 "$SCRATCH/err.conflict")" = copy-conflict ] \
    && [ "$(classify 1 "$SCRATCH/err.killed")" = unexpected ] && [ "$(classify 1 "$SCRATCH/err.other-running")" = unexpected ] \
    && [ "$(classify 1 "$SCRATCH/err.two")" = unexpected ] && [ "$(classify 1 "$SCRATCH/err.lock")" = unexpected ] \
    && [ "$(classify 3 "$SCRATCH/err.copy-running")" = unexpected ] && [ "$(classify 1 "$SCRATCH/err.none")" = unexpected ] \
    && [ "$(classify 1 "$SCRATCH/missing.err")" = unexpected ]; then
    test_pass "drop_classify: exit 0 completed, Docker's name conflict (rsync exit 125) copy-conflict; another container's name, two Error lines, the lock refusal, another status or no Error line: unexpected"
else test_fail "drop_classify outcomes"; fi

# --- the controller's process group (real processes, every one of them this suite's own) -------
PG="$SCRATCH/pg"
mkdir -p "$PG"
cat >"$PG/controller" <<'FAKE'
#!/bin/sh
# A stand-in controller: a child that a kill of the parent alone would leave running.
bash -c "sleep 30" &
echo "$!" >"$1/child"
echo "$$" >"$1/leader"
wait
FAKE
chmod +x "$PG/controller"
own_pgid="$(ps -o pgid= -p $$ | tr -d ' ')"
(persist_migrate_live_own_group "$PG/controller" "$PG") >/dev/null 2>&1 </dev/null &
pg_pid=$!
n=0
while [ ! -s "$PG/leader" ] && [ "$n" -lt 200 ]; do sleep 0.05; n=$((n + 1)); done
pg_child="$(cat "$PG/child" 2>/dev/null)"
if [ "$(cat "$PG/leader" 2>/dev/null)" = "$pg_pid" ] && [ "$(ps -o pgid= -p "$pg_pid" | tr -d ' ')" = "$pg_pid" ] \
    && [ -n "$pg_child" ] && [ "$(ps -o pgid= -p "$pg_child" | tr -d ' ')" = "$pg_pid" ] && [ "$pg_pid" != "$own_pgid" ]; then
    test_pass "own_group: the command runs as the background job itself (same pid), leading a new process group that its children join"
else test_fail "own_group (pid $pg_pid, leader $(cat "$PG/leader" 2>/dev/null), child $pg_child)"; fi
# Refusals, with kill stubbed so a broken refusal sends nothing.
refusals_ok=true
for bad in "" 0 1 01 abc "-$pg_pid" "$$" "$pg_child" "$own_pgid"; do
    out="$(kill() { echo "kill $*" >>"$PG/stub-kills"; }; persist_migrate_live_kill_group "$bad" 2>&1; echo "rc=$?")"
    if [ "$(printf '%s\n' "$out" | sed -n '$p')" != rc=2 ] || ! grep -q '^Refusing: persist_migrate_live_kill_group' <<<"$out"; then
        refusals_ok=false
        echo "  kill_group did not refuse '$bad': $out"
    fi
done
if $refusals_ok && [ ! -e "$PG/stub-kills" ]; then
    test_pass "kill_group refuses an empty, zero, init, padded, negative or non-numeric id, this shell, a process that leads no group and this shell's own group -- nothing sent"
else test_fail "kill_group refusals (stub kills: $(cat "$PG/stub-kills" 2>/dev/null | tr '\n' ' '))"; fi
out="$(persist_migrate_live_kill_group "$pg_pid" 2>&1; echo "rc=$?")"
wait "$pg_pid" 2>/dev/null
pg_rc=$?
if [ "$out" = rc=0 ] && [ "$pg_rc" = 137 ] && persist_migrate_live_group_gone "$pg_pid" && ! kill -0 "$pg_child" 2>/dev/null; then
    test_pass "kill_group SIGKILLs the whole group: the leader dies with status 137 and its child with it (group_gone)"
else test_fail "kill_group kills the group ($out, wait $pg_rc)"; kill -KILL "$pg_child" 2>/dev/null; fi
bash -c "sleep 30" &
lone=$!
if ! persist_migrate_live_group_gone "$own_pgid" 2 && ! persist_migrate_live_group_gone x 2; then
    test_pass "group_gone answers no while a group has a process (and for a bad id), after its bounded tries"
else test_fail "group_gone with a live group"; fi
kill -KILL "$lone" 2>/dev/null
wait "$lone" 2>/dev/null
cat >"$PG/toplevel.sh" <<'PROBE'
#!/bin/bash
# shellcheck source=/dev/null
source "$1"
# shellcheck source=/dev/null
source "$2"
persist_migrate_live_own_group "$3"
echo "rc=$?"
PROBE
printf '#!/bin/sh\necho ran\n' >"$PG/ran"
chmod +x "$PG/ran"
out="$(bash "$PG/toplevel.sh" "$SCRIPT_DIR/lib/persist-live.sh" "$SCRIPT_DIR/lib/persist-migrate-live.sh" "$PG/ran" 2>&1)"
if [ "$(printf '%s\n' "$out" | sed -n '$p')" = rc=2 ] && grep -q '^Refusing: persist_migrate_live_own_group' <<<"$out" && ! grep -qx ran <<<"$out"; then
    test_pass "own_group refuses at a script's top level (it would replace the caller) and runs nothing"
else test_fail "own_group at the top level ($out)"; fi

# --- the controller-drop orchestration, against stand-ins (WP7.2b) ----------------------------
# The stand-in dx-persist-migrate: run 1 (the background controller) records
# itself, starts a child and waits to be killed; later runs record whether run
# 1's process is still alive and answer from rerun-<n>.{out,err,rc}. The
# stand-in dx-lock records the same and prints an audit naming LOCK_PID (run
# 1's pid by default) and `Lock released.`. The NAS (dxe_runtime_call) answers the copy watcher's
# three calls from DROP_RUNNING1 (ok | none | labels | dst), DROP_RUNNING2
# (same | gone) and DROP_GONE (ok | stuck). Everything lands in one transcript.
DROP_BIN="$SCRATCH/drop-bin"
mkdir -p "$DROP_BIN"
cat >"$DROP_BIN/dx-persist-migrate" <<'FAKE'
#!/bin/sh
d="$DROP_DIR"
n=$(( $(cat "$d/migrate-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$d/migrate-count"
if [ "$n" = 1 ]; then
    echo "MIGRATE 1" >>"$d/transcript"
    sh -c "sleep 30" &
    echo "$!" >"$d/child"
    echo "$$" >"$d/leader"
    wait
    exit 0
fi
if kill -0 "$(cat "$d/leader")" 2>/dev/null; then state=alive; else state=dead; fi
echo "MIGRATE $n first=$state" >>"$d/transcript"
cat "$d/rerun-$n.out" 2>/dev/null
cat "$d/rerun-$n.err" >&2 2>/dev/null
exit "$(cat "$d/rerun-$n.rc" 2>/dev/null || echo 0)"
FAKE
cat >"$DROP_BIN/dx-lock" <<'FAKE'
#!/bin/sh
d="$DROP_DIR"
first="$(cat "$d/leader")"
if kill -0 "$first" 2>/dev/null; then state=alive; else state=dead; fi
echo "LOCK $* first=$state" >>"$d/transcript"
echo "held by fixture-host:${LOCK_PID:-$first}:4242:20261012T000000Z since 2026-10-12T00:00:00.000Z"
[ "$1" != unlock ] || echo "Lock released."
FAKE
chmod +x "$DROP_BIN/dx-persist-migrate" "$DROP_BIN/dx-lock"
DROP_N=0
# drop_run RERUN_ERR_FILE RERUN_RC [NAME=VALUE...]: one orchestration in a
# subshell, the stand-in rerun answering with that stderr and status; leaves
# $DROP_DIR/{transcript,steps,result,stderr}.
drop_run() {
    DROP_N=$((DROP_N + 1))
    DROP_DIR="$SCRATCH/drop-$DROP_N"
    mkdir -p "$DROP_DIR/log"
    in_scratch "$DROP_DIR" || exit 1
    cp "$1" "$DROP_DIR/rerun-2.err"
    printf "%s\n" "$2" >"$DROP_DIR/rerun-2.rc"
    shift 2
    (
        canary_env
        export DROP_DIR
        for assignment in "$@"; do
            case "$assignment" in LOCK_PID=*) export "${assignment?}" ;; *) printf -v "${assignment%%=*}" '%s' "${assignment#*=}" ;; esac
        done
        LV_SEQ=0 LV_RC=0 LV_OUT="" LV_ERR="" LV_BG_PID=""
        lv_run() {
            local label="$1"
            shift
            [ "$1" != -- ] || shift
            LV_SEQ=$((LV_SEQ + 1))
            LV_OUT="$DROP_DIR/log/$LV_SEQ-$label.out"
            LV_ERR="$DROP_DIR/log/$LV_SEQ-$label.err"
            LV_RC=0
            ("$@") >"$LV_OUT" 2>"$LV_ERR" </dev/null || LV_RC=$?
        }
        lv_run_bg() {
            local label="$1"
            shift
            [ "$1" != -- ] || shift
            LV_SEQ=$((LV_SEQ + 1))
            ("$@") >"$DROP_DIR/log/$LV_SEQ-$label.out" 2>"$DROP_DIR/log/$LV_SEQ-$label.err" </dev/null &
            LV_BG_PID=$!
        }
        lv_bg_wait() { [ -n "$LV_BG_PID" ] || return 0; LV_RC=0; wait "$LV_BG_PID" || LV_RC=$?; LV_BG_PID=""; }
        lv_ok() { echo "PASS $1" >>"$DROP_DIR/steps"; }
        lv_bad() { echo "FAIL $1" >>"$DROP_DIR/steps"; return 1; }
        lv_check() { local d="$1"; shift; if "$@"; then lv_ok "$d"; return 0; fi; lv_bad "$d"; }
        lv_finding() { echo "FINDING $1" >>"$DROP_DIR/steps"; }
        lv_show_logs() { :; }
        lv_rc_zero() { [ "$LV_RC" -eq 0 ]; }
        lv_rc_is() { [ "$LV_RC" -eq "$1" ]; }
        lv_out_line() { grep -Fqx -- "$1" "$LV_OUT"; }
        dxe_runtime_call() {
            local mode="$7" deadline="${10}" i=0 answer
            [ "$1 $5" = "dx_runtime_docker_ssh_exec dxe-live-copy-watch" ] || { echo "UNEXPECTED $*" >>"$DROP_DIR/transcript"; return 9; }
            if [ "$mode" = running ] && [ ! -e "$DROP_DIR/seen-running" ]; then
                while [ ! -s "$DROP_DIR/leader" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
                : >"$DROP_DIR/seen-running"
                answer="${DROP_RUNNING1:-ok}"
            elif [ "$mode" = running ]; then
                answer="${DROP_RUNNING2:-same}"
            else
                answer="${DROP_GONE:-ok}"
            fi
            echo "NAS $mode $deadline $8 $9" >>"$DROP_DIR/transcript"
            case "$answer" in
                ok | same) printf 'copy=%s\nlabels=%s\nmounts=%s\n' "$COPY_ID" "$CW_LABELS" "$CW_MOUNTS" ;;
                labels) printf 'copy=%s\nlabels=%s\nmounts=%s\n' "$COPY_ID" "${CW_LABELS/persist-copy/persist-verify}" "$CW_MOUNTS" ;;
                dst) printf 'copy=%s\nlabels=%s\nmounts=%s\n' "$COPY_ID" "$CW_LABELS" "${CW_MOUNTS/\/dst=/\/dest=}" ;;
                none | gone | stuck) return 2 ;;
            esac
            [ "$mode" != gone ] || echo "gone=$8 $9"
            return 0
        }
        rc=0
        persist_migrate_live_controller_drop /nas/bin/docker "$DROP_BIN/dx-persist-migrate" "$DROP_BIN/dx-lock" "$LEAF" 77 || rc=$?
        printf 'rc=%s\noutcome=%s\nid=%s\norphan=%s\nbg=%s\nwindow=%s\nlock_left=%s\npid=%s\n' "$rc" "$PERSIST_MIGRATE_LIVE_DROP_OUTCOME" \
            "$PERSIST_MIGRATE_LIVE_DROP_ID" "$PERSIST_MIGRATE_LIVE_DROP_ORPHAN" "${LV_BG_PID:+left}" "$PERSIST_MIGRATE_LIVE_DROP_WINDOW" \
            "$PERSIST_MIGRATE_LIVE_DROP_LOCK_LEFT" "$PERSIST_MIGRATE_LIVE_DROP_PID" >"$DROP_DIR/result"
        if [ -n "$LV_BG_PID" ]; then
            # The orchestration stopped before the drop (the live suite's lv_stop
            # waits for the controller): end this suite's own stand-in here.
            kill -KILL -- "-$LV_BG_PID" 2>/dev/null
            wait "$LV_BG_PID" 2>/dev/null
        fi
    ) 2>"$DROP_DIR/stderr"
    kill -0 "$(cat "$DROP_DIR/child" 2>/dev/null || echo 0)" 2>/dev/null && kill -KILL "$(cat "$DROP_DIR/child")" 2>/dev/null
    return 0
}
drop_result() { sed -n "s/^$1=//p" "$DROP_DIR/result"; }
drop_transcript() { cat "$DROP_DIR/transcript" 2>/dev/null; }
drop_steps() { cat "$DROP_DIR/steps" 2>/dev/null; }
DROP_ORDER="$(printf 'MIGRATE 1\nNAS running 77 %s %s\nLOCK status first=dead\nLOCK unlock --force first=dead\nMIGRATE 2 first=dead\nNAS running 0 %s %s\nNAS gone 77 %s %s' \
    "$CW_COPY" "$CW_VERIFY" "$CW_COPY" "$CW_VERIFY" "$CW_COPY" "$CW_VERIFY")"

drop_run "$SCRATCH/err.copy-running" 1
if [ "$(drop_transcript)" = "$DROP_ORDER" ] && [ "$(drop_result rc)" = 0 ] && [ "$(drop_result outcome)" = refused ] \
    && [ "$(drop_result id)" = "$COPY_ID" ] && [ -z "$(drop_result orphan)" ] && [ -z "$(drop_result bg)" ] \
    && ! grep -q '^FAIL\|^FINDING' "$DROP_DIR/steps" \
    && grep -q '^PASS it carries this profile.s DQ6 labels' "$DROP_DIR/steps" && grep -q '^PASS the dropped controller died of SIGKILL (status 137)' "$DROP_DIR/steps" \
    && grep -q '^PASS no process of its group is left' "$DROP_DIR/steps" && grep -q '^PASS it shows the lock still held by the dropped controller' "$DROP_DIR/steps" \
    && grep -q '^PASS and releases it' "$DROP_DIR/steps" && [ -z "$(drop_result lock_left)" ] && [ -n "$(drop_result pid)" ] \
    && grep -q "^PASS the rerun refuses .* naming $CW_COPY and running" "$DROP_DIR/steps" \
    && grep -q '^PASS the refusal left the copy container alone' "$DROP_DIR/steps" && grep -q '^PASS the orphaned copy ends and removes itself' "$DROP_DIR/steps" \
    && ! kill -0 "$(cat "$DROP_DIR/child")" 2>/dev/null; then
    test_pass "drop: watch for the running copy (deadline), SIGKILL the controller's group, dx-lock status then unlock --force (after it died), rerun (after it died), one look (deadline 0), wait until gone (deadline) -- in that order; refused, untouched"
else test_fail "drop: the happy path (transcript: $(drop_transcript | tr '\n' '|'); result: $(tr '\n' ' ' <"$DROP_DIR/result"); steps: $(grep -v '^PASS' "$DROP_DIR/steps" | tr '\n' '|'))"; fi

drop_run "$SCRATCH/err.copy-running" 1 DROP_RUNNING2=gone
if [ "$(drop_transcript)" = "$DROP_ORDER" ] && [ "$(drop_result rc)" = 0 ] && [ "$(drop_result outcome)" = refused ] \
    && ! grep -q '^FAIL\|^FINDING\|^PASS the refusal left' "$DROP_DIR/steps"; then
    test_pass "drop: a copy container that ends right after the refusal is only noted (still refused, no FAIL)"
else test_fail "drop: the copy ends right after the refusal ($(tr '\n' ' ' <"$DROP_DIR/result"))"; fi

drop_run "$SCRATCH/err.verify-running" 1
if [ "$(drop_result rc)" = 0 ] && [ "$(drop_result outcome)" = refused ] && grep -q "^PASS the rerun refuses .* naming $CW_VERIFY and running" "$DROP_DIR/steps"; then
    test_pass "drop: a refusal naming the running verify container counts as the refusal met running"
else test_fail "drop: the verify container's refusal ($(tr '\n' ' ' <"$DROP_DIR/result"))"; fi

for scenario in "none|a running container named" "labels|it carries this profile" "dst|it binds"; do
    drop_run "$SCRATCH/err.copy-running" 1 "DROP_RUNNING1=${scenario%%|*}"
    if [ "$(drop_result rc)" = 1 ] && [ "$(drop_result bg)" = left ] && [ -z "$(drop_result orphan)" ] \
        && [ "$(drop_transcript)" = "$(printf 'MIGRATE 1\nNAS running 77 %s %s' "$CW_COPY" "$CW_VERIFY")" ] \
        && grep -q "^FAIL ${scenario#*|}" "$DROP_DIR/steps"; then
        test_pass "drop: ${scenario%%|*} at the first look stops before any kill, unlock or rerun, and leaves the controller to the caller"
    else test_fail "drop: ${scenario%%|*} at the first look (transcript: $(drop_transcript | tr '\n' '|'); $(tr '\n' ' ' <"$DROP_DIR/result"))"; fi
done

drop_run "$SCRATCH/err.copy-running" 1 LOCK_PID=1
if [ "$(drop_result rc)" = 1 ] && [ "$(drop_result orphan)" = 1 ] && [ "$(drop_result lock_left)" = 1 ] \
    && [ "$(drop_transcript)" = "$(printf 'MIGRATE 1\nNAS running 77 %s %s\nLOCK status first=dead' "$CW_COPY" "$CW_VERIFY")" ] \
    && grep -q '^FAIL it shows the lock still held by the dropped controller' "$DROP_DIR/steps"; then
    test_pass "drop: a lock whose audit names another pid is never forced: it stops before the unlock and the rerun (orphan copy and lock flagged)"
else test_fail "drop: an audit naming another pid (transcript: $(drop_transcript | tr '\n' '|'))"; fi

for scenario in "err.none|0|completed" "err.copy-exited|1|missed" "err.conflict|1|missed"; do
    file="${scenario%%|*}"
    rest="${scenario#*|}"
    drop_run "$SCRATCH/$file" "${rest%%|*}"
    if [ "$(drop_result rc)" = 0 ] && [ "$(drop_result outcome)" = "${rest#*|}" ] && [ -z "$(drop_result orphan)" ] \
        && [ "$(drop_transcript)" = "$(printf 'MIGRATE 1\nNAS running 77 %s %s\nLOCK status first=dead\nLOCK unlock --force first=dead\nMIGRATE 2 first=dead\nNAS gone 77 %s %s' "$CW_COPY" "$CW_VERIFY" "$CW_COPY" "$CW_VERIFY")" ] \
        && grep -q '^FINDING NOT VALIDATED' "$DROP_DIR/steps" && ! grep -q '^FAIL' "$DROP_DIR/steps"; then
        test_pass "drop: a rerun that did not meet the copy running ($file, exit ${rest%%|*}) is a FINDING ($(drop_result outcome)); the orphan is still waited for"
    else test_fail "drop: rerun $file (transcript: $(drop_transcript | tr '\n' '|'); $(tr '\n' ' ' <"$DROP_DIR/result"); $(drop_steps | grep -v '^PASS' | tr '\n' '|'))"; fi
done

for file in err.lock err.killed err.two err.other-running; do
    drop_run "$SCRATCH/$file" 1
    if [ "$(drop_result rc)" = 1 ] && [ "$(drop_result orphan)" = 1 ] \
        && [ "$(drop_transcript)" = "$(printf 'MIGRATE 1\nNAS running 77 %s %s\nLOCK status first=dead\nLOCK unlock --force first=dead\nMIGRATE 2 first=dead' "$CW_COPY" "$CW_VERIFY")" ] \
        && grep -q '^FAIL the rerun while .* runs refuses' "$DROP_DIR/steps"; then
        test_pass "drop: an unexpected rerun outcome ($file) is a FAIL, with the orphan copy flagged and no further NAS call"
    else test_fail "drop: unexpected rerun $file (transcript: $(drop_transcript | tr '\n' '|'); $(tr '\n' ' ' <"$DROP_DIR/result"))"; fi
done

drop_run "$SCRATCH/err.copy-running" 1 DROP_GONE=stuck
if [ "$(drop_result rc)" = 1 ] && [ "$(drop_result orphan)" = 1 ] && [ "$(drop_transcript)" = "$DROP_ORDER" ] \
    && grep -q '^FAIL the orphaned copy ends and removes itself' "$DROP_DIR/steps"; then
    test_pass "drop: an orphan copy still there at the deadline is a FAIL (flagged for the cleanup)"
else test_fail "drop: a stuck orphan ($(tr '\n' ' ' <"$DROP_DIR/result"))"; fi

# --- the production-inventory runner --------------------------------------------------------
INV_STUB="$SCRATCH/stub/dx-persist-inventory"
mkdir -p "$SCRATCH/stub"
cat >"$INV_STUB" <<'EOF'
#!/bin/sh
env | LC_ALL=C sort >"$(dirname "$0")/env.out"
echo "volume: from-the-stub"
EOF
chmod +x "$INV_STUB"
write_real_profile() {
    {
        echo "export DX_RUNTIME=${1:-docker-ssh}"
        echo "export DX_REMOTE_HOST=dxe-fixture-nas.invalid"
        echo "export DX_CONTAINER_NAME=${2:-dx-qnap}"
        echo "export DX_IMAGE=dx-qnap-nixos"
        echo "export DX_NIX_VOLUME=dx-qnap-nix"
        echo "export DX_PERSIST_VOLUME=dx-qnap-persist"
        echo "export DX_BOOTSTRAP_VOLUME=dx-qnap-bootstrap"
        echo "export DX_SSH_PORT=2222"
        echo "export DX_GUEST_SYSTEM=x86_64-linux"
        echo "export DX_PROFILE_ROOT=/fixture/main-checkout"
        [ -z "${3:-}" ] || echo "export DX_PERSIST_HOST_ROOT=$3"
    } >"$SCRATCH/real-profiles/qnap.env"
}
real_run() {
    rm -f "$SCRATCH/stub/env.out"
    (
        canary_env
        DXE_PERSIST_LIVE_INVENTORY_REAL="${REAL_OPT_IN-dx-qnap}"
        XDG_STATE_HOME="${REAL_STATE-$SCRATCH/run-state}"
        DX_PROFILES_DIR="$SCRATCH/real-profiles"
        DXE_CONFIG_RESOLVED=1
        export DX_CONTAINER_NAME DX_IMAGE DX_PERSIST_VOLUME DX_NIX_VOLUME DX_PERSIST_HOST_ROOT XDG_STATE_HOME DX_PROFILES_DIR DXE_CONFIG_RESOLVED
        export DXE_PERSIST_LIVE_INVENTORY_REAL DXE_PERSIST_LIVE_CANARY
        persist_migrate_live_real_inventory "${REAL_PROFILE-qnap}" /fixture/share "${REAL_COMMAND-$INV_STUB}" >"$SCRATCH/real.out" 2>"$SCRATCH/real.err"
    )
    echo "rc=$?"
}
real_env() { cat "$SCRATCH/stub/env.out" 2>/dev/null; }

write_real_profile
out="$(real_run)"
env_ok=true
for line in DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-qnap DX_IMAGE=dx-qnap-nixos \
    DX_NIX_VOLUME=dx-qnap-nix DX_PERSIST_VOLUME=dx-qnap-persist DX_BOOTSTRAP_VOLUME=dx-qnap-bootstrap DX_SSH_PORT=2222 \
    DX_GUEST_SYSTEM=x86_64-linux DX_PERSIST_HOST_ROOT=/fixture/share "XDG_STATE_HOME=$SCRATCH/run-state"; do
    grep -Fqx -- "$line" <<<"$(real_env)" || { env_ok=false; echo "  missing: $line"; }
done
if [ "$out" = rc=0 ] && $env_ok && [ "$(cat "$SCRATCH/real.out")" = "volume: from-the-stub" ]; then
    test_pass "real inventory: dx-persist-inventory gets the production profile's fields and the share root"
else test_fail "real inventory: the production profile's fields reach dx-persist-inventory (got $out: $(cat "$SCRATCH/real.err"))"; fi
if ! grep -Eq '^(DX_PROFILE_ROOT|DXE_[A-Z_]*|DX_PERSIST_STORAGE|DX_SSH_KEY|DX_USAGE_SERVICE|DX_CONTAINER_RESTART_POLICY|DX_PERSIST_HOST_MOUNT_SENTINEL)=' <<<"$(real_env)" \
    && ! grep -q canary <<<"$(real_env)"; then
    test_pass "real inventory: no DX_PROFILE_ROOT pin, no DXE_* snapshot and nothing of the canary reaches it"
else test_fail "real inventory: leaked variables ($(grep -E '^(DX_PROFILE_ROOT|DXE_)|canary' <<<"$(real_env)" | tr '\n' ' '))"; fi
write_real_profile docker-ssh dx-qnap /fixture/own-root
out="$(real_run)"
if [ "$out" = rc=0 ] && grep -Fqx DX_PERSIST_HOST_ROOT=/fixture/own-root <<<"$(real_env)"; then
    test_pass "real inventory: a share root the production profile sets is kept"
else test_fail "real inventory: a share root the production profile sets is kept (got $out)"; fi
expect_real_refusal() {
    local description="$1" message="$2" out
    out="$(real_run)"
    if [ "$out" = rc=2 ] && [ ! -e "$SCRATCH/stub/env.out" ] && grep -Fq "Refusing: persist_migrate_live_real_inventory: $message" "$SCRATCH/real.err" \
        && [ "$(grep -c '^Refusing: ' "$SCRATCH/real.err")" = 1 ]; then
        test_pass "real inventory refuses $description and runs nothing"
    else test_fail "real inventory refuses $description and runs nothing (got $out: $(cat "$SCRATCH/real.err"))"; fi
}
write_real_profile docker-ssh dx-host
expect_real_refusal "a profile naming another guest" "the profile 'qnap' names DX_CONTAINER_NAME=dx-host, not dx-qnap"
write_real_profile apple dx-qnap
expect_real_refusal "a profile that is not docker-ssh" "the profile 'qnap' is not a docker-ssh profile"
write_real_profile
REAL_PROFILE=missing expect_real_refusal "a missing profile" "no profile 'missing' was found"
REAL_OPT_IN="" expect_real_refusal "without the opt-in" "DXE_PERSIST_LIVE_INVENTORY_REAL is not dx-qnap"
REAL_COMMAND="$SCRATCH/stub/dx-persist-migrate" expect_real_refusal "any command but dx-persist-inventory" "'$SCRATCH/stub/dx-persist-migrate' is not dx-persist-inventory"
REAL_STATE="" expect_real_refusal "without XDG_STATE_HOME" "XDG_STATE_HOME is not set"
printf 'export DX_CONTAINER_NAME=dx-qnap\nnot a setting\n' >"$SCRATCH/real-profiles/qnap.env"
expect_real_refusal "a profile that does not parse" "the profile 'qnap' does not parse"

# --- the library is import-only ------------------------------------------------------------------
purity_probe="$SCRATCH/purity-probe.sh"
cat >"$purity_probe" <<'PROBE'
#!/bin/bash
before="$-|$(trap -p)|$(umask)|$PWD"
# shellcheck source=/dev/null
source "$1" >"$3" 2>&1
# shellcheck source=/dev/null
source "$2" >>"$3" 2>&1
status=$?
after="$-|$(trap -p)|$(umask)|$PWD"
[ "$before" = "$after" ] || echo "state changed: $before -> $after" >>"$3"
exit "$status"
PROBE
if bash "$purity_probe" "$SCRIPT_DIR/lib/persist-live.sh" "$SCRIPT_DIR/lib/persist-migrate-live.sh" "$SCRATCH/purity.out" && [ ! -s "$SCRATCH/purity.out" ]; then
    test_pass "tests/lib/persist-migrate-live.sh is import-only: no output, no shell-state change"
else test_fail "tests/lib/persist-migrate-live.sh is import-only (got: $(cat "$SCRATCH/purity.out"))"; fi

# --- the live suite's gates (fail-closed fakes for every network tool) ---------------------------
fakes="$(fake_tool_dir_create "$SCRATCH")"
transcript="$SCRATCH/remote-transcript"
# The transcript path is written into each fake (not passed in the
# environment): the production-inventory runner starts dx-persist-inventory
# under env -i, and its remote attempts must be recorded too.
for tool in ssh scp sftp docker container tailscale curl nix ssh-keyscan; do
    fake_tool_write "$fakes" "$tool" "t=$(printf '%q' "$transcript")
"'printf "%s|" "${0##*/}" >>"$t"
for a in "$@"; do printf "%s " "$a" | tr "\n" " " >>"$t"; done
printf "\n" >>"$t"
echo "fake: no network in this suite" >&2
exit 255'
done
write_profile() {
    local name="$1" container="$2" port="$3" storage="${4:-host-path}"
    cat >"$SCRATCH/profiles/$name.env" <<EOF
export DX_RUNTIME=docker-ssh
export DX_REMOTE_HOST=dxe-fixture-nas.invalid
export DX_NIX_STORAGE_MODE=direct-volume
export DX_CONTAINER_RESTART_POLICY=no
export DX_CONTAINER_NAME=$container
export DX_IMAGE=$container-image
export DX_NIX_VOLUME=$container-nix
export DX_PERSIST_VOLUME=$container-persist
export DX_BOOTSTRAP_VOLUME=$container-bootstrap
export DX_SSH_KEY=$SCRATCH/home/.ssh/dxe/${container}_key
export DX_SSH_KEY_PUB=$SCRATCH/home/.ssh/dxe/${container}_key.pub
export DX_SSH_PORT=$port
export DX_PERSIST_STORAGE=$storage
export DX_PERSIST_HOST_ROOT=/fixture/share
export DX_PERSIST_HOST_MOUNT_SENTINEL=dxe-fixture-sentinel
EOF
}
write_profile live-canary dx-live-canary 2224
write_profile live-production dx-qnap 2223 volume

# run_live PROFILE SKIP_INTEGRATION OPT_IN [RUN_DIR] -- the suite's output, then rc=N.
run_live() {
    : >"$transcript"
    env -i HOME="$SCRATCH/home" PATH="$fakes:/usr/bin:/bin" TMPDIR="$SCRATCH/tmp" \
        DX_PROFILES_DIR="$SCRATCH/profiles" SKIP_INTEGRATION="$2" DXE_PERSIST_LIVE_CANARY="$3" \
        DXE_PERSIST_LIVE_RUN_DIR="${4:-$SCRATCH/run-$1}" \
        DXE_PERSIST_LIVE_BULK_MIB="${LIVE_BULK_MIB:-}" DXE_PERSIST_LIVE_INVENTORY_REAL="${LIVE_REAL:-}" \
        DXE_PERSIST_LIVE_MIN_FREE_INODES="${LIVE_MIN_INODES:-}" \
        "$BASE_DIR/bin/dx-profile" "$1" bash "$BASE_DIR/tests/test_persist_migrate_live.sh" 2>&1
    echo "rc=$?"
}
no_remote_call() { [ ! -s "$transcript" ]; }
only_discovery() {
    local remote discovery
    remote="$(grep -c . "$transcript" || true)"
    discovery="$(grep -c '^ssh|.*NOTFOUND' "$transcript" || true)"
    [ "$remote" -ge 1 ] && [ "$remote" = "$discovery" ]
}

out="$(run_live live-canary true dx-live-canary)"
if has "$out" "rc=0" && has "$out" "Live /persist migration suite skipped (SKIP_INTEGRATION is not false)" && no_remote_call; then
    test_pass "without --live the live suite skips (exit 0) and contacts nothing"
else test_fail "without --live the live suite skips and contacts nothing ($(tail -n 4 <<<"$out"))"; fi

out="$(run_live live-canary false "")"
if has "$out" "rc=0" && has "$out" "not opted in: set DXE_PERSIST_LIVE_CANARY" && no_remote_call; then
    test_pass "with --live but no DXE_PERSIST_LIVE_CANARY the live suite skips (exit 0) and contacts nothing"
else test_fail "with --live but no opt-in the live suite skips ($(tail -n 4 <<<"$out"))"; fi

out="$(run_live live-production false dx-qnap)"
if ! has "$out" "rc=0" && has "$out" "Refusing: DX_CONTAINER_NAME=dx-qnap is a protected guest" \
    && has "$out" "refuses this profile (the Refusing: lines above); nothing was contacted" && no_remote_call; then
    test_pass "opted in on a production-named profile, the live suite refuses (non-zero) before any remote call"
else test_fail "the live suite refuses a production-named profile before any remote call ($(tail -n 6 <<<"$out"))"; fi

LIVE_BULK_MIB=1
out="$(run_live live-canary false dx-live-canary)"
LIVE_BULK_MIB=""
if ! has "$out" "rc=0" && has "$out" "Refusing: DXE_PERSIST_LIVE_BULK_MIB=1 is not a whole number from 64 to 16384." && no_remote_call; then
    test_pass "a bulk size out of range is refused before any remote call"
else test_fail "a bulk size out of range is refused before any remote call ($(tail -n 4 <<<"$out"))"; fi

LIVE_MIN_INODES=1000
out="$(run_live live-canary false dx-live-canary)"
LIVE_MIN_INODES=""
if ! has "$out" "rc=0" && has "$out" "Refusing: DXE_PERSIST_LIVE_MIN_FREE_INODES=1000 is not a whole number from 600000 to 99999999" && no_remote_call; then
    test_pass "an inode floor below the guard's is refused before any remote call"
else test_fail "an inode floor below the guard's is refused before any remote call ($(tail -n 4 <<<"$out"))"; fi

LIVE_REAL=dx-host
out="$(run_live live-canary false dx-live-canary)"
LIVE_REAL=""
if ! has "$out" "rc=0" && has "$out" "Refusing: DXE_PERSIST_LIVE_INVENTORY_REAL=dx-host is not dx-qnap" && no_remote_call; then
    test_pass "a production inventory of any guest but dx-qnap is refused before any remote call"
else test_fail "a production inventory of another guest is refused before any remote call ($(tail -n 4 <<<"$out"))"; fi

out="$(run_live live-canary false dx-live-canary "$BASE_DIR/tests")"
if ! has "$out" "rc=0" && has "$out" "is inside the checkout" && no_remote_call; then
    test_pass "a run directory inside the checkout is refused before any remote call"
else test_fail "a run directory inside the checkout is refused before any remote call ($(tail -n 4 <<<"$out"))"; fi

out="$(run_live live-canary false dx-live-canary)"
if ! has "$out" "rc=0" && has "$out" "Stopped at the first failure: preflight" \
    && has "$out" "DXE_PERSIST_LIVE_CLEANUP_ONLY=1 DXE_PERSIST_LIVE_RUN_DIR=$(cd "$SCRATCH/run-live-canary" && pwd -P) DXE_PERSIST_LIVE_CANARY=dx-live-canary ./bin/dx-profile live-canary tests/run.sh --live --file tests/test_persist_migrate_live.sh" \
    && only_discovery; then
    test_pass "a canary profile with a failing NAS connection stops at the preflight; its only remote attempts are the read-only Docker CLI discovery"
else test_fail "a canary profile with a failing NAS stops at the preflight ($(tail -n 6 <<<"$out"); transcript: $(sort -u "$transcript" | cut -c1-80 | tr '\n' ' '))"; fi
if [ -d "$SCRATCH/run-live-canary/logs" ] && [ -d "$SCRATCH/run-live-canary/state" ] && [ ! -e "$SCRATCH/home/.local/state/dxe" ]; then
    test_pass "the live suite keeps its state (XDG_STATE_HOME) in its run directory, never the operator's"
else test_fail "the live suite keeps its state in its run directory"; fi

LIVE_REAL=dx-qnap
out="$(run_live live-canary false dx-live-canary "$SCRATCH/run-real-missing")"
LIVE_REAL=""
if ! has "$out" "rc=0" && has "$out" "Refusing: persist_migrate_live_real_inventory: no profile 'qnap' was found" \
    && ! has "$out" "--- preflight ---" && no_remote_call; then
    test_pass "the production-inventory run without a production profile refuses and contacts nothing (no canary case runs)"
else test_fail "the production-inventory run without a production profile ($(tail -n 6 <<<"$out"))"; fi

cp "$SCRATCH/profiles/live-production.env" "$SCRATCH/profiles/qnap.env"
LIVE_REAL=dx-qnap
out="$(run_live live-canary false dx-live-canary "$SCRATCH/run-real")"
LIVE_REAL=""
if ! has "$out" "rc=0" && has "$out" "--- production inventory ---" && ! has "$out" "--- preflight ---" \
    && ! has "$out" "Stopped the canary container" && only_discovery; then
    test_pass "the production-inventory run reads only through dx-persist-inventory: with a failing NAS its only remote attempts are the read-only discovery"
else test_fail "the production-inventory run is read-only ($(tail -n 6 <<<"$out"); transcript: $(sort -u "$transcript" | cut -c1-80 | tr '\n' ' '))"; fi
rm -f "$SCRATCH/profiles/qnap.env"

print_summary
exit_with_code
