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
    for tool in codex gemini claude agy; do printf '#!/bin/sh\n' > "$generation/profile/bin/$tool"; chmod 0755 "$generation/profile/bin/$tool"; done
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
unset -f mv

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

if printf '%s\n' "$DX_AI_OUT" | grep -Eq "D-Bus keyring service (started|already available)"; then
    test_pass "dx-ai ensures D-Bus keyring service"
else
    test_fail "dx-ai ensures D-Bus keyring service"
fi

for tool in codex gemini claude agy; do
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
