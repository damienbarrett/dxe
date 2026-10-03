#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
test_section "dx-usage-service host lifecycle command (bin/dx-usage-service, bin/lib/dx-usage-service.sh)"

# DX_PROFILES_DIR points at an empty fixture: nothing here may resolve a real
# profile, and every ssh is the fixture's own fake (asserted before use).
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-usage-host.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export HOME="$fixture/home" DX_PROFILES_DIR="$fixture/profiles"
mkdir -p "$HOME" "$DX_PROFILES_DIR"
unset XDG_STATE_HOME

CMD="$BASE_DIR/bin/dx-usage-service"
HOSTLIB="$BASE_DIR/bin/lib/dx-usage-service.sh"
assert_file_exists "$CMD" "bin/dx-usage-service exists"
assert_file_exists "$HOSTLIB" "bin/lib/dx-usage-service.sh exists"
[ -x "$CMD" ] && test_pass "bin/dx-usage-service is executable" || test_fail "bin/dx-usage-service is executable"

source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"
# shellcheck source=../bin/lib/dx-usage-service.sh
source "$HOSTLIB"
source "$BASE_DIR/bin/lib/dx-ssh-common.sh"
source "$BASE_DIR/bin/lib/dx-tunnel.sh"
source "$BASE_DIR/bin/lib/dx-backup.sh"

# A docker fake that records each call's argv (one "|"-joined line) and
# answers the service-mode probe (`exec NAME test -d ...`) from US_PROBE_RC.
new_tool_dir() {
    local dir
    dir="$(fake_tool_dir_create "$fixture")"
    fake_tool_write "$dir" uname 'case "$1" in -m) echo x86_64 ;; esac'
    fake_qnap_ssh_write "$dir"
    [ -x "$dir/ssh" ] || { echo "test setup: fake ssh missing in $dir" >&2; exit 1; }
    fake_tool_write "$dir" docker 'old=$IFS; IFS="|"; printf "%s\n" "$*" >> "$US_DOCKER_LOG"; IFS=$old
if [ "$1" = exec ] && [ "$3" = test ]; then exit "${US_PROBE_RC:-0}"; fi
if [ "$1" = exec ] && [ "$3" = tail ]; then printf "log-line\n"; fi
exit 0'
    printf '%s' "$dir"
}
export US_DOCKER_LOG="$fixture/docker.log"
S6=/run/dx-services/.s6-bin
SVC=/run/dx-services/agent-stats
run_docker() {
    # $@ = dx-usage-service arguments. Output on stdout, status in $us_rc.
    local dir; dir="$(new_tool_dir)"
    : > "$US_DOCKER_LOG"
    us_rc=0
    us_out="$( (
        PATH="$dir:/usr/bin:/bin"
        DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-svc
        export DX_GUEST_SYSTEM=x86_64-linux DXE_RUNTIME_DOCKER_BIN=docker
        dx_usage_host_main "$@"
    ) 2>&1 )" || us_rc=$?
}
expect_calls() {
    printf '%s\n' "$@" > "$fixture/expected"
    cmp -s "$fixture/expected" "$US_DOCKER_LOG"
}

# --- bin/dx-create-container's two moved steps (also proven end to end on the
# Apple argv in test_runtime_boundary_characterisation.sh) ----------------------
if ( DX_USAGE_SERVICE=on DX_USAGE_SERVICE_HOST_PORT=2222 DX_SSH_PORT=2222; dx_usage_host_create_check ) 2>"$fixture/check.err"; then
    test_fail "create_check refuses on with the usage port equal to the SSH port"
elif grep -qF "DX_USAGE_SERVICE_HOST_PORT (2222) must differ from DX_SSH_PORT (2222)" "$fixture/check.err"; then
    test_pass "create_check refuses on with the usage port equal to the SSH port"
else
    test_fail "create_check refuses with the documented message (got: $(cat "$fixture/check.err"))"
fi
if ( DX_USAGE_SERVICE=on DX_USAGE_SERVICE_HOST_PORT=8787 DX_SSH_PORT=2222; dx_usage_host_create_check ) \
    && ( DX_USAGE_SERVICE=off DX_USAGE_SERVICE_HOST_PORT=2222 DX_SSH_PORT=2222; dx_usage_host_create_check ); then
    test_pass "create_check accepts distinct ports, and ignores the port entirely when off"
else
    test_fail "create_check accepts distinct ports, and ignores the port entirely when off"
fi
us_args_on="$( DX_USAGE_SERVICE=on DX_USAGE_SERVICE_HOST_PORT=18799; CREATE_ARGS=(--name x); dx_usage_host_create_args; printf '%s|' "${CREATE_ARGS[@]}" )"
us_args_off="$( DX_USAGE_SERVICE=off DX_USAGE_SERVICE_HOST_PORT=18799; CREATE_ARGS=(--name x); dx_usage_host_create_args; printf '%s|' "${CREATE_ARGS[@]}" )"
if [ "$us_args_on" = "--name|x|--publish|18799:8787|--env|DX_USAGE_SERVICE=on|" ] && [ "$us_args_off" = "--name|x|" ]; then
    test_pass "create_args appends exactly the neutral publish item and env token when on, and nothing when off"
else
    test_fail "create_args appends the publish item and env token when on, nothing when off (on: $us_args_on; off: $us_args_off)"
fi

# --- docker-ssh argv per subcommand -------------------------------------------
probe="exec|dx-svc|test|-d|$SVC"
for pair in "start:-u" "stop:-d" "restart:-r"; do
    run_docker "${pair%%:*}"
    if [ "$us_rc" -eq 0 ] && expect_calls "$probe" "exec|dx-svc|$S6/s6-svc|${pair##*:}|$SVC"; then
        test_pass "dx-usage-service ${pair%%:*} probes service mode then runs s6-svc ${pair##*:} on agent-stats only"
    else
        test_fail "dx-usage-service ${pair%%:*} runs s6-svc ${pair##*:} (rc $us_rc; calls: $(cat "$US_DOCKER_LOG"); out: $us_out)"
    fi
done
run_docker status
if [ "$us_rc" -eq 0 ] && expect_calls "$probe" "exec|dx-svc|$S6/s6-svstat|$SVC"; then
    test_pass "dx-usage-service status runs s6-svstat on agent-stats"
else
    test_fail "dx-usage-service status runs s6-svstat (rc $us_rc; calls: $(cat "$US_DOCKER_LOG"))"
fi
LOGFILE=/persist/services/agent-stats/logs/agent-stats/current
run_docker logs
if [ "$us_rc" -eq 0 ] && [ "$us_out" = log-line ] && expect_calls "$probe" "exec|dx-svc|tail|-n|50|$LOGFILE"; then
    test_pass "dx-usage-service logs tails the current agent-stats s6-log file, 50 lines by default"
else
    test_fail "dx-usage-service logs tails 50 lines by default (rc $us_rc; calls: $(cat "$US_DOCKER_LOG"))"
fi
run_docker logs 7
if [ "$us_rc" -eq 0 ] && expect_calls "$probe" "exec|dx-svc|tail|-n|7|$LOGFILE"; then
    test_pass "dx-usage-service logs N tails N lines"
else
    test_fail "dx-usage-service logs N tails N lines (calls: $(cat "$US_DOCKER_LOG"))"
fi
for bad in "logs 0" "logs -3" "logs abc" "logs 50000" "logs 5 6" "start 1" "frobnicate" ""; do
    # shellcheck disable=SC2086
    run_docker $bad
    if [ "$us_rc" -eq 64 ] && [ ! -s "$US_DOCKER_LOG" ] && printf '%s\n' "$us_out" | grep -q 'Usage: dx-usage-service'; then
        test_pass "dx-usage-service '${bad:-<none>}' prints usage and exits 64 without touching the guest"
    else
        test_fail "dx-usage-service '${bad:-<none>}' prints usage and exits 64 without touching the guest (rc $us_rc; calls: $(cat "$US_DOCKER_LOG"))"
    fi
done

# --- not in service mode ------------------------------------------------------------
US_PROBE_RC=1 run_docker restart
if [ "$us_rc" -ne 0 ] && expect_calls "$probe" \
    && printf '%s\n' "$us_out" | grep -qF "is not in usage-service mode" \
    && printf '%s\n' "$us_out" | grep -qF "DX_USAGE_SERVICE=on" \
    && ! printf '%s\n' "$us_out" | grep -qF "s6-"; then
    test_pass "a guest not in service mode gets a helpful message (profile + recreate), never an s6 error, and nothing is run"
else
    test_fail "a guest not in service mode gets a helpful message (rc $us_rc; calls: $(cat "$US_DOCKER_LOG"); out: $us_out)"
fi

# --- Apple refuses ----------------------------------------------------------------------
dir="$(new_tool_dir)"; : > "$US_DOCKER_LOG"; ap_rc=0
ap_out="$( ( PATH="$dir:/usr/bin:/bin"; DX_RUNTIME=apple DX_CONTAINER_NAME=dx-svc dx_usage_host_main status ) 2>&1 )" || ap_rc=$?
if [ "$ap_rc" -eq 1 ] && [ ! -s "$US_DOCKER_LOG" ] && printf '%s\n' "$ap_out" | grep -qF "no usage_service capability" \
    && printf '%s\n' "$ap_out" | grep -qF "DX_RUNTIME=apple"; then
    test_pass "dx-usage-service under DX_RUNTIME=apple refuses with the capability message before any guest call"
else
    test_fail "dx-usage-service under DX_RUNTIME=apple refuses with the capability message (rc $ap_rc; out: $ap_out)"
fi

# --- the entrypoint itself (profile applied, fixture profile, fake ssh) -------------------
printf '%s\n' 'DX_RUNTIME=docker-ssh' 'DX_REMOTE_HOST=dxe-fixture-nas.invalid' 'DX_CONTAINER_NAME=dx-svc' 'DX_GUEST_SYSTEM=x86_64-linux' 'DX_NIX_STORAGE_MODE=direct-volume' > "$DX_PROFILES_DIR/svc.env"
dir="$(new_tool_dir)"; : > "$US_DOCKER_LOG"; en_rc=0
en_out="$( ( PATH="$dir:/usr/bin:/bin"; export DXE_RUNTIME_DOCKER_BIN=docker; "$BASE_DIR/bin/dx-profile" svc "$CMD" status ) 2>&1 )" || en_rc=$?
if [ "$en_rc" -eq 0 ] && expect_calls "$probe" "exec|dx-svc|$S6/s6-svstat|$SVC"; then
    test_pass "bin/dx-usage-service under dx-profile runs status through the entrypoint end to end (fake ssh/docker)"
else
    test_fail "bin/dx-usage-service under dx-profile runs status (rc $en_rc; calls: $(cat "$US_DOCKER_LOG"); out: $en_out)"
fi

print_summary
exit_with_code
