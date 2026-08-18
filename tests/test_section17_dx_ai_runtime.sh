#!/bin/bash
# Section 17: dx-ai Runtime
# Verifies the optional AI tool installer works from inside the running guest.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 17: dx-ai Runtime"

AI_SCRIPT="$CONTAINER_DIR/scripts/dx-ai.sh"
before_flags=$-
# shellcheck source=/dev/null
source "$AI_SCRIPT"
if [ "$before_flags" = "$-" ] \
    && declare -F dx_ai_refresh_pin >/dev/null && declare -F dx_ai_stage_generation >/dev/null \
    && declare -F dx_ai_validate_generation >/dev/null && declare -F dx_ai_publish_generation >/dev/null \
    && declare -F dx_ai_recover_generation >/dev/null; then
    test_pass "dx-ai is a sourceable main with focused generation functions"
else
    test_fail "dx-ai is a sourceable main with focused generation functions"
fi
assert_file_not_contains "$AI_SCRIPT" 'cd /guest-bootstrap' "dx-ai never changes into the published payload"
assert_file_not_contains "$AI_SCRIPT" 'sed -i' "dx-ai pin refresh is independent of Nix source formatting"
assert_file_contains_literal "$AI_SCRIPT" '/persist/home/dx/.local/state/dx-ai' "dx-ai mutable generations live under persist"

ai_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-ai-generations.XXXXXX")"
trap 'chmod -R u+w "$ai_fixture" 2>/dev/null || true; rm -rf "$ai_fixture"' EXIT
published="$ai_fixture/published"; state="$ai_fixture/state"
mkdir -p "$published/pins" "$state/generations/previous"
printf '%s\n' '{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"}' > "$published/pins/agy.json"
printf '%s\n' fixture > "$published/flake.nix"
printf '%s\n' fixture > "$published/flake.lock"
seed_ai_profile() {
    local generation="$1" tool
    mkdir -p "$generation/profile/bin"
    for tool in codex gemini claude agy herdr; do printf '#!/bin/sh\n' > "$generation/profile/bin/$tool"; chmod 0755 "$generation/profile/bin/$tool"; done
}
cp -a "$published/." "$state/generations/previous/"
printf '%s\n' '' > "$state/generations/previous/.predecessor"
seed_ai_profile "$state/generations/previous"
ln -s generations/previous "$state/current"
real_mv="$(command -v mv)"
mv() {
    if [ "${1:-}" = -Tf ]; then rm -f "$3"; "$real_mv" -f "$2" "$3"; else "$real_mv" "$@"; fi
}
stage="$(dx_ai_stage_generation "$published" "$state" next)"
if [ "$(cat "$stage/.predecessor")" = previous ] && [ "$(cat "$published/flake.nix")" = fixture ]; then
    test_pass "AI staging records predecessor without mutating published bootstrap"
else
    test_fail "AI staging records predecessor without mutating published bootstrap"
fi
seed_ai_profile "$stage"
dx_ai_publish_generation "$state" next "$stage"
if [ "$(readlink "$state/current")" = generations/next ] && [ -d "$state/generations/previous" ]; then
    test_pass "AI publication atomically advances current and retains predecessor"
else
    test_fail "AI publication atomically advances current and retains predecessor"
fi

failed_stage="$(dx_ai_stage_generation "$published" "$state" failed)"
seed_ai_profile "$failed_stage"
if (
    set -e
    mv() { [ "${1:-}" != -Tf ] || return 1; "$real_mv" "$@"; }
    dx_ai_publish_generation "$state" failed "$failed_stage"
); then
    test_fail "AI pointer publication failure is reported"
else
    test_pass "AI pointer publication failure is reported"
fi
if [ "$(readlink "$state/current")" = generations/next ] && [ -d "$state/generations/previous" ]; then
    test_pass "failed AI pointer switch preserves current and predecessor"
else
    test_fail "failed AI pointer switch preserves current and predecessor"
fi

if dx_ai_recover_generation "$state" >/dev/null && [ "$(readlink "$state/current")" = generations/previous ]; then
    test_pass "AI recovery atomically selects the retained predecessor"
else
    test_fail "AI recovery atomically selects the retained predecessor"
fi

pin_before="$(shasum -a 256 "$published/pins/agy.json")"
if (
    curl() { printf '%s\n' '{}'; }
    jq() { printf '%s' ''; }
    dx_ai_refresh_pin "$published"
); then
    test_pass "malformed upstream AI manifest is non-destructive"
else
    test_fail "malformed upstream AI manifest is non-destructive"
fi
if [ "$pin_before" = "$(shasum -a 256 "$published/pins/agy.json")" ]; then test_pass "malformed AI manifest leaves pin unchanged"; else test_fail "malformed AI manifest leaves pin unchanged"; fi

# R5: an unavailable boot ID is not an identity. In that environment dx-ai
# must fail before touching a live owner's lock rather than parse an empty
# first TSV field and reclaim it as stale.
if (
    proc_root="$ai_fixture/no-identity-proc"
    lock="$ai_fixture/missing-identity.lock"
    mkdir -p "$proc_root" "$lock"
    printf 'old-boot\t999\t123\n' > "$lock/owner"
    set +e
    out="$(dx_ai_lock_acquire "$lock" "$proc_root" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 1 ] && [ -d "$lock" ] && [ "$(cat "$lock/owner")" = $'old-boot\t999\t123' ] && printf '%s\n' "$out" | stdin_matches "cannot identify lock owner process"
); then
    test_pass "dx-ai refuses lock acquisition when all process identities are unavailable (R5)"
else
    test_fail "dx-ai refuses lock acquisition when all process identities are unavailable (R5)"
fi

# R5: parse field 22 in Bash, including a comm field containing a closing
# parenthesis and spaces. This runs before the lock code needs the identity,
# so no external awk can be required in the early guest bootstrap path.
proc_root="$ai_fixture/proc-identity"
mkdir -p "$proc_root/sys/kernel/random" "$proc_root/4242"
printf '%s\n' '4242 (worker ) with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 424242' > "$proc_root/4242/stat"
printf '%s\n' 'btime 1785827572' > "$proc_root/stat"
printf '%s\n' 'a1b2c3d4-e5f6-7890-abcd-ef0123456789' > "$proc_root/sys/kernel/random/boot_id"
if [ "$(dx_ai_process_start 4242 "$proc_root")" = 424242 ]; then
    test_pass "dx-ai parses proc stat starttime in Bash with a complex comm field (R5)"
else
    test_fail "dx-ai parses proc stat starttime in Bash with a complex comm field (R5)"
fi
if [ "$(dx_ai_boot_id "$proc_root")" = a1b2c3d4-e5f6-7890-abcd-ef0123456789 ]; then
    test_pass "dx-ai preserves raw UUID boot identities for existing owner records (R5)"
else
    test_fail "dx-ai preserves raw UUID boot identities for existing owner records (R5)"
fi
rm -f "$proc_root/sys/kernel/random/boot_id"
if [ "$(dx_ai_boot_id "$proc_root")" = btime:1785827572 ]; then
    test_pass "dx-ai falls back to an explicit proc btime boot identity (R5)"
else
    test_fail "dx-ai falls back to an explicit proc btime boot identity (R5)"
fi
mkdir -p "$proc_root/$$"
printf '%s\n' "$$ (dx-ai) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 777" > "$proc_root/$$/stat"
btime_lock="$ai_fixture/btime.lock"
if dx_ai_lock_acquire "$btime_lock" "$proc_root" && [ "$(cut -f1 "$btime_lock/owner")" = btime:1785827572 ]; then
    dx_ai_lock_release "$btime_lock"
    test_pass "dx-ai acquires a lock with the btime fallback identity (R5)"
else
    dx_ai_lock_release "$btime_lock" 2>/dev/null || true
    test_fail "dx-ai acquires a lock with the btime fallback identity (R5)"
fi

# --- F8: a successful sourced dx_ai_main must release its lock and clear its EXIT trap ---
# Reuses the mv() wrapper above (still active) to translate publish's `mv -Tf`
# for hosts whose real mv lacks GNU's -T.
f8_published="$ai_fixture/f8-published"; f8_state="$ai_fixture/f8-state"
mkdir -p "$f8_published/pins"
printf '%s\n' '{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"}' > "$f8_published/pins/agy.json"
printf '%s\n' fixture > "$f8_published/flake.nix"
printf '%s\n' fixture > "$f8_published/flake.lock"

# Stub every function that would otherwise touch the real Nix store or /persist,
# so this exercises dx_ai_main's own control flow (locking, staging, publication)
# rather than the network/build/credential side effects those functions own.
dx_ai_update_flake() { :; }
dx_ai_install_profile() {
    local stage="$1" tool
    mkdir -p "$stage/profile/bin"
    for tool in codex gemini claude agy herdr; do printf '#!/bin/sh\n' > "$stage/profile/bin/$tool"; chmod 0755 "$stage/profile/bin/$tool"; done
}
dx_ai_setup_credentials() { :; }
dx_ai_ensure_keyring() { :; }
dx_ai_verify() { :; }
# The coverage container runs every test as root; stub id so this probe
# exercises dx_ai_main's lock lifecycle (what F8 is about) rather than
# tripping its unrelated "run as dx, not root" guard.
id() { printf '%s\n' 1000; }
# The host running this unit test may not expose Linux /proc. Provide the
# identity that a real guest supplies so F8 keeps testing lock release rather
# than the R5 fail-closed guard above.
dx_ai_boot_id() { printf '%s\n' test-boot-id; }
dx_ai_process_start() { printf '%s\n' 123; }

f8_path_before="$PATH"
DX_AI_BOOTSTRAP_ROOT="$f8_published" DX_AI_STATE_ROOT="$f8_state" dx_ai_main
f8_main_rc=$?
f8_trap_after="$(trap -p EXIT)"
PATH="$f8_path_before"
# dx_ai_main's own EXIT trap replaced the fixture-cleanup trap installed above;
# reinstall it now that the probe of its post-call state is complete.
trap 'chmod -R u+w "$ai_fixture" 2>/dev/null || true; rm -rf "$ai_fixture"' EXIT
# Restore the real functions the block above stubbed out.
# shellcheck source=/dev/null
source "$AI_SCRIPT"
unset -f mv id

if [ "$f8_main_rc" -eq 0 ] && [ ! -d "$f8_state/.lock" ] && [ -z "$f8_trap_after" ]; then
    test_pass "a successful sourced dx_ai_main releases its lock and clears its EXIT trap"
else
    test_fail "a successful sourced dx_ai_main releases its lock and clears its EXIT trap"
fi

# --- F15: --supports is a silent, exact-arity capability probe ---
if out="$(dx_ai_main --supports herdr)" && [ -z "$out" ]; then
    test_pass "--supports <tool> for a known tool exits 0 with no stdout"
else
    test_fail "--supports <tool> for a known tool exits 0 with no stdout"
fi

out="$(dx_ai_main --supports nonexistent-tool)"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
    test_pass "--supports <tool> for an unknown tool exits 1 with no stdout"
else
    test_fail "--supports <tool> for an unknown tool exits 1 with no stdout"
fi

dx_ai_main --supports >/dev/null 2>&1
if [ "$?" -eq 64 ]; then
    test_pass "--supports with no tool name is a usage error (exit 64)"
else
    test_fail "--supports with no tool name is a usage error (exit 64)"
fi

dx_ai_main --supports herdr junk extra >/dev/null 2>&1
if [ "$?" -eq 64 ]; then
    test_pass "--supports rejects trailing arguments (exit 64)"
else
    test_fail "--supports rejects trailing arguments (exit 64)"
fi

# Herdr agent integrations install hook files into the agent config directories
# dx-ai already owns, so dx-ai re-asserts them for every published generation.
# HERDR_BIN_PATH is the same injection seam dx-herdr-navigate.sh uses.
herdr_fixture="$ai_fixture/herdr"
mkdir -p "$herdr_fixture"
herdr_stub="$herdr_fixture/herdr"
cat > "$herdr_stub" <<'HERDR_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DXE_HERDR_STUB_LOG"
case "$1 ${2:-}" in
    "integration status")
        [ "${DXE_HERDR_STUB_STATUS_RC:-0}" -eq 0 ] || exit "$DXE_HERDR_STUB_STATUS_RC"
        if [ "${3:-}" = --outdated-only ]; then
            printf '%s' "${DXE_HERDR_STUB_OUTDATED:-}"
        else
            printf '%s' "${DXE_HERDR_STUB_STATUS:-}"
        fi
        ;;
    "integration install") exit "${DXE_HERDR_STUB_INSTALL_RC:-0}" ;;
esac
HERDR_STUB
chmod 0755 "$herdr_stub"

herdr_stub_log="$herdr_fixture/log"
run_herdr_integrations() {
    : > "$herdr_stub_log"
    (
        export DXE_HERDR_STUB_LOG="$herdr_stub_log"
        export DXE_HERDR_STUB_STATUS="${1:-}"
        export DXE_HERDR_STUB_OUTDATED="${2:-}"
        export DXE_HERDR_STUB_INSTALL_RC="${3:-0}"
        export DXE_HERDR_STUB_STATUS_RC="${4:-0}"
        HERDR_BIN_PATH="$herdr_stub" dx_ai_install_herdr_integrations
    )
}
herdr_installed_targets() {
    sed -n 's/^integration install //p' "$herdr_stub_log" | sort | tr '\n' ' '
}

# Transcribed from real `herdr integration status` output (0.8.0), not invented.
# An up-to-date integration reports `current (vN)`; the earlier fixture used
# `installed`, a word Herdr never emits, so the "does not reinstall" assertion
# below passed against a format the real tool does not produce -- and dx-ai
# reinstalled every healthy integration on every run in the field.
all_missing="claude: not installed (/home/dx/.claude/hooks/herdr-agent-state.sh)
codex: not installed (/home/dx/.codex/herdr-agent-state.sh)
cursor: not installed (/home/dx/.cursor/herdr-agent-state.sh)"
all_current="claude: current (v7) (/home/dx/.claude/hooks/herdr-agent-state.sh)
codex: current (v7) (/home/dx/.codex/herdr-agent-state.sh)"
all_outdated="claude: outdated (v6) (/home/dx/.claude/hooks/herdr-agent-state.sh)
codex: current (v7) (/home/dx/.codex/herdr-agent-state.sh)"

if run_herdr_integrations "$all_missing" "" >/dev/null 2>&1 \
    && [ "$(herdr_installed_targets)" = "claude codex " ]; then
    test_pass "dx-ai installs the missing Herdr integrations for the agents it manages"
else
    test_fail "dx-ai installs the missing Herdr integrations for the agents it manages"
fi

if run_herdr_integrations "$all_missing" "" >/dev/null 2>&1 \
    && ! grep -q 'integration install cursor' "$herdr_stub_log"; then
    test_pass "dx-ai leaves Herdr integrations for unmanaged agents alone"
else
    test_fail "dx-ai leaves Herdr integrations for unmanaged agents alone"
fi

if run_herdr_integrations "$all_current" "" >/dev/null 2>&1 \
    && [ -z "$(herdr_installed_targets)" ]; then
    test_pass "a repeated dx-ai run reinstalls no current Herdr integration"
else
    test_fail "a repeated dx-ai run reinstalls no current Herdr integration"
fi

if run_herdr_integrations "$all_current" "codex: outdated (/home/dx/.codex/herdr-agent-state.sh)" >/dev/null 2>&1 \
    && [ "$(herdr_installed_targets)" = "codex " ]; then
    test_pass "dx-ai refreshes a Herdr integration that upstream reports outdated"
else
    test_fail "dx-ai refreshes a Herdr integration that upstream reports outdated"
fi

# The same signal in the full listing rather than --outdated-only.
if run_herdr_integrations "$all_outdated" "" >/dev/null 2>&1 \
    && [ "$(herdr_installed_targets)" = "claude " ]; then
    test_pass "dx-ai refreshes an integration the status listing marks outdated"
else
    test_fail "dx-ai refreshes an integration the status listing marks outdated"
fi

# An unrecognised state must not put dx-ai into a reinstall loop.
if run_herdr_integrations "claude: bewildered (v9) (/home/dx/.claude/hooks/x.sh)
codex: current (v7) (/home/dx/.codex/herdr-agent-state.sh)" "" >/dev/null 2>&1 \
    && [ -z "$(herdr_installed_targets)" ]; then
    test_pass "an unrecognised Herdr integration state is left alone, not reinstalled"
else
    test_fail "an unrecognised Herdr integration state is left alone, not reinstalled"
fi

if (
    export DXE_HERDR_STUB_LOG="$herdr_stub_log"
    PATH=/nonexistent HERDR_BIN_PATH='' dx_ai_install_herdr_integrations
) >/dev/null 2>&1; then
    test_pass "dx-ai treats an absent Herdr as a skip, not a failure"
else
    test_fail "dx-ai treats an absent Herdr as a skip, not a failure"
fi

if run_herdr_integrations "$all_missing" "" 1 >/dev/null 2>&1; then
    test_pass "a failed Herdr integration install does not fail the AI update"
else
    test_fail "a failed Herdr integration install does not fail the AI update"
fi

if run_herdr_integrations "" "" 0 1 >/dev/null 2>&1 \
    && [ -z "$(herdr_installed_targets)" ]; then
    test_pass "an unreadable Herdr integration status installs nothing and does not fail"
else
    test_fail "an unreadable Herdr integration status installs nothing and does not fail"
fi

assert_grep_in_file "$AI_SCRIPT" '^ +dx_ai_install_herdr_integrations$' "dx-ai runs the Herdr integration step from its main flow"
assert_file_not_contains "$AI_SCRIPT" 'dx_ai_install_herdr_integrations || return' "dx-ai never lets an optional Herdr integration fail the update"

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "dx-ai guest runtime checks (--skip-integration)"
    print_summary
    exit_with_code
fi

if ! requires_container; then
    print_summary
    exit_with_code
fi

if ! wait_for_ssh 60; then
    test_fail "SSH not reachable on localhost:$DX_SSH_PORT"
    print_summary
    exit_with_code
fi

run_guest() {
    "$BASE_DIR/bin/dx-ssh" "$1"
}

set +e
DX_AI_OUT="$(run_guest 'DBUS_SESSION_BUS_ADDRESS= dx-ai' 2>&1)"
DX_AI_RC=$?
set -e

if [ "$DX_AI_RC" -eq 0 ]; then
    test_pass "dx-ai completes successfully inside the guest"
else
    test_fail "dx-ai completes successfully inside the guest"
    printf '%s\n' "$DX_AI_OUT" >&2
    print_summary
    exit_with_code
fi

if printf '%s\n' "$DX_AI_OUT" | stdin_matches -E "D-Bus keyring service (started|already available)"; then
    test_pass "dx-ai ensures D-Bus keyring service"
else
    test_fail "dx-ai ensures D-Bus keyring service"
fi

for tool in codex gemini claude agy herdr; do
    if run_guest "command -v $tool" >/dev/null 2>&1; then
        test_pass "$tool is available after dx-ai"
    else
        test_fail "$tool is available after dx-ai"
    fi
done

if run_guest 'case "$(agy --version)" in 0.*|1.0.0) exit 1 ;; *) exit 0 ;; esac' >/dev/null 2>&1; then
    test_pass "agy version includes OAuth persistence fixes"
else
    test_fail "agy version includes OAuth persistence fixes"
fi

if run_guest 'test -L ~/.gemini && test "$(readlink ~/.gemini)" = /persist/home/dx/.gemini && test -d ~/.gemini/antigravity-cli' >/dev/null 2>&1; then
    test_pass "agy state directory is under persisted Gemini storage"
else
    test_fail "agy state directory is under persisted Gemini storage"
fi

if run_guest 'marker=".dxe-agy-persistence-test-$$"; echo persisted > "$HOME/.gemini/antigravity-cli/$marker" && test -f "/persist/home/dx/.gemini/antigravity-cli/$marker"; rc=$?; rm -f "$HOME/.gemini/antigravity-cli/$marker"; exit $rc' >/dev/null 2>&1; then
    test_pass "agy persisted state path is writable through ~/.gemini"
else
    test_fail "agy persisted state path is writable through ~/.gemini"
fi

if run_guest 'address_file=/persist/home/dx/.local/state/dx/keyring-address; test -s "$address_file" && IFS= read -r address < "$address_file" && case "$address" in unix:path=/*) exit 0 ;; *) exit 1 ;; esac' >/dev/null 2>&1; then
    test_pass "dx-ai writes one validated raw D-Bus keyring address"
else
    test_fail "dx-ai writes one validated raw D-Bus keyring address"
fi

print_summary
exit_with_code
