#!/bin/bash
# Section 27: QNAP Phase 0 scripts (tests/qnap/phase0-inventory.sh,
# tests/qnap/phase0-spike.sh)
#
# Container-free contracts driven entirely by a stub ssh/docker on PATH --
# there is no NAS to reach yet (qnap-dxe-plan.md Phase 0). Every case here
# proves a safety property from the plan rather than matching source text:
# --dry-run never connects, a real run refuses to proceed past an
# unreachable host, every created/queried resource is scoped to
# "dxe-spike-*" + the "dxe.role=spike" label, --cleanup only ever removes
# what a label-filtered query returned, guarded restarts stay off without
# their flag, and a planted secret-shaped string never survives into the
# inventory report.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=qnap/lib/phase0-common.sh
source "$SCRIPT_DIR/qnap/lib/phase0-common.sh"

test_section "Section 27: QNAP Phase 0 Scripts"

QNAP_INV="$BASE_DIR/tests/qnap/phase0-inventory.sh"
QNAP_SPIKE="$BASE_DIR/tests/qnap/phase0-spike.sh"

assert_file_exists "$QNAP_INV" "phase0-inventory.sh exists"
assert_file_exists "$QNAP_SPIKE" "phase0-spike.sh exists"
assert_file_exists "$BASE_DIR/tests/qnap/lib/phase0-common.sh" "phase0-common.sh exists"
assert_file_exists "$BASE_DIR/tests/qnap/README.md" "tests/qnap/README.md exists"

for script in "$QNAP_INV" "$QNAP_SPIKE" "$BASE_DIR/tests/qnap/lib/phase0-common.sh"; do
    if bash -n "$script"; then test_pass "$(basename "$script") passes bash syntax"; else test_fail "$(basename "$script") passes bash syntax"; fi
done

# Never a TCP-exposed daemon, never published beyond loopback
# (qnap-dxe-plan.md non-goals/Phase 0 safety rule).
assert_file_not_contains "$QNAP_SPIKE" 'DOCKER_HOST=tcp' "spike never exposes the daemon over TCP"
assert_file_contains_literal "$QNAP_SPIKE" '127.0.0.1:2222:2222' "spike publishes guest port 2222 to loopback only"

STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dxe-qnap-stub.XXXXXX")"
MARKER="$(mktemp "${TMPDIR:-/tmp}/dxe-qnap-marker.XXXXXX")"
rm -f "$MARKER"
cleanup_stub() { rm -rf "$STUB_DIR"; rm -f "$MARKER"; }
trap cleanup_stub EXIT

write_stub() {
    local name="$1" body="$2"
    printf '#!/bin/bash\n%s\n' "$body" >"$STUB_DIR/$name"
    chmod +x "$STUB_DIR/$name"
}

reset_marker() { : >"$MARKER"; }

# A connectable ssh that answers "true" and reachability probes, echoes a
# loopback-only ss -ltn line, and returns canned inventory fields (including
# a planted, token-shaped secret) for the phase0-inventory.sh heredoc.
write_stub ssh '
printf "ssh %s\n" "$*" >> "'"$MARKER"'"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    true) exit 0 ;;
    reboot) exit 0 ;;
esac
case "$*" in
    *"ss -ltn"*) printf "LISTEN 0 128 127.0.0.1:2222 0.0.0.0:*\n"; exit 0 ;;
    *"container-station.sh restart"*) exit 0 ;;
esac
case "$last" in
    *DXE_UNAME_M*)
        cat <<OUT
DXE_UNAME_M=x86_64
DXE_UNAME_R=5.10.60-qnap
DXE_DOCKER_PATH=/usr/local/bin/docker
DXE_DOCKER_VERSION_BEGIN
Docker version 24.0.7, build afdd53b
Authorization: Bearer ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234
DXE_DOCKER_VERSION_END
DXE_DOCKER_INFO=ServerVersion=24.0.7 OSType=linux Architecture=x86_64 NCPU=8 MemTotalBytes=16000000000 CgroupDriver=cgroupfs StorageDriver=overlay2 DockerRootDir=/share/CACHEDEV1_DATA/.qpkg/container-station/docker
DXE_DOCKER_COMPOSE_VERSION=Docker Compose version v2.20.0
DXE_ROOT_DIR_FREE=500000000K free of 900000000K total
DXE_DIAL_STDIO_EXIT=0
DXE_CPU_COUNT=8
DXE_MEMINFO=MemTotal: 16384000 kB; MemAvailable: 8000000 kB;
DXE_LOADAVG=0.10 0.05 0.01 1/200 1234
DXE_TAILSCALE_PATH=/usr/sbin/tailscale
DXE_TAILSCALE_VERSION=1.60.0
DXE_QTS_VERSION=5.1.0
DXE_CONTAINER_STATION_VERSION=3.0.1
DXE_BACKUP_INDICATION=present (snapshot config file found; not read)
OUT
        exit 0
        ;;
esac
exit 0
'

# A connectable docker that records every invocation and answers with
# canned, minimal, always-successful output.
write_stub docker '
printf "docker %s\n" "$*" >> "'"$MARKER"'"
args=("$@")
case "${args[0]:-}" in -H) unset "args[0]" "args[1]"; args=("${args[@]}") ;; esac
sub="${args[0]:-}"
case "$sub" in
    version) echo "Docker version 24.0.7, build local"; exit 0 ;;
    pull) echo "digest: sha256:deadbeef"; exit 0 ;;
    inspect) echo "sha256:deadbeef"; exit 0 ;;
    build) echo "Successfully built"; exit 0 ;;
    volume)
        case "${args[1]:-}" in
            create) echo "${args[*]: -1}"; exit 0 ;;
            ls) exit 0 ;;
            rm) exit 0 ;;
        esac
        ;;
    run) exit 0 ;;
    exec) exit 0 ;;
    ps) exit 0 ;;
    rm) exit 0 ;;
    image)
        case "${args[1]:-}" in ls) exit 0 ;; esac
        ;;
    rmi) exit 0 ;;
    restart) exit 0 ;;
esac
exit 0
'

# A docker whose *labelled* queries return one container, three volumes, and
# one image, but whose *unfiltered* (full) queries additionally return an
# unrelated, non-spike resource -- proving cleanup only ever acts on the
# label-filtered set, never the full listing.
write_stub docker_with_unrelated '
printf "docker %s\n" "$*" >> "'"$MARKER"'"
args=("$@")
case "${args[0]:-}" in -H) unset "args[0]" "args[1]"; args=("${args[@]}") ;; esac
sub="${args[0]:-}"
has_label_filter=0
for a in "${args[@]}"; do
    case "$a" in "label=dxe.role=spike") has_label_filter=1 ;; esac
done
case "$sub" in
    ps)
        if [ "$has_label_filter" -eq 1 ]; then echo "dxe-spike-container"; else echo "dxe-spike-container"; echo "some-other-container"; fi
        exit 0
        ;;
    volume)
        case "${args[1]:-}" in
            ls)
                if [ "$has_label_filter" -eq 1 ]; then
                    printf "dxe-spike-nix\ndxe-spike-persist\ndxe-spike-bootstrap\n"
                else
                    printf "dxe-spike-nix\ndxe-spike-persist\ndxe-spike-bootstrap\nsome-other-volume\n"
                fi
                exit 0
                ;;
            rm) exit 0 ;;
        esac
        ;;
    image)
        case "${args[1]:-}" in
            ls)
                if [ "$has_label_filter" -eq 1 ]; then echo "dxe-spike-image:phase0"; else echo "dxe-spike-image:phase0"; echo "some-other-image:latest"; fi
                exit 0
                ;;
        esac
        ;;
    rm|rmi) exit 0 ;;
esac
exit 0
'

# An unreachable ssh: every invocation (including the mandatory preflight)
# fails exactly the way OpenSSH reports a transport failure (exit 255).
write_stub ssh_unreachable '
printf "ssh %s\n" "$*" >> "'"$MARKER"'"
exit 255
'
write_stub docker_unreachable '
printf "docker %s\n" "$*" >> "'"$MARKER"'"
exit 0
'

run_with_stubs() {
    # $1: space-separated stub names to symlink as ssh/docker for this call;
    # remaining args: the command to run.
    local names="$1"; shift
    local run_dir
    run_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-qnap-run.XXXXXX")"
    local n
    for n in $names; do ln -sf "$STUB_DIR/$n" "$run_dir/${n%%_*}"; done
    PATH="$run_dir:$PATH" "$@"
    local status=$?
    rm -rf "$run_dir"
    return $status
}

# --- (a) --dry-run prints the exact remote command list, never connects ---

reset_marker
inv_dry_out="$(run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_INV" --dry-run 2>&1)"
if [ ! -s "$MARKER" ]; then test_pass "inventory --dry-run never invokes ssh/docker"; else test_fail "inventory --dry-run never invokes ssh/docker"; fi
if printf '%s' "$inv_dry_out" | stdin_matches -F -- "section27-host" \
    && printf '%s' "$inv_dry_out" | stdin_matches -F -- "uname -m" \
    && printf '%s' "$inv_dry_out" | stdin_matches -F -- "docker -H ssh://section27-host version"; then
    test_pass "inventory --dry-run prints the exact planned remote command list"
else
    test_fail "inventory --dry-run prints the exact planned remote command list"
fi

reset_marker
spike_dry_out="$(run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --dry-run 2>&1)"
if [ ! -s "$MARKER" ]; then test_pass "spike --dry-run never invokes ssh/docker"; else test_fail "spike --dry-run never invokes ssh/docker"; fi
if printf '%s' "$spike_dry_out" | stdin_matches -F -- "DRY-RUN: docker -H ssh://section27-host pull" \
    && printf '%s' "$spike_dry_out" | stdin_matches -F -- "DRY-RUN: docker -H ssh://section27-host volume create --label dxe.role=spike dxe-spike-nix" \
    && printf '%s' "$spike_dry_out" | stdin_matches -F -- "-W 127.0.0.1:2222"; then
    test_pass "spike --dry-run prints the exact planned remote command list"
else
    test_fail "spike --dry-run prints the exact planned remote command list"
fi

# --- (b) refuses to run without DXE_QNAP_HOST reachable, before mutation ---

reset_marker
set +e
run_with_stubs "ssh_unreachable docker_unreachable" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" >"$STUB_DIR/refuse_out.log" 2>&1
refuse_status=$?
set -e
refuse_out="$(cat "$STUB_DIR/refuse_out.log")"
if [ "$refuse_status" -ne 0 ]; then test_pass "spike exits non-zero when the host is unreachable"; else test_fail "spike exits non-zero when the host is unreachable"; fi
if printf '%s' "$refuse_out" | stdin_matches -F -- "cannot reach" && printf '%s' "$refuse_out" | stdin_matches -F -- "section27-host"; then
    test_pass "spike prints a clear unreachable-host error naming the host alias"
else
    test_fail "spike prints a clear unreachable-host error naming the host alias"
fi
if [ "$(grep -c '^ssh ' "$MARKER" || true)" -eq 1 ] && ! stdin_matches -F -- "docker " <"$MARKER"; then
    test_pass "spike issues only the reachability preflight before refusing -- no docker call, no further ssh call"
else
    test_fail "spike issues only the reachability preflight before refusing -- no docker call, no further ssh call"
fi

# --- (c) every docker create/run/volume-create invocation in dry-run output ---
# --- carries the dxe-spike- name prefix and the dxe.role=spike label      ---

creation_lines="$(printf '%s\n' "$spike_dry_out" | grep -E 'DRY-RUN:.*(volume create|run -d)' || true)"
if [ -n "$creation_lines" ]; then
    all_scoped=1
    while IFS= read -r line; do
        case "$line" in
            *"$DXE_SPIKE_PREFIX"*"$DXE_SPIKE_LABEL"*) ;;
            *"$DXE_SPIKE_LABEL"*"$DXE_SPIKE_PREFIX"*) ;;
            *) all_scoped=0 ;;
        esac
    done <<<"$creation_lines"
    if [ "$all_scoped" -eq 1 ]; then
        test_pass "every dry-run volume-create/run invocation carries the dxe-spike- prefix and dxe.role=spike label"
    else
        test_fail "every dry-run volume-create/run invocation carries the dxe-spike- prefix and dxe.role=spike label"
    fi
else
    test_fail "dry-run output contains at least one volume-create/run invocation to check"
fi

# Behavioral (not source-text) proof that the actual disposable-container
# create command never asks for --privileged or CAP_SYS_ADMIN: grepping the
# whole source file would also match this script's own "no --privileged, no
# CAP_SYS_ADMIN" step-5 description text, so check the real planned argv
# instead.
run_line="$(printf '%s\n' "$spike_dry_out" | grep -E 'DRY-RUN:.*run -d' || true)"
if [ -n "$run_line" ] && ! printf '%s' "$run_line" | stdin_matches -F -- '--privileged' && ! printf '%s' "$run_line" | stdin_matches -F -- 'CAP_SYS_ADMIN'; then
    test_pass "the disposable container's run command never adds --privileged or CAP_SYS_ADMIN"
else
    test_fail "the disposable container's run command never adds --privileged or CAP_SYS_ADMIN"
fi

# --- (d) --cleanup only issues removals for labelled resources ------------

reset_marker
set +e
run_with_stubs "ssh docker_with_unrelated" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --cleanup >"$STUB_DIR/cleanup_out.log" 2>&1
cleanup_status=$?
set -e
if [ "$cleanup_status" -eq 0 ]; then test_pass "spike --cleanup exits 0 against a reachable host"; else test_fail "spike --cleanup exits 0 against a reachable host"; fi

if grep -q -- '--filter label=dxe.role=spike' "$MARKER"; then
    test_pass "--cleanup queries are scoped by label=dxe.role=spike, not a blanket listing"
else
    test_fail "--cleanup queries are scoped by label=dxe.role=spike, not a blanket listing"
fi
for expect in 'rm -f dxe-spike-container' 'volume rm dxe-spike-nix' 'volume rm dxe-spike-persist' 'volume rm dxe-spike-bootstrap' 'rmi dxe-spike-image:phase0'; do
    if grep -qF -- "$expect" "$MARKER"; then test_pass "--cleanup removes labelled resource: $expect"; else test_fail "--cleanup removes labelled resource: $expect"; fi
done
for forbidden in 'rm -f some-other-container' 'volume rm some-other-volume' 'rmi some-other-image:latest'; do
    if grep -qF -- "$forbidden" "$MARKER"; then test_fail "--cleanup never touches unrelated resource: $forbidden"; else test_pass "--cleanup never touches unrelated resource: $forbidden"; fi
done

# --cleanup is idempotent: nothing labelled left means nothing removed, exit 0.
reset_marker
set +e
run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --cleanup >"$STUB_DIR/cleanup_empty_out.log" 2>&1
cleanup_empty_status=$?
set -e
cleanup_empty_out="$(cat "$STUB_DIR/cleanup_empty_out.log")"
if [ "$cleanup_empty_status" -eq 0 ] && printf '%s' "$cleanup_empty_out" | stdin_matches -F -- "No labelled containers to remove."; then
    test_pass "--cleanup with nothing labelled left is idempotent (exit 0, no removals)"
else
    test_fail "--cleanup with nothing labelled left is idempotent (exit 0, no removals)"
fi

# --- (e) reboot/service restarts are skipped without their flags -----------

reset_marker
set +e
run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" >"$STUB_DIR/norestart_out.log" 2>&1
set -e
norestart_out="$(cat "$STUB_DIR/norestart_out.log")"
if printf '%s' "$norestart_out" | stdin_matches -F -- "Step 8a: SKIP" \
    && printf '%s' "$norestart_out" | stdin_matches -F -- "Step 8b: SKIP" \
    && printf '%s' "$norestart_out" | stdin_matches -F -- "Step 8c: SKIP"; then
    test_pass "steps 8a/8b/8c report SKIP without their flags"
else
    test_fail "steps 8a/8b/8c report SKIP without their flags"
fi
if grep -qE ' reboot$' "$MARKER"; then
    test_fail "no reboot command is ever issued without --with-nas-reboot"
else
    test_pass "no reboot command is ever issued without --with-nas-reboot"
fi
if grep -q 'restart dxe-spike-container' "$MARKER" || grep -q 'container-station.sh restart' "$MARKER"; then
    test_fail "no restart command is ever issued without --with-service-restart"
else
    test_pass "no restart command is ever issued without --with-service-restart"
fi

reset_marker
set +e
run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --with-service-restart --with-nas-reboot >"$STUB_DIR/withrestart_out.log" 2>&1
set -e
if grep -q 'restart dxe-spike-container' "$MARKER"; then test_pass "--with-service-restart issues the container restart"; else test_fail "--with-service-restart issues the container restart"; fi
if grep -q 'container-station.sh restart' "$MARKER"; then test_pass "--with-service-restart issues the Container Station restart"; else test_fail "--with-service-restart issues the Container Station restart"; fi
if grep -qE ' reboot$' "$MARKER"; then test_pass "--with-nas-reboot issues the NAS reboot"; else test_fail "--with-nas-reboot issues the NAS reboot"; fi

# --- (f) the inventory report redacts a planted token-like string ---------

REPORT_OUT="$STUB_DIR/report.md"
reset_marker
set +e
run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_INV" --report "$REPORT_OUT" >/dev/null 2>&1
inv_status=$?
set -e
if [ "$inv_status" -eq 0 ]; then test_pass "inventory exits 0 against a reachable host"; else test_fail "inventory exits 0 against a reachable host"; fi
assert_file_exists "$REPORT_OUT" "inventory writes a report file"
if [ -f "$REPORT_OUT" ]; then
    if grep -qF -- 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234' "$REPORT_OUT"; then
        test_fail "the planted token-like string is redacted from the report"
    else
        test_pass "the planted token-like string is redacted from the report"
    fi
    assert_file_contains_literal "$REPORT_OUT" '[REDACTED' "the report carries a redaction marker in its place"
    assert_file_contains_literal "$REPORT_OUT" 'Host alias:' "the report header names the host alias"
    assert_file_contains_literal "$REPORT_OUT" 'Commit:' "the report header names the script's git commit"
fi

# --- A single failing step reports FAIL and does not abort the run --------
#
# The spike script runs under its own `set -euo pipefail`. Every step calls
# a function whose last command is the real docker/ssh invocation, so a
# bare "cmd; step_verdict "$?"" pair would make the *first* failing step
# kill the whole script before it could ever print FAIL or reach later
# steps/cleanup -- exactly the bug this test caught by hand while writing
# phase0-spike.sh (see the branch progress file). Force step 2's base-image
# pull to fail and confirm steps 3-9 still run and the run still exits
# non-zero (not merely "some assertion never ran").
write_stub docker_step2_fails '
printf "docker %s\n" "$*" >> "'"$MARKER"'"
args=("$@")
case "${args[0]:-}" in -H) unset "args[0]" "args[1]"; args=("${args[@]}") ;; esac
sub="${args[0]:-}"
case "$sub" in
    pull) exit 1 ;;
    volume)
        case "${args[1]:-}" in create) echo "${args[*]: -1}"; exit 0 ;; ls|rm) exit 0 ;; esac
        ;;
    image)
        case "${args[1]:-}" in ls) exit 0 ;; esac
        ;;
    version|inspect|build|run|exec|ps|rm|rmi|restart) exit 0 ;;
esac
exit 0
'

reset_marker
set +e
run_with_stubs "ssh docker_step2_fails" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" >"$STUB_DIR/step2fail_out.log" 2>&1
step2fail_status=$?
set -e
step2fail_out="$(cat "$STUB_DIR/step2fail_out.log")"
if [ "$step2fail_status" -ne 0 ]; then
    test_pass "a failing step still exits the run non-zero overall"
else
    test_fail "a failing step still exits the run non-zero overall"
fi
if printf '%s' "$step2fail_out" | stdin_matches -F -- "Step 2: FAIL"; then
    test_pass "the failing step is reported as FAIL rather than aborting silently"
else
    test_fail "the failing step is reported as FAIL rather than aborting silently"
fi
if printf '%s' "$step2fail_out" | stdin_matches -F -- "Step 5: PASS" && printf '%s' "$step2fail_out" | stdin_matches -F -- "Step 9:"; then
    test_pass "steps after a failing step still run (no set -e abort mid-run)"
else
    test_fail "steps after a failing step still run (no set -e abort mid-run)"
fi

print_summary
exit_with_code
