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
    DX_TUNNEL_LOCK_TIMEOUT=1
    DXE_SELF_PROCESS_IDENTITY="test-$$"
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
    [ "$reclaim_status" -eq 0 ] \
        && printf '%s\n' "$reclaim_output" | grep -q 'fake 100 20 80 20% /nix' \
        && [ "$df_failure_status" -eq 37 ] \
        && ! printf '%s\n' "$reclaim_output" | grep -q 'sed:.*not found'
); then
    test_pass "reclaim reports guest filesystems without a guest sed binary"
else
    test_fail "reclaim reports guest filesystems without a guest sed binary"
fi
assert_file_contains_literal "$BASE_DIR/bin/dx-wait-ssh" 'print_container_logs 5' "bootstrap progress shows several recent guest log lines"
assert_file_contains_literal "$BASE_DIR/bin/dx-wait-ssh" 'approximately' "bootstrap wait budget is rendered in human-readable minutes"
assert_file_contains_literal "$BASE_DIR/bin/dx-create-container" '-- "$DX_BOOTSTRAP_PATH"' "bootstrap path crosses the launcher boundary positionally"
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

    out="$(TERM_PROGRAM=Apple_Terminal "$BASE_DIR/bin/dx-ssh" 2>&1)"
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
    DX_SSH_KEY="$BASE_DIR/dx_key" DX_SSH_PORT=2222 DX_SSH_CONNECT_TIMEOUT=1 dx_run_interactive_ssh "true" >/dev/null 2>&1
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

print_summary
exit_with_code
