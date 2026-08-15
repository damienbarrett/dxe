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

source "$BASE_DIR/bin/dx-forward"
if [ "$(parse_all_forwards 5173 8000:8001)" = $'5173:5173\n8001:8000' ]; then test_pass "forward wrapper parses direction-specific mappings"; else test_fail "forward wrapper parses direction-specific mappings"; fi
if parse_all_forwards 80 >/dev/null 2>&1; then test_fail "forward wrapper rejects privileged host ports"; else test_pass "forward wrapper rejects privileged host ports"; fi
source "$BASE_DIR/bin/dx-reverse"
if [ "$(parse_all_reverses 5432 3000:13000)" = $'5432:5432\n13000:3000' ]; then test_pass "reverse wrapper parses direction-specific mappings"; else test_fail "reverse wrapper parses direction-specific mappings"; fi

assert_file_not_contains "$BASE_DIR/bin/dx-forward" 'DX_FORWARD_TEST_MODE' "forward has no production test seam"
assert_file_not_contains "$BASE_DIR/bin/dx-reverse" 'DX_REVERSE_TEST_MODE' "reverse has no production test seam"
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
