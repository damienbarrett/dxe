#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
# No `-e`: cases capture non-zero exit statuses by hand.
set -uo pipefail

# Root Nix calls in the bootstrap must not leave root-owned paths in dx's
# single-user store (fix/gc-rootpaths, observed live 2026-10-12).
#
# The bootstrap runs Nix as root for the root essentials profile
# (install_essential_packages; upgrade_essential_packages' remove / install /
# rollback -- all through run_root_nix). In a store that belongs to dx (the
# direct-volume guests from their first boot on; Apple guests whenever /nix is
# already the volume mount when the essentials step runs), every store path
# such a call creates is root-owned: the built output, its .drv, the flake
# source copy, every substituted path and the profile environment
# (`...-profile`) -- reproduced against Nix 2.34.8, see the Red commit
# message. dx's `nix-collect-garbage` must make a directory writable before
# it can empty it, cannot chmod a root-owned one, and aborts the whole
# collection:
#   error: fchmodat2 "/nix/store/c0dj6b...-profile": Operation not permitted
# (c0dj6b...-profile is the EMPTY profile environment that `nix profile
# remove` creates: the probe produced exactly that path). The same root
# ownership stops dx's `nix-store --repair-path` of such a path, and the log
# bucket a root build creates (/nix/var/log/nix/drvs/<2 chars>, root 0755)
# makes every later dx build whose derivation falls in that bucket fail:
#   error: creating log file "/nix/var/log/nix/drvs/sy/...drv.bz2": Permission denied
#
# Interface contract (container/dx-nixos-26.05/bootstrap/common.sh):
#
#   hand_back_root_nix_paths   (no arguments)
#     Operates on STORE="${DX_ESSENTIALS_ROOT:-}/nix/store" and
#     LOG="${DX_ESSENTIALS_ROOT:-}/nix/var/log/nix" (the prefix
#     essentials_profile_path and run_root_nix already honour). Runs as root.
#       - When STORE is missing, is a symlink, or is owned by uid 0 (the
#         image's own store before the /nix volume replaces it, or a volume
#         before its one-time ownership migration): nothing at all is
#         changed, nothing is printed, chown is never run; returns 0.
#       - Otherwise the store owner OWNER is STORE's own numeric uid:gid
#         (the dx account may not exist yet when this runs).
#       - Every DIRECT entry of STORE owned by uid 0 (dot-entries included)
#         is handed to OWNER together with everything inside it. A symlink is
#         re-owned itself and never followed -- not as the entry, not inside
#         it; nothing outside STORE changes through a link. Entries owned by
#         any non-root uid are never touched, nor is anything inside them
#         (a root-owned inode inside a dx path -- auto-optimise's hard link to
#         a root file -- is harmless to GC and stays as it is; no full-store
#         walk). STORE itself is never changed.
#       - When LOG is a real directory (not a symlink): every entry beneath
#         LOG owned by uid 0 is handed to OWNER (a symlink itself, never its
#         target). LOG itself is never changed. A symlinked LOG is skipped.
#       - Modes and mtimes are never changed (store paths stay read-only, as
#         Nix requires); nothing else is touched: not /nix/var/nix (db,
#         profiles -- per-user/root stays root's --, gcroots, temproots), not
#         anything outside STORE and LOG.
#       - chown is the only tool that changes anything, found on PATH, and
#         never with a symlink-following option (-L, -H, --dereference); its
#         path operands are always strictly beneath STORE or LOG.
#       - Output: when N > 0 entries were handed back (each root-owned direct
#         store entry counts once, whatever it contains; each root-owned
#         entry beneath LOG counts once), exactly one stdout line
#           Handed N root-owned Nix path(s) back to the store owner UID:GID.
#         and nothing when N = 0. A failed hand-back (a chown fails) still
#         tries every other entry, prints a line containing
#           Warning: could not hand root-owned Nix paths back to the store owner
#         on stderr and returns non-zero.
#
#   run_root_nix ARG...  calls hand_back_root_nix_paths once after nix has
#     exited (after its own temp-roots cleanup), on success and on failure;
#     its own status is still nix's, and a failed hand-back never changes it.
#     So each root nix call is followed by its own hand-back: an upgrade
#     (remove, install, rollback) hands back three times.
#
# The real-ownership cases need root (rp_root_runner_reason): they run in
# tests/run-coverage-linux.sh's isolated root runner (any root Linux shell
# with bash, GNU coreutils/findutils, sed and awk will do) and skip elsewhere.
# Every path such a case changes is inside this suite's own mktemp root,
# through a recording, fenced `chown` (tests/lib/nix-rootpaths-fixture.sh)
# that refuses symlink-following options and anything outside the case.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=lib/nix-rootpaths-fixture.sh
source "$SCRIPT_DIR/lib/nix-rootpaths-fixture.sh"
# shellcheck source=../container/dx-nixos-26.05/bootstrap/common.sh
source "$CONTAINER_DIR/bootstrap/common.sh"
test_section "Bootstrap: root Nix calls hand root-owned store and log paths back to the store owner"

dxe_test_mktemp_dir RB_ROOT "${TMPDIR:-/tmp}/dxe-bootstrap-rootpaths.XXXXXX"
rb_cleanup() {
    case "$RB_ROOT" in
        "${TMPDIR:-/tmp}"/dxe-bootstrap-rootpaths.?*) chmod -R u+rwx "$RB_ROOT" 2>/dev/null; rm -rf "$RB_ROOT" ;;
    esac
}
trap rb_cleanup EXIT

FAKE_DIR="$(fake_tool_dir_create "$RB_ROOT")" || exit 1
STUB_DIR="$RB_ROOT/stubs"
rp_write_chown_stub "$STUB_DIR"
RP_REAL_CHOWN="$(command -v chown)"
export RP_REAL_CHOWN

# A fake `nix` for the root runner: like a root Nix call into dx's store, it
# leaves new root-owned paths behind -- a profile environment directory, a
# .drv file and a log bucket holding one log -- named after its call number
# k (new<k>-profile, new<k>.drv, drvs/q<k>/x.drv.bz2), writes its own
# temp-roots file, prints one line on stdout and one on stderr, and exits
# with RB_INSTALL_RC / RB_REMOVE_RC for `profile install` / `profile remove`.
fake_tool_write "$FAKE_DIR" nix '
printf "%s\t%s\n" "$$" "$*" >> "$RB_NIX_LOG"
k="$(wc -l < "$RB_NIX_LOG" | tr -d " ")"
s="$RB_CASE/nix/store"
mkdir -p "$s/new$k-profile/bin"
printf "{}\n" > "$s/new$k-profile/manifest.json"
chmod 0444 "$s/new$k-profile/manifest.json"
chmod 0555 "$s/new$k-profile/bin" "$s/new$k-profile"
printf "drv\n" > "$s/new$k.drv"
chmod 0444 "$s/new$k.drv"
mkdir -p "$RB_CASE/nix/var/log/nix/drvs/q$k"
printf "log\n" > "$RB_CASE/nix/var/log/nix/drvs/q$k/x.drv.bz2"
printf "/nix/store/ffff-temp\0" > "$RB_CASE/nix/var/nix/temproots/$$"
printf "FAKE-NIX-OUT %s %s\n" "$1" "$2"
printf "FAKE-NIX-ERR %s %s\n" "$1" "$2" >&2
case "$*" in
    *"profile install"*) exit "${RB_INSTALL_RC:-0}" ;;
    *"profile remove"*) exit "${RB_REMOVE_RC:-0}" ;;
esac
exit 0'

# rb_new_case [full|clean|none] -- a fresh case directory: the full fixture,
# the clean one, or nothing at all (no store).
rb_new_case() {
    dxe_test_mktemp_dir RB_CASE "$RB_ROOT/case.XXXXXX"
    RB_NIX_LOG="$RB_CASE/nix.log"
    RP_CHOWN_LOG="$RB_CASE/chown.log"
    RP_FENCE="$RB_CASE"
    : > "$RB_NIX_LOG"
    : > "$RP_CHOWN_LOG"
    unset RP_CHOWN_FAIL_MATCH
    export RB_CASE RB_NIX_LOG RP_CHOWN_LOG RP_FENCE
    case "${1:-full}" in
        full) rp_fixture_build "$RB_CASE" ;;
        clean) rp_fixture_build_clean "$RB_CASE" ;;
        none) : ;;
    esac
}

# rb_run FUNCTION [ARG...] -- runs a bootstrap function as the bootstrap
# would, with the recording chown and the fake nix first on PATH and
# DX_ESSENTIALS_ROOT at this case; captures stdout, stderr and status.
rb_run() {
    rb_rc=0
    (
        PATH="$STUB_DIR:$FAKE_DIR:$PATH"
        DX_ESSENTIALS_ROOT="$RB_CASE"
        DX_BOOTSTRAP_ROOT=/guest-bootstrap
        export PATH DX_ESSENTIALS_ROOT DX_BOOTSTRAP_ROOT
        # Fail closed: never reach the code under test unless `chown` is the
        # recording, fenced stub.
        [ "$(command -v chown)" = "$STUB_DIR/chown" ] || exit 96
        if ! declare -F hand_back_root_nix_paths >/dev/null; then
            echo "hand_back_root_nix_paths is not defined" >&2
            exit 95
        fi
        "$@"
    ) > "$RB_CASE/out" 2> "$RB_CASE/err" || rb_rc=$?
}

rb_check() {
    local label="$1"
    shift
    if "$@"; then
        test_pass "$label"
    else
        test_fail "$label"
        echo "    status: $rb_rc"
        echo "    stdout: $(cat "$RB_CASE/out" 2>/dev/null)"
        echo "    stderr: $(cat "$RB_CASE/err" 2>/dev/null)"
        echo "    chown calls: $(tr '\n' ' ' < "$RP_CHOWN_LOG" 2>/dev/null)"
        echo "    nix calls: $(tr '\t\n' '| ' < "$RB_NIX_LOG" 2>/dev/null)"
    fi
}

rb_out_is() { [ "$(cat "$RB_CASE/out")" = "$1" ]; }
rb_out_empty() { [ ! -s "$RB_CASE/out" ]; }
rb_err_empty() { [ ! -s "$RB_CASE/err" ]; }
rb_warning_given() { grep -F -- 'Warning: could not hand root-owned Nix paths back to the store owner' "$RB_CASE/err" >/dev/null; }
rb_no_chown() { [ "$(rp_chown_calls)" -eq 0 ] && ! rp_chown_refused; }
rb_chown_used_in_scope() {
    [ "$(rp_chown_calls)" -ge 1 ] && ! rp_chown_refused \
        && rp_chown_operands_in_scope "$RB_CASE/nix/store" "$RB_CASE/nix/var/log/nix"
}
rb_manifest_is() { [ "$(rp_manifest "$RB_CASE")" = "$1" ]; }
rb_nix_calls() { wc -l < "$RB_NIX_LOG" | tr -d ' '; }
rb_nix_argv_starts() {
    local argv
    argv="$(sed -n "${1}p" "$RB_NIX_LOG" | cut -f2-)"
    case "$argv" in "$2"*) return 0 ;; esac
    return 1
}
RB_HANDED_LINE="Handed $RP_HANDED_COUNT root-owned Nix path(s) back to the store owner $RP_DX_OWNER."
RB_NIX_HANDED_LINE="Handed 4 root-owned Nix path(s) back to the store owner $RP_DX_OWNER."

# =============================================================================
# Any host.
# =============================================================================

if declare -F hand_back_root_nix_paths >/dev/null; then
    test_pass "hand_back_root_nix_paths is defined by bootstrap/common.sh"
else
    test_fail "hand_back_root_nix_paths is defined by bootstrap/common.sh"
fi

rb_new_case none
rb_run hand_back_root_nix_paths
rb_check "no store under DX_ESSENTIALS_ROOT: nothing to hand back -- silent, returns 0, never runs chown" \
    eval '[ "$rb_rc" -eq 0 ] && rb_out_empty && rb_err_empty && rb_no_chown'

# =============================================================================
# Real ownership (root runner only).
# =============================================================================

RB_REASON="$(rp_root_runner_reason)"
if [ -n "$RB_REASON" ]; then
    for rb_label in \
        "hand-back: exactly the root-owned direct store entries (and all inside them) and root-owned log entries go to the store owner" \
        "hand-back: idempotent, store owned by root, symlinked store, symlinked log directory" \
        "hand-back: a failing chown" \
        "run_root_nix: install, failing install, upgrade, failing upgrade hand back each call's paths"; do
        test_skip "$rb_label ($RB_REASON)"
    done
    print_summary
    exit_with_code
fi

# --- The full fixture --------------------------------------------------------
# The fixture itself: without this, the "nothing changes" cases below could
# pass vacuously.
rb_new_case full
rb_check "fixture: the full fixture really holds the 5 root-owned direct store entries and 4 root-owned log entries the rule names" \
    eval '[ "$(rp_root_owned_left "$RB_CASE" | LC_ALL=C sort)" = "$(printf "%s\n" log:drvs/ab/cd-root-built.drv.bz2 log:drvs/sy log:drvs/sy/bfh-bootstrap-essentials.drv.bz2 log:drvs/zz-link store:.hidden-root store:aaaa-profile store:bbbb-bootstrap-essentials.drv store:cccc-source store:dddd-link | LC_ALL=C sort)" ]'

rb_new_case full
rb_before="$(rp_manifest "$RB_CASE")"
rb_expected="$(printf '%s\n' "$rb_before" | rp_expect "$RP_DX_OWNER" "$RP_HANDED_STORE
$RP_HANDED_LOG")"
rb_run hand_back_root_nix_paths
rb_check "hand-back: exactly the root-owned direct store entries (with everything inside them, symlinks themselves) and the root-owned log entries now belong to the store owner; every other owner, every mode and every mtime is unchanged, and nothing outside the store and log directories changed" \
    rb_manifest_is "$rb_expected"
rb_check "hand-back: prints exactly '$RB_HANDED_LINE'" \
    rb_out_is "$RB_HANDED_LINE"
rb_check "hand-back: returns 0 with nothing on stderr" \
    eval '[ "$rb_rc" -eq 0 ] && rb_err_empty'
rb_check "hand-back: changes ownership only through the chown on PATH, never following a symlink, with every path operand strictly beneath the store or the log directory" \
    rb_chown_used_in_scope

# Read inside the eval'd check below.
# shellcheck disable=SC2034
rb_after="$(rp_manifest "$RB_CASE")"
: > "$RP_CHOWN_LOG"
rb_run hand_back_root_nix_paths
rb_check "hand-back again with nothing root-owned left: silent, returns 0, runs no chown, changes nothing" \
    eval '[ "$rb_rc" -eq 0 ] && rb_out_empty && rb_err_empty && rb_no_chown && rb_manifest_is "$rb_after"'

# --- Root's own store: nothing to hand back to ------------------------------
rb_new_case full
chown -h 0:0 "$RB_CASE/nix/store"
rb_before="$(rp_manifest "$RB_CASE")"
rb_run hand_back_root_nix_paths
rb_check "store owned by root (the image's store, or a volume before its migration): nothing changes anywhere, silent, returns 0, no chown" \
    eval '[ "$rb_rc" -eq 0 ] && rb_out_empty && rb_err_empty && rb_no_chown && rb_manifest_is "$rb_before"'

# --- A symlinked store is never followed -------------------------------------
rb_new_case full
mkdir "$RB_CASE/elsewhere"
mv "$RB_CASE/nix/store" "$RB_CASE/elsewhere/store"
ln -s ../elsewhere/store "$RB_CASE/nix/store"
chown -h "$RP_DX_OWNER" "$RB_CASE/nix/store"
rb_before="$(rp_manifest "$RB_CASE")"
rb_run hand_back_root_nix_paths
rb_check "store is a symlink: nothing changes anywhere (not through the link, not in the log directory), silent, returns 0, no chown" \
    eval '[ "$rb_rc" -eq 0 ] && rb_out_empty && rb_err_empty && rb_no_chown && rb_manifest_is "$rb_before"'

# --- A symlinked log directory is skipped ------------------------------------
rb_new_case full
mkdir "$RB_CASE/elsewhere"
mv "$RB_CASE/nix/var/log/nix" "$RB_CASE/elsewhere/log"
ln -s ../../../elsewhere/log "$RB_CASE/nix/var/log/nix"
chown -h "$RP_DX_OWNER" "$RB_CASE/nix/var/log/nix"
rb_before="$(rp_manifest "$RB_CASE")"
rb_expected="$(printf '%s\n' "$rb_before" | rp_expect "$RP_DX_OWNER" "$RP_HANDED_STORE")"
rb_run hand_back_root_nix_paths
rb_check "log directory is a symlink: the store's root-owned entries are handed back, nothing behind the link changes" \
    rb_manifest_is "$rb_expected"
rb_check "log directory is a symlink: counts only the store entries" \
    eval '[ "$rb_rc" -eq 0 ] && rb_out_is "Handed $RP_HANDED_STORE_COUNT root-owned Nix path(s) back to the store owner $RP_DX_OWNER." && rb_err_empty'

# --- One entry cannot be handed back ----------------------------------------
rb_new_case full
rb_before="$(rp_manifest "$RB_CASE")"
rb_expected="$(printf '%s\n' "$rb_before" | rp_expect "$RP_DX_OWNER" "$(printf '%s\n' "$RP_HANDED_STORE
$RP_HANDED_LOG" | grep -v cccc-source)")"
RP_CHOWN_FAIL_MATCH=cccc-source
export RP_CHOWN_FAIL_MATCH
rb_run hand_back_root_nix_paths
unset RP_CHOWN_FAIL_MATCH
rb_check "a chown that fails for one entry: every other root-owned entry is still handed back, the failed one stays as it was" \
    rb_manifest_is "$rb_expected"
rb_check "a chown that fails for one entry: warns on stderr and returns non-zero" \
    eval '[ "$rb_rc" -ne 0 ] && rb_warning_given'

# --- run_root_nix: every root nix call is followed by its own hand-back ------
rb_nothing_root_owned() { [ -z "$(rp_root_owned_left "$RB_CASE")" ]; }
# nix's new paths belong to the store owner all the way down, read-only modes kept.
rb_nix_paths_handed() {
    local k="$1"
    [ -z "$(find "$RB_CASE/nix/store/new$k-profile" "$RB_CASE/nix/store/new$k.drv" "$RB_CASE/nix/var/log/nix/drvs/q$k" ! -user "${RP_DX_OWNER%%:*}" -print)" ] \
        && [ "$(stat -c %a "$RB_CASE/nix/store/new$k-profile")" = 555 ] \
        && [ "$(stat -c %a "$RB_CASE/nix/store/new$k-profile/manifest.json")" = 444 ] \
        && [ "$(stat -c %a "$RB_CASE/nix/store/new$k.drv")" = 444 ]
}
# The out-of-scope sentinels are still root's.
rb_sentinels_root() {
    [ "$(stat -c %u "$RB_CASE/nix/var/nix/profiles/per-user/root")" = 0 ] \
        && [ "$(stat -c %u "$RB_CASE/nix/var/nix/temproots/110")" = 0 ]
}

# The fake itself: without this, the "handed back" checks below could pass
# vacuously.
rb_new_case clean
(PATH="$FAKE_DIR:$PATH" nix --version) >/dev/null 2>&1
rb_check "fixture: the fake root nix really leaves root-owned paths behind (a profile directory, a .drv, a log bucket and its log)" \
    eval '[ "$(rp_root_owned_left "$RB_CASE" | LC_ALL=C sort)" = "$(printf "%s\n" log:drvs/q1 log:drvs/q1/x.drv.bz2 store:new1-profile store:new1.drv | LC_ALL=C sort)" ]'

rb_new_case clean
rb_run install_essential_packages
rb_check "install: one root nix call, argv unchanged, returns 0" \
    eval '[ "$rb_rc" -eq 0 ] && [ "$(rb_nix_calls)" -eq 1 ] && rb_nix_argv_starts 1 "profile install --profile /nix/var/nix/profiles/per-user/root/profile /guest-bootstrap#bootstrap-essentials --no-update-lock-file"'
rb_check "install: the paths the root nix call left (profile dir, .drv, log bucket) belong to the store owner, read-only modes kept" \
    eval 'rb_nix_paths_handed 1 && rb_nothing_root_owned'
rb_check "install: stdout is nix's own line, then the hand-back line -- the hand-back runs after nix has exited" \
    rb_out_is "FAKE-NIX-OUT profile install
$RB_NIX_HANDED_LINE"
rb_check "install: nix's stderr passes through; the root profile directory and other temp-roots files stay root's" \
    eval 'grep -Fx "FAKE-NIX-ERR profile install" "$RB_CASE/err" >/dev/null && rb_sentinels_root'

rb_new_case clean
RB_INSTALL_RC=9
export RB_INSTALL_RC
rb_run install_essential_packages
unset RB_INSTALL_RC
rb_check "install (nix fails with 9): returns 9, and the paths it left are still handed back" \
    eval '[ "$rb_rc" -eq 9 ] && rb_nix_paths_handed 1 && rb_nothing_root_owned && rb_out_is "FAKE-NIX-OUT profile install
$RB_NIX_HANDED_LINE"'

rb_new_case clean
rb_run upgrade_essential_packages
rb_check "upgrade: remove then install, each followed by its own hand-back; returns 0" \
    eval '[ "$rb_rc" -eq 0 ] && [ "$(rb_nix_calls)" -eq 2 ] && rb_out_is "FAKE-NIX-OUT profile remove
$RB_NIX_HANDED_LINE
FAKE-NIX-OUT profile install
$RB_NIX_HANDED_LINE"'
rb_check "upgrade: nothing root-owned is left in the store or the log directory" \
    eval 'rb_nix_paths_handed 1 && rb_nix_paths_handed 2 && rb_nothing_root_owned && rb_sentinels_root'

rb_new_case clean
RB_INSTALL_RC=5
export RB_INSTALL_RC
rb_run upgrade_essential_packages
unset RB_INSTALL_RC
rb_check "upgrade (install fails with 5): remove, install, rollback -- each followed by its own hand-back -- and returns 5" \
    eval '[ "$rb_rc" -eq 5 ] && [ "$(rb_nix_calls)" -eq 3 ] && rb_nix_argv_starts 3 "profile rollback --profile /nix/var/nix/profiles/per-user/root/profile" && rb_out_is "FAKE-NIX-OUT profile remove
$RB_NIX_HANDED_LINE
FAKE-NIX-OUT profile install
$RB_NIX_HANDED_LINE
FAKE-NIX-OUT profile rollback
$RB_NIX_HANDED_LINE"'
rb_check "upgrade (install fails): nothing root-owned is left" \
    eval 'rb_nix_paths_handed 1 && rb_nix_paths_handed 2 && rb_nix_paths_handed 3 && rb_nothing_root_owned'

rb_new_case clean
RP_CHOWN_FAIL_MATCH=new1-profile
RB_INSTALL_RC=0
export RP_CHOWN_FAIL_MATCH RB_INSTALL_RC
rb_run install_essential_packages
unset RP_CHOWN_FAIL_MATCH RB_INSTALL_RC
rb_check "install (the hand-back fails): run_root_nix still returns nix's status (0) and warns on stderr" \
    eval '[ "$rb_rc" -eq 0 ] && rb_warning_given'

print_summary
exit_with_code
