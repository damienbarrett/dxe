#!/bin/bash
# Section 3: Split Bootstrap From Runtime
# Tests for: bootstrap.sh structure, idempotency, functions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 3: Split Bootstrap From Runtime"

# Test: bootstrap.sh exists
assert_file_exists "$BOOTSTRAP" "bootstrap.sh exists"

# Test: bootstrap.sh uses set -euo pipefail
assert_file_contains "$BOOTSTRAP" "set -euo pipefail" "bootstrap.sh uses set -euo pipefail"

# Test: bootstrap.sh has functions defined
if grep -q "^[a-zA-Z_][a-zA-Z0-9_]*() {" "$BOOTSTRAP" || grep -q "^function " "$BOOTSTRAP"; then
    test_pass "bootstrap.sh has functions defined"
else
    test_fail "bootstrap.sh has functions defined"
fi

# Test: bootstrap.sh checks if dx user exists before creating
assert_file_contains "$BOOTSTRAP" "id -u dx" "bootstrap.sh checks if dx user exists"

# Test: bootstrap.sh prevents duplicate shell config
# Home Manager-managed shell files are idempotent; direct .bashrc appends must be guarded.
if grep -q "home-manager\|homeConfigurations" "$BOOTSTRAP" || grep -q "grep.*bashrc\|!.*grep.*bashrc" "$BOOTSTRAP"; then
    test_pass "bootstrap.sh prevents duplicate shell config"
else
    test_fail "bootstrap.sh prevents duplicate shell config"
fi

# Test: bootstrap.sh checks if sshd is running before starting
if grep -q "sshd.*running\|pgrep.*sshd\|ps.*sshd" "$BOOTSTRAP"; then
    test_pass "bootstrap.sh checks if sshd is already running"
else
    test_fail "bootstrap.sh checks if sshd is already running"
fi

# Test: bootstrap.sh preserves passwordless sudo
assert_file_contains "$BOOTSTRAP" "dx ALL=(ALL) NOPASSWD:ALL" "bootstrap.sh keeps passwordless sudo for dx"

# Test: bootstrap repairs Nix store ownership for older persistent volumes
assert_file_contains "$BOOTSTRAP" "ensure_nix_ownership" "bootstrap centralizes Nix ownership repair"
assert_file_contains "$BOOTSTRAP" "stat -c '%u:%g'" "bootstrap verifies Nix ownership marker owner"
assert_file_contains "$BOOTSTRAP" "chown dx:dx \"\$sentinel\"" "bootstrap marks repaired Nix ownership as dx-owned"

# Test: Home Manager activation is bounded and retryable so Nix substitutes
# cannot wedge the guest before sshd starts.
assert_file_contains "$BOOTSTRAP" "DX_GUEST_ACTIVATION_TIMEOUT" "bootstrap exposes a guest activation timeout"
assert_file_contains "$BOOTSTRAP" "DX_GUEST_ACTIVATION_ATTEMPTS" "bootstrap exposes guest activation attempts"
assert_file_contains "$BOOTSTRAP" "run_as_dx_with_timeout" "bootstrap can run dx commands with a timeout"
assert_file_contains "$BOOTSTRAP" "timeout --kill-after=30s" "bootstrap kills stuck activation process groups"
assert_file_contains "$BOOTSTRAP" "run_home_manager_activation" "bootstrap centralizes Home Manager activation"
assert_file_contains "$BOOTSTRAP" "stalled-download-timeout 60" "bootstrap bounds stalled Nix downloads during activation"
assert_file_contains "$BOOTSTRAP" "Retrying Home Manager activation" "bootstrap retries failed activation before giving up"

# A clean Nix store must have enough wall-clock time to download and activate
# the complete Home Manager closure.
BOOTSTRAP_FUNCTIONS="$(mktemp)"
sed '/^# Main$/,$d' "$BOOTSTRAP" > "$BOOTSTRAP_FUNCTIONS"
BOOTSTRAP_DEFAULT_TIMEOUT="$(
    (
        unset DX_GUEST_ACTIVATION_TIMEOUT
        source "$BOOTSTRAP_FUNCTIONS"
        DX_GUEST_ACTIVATION_ATTEMPTS=1
        run_as_dx_with_timeout() {
            printf '%s\n' "$1"
            return 0
        }
        run_home_manager_activation
    ) | tail -1
)"
if [ "$BOOTSTRAP_DEFAULT_TIMEOUT" = "1800" ]; then
    test_pass "bootstrap gives a fresh Home Manager activation a 30-minute default window"
else
    test_fail "bootstrap gives a fresh Home Manager activation a 30-minute default window"
fi

# Exercise the activation retry function without running the bootstrap main
# routine. A failed final attempt must retain the command's real status so the
# container exits and the host can report the failure.
BOOTSTRAP_ACTIVATION_OUTPUT="$(mktemp)"
set +e
(
    source "$BOOTSTRAP_FUNCTIONS"
    DX_GUEST_ACTIVATION_TIMEOUT=1
    DX_GUEST_ACTIVATION_ATTEMPTS=1
    DX_GUEST_ACTIVATION_RETRY_DELAY=1
    run_as_dx_with_timeout() {
        return 42
    }
    run_home_manager_activation
) >"$BOOTSTRAP_ACTIVATION_OUTPUT" 2>&1
BOOTSTRAP_ACTIVATION_STATUS=$?
set -e
if [ "$BOOTSTRAP_ACTIVATION_STATUS" -eq 42 ] \
    && grep -q "failed with exit status 42" "$BOOTSTRAP_ACTIVATION_OUTPUT"; then
    test_pass "bootstrap preserves the final Home Manager activation failure"
else
    test_fail "bootstrap preserves the final Home Manager activation failure"
fi
rm -f "$BOOTSTRAP_FUNCTIONS" "$BOOTSTRAP_ACTIVATION_OUTPUT"

# The user-visible ~/persist/home path must remain writable after a fresh
# volume creates its intermediate directories as root.
assert_file_contains "$BOOTSTRAP" \
    "install -d -o dx -g dx -m 0755 /persist/home /persist/home/dx" \
    "bootstrap gives dx ownership of persistent home directories"

# Minimal base images do not provide /etc/os-release; bootstrap must publish
# the release identity declared by the pinned flake.
assert_file_contains "$BOOTSTRAP" "configure_release_identity" "bootstrap centralizes guest release identity"
assert_file_contains "$BOOTSTRAP" "VERSION_ID=\\\"\$release\\\"" "bootstrap writes the pinned release to os-release"

# Test: bootstrap initializes persisted Claude config as valid JSON
assert_file_not_contains "$BOOTSTRAP" "touch /persist/home/dx/.claude.json" "bootstrap does not create empty Claude JSON config"
assert_file_contains "$BOOTSTRAP" "printf '%s\\\\n' '{}' > /persist/home/dx/.claude.json" "bootstrap initializes empty Claude config as JSON"

# Test: bootstrap persists GitHub CLI auth/config across rebuilds
assert_file_contains "$BOOTSTRAP" "/persist/home/dx/.config/gh" "bootstrap persists GitHub CLI config under persist storage"
assert_file_contains "$BOOTSTRAP" "ln -sfnT /persist/home/dx/.config/gh /home/dx/.config/gh" "bootstrap links GitHub CLI config into home"
GH_PERSIST_LINE=$(grep -n "^[[:space:]]*setup_gh_persistence$" "$BOOTSTRAP" | head -1 | cut -d: -f1 || echo "")
AI_GATE_LINE=$(grep -n "dx-ai-tools" "$BOOTSTRAP" | head -1 | cut -d: -f1 || echo "")
if [ -n "$GH_PERSIST_LINE" ] && { [ -z "$AI_GATE_LINE" ] || [ "$GH_PERSIST_LINE" -lt "$AI_GATE_LINE" ]; }; then
    test_pass "GitHub CLI persistence is not gated by optional AI tools"
else
    test_fail "GitHub CLI persistence is not gated by optional AI tools"
fi

# Test: bootstrap creates the tmux-resurrect save directory on persistent
# storage (Home Manager cannot create it because /persist is a runtime mount).
assert_file_contains "$BOOTSTRAP" "install -d -o dx -g dx -m 0755 /persist/home/dx/.local/share/tmux/resurrect" "bootstrap creates the persisted tmux-resurrect directory"
RSR_PERSIST_LINE=$(grep -n "^[[:space:]]*setup_tmux_persistence$" "$BOOTSTRAP" | head -1 | cut -d: -f1 || echo "")
if [ -n "$RSR_PERSIST_LINE" ] && { [ -z "$AI_GATE_LINE" ] || [ "$RSR_PERSIST_LINE" -lt "$AI_GATE_LINE" ]; }; then
    test_pass "tmux-resurrect persistence is not gated by optional AI tools"
else
    test_fail "tmux-resurrect persistence is not gated by optional AI tools"
fi

# Test: bootstrap.sh is idempotent for user creation
# Check that user creation is conditional
assert_file_contains "$BOOTSTRAP" "if.*id -u dx" "bootstrap.sh conditionally creates dx user"

# Test: sshd starts only after guest tools are installed and verified
INSTALL_CALL=$(grep -n "^configure_guest$" "$BOOTSTRAP" | tail -1 | cut -d: -f1 || echo "")
VERIFY_CALL=$(grep -n "^verify_guest_tools$" "$BOOTSTRAP" | tail -1 | cut -d: -f1 || echo "")
START_SSH_CALL=$(grep -n "^exec \\\"\$SSHD_BIN\\\"" "$BOOTSTRAP" | tail -1 | cut -d: -f1 || echo "")
if [ -n "$INSTALL_CALL" ] && [ -n "$VERIFY_CALL" ] && [ -n "$START_SSH_CALL" ] &&
    [ "$INSTALL_CALL" -lt "$VERIFY_CALL" ] && [ "$VERIFY_CALL" -lt "$START_SSH_CALL" ]; then
    test_pass "bootstrap.sh starts sshd after guest tools are verified"
else
    test_fail "bootstrap.sh starts sshd after guest tools are verified"
fi

# Test: declarative timezone configuration exists
assert_file_contains "$FLAKE_NIX" "tzdata" "flake.nix includes tzdata"
assert_file_contains "$BOOTSTRAP" "resolve_timezone_file" "bootstrap centralizes timezone file resolution"
assert_file_contains "$BOOTSTRAP" "/nix/store -path" "bootstrap resolves timezone data directly from the Nix store"
assert_file_contains "$BOOTSTRAP" "/home/dx/.nix-profile/bin/find" "bootstrap can use find from the dx Nix profile"
assert_file_contains "$BOOTSTRAP" "/home/dx/.nix-profile/share/zoneinfo" "bootstrap falls back to user profile timezone data"
assert_file_contains "$BOOTSTRAP" "run_as_dx 'printf %s \"\${TZDIR:-}\"'" "bootstrap keeps guest shell TZDIR as a last-resort fallback"
assert_file_contains "$BOOTSTRAP" "/etc/timezone" "bootstrap writes textual timezone for tools that do not infer localtime symlinks"
TZ_CALL=$(grep -n "^configure_timezone" "$BOOTSTRAP" | tail -1 | cut -d: -f1 || echo "")
if [ -n "$VERIFY_CALL" ] && [ -n "$TZ_CALL" ] && [ "$VERIFY_CALL" -lt "$TZ_CALL" ]; then
    test_pass "bootstrap configures timezone after guest tools are verified"
else
    test_fail "bootstrap configures timezone after guest tools are verified"
fi
assert_file_contains "$SHELL_NIX" "TZ = \":/etc/localtime\"" "shell.nix points Bash/Fish TZ at /etc/localtime"
assert_file_contains "$SHELL_NIX" "TZDIR = \"\${pkgs.tzdata}/share/zoneinfo\"" "shell.nix sets TZDIR for Bash/Fish"
assert_file_contains "$SHELL_NIX" "\$env.TZ = \":/etc/localtime\"" "shell.nix points Nushell TZ at /etc/localtime"
assert_file_contains "$SHELL_NIX" "\$env.TZDIR = \"\${pkgs.tzdata}/share/zoneinfo\"" "shell.nix sets TZDIR for Nushell"

# Test: bash syntax check
if bash -n "$BOOTSTRAP" 2>/dev/null; then
    test_pass "bootstrap.sh passes bash syntax check"
else
    test_fail "bootstrap.sh passes bash syntax check"
fi

# -----------------------------------------------------------------------------
# nix-base-plan.md change 2: bootstrap.sh edits + temporary old-base guard.
# The guard assertions below (both the regression checks and the behavioral
# fixtures) land in the same commit as the base-image FROM flip and are
# removed together with guard_old_base and dx-start-container's host-site
# guard once every machine (primary, side containers, profiles) has changed
# over -- see nix-base-plan.md's Decisions section.
# -----------------------------------------------------------------------------

# Test: shebang is the portable form. The official base's entrypoint loop
# execs this script directly; a hardcoded #!/bin/bash fails with ENOENT
# because the official image has no /bin/bash.
if [ "$(head -n1 "$BOOTSTRAP")" = "#!/usr/bin/env bash" ]; then
    test_pass "bootstrap.sh shebang is exactly #!/usr/bin/env bash"
else
    test_fail "bootstrap.sh shebang is exactly #!/usr/bin/env bash"
fi

# Test: create_user requests /bin/sh, not /bin/bash, for the dx login shell
# (nushell replaces it at the end of configure_guest anyway).
assert_file_contains "$BOOTSTRAP" "useradd -m -g dx -s /bin/sh dx" "bootstrap.sh creates dx with -s /bin/sh"
if grep "useradd" "$BOOTSTRAP" | grep -q -- "-s /bin/bash"; then
    test_fail "no useradd line in bootstrap.sh requests -s /bin/bash"
else
    test_pass "no useradd line in bootstrap.sh requests -s /bin/bash"
fi

# Test: no /bin/bash reference survives in bootstrap.sh outside guard_old_base
# itself (the guard necessarily contains the string it tests for -- pass 5).
GUARD_DEF_LINE="$(grep -n '^guard_old_base()' "$BOOTSTRAP" | head -1 | cut -d: -f1 || echo "")"
GUARD_END_LINE=""
if [ -n "$GUARD_DEF_LINE" ]; then
    GUARD_END_LINE="$(awk -v start="$GUARD_DEF_LINE" 'NR > start && /^}/ { print NR; exit }' "$BOOTSTRAP")"
fi

if [ -n "$GUARD_DEF_LINE" ] && [ -n "$GUARD_END_LINE" ]; then
    BOOTSTRAP_SANS_GUARD="$(mktemp)"
    sed "${GUARD_DEF_LINE},${GUARD_END_LINE}d" "$BOOTSTRAP" > "$BOOTSTRAP_SANS_GUARD"
    if ! grep -q "/bin/bash" "$BOOTSTRAP_SANS_GUARD"; then
        test_pass "bootstrap.sh has no /bin/bash reference outside guard_old_base"
    else
        test_fail "bootstrap.sh has no /bin/bash reference outside guard_old_base"
    fi
    rm -f "$BOOTSTRAP_SANS_GUARD"
else
    test_fail "bootstrap.sh has no /bin/bash reference outside guard_old_base"
fi

# The rest of the guest payload directory (Containerfile, flake.nix, home/,
# scripts/, etc.) must carry no /bin/bash reference at all.
PAYLOAD_BASH_HITS="$(grep -rl "/bin/bash" "$CONTAINER_DIR" 2>/dev/null | grep -vx "$BOOTSTRAP" || true)"
if [ -z "$PAYLOAD_BASH_HITS" ]; then
    test_pass "no /bin/bash reference elsewhere in the guest payload directory"
else
    test_fail "no /bin/bash reference elsewhere in the guest payload directory"
fi

# Test: both temporary guard sites are present -- bootstrap.sh defines
# guard_old_base above # Main and invokes it inside # Main (a top-level
# invocation above # Main would explode when this file's BOOTSTRAP_FUNCTIONS
# is sourced above, since /bin/bash exists on this macOS test host).
MAIN_SECTION_LINE="$(grep -n '^# Main$' "$BOOTSTRAP" | head -1 | cut -d: -f1 || echo "")"
GUARD_CALL_LINE="$(grep -n '^guard_old_base$' "$BOOTSTRAP" | head -1 | cut -d: -f1 || echo "")"
if [ -n "$GUARD_DEF_LINE" ] && [ -n "$MAIN_SECTION_LINE" ] && [ -n "$GUARD_CALL_LINE" ] \
    && [ "$GUARD_DEF_LINE" -lt "$MAIN_SECTION_LINE" ] && [ "$GUARD_CALL_LINE" -gt "$MAIN_SECTION_LINE" ]; then
    test_pass "bootstrap.sh defines guard_old_base above Main and invokes it only inside Main"
else
    test_fail "bootstrap.sh defines guard_old_base above Main and invokes it only inside Main"
fi

assert_file_contains "$BASE_DIR/bin/dx-start-container" "OLD_BASE" \
    "dx-start-container carries the host-site old-base guard (OLD_BASE token check)"

# Test: guard_old_base's guard-only test-mode entry point exits before any
# bootstrap step, and its filesystem check reads DX_GUARD_ROOT so behavioral
# coverage needs no disposable containers (pass 4/5 harness).
DX_GUARD_TEST_TMP="$(mktemp -d)"
DX_GUARD_ROOT_ABSENT="$DX_GUARD_TEST_TMP/absent-base"
DX_GUARD_ROOT_REGULAR="$DX_GUARD_TEST_TMP/regular-file-base"
DX_GUARD_ROOT_DANGLING="$DX_GUARD_TEST_TMP/dangling-symlink-base"
mkdir -p "$DX_GUARD_ROOT_ABSENT" "$DX_GUARD_ROOT_REGULAR/bin" "$DX_GUARD_ROOT_DANGLING/bin"
: > "$DX_GUARD_ROOT_REGULAR/bin/bash"
ln -s /nonexistent-dx-guard-test-target "$DX_GUARD_ROOT_DANGLING/bin/bash"

DX_GUARD_PASS_OUT="$(mktemp)"
set +e
DX_GUARD_ROOT="$DX_GUARD_ROOT_ABSENT" DX_BOOTSTRAP_TEST_MODE=guard bash "$BOOTSTRAP" >"$DX_GUARD_PASS_OUT" 2>&1
DX_GUARD_PASS_STATUS=$?
set -e
if [ "$DX_GUARD_PASS_STATUS" -eq 0 ] \
    && ! grep -qE "Installing essential tools|Setting up dedicated Nix volume|Configuring Nix daemon|Creating user dx" "$DX_GUARD_PASS_OUT"; then
    test_pass "guard_old_base passes when DX_GUARD_ROOT/bin/bash is absent, and DX_BOOTSTRAP_TEST_MODE=guard exits before any bootstrap step runs"
else
    test_fail "guard_old_base passes when DX_GUARD_ROOT/bin/bash is absent, and DX_BOOTSTRAP_TEST_MODE=guard exits before any bootstrap step runs"
fi

DX_GUARD_REGULAR_OUT="$(mktemp)"
set +e
DX_GUARD_ROOT="$DX_GUARD_ROOT_REGULAR" DX_BOOTSTRAP_TEST_MODE=guard bash "$BOOTSTRAP" >"$DX_GUARD_REGULAR_OUT" 2>&1
DX_GUARD_REGULAR_STATUS=$?
set -e
if [ "$DX_GUARD_REGULAR_STATUS" -ne 0 ] \
    && grep -qi "nix-base-plan.md" "$DX_GUARD_REGULAR_OUT" \
    && grep -qi "flakes-base" "$DX_GUARD_REGULAR_OUT"; then
    test_pass "guard_old_base fails closed on a regular DX_GUARD_ROOT/bin/bash file, naming the changeover procedure"
else
    test_fail "guard_old_base fails closed on a regular DX_GUARD_ROOT/bin/bash file, naming the changeover procedure"
fi

DX_GUARD_DANGLING_OUT="$(mktemp)"
set +e
DX_GUARD_ROOT="$DX_GUARD_ROOT_DANGLING" DX_BOOTSTRAP_TEST_MODE=guard bash "$BOOTSTRAP" >"$DX_GUARD_DANGLING_OUT" 2>&1
DX_GUARD_DANGLING_STATUS=$?
set -e
if [ "$DX_GUARD_DANGLING_STATUS" -ne 0 ] \
    && grep -qi "nix-base-plan.md" "$DX_GUARD_DANGLING_OUT" \
    && grep -qi "flakes-base" "$DX_GUARD_DANGLING_OUT"; then
    test_pass "guard_old_base fails closed on a dangling DX_GUARD_ROOT/bin/bash symlink, naming the changeover procedure"
else
    test_fail "guard_old_base fails closed on a dangling DX_GUARD_ROOT/bin/bash symlink, naming the changeover procedure"
fi

rm -f "$DX_GUARD_PASS_OUT" "$DX_GUARD_REGULAR_OUT" "$DX_GUARD_DANGLING_OUT"
rm -rf "$DX_GUARD_TEST_TMP"

print_summary
exit_with_code
