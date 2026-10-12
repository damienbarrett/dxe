#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
# No `-e`: cases capture non-zero exit statuses by hand.
set -uo pipefail

# Unit cases for the bootstrap's root Nix wrapper (fix/gc-temproots) beyond
# the locked acceptance suite, tests/test_bootstrap_nix_temproots.sh:
#
#   - running nix as a background child must not change what it reads on
#     stdin (bash gives an asynchronous command /dev/null unless told not to);
#   - in production DX_ESSENTIALS_ROOT is unset, and the cleanup is then
#     exactly one non-recursive `rm -f -- /nix/var/nix/temproots/<nix's pid>`.
#     That case runs with a recording `rm` stub that removes nothing, and only
#     after proving the stub is the `rm` the wrapper will find: no real /nix
#     path is ever handed to a real rm from this suite.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=../container/dx-nixos-26.05/bootstrap/common.sh
source "$CONTAINER_DIR/bootstrap/common.sh"
test_section "Bootstrap root Nix wrapper: unit cases"

BU_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-bootstrap-nix-unit.XXXXXX")"
bu_cleanup() {
    case "$BU_ROOT" in
        "${TMPDIR:-/tmp}"/dxe-bootstrap-nix-unit.?*) rm -rf "$BU_ROOT" ;;
    esac
}
trap bu_cleanup EXIT

FAKE_DIR="$(fake_tool_dir_create "$BU_ROOT")"
STUB_DIR="$BU_ROOT/stubs"

# A fake `nix` that logs its own pid and copies whatever it reads on stdin.
fake_tool_write "$FAKE_DIR" nix '
printf "%s\n" "$$" >> "$BU_NIX_LOG"
cat > "$BU_STDIN_CAPTURE"
exit 0'

# A recording `rm` that removes nothing.
fake_tool_write "$STUB_DIR" rm '
printf "%s\n" "$*" >> "$BU_RM_LOG"
exit 0'

bu_new_case() {
    BU_CASE="$(mktemp -d "$BU_ROOT/case.XXXXXX")"
    BU_NIX_LOG="$BU_CASE/nix.log"
    BU_STDIN_CAPTURE="$BU_CASE/stdin"
    BU_RM_LOG="$BU_CASE/rm.log"
    : > "$BU_NIX_LOG"
    : > "$BU_RM_LOG"
    mkdir -p "$BU_CASE/nix/var/nix/temproots"
    export BU_NIX_LOG BU_STDIN_CAPTURE BU_RM_LOG
}

bu_check() {
    local label="$1"
    shift
    if "$@"; then
        test_pass "$label"
    else
        test_fail "$label"
        echo "    status: $bu_rc"
        echo "    nix pids: $(tr '\n' ' ' < "$BU_NIX_LOG")"
        echo "    stdin seen: $(cat "$BU_STDIN_CAPTURE" 2>/dev/null)"
        echo "    rm calls: $(tr '\n' '|' < "$BU_RM_LOG")"
    fi
}

# --- stdin reaches nix unchanged -------------------------------------------
bu_new_case
bu_rc=0
(
    PATH="$FAKE_DIR:$PATH"
    DX_ESSENTIALS_ROOT="$BU_CASE"
    DX_BOOTSTRAP_ROOT=/guest-bootstrap
    export PATH DX_ESSENTIALS_ROOT DX_BOOTSTRAP_ROOT
    install_essential_packages <<<"stdin-for-nix"
) > "$BU_CASE/out" 2> "$BU_CASE/err" || bu_rc=$?
bu_check "install: nix, run as a child, still reads the caller's stdin" \
    eval '[ "$bu_rc" -eq 0 ] && [ "$(cat "$BU_STDIN_CAPTURE")" = stdin-for-nix ]'

# --- production prefix: DX_ESSENTIALS_ROOT unset ---------------------------
bu_new_case
bu_rc=0
(
    PATH="$STUB_DIR:$FAKE_DIR:$PATH"
    unset DX_ESSENTIALS_ROOT
    DX_BOOTSTRAP_ROOT=/guest-bootstrap
    export PATH DX_BOOTSTRAP_ROOT
    # Fail closed: never reach the wrapper unless `rm` is the recording stub.
    [ "$(command -v rm)" = "$STUB_DIR/rm" ] || exit 97
    install_essential_packages </dev/null
) > "$BU_CASE/out" 2> "$BU_CASE/err" || bu_rc=$?
bu_check "install (no DX_ESSENTIALS_ROOT): the recording rm stub is the rm the wrapper finds" \
    [ "$bu_rc" -ne 97 ]
bu_check "install (no DX_ESSENTIALS_ROOT): exactly one non-recursive rm -f -- /nix/var/nix/temproots/<nix's own pid>" \
    eval '[ "$bu_rc" -eq 0 ] && [ "$(wc -l < "$BU_NIX_LOG" | tr -d " ")" -eq 1 ] && [ "$(cat "$BU_RM_LOG")" = "-f -- /nix/var/nix/temproots/$(cat "$BU_NIX_LOG")" ]'

print_summary
exit_with_code
