#!/bin/bash
# Section 17: dx-ai Runtime
# Verifies the optional AI tool installer works from inside the running guest.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 17: dx-ai Runtime"

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

if printf '%s\n' "$DX_AI_OUT" | grep -q "D-Bus keyring service started"; then
    test_pass "dx-ai starts D-Bus keyring service"
else
    test_fail "dx-ai starts D-Bus keyring service"
fi

for tool in codex gemini claude agy; do
    if run_guest "command -v $tool" >/dev/null 2>&1; then
        test_pass "$tool is available after dx-ai"
    else
        test_fail "$tool is available after dx-ai"
    fi
done

if run_guest 'test -s "$HOME/.dx-keyring-env" && . "$HOME/.dx-keyring-env" && test -n "${DBUS_SESSION_BUS_ADDRESS:-}"' >/dev/null 2>&1; then
    test_pass "dx-ai writes a sourceable D-Bus keyring environment"
else
    test_fail "dx-ai writes a sourceable D-Bus keyring environment"
fi

print_summary
exit_with_code
