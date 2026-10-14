#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
# No `-e`: cases capture non-zero exit statuses by hand.
set -uo pipefail

# The bootstrap's root Nix calls must not leave a root-owned temporary-roots
# file behind (fix/gc-temproots, observed live 2026-10-12).
#
# Nix names a process's temp-roots file /nix/var/nix/temproots/<its pid> and
# creates it root:root 0600 when root runs it. Nix 2.34's flake-building
# commands -- `nix profile install <flake>#<attr>` among them, exactly the
# bootstrap's essentials install -- do not unlink that file on exit, even on
# success (reproduced in nixos/nix:2.34.8; see the Red commit message). Left
# in the dx-owned single-user store, dx's `nix-collect-garbage` cannot open
# it and aborts the whole collection.
#
# Interface contract (container/dx-nixos-26.05/bootstrap/common.sh):
#
#   Every root `nix` invocation in the essentials helpers --
#   install_essential_packages (`nix profile install`), and
#   upgrade_essential_packages (`nix profile remove`, the install, and
#   `nix profile rollback`) -- runs `nix` as a child process, waits for it to
#   finish, and then removes exactly that child's own temp-roots file,
#   "${DX_ESSENTIALS_ROOT:-}/nix/var/nix/temproots/<child pid>" (the same
#   DX_ESSENTIALS_ROOT prefix essentials_profile_path already honours), on
#   success AND on failure. The child is `nix` itself, so its pid is the
#   file's name (for a simple command run with `&`, $! is that pid).
#   Nothing else in the directory is touched. The `nix` argv, its exit
#   status, and its stdout/stderr pass through unchanged, and the helpers'
#   existing decisions (rollback only after a removal, the install's status
#   wins) are unchanged.
#
#   Residual (documented, not tested): a new process that is assigned the
#   just-reaped pid and creates its own temp-roots file before the removal
#   would lose it -- a window of one unlink right after `wait`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=../container/dx-nixos-26.05/bootstrap/common.sh
source "$CONTAINER_DIR/bootstrap/common.sh"
test_section "Bootstrap: root Nix calls leave no temporary-roots file behind"

BT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-bootstrap-temproots.XXXXXX")"
bt_cleanup() {
    case "$BT_ROOT" in
        "${TMPDIR:-/tmp}"/dxe-bootstrap-temproots.?*) chmod -R u+rwx "$BT_ROOT" 2>/dev/null; rm -rf "$BT_ROOT" ;;
    esac
}
trap bt_cleanup EXIT

FAKE_DIR="$(fake_tool_dir_create "$BT_ROOT")"

# A fake `nix` that behaves like Nix 2.34's flake commands as root: it writes
# its temp-roots file, named after its own pid, and exits WITHOUT removing
# it. It logs "<pid><TAB><argv>" and prints one line on each of stdout and
# stderr; the exit status of `profile install` / `profile remove` is
# scriptable.
fake_tool_write "$FAKE_DIR" nix '
printf "%s\t%s\n" "$$" "$*" >> "$BT_NIX_LOG"
printf "FAKE-NIX-OUT %s %s\n" "$1" "$2"
printf "FAKE-NIX-ERR %s %s\n" "$1" "$2" >&2
printf "/nix/store/ffff-temp\0" > "$BT_TEMPROOTS/$$"
chmod 0600 "$BT_TEMPROOTS/$$"
case "$*" in
    *"profile install"*) exit "${BT_INSTALL_RC:-0}" ;;
    *"profile remove"*) exit "${BT_REMOVE_RC:-0}" ;;
esac
exit 0'

# bt_new_case -- a fresh essentials root with a temp-roots directory holding
# two files that belong to other processes (one readable, one not); they
# must never be touched.
bt_new_case() {
    BT_CASE="$(mktemp -d "$BT_ROOT/case.XXXXXX")"
    BT_TEMPROOTS="$BT_CASE/nix/var/nix/temproots"
    BT_NIX_LOG="$BT_CASE/nix.log"
    mkdir -p "$BT_TEMPROOTS"
    : > "$BT_NIX_LOG"
    printf 'other-a\n' > "$BT_TEMPROOTS/424242"
    printf 'other-b\n' > "$BT_TEMPROOTS/424243"
    chmod 0000 "$BT_TEMPROOTS/424243"
    export BT_CASE BT_TEMPROOTS BT_NIX_LOG
}

# bt_run FUNCTION -- runs a bootstrap function with the fake nix first on
# PATH and DX_ESSENTIALS_ROOT at this case's root; captures stdout, stderr
# and status.
bt_run() {
    bt_rc=0
    (
        PATH="$FAKE_DIR:$PATH"
        DX_ESSENTIALS_ROOT="$BT_CASE"
        DX_BOOTSTRAP_ROOT=/guest-bootstrap
        export PATH DX_ESSENTIALS_ROOT DX_BOOTSTRAP_ROOT
        "$@"
    ) > "$BT_CASE/out" 2> "$BT_CASE/err" || bt_rc=$?
}

bt_check() {
    local label="$1"
    shift
    if "$@"; then
        test_pass "$label"
    else
        test_fail "$label"
        echo "    status: $bt_rc"
        echo "    nix log: $(tr '\t\n' '| ' < "$BT_NIX_LOG")"
        echo "    temproots now: $(ls -A "$BT_TEMPROOTS" | LC_ALL=C sort | tr '\n' ' ')"
        echo "    stdout: $(cat "$BT_CASE/out" 2>/dev/null)"
        echo "    stderr: $(cat "$BT_CASE/err" 2>/dev/null)"
    fi
}

# The two other processes' temp-roots files are still there, as regular
# files, with their content intact.
bt_others_untouched() {
    [ -f "$BT_TEMPROOTS/424242" ] && [ -f "$BT_TEMPROOTS/424243" ] || return 1
    [ "$(cat "$BT_TEMPROOTS/424242")" = other-a ] || return 1
    chmod 0600 "$BT_TEMPROOTS/424243"
    [ "$(cat "$BT_TEMPROOTS/424243")" = other-b ] || return 1
    chmod 0000 "$BT_TEMPROOTS/424243"
}
bt_nix_calls() { wc -l < "$BT_NIX_LOG" | tr -d ' '; }
bt_nix_argv() { sed -n "${1}p" "$BT_NIX_LOG" | cut -f2-; }
bt_nix_pid() { sed -n "${1}p" "$BT_NIX_LOG" | cut -f1; }
bt_nix_argv_starts() { case "$(bt_nix_argv "$1")" in "$2"*) return 0 ;; esac; return 1; }
bt_own_files_gone() {
    local n pid
    n="$(bt_nix_calls)"
    [ "$n" -ge 1 ] || return 1
    while [ "$n" -ge 1 ]; do
        pid="$(bt_nix_pid "$n")"
        [ -n "$pid" ] && [ ! -e "$BT_TEMPROOTS/$pid" ] || return 1
        n=$((n - 1))
    done
}

# --- The fixture itself: the fake really leaves its file behind. ----------
# Without this, every "file is gone" case below could pass vacuously.
bt_new_case
bt_run nix --version
bt_check "fixture: a root nix process that exits leaves /nix/var/nix/temproots/<its pid> behind" \
    eval '[ "$(bt_nix_calls)" -eq 1 ] && [ -f "$BT_TEMPROOTS/$(bt_nix_pid 1)" ]'

# --- install_essential_packages ------------------------------------------
bt_new_case
bt_run install_essential_packages
bt_check "install: runs one nix profile install into the per-user root profile, argv unchanged" \
    eval '[ "$(bt_nix_calls)" -eq 1 ] && bt_nix_argv_starts 1 "profile install --profile /nix/var/nix/profiles/per-user/root/profile /guest-bootstrap#bootstrap-essentials --no-update-lock-file --extra-experimental-features nix-command flakes"'
bt_check "install: the finished root nix process leaves no temp-roots file behind" \
    bt_own_files_gone
bt_check "install: other processes' temp-roots files are untouched" \
    bt_others_untouched
bt_check "install: returns nix's status (0)" \
    [ "$bt_rc" -eq 0 ]
bt_check "install: nix's stdout and stderr pass through" \
    eval 'grep -Fx "FAKE-NIX-OUT profile install" "$BT_CASE/out" >/dev/null && grep -Fx "FAKE-NIX-ERR profile install" "$BT_CASE/err" >/dev/null'

bt_new_case
BT_INSTALL_RC=9
export BT_INSTALL_RC
bt_run install_essential_packages
unset BT_INSTALL_RC
bt_check "install (nix fails with 9): returns 9" \
    [ "$bt_rc" -eq 9 ]
bt_check "install (nix fails): its temp-roots file is still removed" \
    bt_own_files_gone
bt_check "install (nix fails): other processes' temp-roots files are untouched" \
    bt_others_untouched

# --- upgrade_essential_packages ------------------------------------------
bt_new_case
bt_run upgrade_essential_packages
bt_check "upgrade: removes the old element, then installs -- two root nix calls" \
    eval '[ "$(bt_nix_calls)" -eq 2 ] && bt_nix_argv_starts 1 "profile remove --profile /nix/var/nix/profiles/per-user/root/profile bootstrap-essentials" && bt_nix_argv_starts 2 "profile install --profile /nix/var/nix/profiles/per-user/root/profile"'
bt_check "upgrade: neither root nix call leaves a temp-roots file behind" \
    bt_own_files_gone
bt_check "upgrade: other processes' temp-roots files are untouched" \
    bt_others_untouched
bt_check "upgrade: returns 0" \
    [ "$bt_rc" -eq 0 ]

bt_new_case
BT_INSTALL_RC=5
export BT_INSTALL_RC
bt_run upgrade_essential_packages
unset BT_INSTALL_RC
bt_check "upgrade (install fails with 5): remove, install, rollback -- three root nix calls -- and returns 5" \
    eval '[ "$(bt_nix_calls)" -eq 3 ] && bt_nix_argv_starts 3 "profile rollback --profile /nix/var/nix/profiles/per-user/root/profile" && [ "$bt_rc" -eq 5 ]'
bt_check "upgrade (install fails): none of the three root nix calls leaves a temp-roots file behind" \
    bt_own_files_gone
bt_check "upgrade (install fails): other processes' temp-roots files are untouched" \
    bt_others_untouched

bt_new_case
BT_REMOVE_RC=1
BT_INSTALL_RC=5
export BT_REMOVE_RC BT_INSTALL_RC
bt_run upgrade_essential_packages
unset BT_REMOVE_RC BT_INSTALL_RC
bt_check "upgrade (nothing removed, install fails): no rollback and returns 5" \
    eval '[ "$(bt_nix_calls)" -eq 2 ] && [ "$bt_rc" -eq 5 ]'
bt_check "upgrade (nothing removed, install fails): neither call leaves a temp-roots file behind; other processes' files untouched" \
    eval 'bt_own_files_gone && bt_others_untouched'

print_summary
exit_with_code
