#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -euo pipefail

# Unit cases for the decisions that used to live inline in bin/dx,
# bin/dx-profile and bin/qx (unscoped entrypoints) and now live in covered
# libraries: dx_connect_or_bring_up (bin/lib/dx-container.sh) and the
# dx_profile_* helpers (bin/lib/dx-config.sh). tests/test_qx.sh stays the
# end-to-end contract; every branch is exercised here with fakes only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"
test_section "Entrypoint decisions (dx connect-or-bring-up, profile helpers)"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-entrypoint.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
unset DX_PROFILES_DIR
export ENTRY_TEST_LOG="$fixture/log"

# --- dx_connect_or_bring_up -------------------------------------------------
children="$fixture/children"
mkdir -p "$children"
for child in dx-create-keys dx-create-image dx-create-volumes dx-create-container dx-start-container dx-wait-ssh dx-ssh; do
    cat > "$children/$child" <<'CHILD'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$ENTRY_TEST_LOG"
[ "${0##*/}" != "${ENTRY_TEST_FAIL_CHILD:-}" ] || exit 31
[ "${0##*/}" != dx-ssh ] || printf '<%s>\n' "$@" >> "$ENTRY_TEST_LOG"
CHILD
    chmod +x "$children/$child"
done

# run_decision [args...]: stubs every runtime question from ENTRY_* knobs, runs
# the function in a subshell (so exec and traps are contained) and sets
# decision_status / decision_log. Stub defaults: service up, guest running,
# owned, lock free.
run_decision() {
    : > "$ENTRY_TEST_LOG"
    decision_status=0
    (
        DX_CONTAINER_NAME=dx-entry
        dx_require_container_cli() { printf '%s\n' available >> "$ENTRY_TEST_LOG"; return "${ENTRY_AVAILABLE:-0}"; }
        container_system_is_running() { printf '%s\n' system-status >> "$ENTRY_TEST_LOG"; [ "${ENTRY_SERVICE:-up}" = up ]; }
        container_system_ensure_started() { printf '%s\n' ensure-started >> "$ENTRY_TEST_LOG"; return "${ENTRY_START_STATUS:-0}"; }
        container_is_running() { printf 'running:%s\n' "$1" >> "$ENTRY_TEST_LOG"; [ "${ENTRY_GUEST:-running}" = running ]; }
        container_owned() { printf 'owned:%s:%s\n' "$1" "$2" >> "$ENTRY_TEST_LOG"; return "${ENTRY_OWNED_STATUS:-0}"; }
        dx_lifecycle_lock_acquire() { printf '%s\n' lock >> "$ENTRY_TEST_LOG"; return "${ENTRY_LOCK_STATUS:-0}"; }
        dx_lifecycle_lock_release() { printf '%s\n' unlock >> "$ENTRY_TEST_LOG"; }
        dx_connect_or_bring_up "$children" "$@"
    ) >/dev/null 2>&1 || decision_status=$?
    decision_log="$(tr '\n' ' ' < "$ENTRY_TEST_LOG")"
}
expect_decision() { # status "log"
    [ "$decision_status" -eq "$1" ] && [ "$decision_log" = "$2 " ]
}

run_decision 'uname -a' ''
if expect_decision 0 'available system-status running:dx-entry lock owned:dx-entry:connect unlock dx-ssh <uname -a> <>'; then
    test_pass "running and owned guest: lock brackets the ownership check only, then dx-ssh gets the arguments"
else test_fail "running and owned guest connects (status $decision_status, log '$decision_log')"; fi

ENTRY_OWNED_STATUS=17 run_decision
if expect_decision 17 'available system-status running:dx-entry lock owned:dx-entry:connect unlock'; then
    test_pass "running but foreign guest is refused with its status, releasing the lock, never reaching dx-ssh"
else test_fail "foreign guest is refused (status $decision_status, log '$decision_log')"; fi

ENTRY_LOCK_STATUS=1 run_decision
if expect_decision 1 'available system-status running:dx-entry lock'; then
    test_pass "a held lifecycle lock refuses a reconnect before the ownership check"
else test_fail "held lock refuses (status $decision_status, log '$decision_log')"; fi

ENTRY_GUEST=stopped run_decision 'x'
if expect_decision 0 'available system-status running:dx-entry lock ensure-started dx-create-keys dx-create-image dx-create-volumes dx-create-container dx-start-container dx-wait-ssh unlock dx-ssh <x>'; then
    test_pass "stopped guest: lock, service ensure, every bring-up child in order, unlock, then dx-ssh"
else test_fail "stopped guest brings up (status $decision_status, log '$decision_log')"; fi

ENTRY_GUEST=stopped ENTRY_LOCK_STATUS=1 run_decision
if expect_decision 1 'available system-status running:dx-entry lock'; then
    test_pass "a held lifecycle lock refuses a bring-up before any mutation"
else test_fail "held lock refuses bring-up (status $decision_status, log '$decision_log')"; fi

ENTRY_GUEST=stopped ENTRY_TEST_FAIL_CHILD=dx-create-volumes run_decision
if expect_decision 31 'available system-status running:dx-entry lock ensure-started dx-create-keys dx-create-image dx-create-volumes unlock'; then
    test_pass "a failing bring-up child stops the sequence, releases the lock and never connects"
else test_fail "failing child stops bring-up (status $decision_status, log '$decision_log')"; fi

ENTRY_SERVICE=down run_decision 'y'
if expect_decision 0 'available system-status lock ensure-started running:dx-entry owned:dx-entry:connect unlock dx-ssh <y>'; then
    test_pass "service down: one lock held through service start, then connect releases it before dx-ssh"
else test_fail "service down then running guest (status $decision_status, log '$decision_log')"; fi

ENTRY_SERVICE=down ENTRY_GUEST=absent run_decision
if expect_decision 0 'available system-status lock ensure-started running:dx-entry dx-create-keys dx-create-image dx-create-volumes dx-create-container dx-start-container dx-wait-ssh unlock dx-ssh <>'; then
    test_pass "service down and no guest: the service-start lock is kept through bring-up (one acquire)"
else test_fail "service down then bring-up (status $decision_status, log '$decision_log')"; fi

ENTRY_SERVICE=down ENTRY_START_STATUS=27 run_decision
if expect_decision 27 'available system-status lock ensure-started unlock'; then
    test_pass "service start failure releases the lock without querying the guest"
else test_fail "service start failure (status $decision_status, log '$decision_log')"; fi

ENTRY_SERVICE=down ENTRY_LOCK_STATUS=1 run_decision
if expect_decision 1 'available system-status lock'; then
    test_pass "a held lock refuses before the service is started"
else test_fail "held lock before service start (status $decision_status, log '$decision_log')"; fi

ENTRY_AVAILABLE=42 run_decision
if expect_decision 42 'available'; then
    test_pass "an unavailable runtime fails before any service or guest query"
else test_fail "unavailable runtime (status $decision_status, log '$decision_log')"; fi

# --- dx_profile_* helpers -----------------------------------------------------
profile_root="$fixture/root"
mkdir -p "$profile_root/tests/profiles" "$fixture/xdg/dxe/profiles" "$fixture/explicit"
printf '%s\n' 'DX_CONTAINER_NAME=dx-bundled' > "$profile_root/tests/profiles/shared.env"
printf '%s\n' 'DX_CONTAINER_NAME=dx-bundled-only' > "$profile_root/tests/profiles/bundled-only.env"
printf '%s\n' 'DX_CONTAINER_NAME=dx-user' > "$fixture/xdg/dxe/profiles/shared.env"
printf '%s\n' 'DX_CONTAINER_NAME=dx-explicit' > "$fixture/explicit/shared.env"

resolve() { ( DX_PROJECT_ROOT="$profile_root"; XDG_CONFIG_HOME="$fixture/xdg"; "$@" ); }

if [ "$(resolve dx_profile_resolve_file shared)" = "$fixture/xdg/dxe/profiles/shared.env" ]; then
    test_pass "profile lookup prefers the user config directory"
else test_fail "profile lookup prefers the user config directory"; fi
if [ "$(resolve dx_profile_resolve_file bundled-only)" = "$profile_root/tests/profiles/bundled-only.env" ]; then
    test_pass "profile lookup falls back to the bundled fixtures"
else test_fail "profile lookup falls back to the bundled fixtures"; fi
if [ "$(DX_PROFILES_DIR="$fixture/explicit" resolve dx_profile_resolve_file shared)" = "$fixture/explicit/shared.env" ]; then
    test_pass "an explicit DX_PROFILES_DIR wins"
else test_fail "an explicit DX_PROFILES_DIR wins"; fi
if [ "$(env -u XDG_CONFIG_HOME HOME="$fixture/home" bash -c 'source "$1"; DX_PROJECT_ROOT="$2"; unset DX_PROFILES_DIR; dx_profile_search_dirs' _ "$BASE_DIR/bin/lib/dx-config.sh" "$profile_root" | head -n1)" = "$fixture/home/.config/dxe/profiles" ]; then
    test_pass "without XDG_CONFIG_HOME the user directory is under HOME/.config"
else test_fail "without XDG_CONFIG_HOME the user directory is under HOME/.config"; fi
missing_status=0
missing_err="$(DX_PROFILES_DIR="$fixture/explicit" resolve dx_profile_resolve_file nope 2>&1)" || missing_status=$?
if [ "$missing_status" -eq 1 ] && printf '%s\n' "$missing_err" | stdin_matches -F "Error: Profile not found: $fixture/explicit/nope.env" \
    && ! printf '%s\n' "$missing_err" | stdin_matches -F 'also checked'; then
    test_pass "a missing explicit profile fails without naming a fallback"
else test_fail "a missing explicit profile fails (status $missing_status, got '$missing_err')"; fi
missing_status=0
missing_err="$(resolve dx_profile_resolve_file nope 2>&1)" || missing_status=$?
if [ "$missing_status" -eq 1 ] && printf '%s\n' "$missing_err" | stdin_matches -F "(also checked $profile_root/tests/profiles/nope.env)"; then
    test_pass "a missing profile names both searched locations"
else test_fail "a missing profile names both searched locations (status $missing_status, got '$missing_err')"; fi
for bad_name in '' '.hidden' '-x' 'a;b' 'a b'; do
    bad_status=0
    bad_err="$(resolve dx_profile_resolve_file "$bad_name" 2>&1)" || bad_status=$?
    if [ "$bad_status" -eq 2 ] && printf '%s\n' "$bad_err" | stdin_matches -F "invalid profile name '$bad_name'"; then
        test_pass "profile name '$bad_name' is rejected with status 2"
    else test_fail "profile name '$bad_name' is rejected with status 2 (status $bad_status, got '$bad_err')"; fi
done
if dx_profile_name_valid qnap-canary && dx_profile_name_valid a.b_c-1 \
    && ! dx_profile_name_valid '' && ! dx_profile_name_valid .x && ! dx_profile_name_valid 'a/b'; then
    test_pass "dx_profile_name_valid applies the registry name rule"
else test_fail "dx_profile_name_valid applies the registry name rule"; fi

usage_out="$(resolve dx_profile_usage dx-profile 2>&1)"
if printf '%s\n' "$usage_out" | stdin_matches -F 'Usage: dx-profile <profile> <command...>' \
    && printf '%s\n' "$usage_out" | stdin_matches -F "  shared ($fixture/xdg/dxe/profiles)" \
    && printf '%s\n' "$usage_out" | stdin_matches -F "  bundled-only ($profile_root/tests/profiles)"; then
    test_pass "usage lists the profiles in every searched directory"
else test_fail "usage lists the profiles in every searched directory (got '$usage_out')"; fi

# dx_profile_enforce_pin NAME: only a pin that came from the profile itself.
pin_real="$(cd "$profile_root" && pwd -P)"
ln -s "$profile_root" "$fixture/root-link"
pin_case() { # origin pin -> status
    ( DX_PROJECT_ROOT="$profile_root"; DX_PROFILE_ROOT="$2"; DXE_CONFIG_ORIGIN_DX_PROFILE_ROOT="$1"; dx_profile_enforce_pin shared ) >/dev/null 2>&1
}
if pin_case profile:shared "$pin_real" && pin_case profile:shared "$fixture/root-link" \
    && pin_case profile:shared '' && pin_case environment "$fixture/elsewhere" && pin_case default ''; then
    test_pass "a matching, symlinked, empty or non-profile pin is accepted"
else test_fail "a matching, symlinked, empty or non-profile pin is accepted"; fi
pin_status=0
pin_err="$( ( DX_PROJECT_ROOT="$profile_root"; DX_PROFILE_ROOT="$fixture/elsewhere"; DXE_CONFIG_ORIGIN_DX_PROFILE_ROOT=profile:shared; dx_profile_enforce_pin shared ) 2>&1)" || pin_status=$?
if [ "$pin_status" -eq 2 ] && printf '%s\n' "$pin_err" | stdin_matches -F "Error: profile 'shared' is pinned to $fixture/elsewhere; run it from that checkout."; then
    test_pass "a pin naming another or missing directory is refused with status 2"
else test_fail "a mismatched pin is refused (status $pin_status, got '$pin_err')"; fi

# dx_profile_apply: parse, export, enforce the pin, resolve. A profile that
# sets a field reaches the environment with its origin recorded.
apply_out="$(env -i PATH="$PATH" HOME="$fixture/home" bash -c '
    source "$1"; DX_PROJECT_ROOT="$2"; export DX_PROJECT_ROOT
    dx_profile_apply shared "$3" && printf "%s %s\n" "$DX_CONTAINER_NAME" "$DXE_CONFIG_ORIGIN_DX_CONTAINER_NAME"
' _ "$BASE_DIR/bin/lib/dx-config.sh" "$profile_root" "$fixture/xdg/dxe/profiles/shared.env" 2>&1)"
if [ "$apply_out" = "dx-user profile:shared" ]; then
    test_pass "dx_profile_apply exports the profile's fields with their origin"
else test_fail "dx_profile_apply exports the profile's fields with their origin (got '$apply_out')"; fi
printf '%s\n' 'DX_CONTAINER_NAME=$(bad)' > "$fixture/bad.env"
bad_status=0
env -i PATH="$PATH" HOME="$fixture/home" bash -c 'source "$1"; DX_PROJECT_ROOT="$2"; dx_profile_apply bad "$3"' _ "$BASE_DIR/bin/lib/dx-config.sh" "$profile_root" "$fixture/bad.env" >/dev/null 2>&1 || bad_status=$?
if [ "$bad_status" -ne 0 ]; then test_pass "dx_profile_apply fails on a malformed profile"; else test_fail "dx_profile_apply fails on a malformed profile"; fi
printf '%s\n' "DX_PROFILE_ROOT=$fixture/elsewhere" > "$fixture/pinned.env"
bad_status=0
env -i PATH="$PATH" HOME="$fixture/home" bash -c 'source "$1"; DX_PROJECT_ROOT="$2"; dx_profile_apply pinned "$3"' _ "$BASE_DIR/bin/lib/dx-config.sh" "$profile_root" "$fixture/pinned.env" >/dev/null 2>&1 || bad_status=$?
if [ "$bad_status" -eq 2 ]; then test_pass "dx_profile_apply refuses a pin to another checkout with status 2"; else test_fail "dx_profile_apply refuses a pin to another checkout (status $bad_status)"; fi

# --- dx_qx_profile ------------------------------------------------------------
if [ "$(env -u QX_PROFILE bash -c 'source "$1"; dx_qx_profile' _ "$BASE_DIR/bin/lib/dx-config.sh")" = qnap ] \
    && [ "$(QX_PROFILE='' bash -c 'source "$1"; dx_qx_profile' _ "$BASE_DIR/bin/lib/dx-config.sh")" = qnap ] \
    && [ "$(QX_PROFILE=other bash -c 'source "$1"; dx_qx_profile' _ "$BASE_DIR/bin/lib/dx-config.sh")" = other ]; then
    test_pass "dx_qx_profile defaults to qnap and honours QX_PROFILE"
else test_fail "dx_qx_profile defaults to qnap and honours QX_PROFILE"; fi
qx_status=0
qx_err="$(QX_PROFILE='bad;name' bash -c 'source "$1"; dx_qx_profile' _ "$BASE_DIR/bin/lib/dx-config.sh" 2>&1)" || qx_status=$?
if [ "$qx_status" -eq 2 ] && printf '%s\n' "$qx_err" | stdin_matches -F "Error: invalid QX_PROFILE 'bad;name'."; then
    test_pass "dx_qx_profile rejects an invalid name with status 2"
else test_fail "dx_qx_profile rejects an invalid name (status $qx_status, got '$qx_err')"; fi

print_summary
exit_with_code
