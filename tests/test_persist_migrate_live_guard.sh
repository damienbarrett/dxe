#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
# WP7.2: everything about the LIVE /persist migration suite
# (tests/test_persist_migrate_live.sh) that can be proven without a NAS:
#   - persist_migrate_live_guard (tests/lib/persist-migrate-live.sh) keeps
#     every WP7.1 refusal and adds its own (rollback volume, root comma, bulk
#     size, the production-inventory opt-in), one `Refusing:` line each, with
#     no command call at all;
#   - the read-only runners: persist_migrate_live_dir_read and
#     persist_migrate_live_volume_read start exactly one pinned read-only
#     container (the volume one only after its DQ6 check), or none;
#   - the NAS-side interrupt: persist_migrate_live_interrupt's pinned ssh call
#     and refusals, and its NAS script (under sh and dash, against a recording
#     fake docker) killing exactly the one copy container, at the right moment,
#     and nothing else;
#   - the container scripts (LIST, TEMP_ASIDE, RETIRED_ASIDE), run with only
#     the bare image's tools on PATH against temporary directories, and the
#     guest scripts (SEED, CHANGES, CHECK) against a temporary /persist;
#   - the production-inventory runner: exactly the production profile's
#     fields minus DX_PROFILE_ROOT reach dx-persist-inventory, nothing of the
#     canary, and every refusal runs nothing;
#   - the live suite's own gates: it skips without --live or the opt-in,
#     refuses before any remote call, and with a failing NAS stops at the
#     read-only preflight.
# The scripts run real mv, mkdir, rm and chmod, but only inside the temporary
# directory this suite creates (checked before each run). No test here
# reaches a real host: every network tool is a fail-closed fake.
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
    [ "$(persist_migrate_live_bulk_mib)" = 128 ]
) && test_pass "the rollback volume defaults to <DX_PERSIST_VOLUME>-rollback and the bulk size to 2048 MiB; both can be set" \
  || test_fail "the rollback volume and bulk size defaults and overrides"

# --- recording runners ------------------------------------------------------------
# record_call FUNCTION [NAME=VALUE]... -- ARG...: runs FUNCTION over canary_env
# with a dxe_runtime_call that records each call (one argv word per line, a
# "--call--" line between calls) and fails the calls named in FAIL_CALLS.
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
            return 0
        }
        # shellcheck disable=SC2123 # no command search path: the runners make only the recorded call
        PATH="$SCRATCH/no-commands"
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
    dx-live-canary-image dx-live-canary-persist /fixture/real/dxe/dx-live-canary/persist dxe-live-bulk dxe-live-blob.bin 900)"
out="$(record_call persist_migrate_live_interrupt -- /nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 900)"
if [ "$out" = rc=0 ] && [ "$(calls)" = "$expected" ]; then
    test_pass "interrupt: one NAS-shell call running the watcher with the canary's image, volume and canonical leaf"
else test_fail "interrupt: pinned call (got $out: $(calls | sed -n '1,3p' | tr '\n' ' '))"; fi
for refusal in "docker /fixture/real/dxe/dx-live-canary/persist 900" "/nas/my docker /fixture/real/dxe/dx-live-canary/persist 900" \
    "/nas/bin/docker /fixture/real/dxe/dx-other-canary/persist 900" "/nas/bin/docker /fixture/real/dxe/dx-live-canary 900" \
    "/nas/bin/docker /fixture/a,b/dxe/dx-live-canary/persist 900" "/nas/bin/docker /fixture/../dxe/dx-live-canary/persist 900" \
    "/nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 9" "/nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 3601" \
    "/nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 0900" "/nas/bin/docker /fixture/real/dxe/dx-live-canary/persist x"; do
    # shellcheck disable=SC2086 # three words on purpose (the docker path with a blank is the one case of four)
    case "$refusal" in
        "/nas/my docker "*) out="$(record_call persist_migrate_live_interrupt -- "/nas/my docker" /fixture/real/dxe/dx-live-canary/persist 900)" ;;
        *) out="$(record_call persist_migrate_live_interrupt -- $refusal)" ;;
    esac
    if [ "$out" = rc=2 ] && [ -z "$(calls)" ] && grep -q '^Refusing: persist_migrate_live_interrupt' "$SCRATCH/call.err"; then
        test_pass "interrupt refuses ($refusal) with nothing run on the NAS"
    else test_fail "interrupt refuses ($refusal) with nothing run (got $out: $(calls | sed -n '1p'))"; fi
done
for change in DX_IMAGE=dx-qnap-nixos DX_PERSIST_VOLUME=dx-qnap-persist DX_CONTAINER_NAME=dx-qnap; do
    out="$(record_call persist_migrate_live_interrupt "$change" -- /nas/bin/docker /fixture/real/dxe/dx-live-canary/persist 900)"
    if [ "$out" = rc=2 ] && [ -z "$(calls)" ]; then
        test_pass "interrupt refuses $change with nothing run on the NAS"
    else test_fail "interrupt refuses $change (got $out)"; fi
done

# --- script shape -----------------------------------------------------------------
for name in SCRIPT_LIST SCRIPT_TEMP_ASIDE SCRIPT_RETIRED_ASIDE NAS_SCRIPT_INTERRUPT; do
    var="PERSIST_MIGRATE_LIVE_$name"
    case "${!var}" in
        *"
"* | *"'"*) test_fail "$var is one line with no single quote (the NAS transport %q-quotes argv)" ;;
        *) test_pass "$var is one line with no single quote" ;;
    esac
done
for name in SCRIPT_TEMP_ASIDE SCRIPT_RETIRED_ASIDE; do
    var="PERSIST_MIGRATE_LIVE_$name"
    case "${!var}" in
        "$PERSIST_LIVE_SCRIPT_PRELUDE"*) test_pass "$var starts in the canary directory (WP7.1's prelude)" ;;
        *) test_fail "$var starts in the canary directory (WP7.1's prelude)" ;;
    esac
done
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

# --- TEMP_ASIDE and RETIRED_ASIDE (sh/dash, bare tools) ---------------------------------------
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

for sh_name in $SHELLS; do
    new_canary
    c="$CANARY"
    b="$c/persist/dxe-live-bulk"
    printf 'partial\n' >"$b/.dxe-live-blob.bin.Ab12Cd"
    printf 'other\n' >"$b/.dxe-live-blob.bin.toolong7"
    printf 'other\n' >"$b/.other-file.Ab12Cd"
    ln -s dxe-live-blob.bin "$b/.dxe-live-blob.bin.SyMlNk"
    out="$(run_script "$sh_name" "$c" "$PERSIST_MIGRATE_LIVE_SCRIPT_TEMP_ASIDE" dxe-live-bulk dxe-live-blob.bin)"
    rc=$?
    if [ "$rc" = 0 ] && [ "$out" = "moved=.dxe-live-blob.bin.Ab12Cd" ] && [ "$(cat "$c/rsync-temp.dxe-live-aside/.dxe-live-blob.bin.Ab12Cd")" = partial ] \
        && [ "$(mode_of "$c/rsync-temp.dxe-live-aside")" = 700 ] && [ ! -e "$b/.dxe-live-blob.bin.Ab12Cd" ] \
        && [ -f "$b/.dxe-live-blob.bin.toolong7" ] && [ -f "$b/.other-file.Ab12Cd" ] && [ -L "$b/.dxe-live-blob.bin.SyMlNk" ] \
        && [ "$(cat "$b/dxe-live-blob.bin")" = blob ] && outside_ok "$c"; then
        test_pass "[$sh_name] TEMP_ASIDE moves exactly rsync's regular temp file of the blob into a 0700 aside directory, nothing else"
    else test_fail "[$sh_name] TEMP_ASIDE moves exactly the temp file (rc $rc: $out)"; fi
    run_script "$sh_name" "$c" "$PERSIST_MIGRATE_LIVE_SCRIPT_TEMP_ASIDE" dxe-live-bulk dxe-live-blob.bin >/dev/null 2>&1
    rc=$?
    printf 'again\n' >"$b/.dxe-live-blob.bin.Ab12Cd"
    run_script "$sh_name" "$c" "$PERSIST_MIGRATE_LIVE_SCRIPT_TEMP_ASIDE" dxe-live-bulk dxe-live-blob.bin >/dev/null 2>&1
    rc_exists=$?
    run_script "$sh_name" "$c" "$PERSIST_MIGRATE_LIVE_SCRIPT_TEMP_ASIDE" ../x dxe-live-blob.bin >/dev/null 2>&1
    rc_bad=$?
    run_script "$sh_name" "$c" "$PERSIST_MIGRATE_LIVE_SCRIPT_TEMP_ASIDE" dxe-live-bulk 'a/b' >/dev/null 2>&1
    rc_bad2=$?
    if [ "$rc" = 3 ] && [ "$rc_exists" = 1 ] && [ "$(cat "$b/.dxe-live-blob.bin.Ab12Cd")" = again ] && [ "$rc_bad" = 2 ] && [ "$rc_bad2" = 2 ]; then
        test_pass "[$sh_name] TEMP_ASIDE: none left is status 3, an existing target is refused, bad names are status 2"
    else test_fail "[$sh_name] TEMP_ASIDE refusals ($rc/$rc_exists/$rc_bad/$rc_bad2)"; fi

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
# The fake sleep counts its calls; on call 2 the copy starts, on call 4 rsync's
# temp file of the blob appears (TEMP_AT overrides), so the watcher must wait
# for both.
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
if [ "$n" -ge "${TEMP_AT:-4}" ] && [ -n "${TEMP_FILE:-}" ]; then : >"$TEMP_FILE"; fi
exit 0
EOF
chmod +x "$WATCH/bin/docker" "$WATCH/bin/sleep"
ln -s "$(command -v date)" "$WATCH/bin/date"
# A NAS whose sleep takes whole seconds only (QTS's may): this fake sleep
# refuses a fraction, logs every call, starts the copy on its first accepted
# call and makes the temp file appear on its third.
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
if [ "$n" -ge 3 ] && [ -n "${TEMP_FILE:-}" ]; then : >"$TEMP_FILE"; fi
exit 0
EOF
chmod +x "$WATCH/bin-int/sleep"
RSYNC_BIN="$PERSIST_MIGRATE_LIVE_RSYNC_BIN"
LEAF="$SCRATCH/watch-share/dxe/dx-live-canary/persist"
COPY_ID=aaaaaaaaaaaa1111111111111111111111111111111111111111111111111111
INV_ID=bbbbbbbbbbbb2222222222222222222222222222222222222222222222222222
OTHER_ID=cccccccccccc3333333333333333333333333333333333333333333333333333
SECOND_ID=dddddddddddd4444444444444444444444444444444444444444444444444444

# watch_setup NAME: a fresh state directory with the three usual candidates.
watch_setup() {
    WS="$WATCH/state-$1"
    mkdir -p "$WS"
    in_scratch "$WS" || exit 1
    mkdir -p "$LEAF/dxe-live-bulk"
    rm -f "$LEAF/dxe-live-bulk/".dxe-live-blob.bin.*
    printf '%s\n%s\n%s\n' "$INV_ID" "$OTHER_ID" "$COPY_ID" >"$WS/ids"
    printf '%s|-aH --numeric-ids -A -X --exclude=/.dxe-persist-dir --exclude=._* /src/ /dst/ |/nix=/x;/dst=%s;/src=/var/lib/docker/volumes/v/_data;\n' "$RSYNC_BIN" "$LEAF" >"$WS/inspect-$COPY_ID"
    printf 'sh|-c script sh /v |/v=/var/lib/docker/volumes/v/_data;\n' >"$WS/inspect-$INV_ID"
    printf '%s|-aH --numeric-ids --exclude=/.dxe-persist-dir --exclude=._* /src/ /dst/ |/dst=%s/elsewhere;/src=/y;\n' "$RSYNC_BIN" "$LEAF" >"$WS/inspect-$OTHER_ID"
    for id in "$COPY_ID" "$INV_ID" "$OTHER_ID"; do : >"$WS/running-$id"; : >"$WS/exists-$id"; done
}
watch_run() {
    local shell="$1" deadline="$2"
    WATCH_STATE="$WS" TEMP_FILE="${TEMP_FILE-$LEAF/dxe-live-bulk/.dxe-live-blob.bin.Zz9Yy8}" PATH="${WATCH_BIN:-$WATCH/bin}:$BARE_TOOLS" \
        "$(command -v "$shell")" -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" dxe-live-interrupt "$WATCH/bin/docker" \
        dx-live-canary-image dx-live-canary-persist "${WATCH_LEAF:-$LEAF}" dxe-live-bulk dxe-live-blob.bin "$deadline"
}
kills() { grep -c '^kill ' "$WS/calls" 2>/dev/null || true; }

for sh_name in $SHELLS; do
    watch_setup "happy-$sh_name"
    out="$(watch_run "$sh_name" 60 2>"$WS/err")"
    rc=$?
    expected="$(printf 'copy=%s\ninterrupted=%s temp=.dxe-live-blob.bin.Zz9Yy8\ngone=%s' "${COPY_ID:0:12}" "${COPY_ID:0:12}" "${COPY_ID:0:12}")"
    if [ "$rc" = 0 ] && [ "$out" = "$expected" ] && [ "$(kills)" = 1 ] && grep -qx "kill $COPY_ID" "$WS/calls" \
        && [ -e "$WS/running-$INV_ID" ] && [ -e "$WS/running-$OTHER_ID" ] && [ "$(cat "$WS/sleeps")" -ge 4 ]; then
        test_pass "[$sh_name] the watcher waits for the copy and its temp file, then kills exactly the one copy container (not the inventory, not another destination's rsync)"
    else test_fail "[$sh_name] the watcher kills exactly the copy container (rc $rc: $out; $(tr '\n' ' ' <"$WS/err"))"; fi
    if grep -Fqx "ps -q --no-trunc --filter ancestor=dx-live-canary-image --filter volume=dx-live-canary-persist --filter status=running" "$WS/calls" \
        && awk '$1 != "ps" && $1 != "inspect" && $1 != "kill" { bad = 1 } END { exit bad }' "$WS/calls"; then
        test_pass "[$sh_name] the watcher only lists (image, volume, running), inspects and kills"
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
    TEMP_FILE="" watch_run "$sh_name" 60 >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 3 ] && [ "$(kills)" = 0 ]; then
        test_pass "[$sh_name] the copy ends before its temp file appears: status 3 and nothing killed"
    else test_fail "[$sh_name] the copy ends before its temp file (rc $rc, kills $(kills))"; fi

    watch_setup "symlink-$sh_name"
    ln -s "$LEAF/dxe-live-bulk/dxe-live-blob.bin" "$LEAF/dxe-live-bulk/.dxe-live-blob.bin.LnK123"
    : >"$LEAF/dxe-live-bulk/dxe-live-blob.bin"
    rm -f "$WS/running-$COPY_ID"
    TEMP_FILE="" watch_run "$sh_name" 60 >/dev/null 2>&1
    rc=$?
    rm -f "$LEAF/dxe-live-bulk/.dxe-live-blob.bin.LnK123" "$LEAF/dxe-live-bulk/dxe-live-blob.bin"
    if [ "$rc" = 3 ] && [ "$(kills)" = 0 ]; then
        test_pass "[$sh_name] a symlink named like the temp file is no trigger"
    else test_fail "[$sh_name] a symlink named like the temp file is no trigger (rc $rc, kills $(kills))"; fi

    watch_setup "unreadable-$sh_name"
    chmod 000 "$LEAF/dxe-live-bulk"
    TEMP_FILE="" watch_run "$sh_name" 60 >/dev/null 2>&1
    rc=$?
    chmod 0755 "$LEAF/dxe-live-bulk"
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
    TEMP_AT=1 watch_run "$sh_name" 0 >/dev/null 2>&1
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

    watch_setup "args-$sh_name"
    rc_list=""
    for bad in "relative-docker" "deadline" "dst"; do
        case "$bad" in
            relative-docker) WATCH_STATE="$WS" PATH="$WATCH/bin:$BARE_TOOLS" "$(command -v "$sh_name")" -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" x docker i v "$LEAF" b f 60 >/dev/null 2>&1 ;;
            deadline) WATCH_STATE="$WS" PATH="$WATCH/bin:$BARE_TOOLS" "$(command -v "$sh_name")" -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" x "$WATCH/bin/docker" i v "$LEAF" b f 6x >/dev/null 2>&1 ;;
            dst) WATCH_STATE="$WS" PATH="$WATCH/bin:$BARE_TOOLS" "$(command -v "$sh_name")" -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" x "$WATCH/bin/docker" i v /fixture/x b f 60 >/dev/null 2>&1 ;;
        esac
        rc_list="$rc_list$?"
    done
    if [ "$rc_list" = 111 ] && [ ! -e "$WS/calls" ]; then
        test_pass "[$sh_name] the watcher refuses a relative docker path, a bad deadline and a bad destination before any docker call"
    else test_fail "[$sh_name] the watcher's argument checks ($rc_list)"; fi
done

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
