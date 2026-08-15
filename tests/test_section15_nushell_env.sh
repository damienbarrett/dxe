#!/bin/bash
# Section 15: Nushell Environment Configuration
# Verifies the nushell envFile (home/shell.nix) uses proper string
# interpolation rather than single-quoted literals like '($home)/...'.
# Single-quoted nushell strings are literal — they don't expand $home,
# so SSL_CERT_FILE ends up as a non-existent path and git/curl fail with
# "unable to get local issuer certificate".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 15: Nushell Environment"

# ---------- Static checks (no container needed) ----------

assert_file_exists "$SHELL_NIX" "home/shell.nix exists"

# Negative: any nushell-style single-quoted ($home) literal in SSL/PATH lines is a bug.
if grep -E "(SSL_CERT_FILE|NIX_SSL_CERT_FILE|env\.PATH).*'\(\\\$home\)" "$SHELL_NIX" >/dev/null 2>&1; then
    test_fail "shell.nix uses literal '(\$home) in nushell envFile (no interpolation)"
else
    test_pass "shell.nix avoids literal '(\$home) in nushell envFile"
fi

# Positive: SSL paths use $"($nu.home-dir)/..." interpolation.
if grep -E '\$env\.SSL_CERT_FILE.*\$"\(\$nu\.home-dir\)' "$SHELL_NIX" >/dev/null 2>&1; then
    test_pass "shell.nix SSL_CERT_FILE uses \$\"(\$nu.home-dir)/...\" interpolation"
else
    test_fail "shell.nix SSL_CERT_FILE uses \$\"(\$nu.home-dir)/...\" interpolation"
fi
if grep -E '\$env\.NIX_SSL_CERT_FILE.*\$"\(\$nu\.home-dir\)' "$SHELL_NIX" >/dev/null 2>&1; then
    test_pass "shell.nix NIX_SSL_CERT_FILE uses \$\"(\$nu.home-dir)/...\" interpolation"
else
    test_fail "shell.nix NIX_SSL_CERT_FILE uses \$\"(\$nu.home-dir)/...\" interpolation"
fi

if grep -E '\$env\.PATH.*\$"\(\$nu\.home-dir\)/\.local/bin"' "$SHELL_NIX" >/dev/null 2>&1; then
    test_pass "shell.nix adds ~/.local/bin to nushell PATH"
else
    test_fail "shell.nix adds ~/.local/bin to nushell PATH"
fi

if grep -Fq '$env.TZ = ":/etc/localtime"' "$SHELL_NIX"; then
    test_pass "shell.nix points nushell TZ at /etc/localtime"
else
    test_fail "shell.nix points nushell TZ at /etc/localtime"
fi

if grep -Eq 'LG_CONFIG_FILE.*path exists|path exists.*LG_CONFIG_FILE' "$SHELL_NIX"; then
    test_pass "shell.nix configures lazygit config conditionally"
else
    test_fail "shell.nix configures lazygit config conditionally"
fi

if grep -q -- "split row.*--max" "$SHELL_NIX"; then
    test_fail "nushell keyring env parsing avoids unsupported split row --max"
else
    test_pass "nushell keyring env parsing avoids unsupported split row --max"
fi

# Fish snippets live inside a Nix indented string, where two adjacent single
# quotes terminate/escape the Nix string instead of representing a Fish empty
# string literal. Use double quotes for empty Fish strings in this file.
if sed -n '/programs\.fish =/,/programs\.nushell =/p' "$SHELL_NIX" | grep -E "string replace.*''" >/dev/null 2>&1; then
    test_fail "fish shell init avoids Nix-breaking adjacent single quotes"
else
    test_pass "fish shell init avoids Nix-breaking adjacent single quotes"
fi

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "nushell SSH/SCP guest runtime checks (--skip-integration)"
    print_summary
    exit_with_code
fi

# ---------- Runtime checks (require running container) ----------

if ! requires_container; then
    print_summary
    exit_with_code
fi

if ! wait_for_ssh 60; then
    test_fail "SSH not reachable on localhost:$DX_SSH_PORT"
    print_summary
    exit_with_code
fi

SSH_COMMON_OPTS=(
    "-i" "$DX_SSH_KEY"
    "-o" "StrictHostKeyChecking=no"
    "-o" "UserKnownHostsFile=/dev/null"
    "-o" "IdentitiesOnly=yes"
    "-o" "BatchMode=yes"
    "-o" "ConnectTimeout=5"
)
# ssh uses -p for port; scp uses -P. Keep them separate.
SSH_OPTS=("${SSH_COMMON_OPTS[@]}" "-p" "$DX_SSH_PORT")
SCP_OPTS=("${SSH_COMMON_OPTS[@]}" "-P" "$DX_SSH_PORT")

# Run a nushell script inside the guest. We scp the script over rather than
# trying to embed it in an ssh command — quoting through ssh + bash + nu
# eats nushell's $"..." interpolation syntax.
run_nu() {
    local script="$1"
    local local_tmp remote_path
    local_tmp=$(mktemp -t dx_nu_probe.XXXXXX)
    remote_path="/tmp/$(basename "$local_tmp").nu"
    printf '%s\n' "$script" > "$local_tmp"
    scp "${SCP_OPTS[@]}" "$local_tmp" "dx@127.0.0.1:$remote_path" >/dev/null 2>&1
    local rc=$?
    rm -f "$local_tmp"
    [ $rc -eq 0 ] || return $rc
    ssh "${SSH_OPTS[@]}" dx@127.0.0.1 "bash -lc 'nu $remote_path; rc=\$?; rm -f $remote_path; exit \$rc'"
}

# Probe: source env.nu (this is what an interactive nushell session does on
# startup) and confirm the cert vars resolve to real files.
# Use a single-quoted bash string rather than a heredoc — bash 3.2 (the
# default on macOS) strips $"..." (locale translation) from quoted heredocs,
# which mangles nushell's interpolation syntax.
PROBE='source ~/.config/nushell/env.nu
let s = ($env.SSL_CERT_FILE? | default "")
let n = ($env.NIX_SSL_CERT_FILE? | default "")
print $"SSL=($s)"
print $"NIX=($n)"
print $"SSL_EXISTS=($s | path exists)"
print $"NIX_EXISTS=($n | path exists)"'

PROBE_OUT=$(run_nu "$PROBE" 2>&1 || true)

if echo "$PROBE_OUT" | stdin_matches "^SSL_EXISTS=true$"; then
    test_pass "nushell SSL_CERT_FILE resolves to an existing file after sourcing env.nu"
else
    line=$(echo "$PROBE_OUT" | grep -E "^SSL=" | head -1)
    test_fail "nushell SSL_CERT_FILE does not resolve to an existing file (${line:-no output})"
fi

if echo "$PROBE_OUT" | stdin_matches "^NIX_EXISTS=true$"; then
    test_pass "nushell NIX_SSL_CERT_FILE resolves to an existing file after sourcing env.nu"
else
    line=$(echo "$PROBE_OUT" | grep -E "^NIX=" | head -1)
    test_fail "nushell NIX_SSL_CERT_FILE does not resolve to an existing file (${line:-no output})"
fi

LAZYGIT_PROBE='source ~/.config/nushell/env.nu
let repo = (mktemp -d)
cd $repo
^git init -q
let result = (^timeout 3 lazygit | complete)
print $"LG_EXIT=($result.exit_code)"
print $"LG_STDERR=($result.stderr)"'

LAZYGIT_PROBE_OUT=$(run_nu "$LAZYGIT_PROBE" 2>&1 || true)

if echo "$LAZYGIT_PROBE_OUT" | stdin_matches "stat /home/dx/.cache/dx/tinty/lazygit.yml"; then
    test_fail "nushell still points lazygit at a missing tinted theme file"
else
    test_pass "nushell can launch lazygit without the missing tinted theme file"
fi

print_summary
exit_with_code
