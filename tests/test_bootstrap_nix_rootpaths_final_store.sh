#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
# No `-e` here: cases capture non-zero exit statuses by hand. The boot itself
# runs under `set -euo pipefail` (fs_run), as bootstrap.sh runs it.
set -uo pipefail

# The boot leaves no root-owned entries in the persistent Nix store
# (fix/gc-rootpaths-remount, seen live on the Mac guest dx-test,
# 2026-10-13).
#
# fix/gc-rootpaths made every root Nix call hand its paths back
# (run_root_nix -> hand_back_root_nix_paths). In apple-image mode that call
# runs against the image's own store, which root owns, so the hand-back is a
# no-op by design; the persistent store gets the essentials closure only
# later, from populate_prepared_nix_volume's import
# (nix_store_import_registered: `nix copy ... --to
# local?store=/nix/store&real=<volume>/store...`, the
# "copying path '...-dx-bootstrap-essentials.drv' to 'local://'" lines of the
# boot log). That copy runs as dx, not root -- reproduced against Nix 2.34.8
# (see the Red commit message): every path it creates is dx's -- but the
# store keeps `auto-optimise-store = true` (configure_single_user_nix), so a
# newly copied regular file, a top-level .drv included, is replaced by a hard
# link to an existing .links inode with the same content, and when that inode
# is root's (an earlier root Nix call against the volume) the new top-level
# entry is root-owned too. A root Nix call that ran against the volume
# itself (a bootstrap from before fix/gc-rootpaths; an already-mounted /nix)
# leaves root-owned directories behind as well. dx-test held five such
# entries after a recreate (nix-ld-2.0.6 and four .drv files); dx-gc's own
# hand-back healed them, the boot did not. Root-owned direct store entries
# abort dx's garbage collection (fchmodat2: Operation not permitted) and stop
# dx's own repair of those paths; a root-owned log bucket stops dx's builds.
#
# Interface contract (container/dx-nixos-26.05/bootstrap.sh, bootstrap_phases;
# bootstrap/common.sh's hand_back_root_nix_paths itself is unchanged):
#
#   bootstrap_phases calls hand_back_root_nix_paths exactly once per boot as
#   its own step, immediately after ensure_essentials_valid and immediately
#   before publish_nix_image_store_identity:
#     ... populate_prepared_nix_volume, verify_remount_prerequisites,
#     nix_restore_image_default_profile, ensure_essentials_valid,
#     hand_back_root_nix_paths, publish_nix_image_store_identity,
#     configure_release_identity, ...
#   - By then the store is in its final place (/nix: the remounted volume in
#     apple-image mode, the volume itself from container start in
#     direct-volume mode -- the same shared call site either way), the
#     essentials closure is in it, and ensure_essentials_valid (the only
#     content-level verifier) has proven that closure -- chown and stat among
#     it -- sound, so no tool from the persistent store runs for a new purpose
#     before its verifier (store-trust-plan.md Problem 2); find comes from the
#     image default profile nix_restore_image_default_profile has just
#     restored. Every later phase (the identity marker, persistence, ssh,
#     Home Manager activation as dx, ...) meets no root-owned entry.
#   - It is hand_back_root_nix_paths with its own rule and guards, on
#     "${DX_ESSENTIALS_ROOT:-}/nix" (production: /nix, the final store):
#     nothing at all when the store is missing, is a symlink or is owned by
#     uid 0; otherwise only the root-owned direct store entries (with
#     everything inside them, symlinks never followed) and the root-owned
#     entries beneath the log directory go to the store's numeric owner;
#     stdout "Handed N root-owned Nix path(s) back to the store owner
#     UID:GID." when N > 0, nothing otherwise.
#   - A failed hand-back never fails the boot: its own warning ("Warning:
#     could not hand root-owned Nix paths back to the store owner ...")
#     reaches stderr, every later phase still runs, and bootstrap_phases still
#     succeeds under `set -euo pipefail` (for example
#     `hand_back_root_nix_paths || true`).
#   - The essentials step's own per-call hand-backs (run_root_nix) stay as
#     they are; this is one more call per boot, outside the essentials step.
#
# How the cases see it: every documented phase is shadowed by a recorder (as
# tests/test_section3_bootstrap.sh's phase-order case does) and
# hand_back_root_nix_paths is wrapped by a recorder that then runs the real
# function, so a case sees when the hand-back ran, how often, and what it did.
# The shadowed populate_prepared_nix_volume and ensure_essentials_valid put new
# root-owned entries into the store (what the import and the steps before
# the hand-back can leave), and the shadowed publish_nix_image_store_identity
# records what is still root-owned when the boot moves on.
#
# Any host: `chown` is a recording stub that changes nothing, `stat` a stub
# that reports a scripted store owner (or fails), and `find` runs the host's
# real find over this run's own fixture with `-uid 0` replaced by
# `-name 'r-*'` (a non-root user cannot create root-owned files, so there
# "root-owned" means "named r-*"; the same fakes as
# tests/test_bootstrap_nix_rootpaths_unit.sh).
#
# Real ownership (rp_root_runner_reason): tests/run-coverage-linux.sh's
# isolated root runner (any root Linux shell with bash, GNU
# coreutils/findutils, sed and awk); skipped elsewhere with the reason. Every
# path such a case changes is inside this suite's own mktemp root, through the
# recording, fenced `chown` of tests/lib/nix-rootpaths-fixture.sh, which
# refuses symlink-following options and anything outside the case.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=lib/nix-rootpaths-fixture.sh
source "$SCRIPT_DIR/lib/nix-rootpaths-fixture.sh"
# shellcheck source=../container/dx-nixos-26.05/bootstrap/common.sh
source "$CONTAINER_DIR/bootstrap/common.sh"
# Defines bootstrap_phases and bootstrap_main only: its own
# `[ "${BASH_SOURCE[0]}" = "$0" ]` guard keeps sourcing from running anything.
# shellcheck source=../container/dx-nixos-26.05/bootstrap.sh
source "$BOOTSTRAP"
test_section "Bootstrap: the boot hands root-owned paths in the final Nix store back once, before it moves on"

FS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-bootfinal-rootpaths.XXXXXX")"
fs_cleanup() {
    case "$FS_ROOT" in
        "${TMPDIR:-/tmp}"/dxe-bootfinal-rootpaths.?*) chmod -R u+rwx "$FS_ROOT" 2>/dev/null; rm -rf "$FS_ROOT" ;;
    esac
}
trap fs_cleanup EXIT

FS_REAL_FIND="$(command -v find)"
export FS_REAL_FIND

# Any-host fakes (fail-closed for nix and every remote tool).
FAKE_DIR="$(fake_tool_dir_create "$FS_ROOT")"
# chown: appends "chown <operand relative to the case>" to the shared event
# log, changes nothing, and fails for an operand containing $FS_CHOWN_FAIL.
fake_tool_write "$FAKE_DIR" chown '
operand="${!#}"
printf "chown %s\n" "${operand#"$FS_CASE"/}" >> "$FS_EVENTS"
if [ -n "${FS_CHOWN_FAIL:-}" ]; then
    case "$operand" in *"$FS_CHOWN_FAIL"*) exit 1 ;; esac
fi
exit 0'
fake_tool_write "$FAKE_DIR" stat '
[ -z "${FS_STAT_FAIL:-}" ] || { echo "stat: cannot stat" >&2; exit 1; }
printf "%s\n" "$FS_STORE_OWNER"'
fake_tool_write "$FAKE_DIR" find '
args=()
while [ "$#" -gt 0 ]; do
    if [ "$1" = -uid ] && [ "${2:-}" = 0 ]; then
        args+=(-name "r-*")
        shift 2
        continue
    fi
    args+=("$1")
    shift
done
exec "$FS_REAL_FIND" "${args[@]}"'

# Real-ownership tools: the fenced, recording chown in front of the real one.
STUB_DIR="$FS_ROOT/stubs"
rp_write_chown_stub "$STUB_DIR"
RP_REAL_CHOWN="$(command -v chown)"
export RP_REAL_CHOWN

# The documented phases bootstrap_phases runs, in order (bootstrap.sh).
FS_PHASES="configure_single_user_nix install_essentials link_system_bash capture_nix_image_default_profile prepare_nix_volume materialize_auth_files create_user populate_prepared_nix_volume verify_remount_prerequisites nix_restore_image_default_profile ensure_essentials_valid publish_nix_image_store_identity configure_release_identity setup_persist configure_ssh configure_guest verify_guest_tools configure_timezone"

# The event log a boot must leave: every phase, and the hand-back exactly once
# between ensure_essentials_valid and publish_nix_image_store_identity.
FS_EXPECTED_EVENTS="phase configure_single_user_nix
phase install_essentials
phase link_system_bash
phase capture_nix_image_default_profile
phase prepare_nix_volume
phase materialize_auth_files
phase create_user
phase populate_prepared_nix_volume
phase verify_remount_prerequisites
phase nix_restore_image_default_profile
phase ensure_essentials_valid
hand-back
phase publish_nix_image_store_identity
phase configure_release_identity
phase setup_persist
phase configure_ssh
phase configure_guest
phase verify_guest_tools
phase configure_timezone"

# fs_stdout_with LINE -- the boot's stdout when the hand-back printed LINE
# (one marker per phase; LINE right after ensure_essentials_valid's).
fs_stdout_with() {
    local phase
    for phase in $FS_PHASES; do
        printf 'PHASE %s\n' "$phase"
        if [ "$phase" = ensure_essentials_valid ] && [ -n "$1" ]; then printf '%s\n' "$1"; fi
    done
}

# --- Cases -------------------------------------------------------------------

# fs_new_case -- a fresh case directory with empty logs and default knobs.
fs_new_case() {
    FS_CASE="$(mktemp -d "$FS_ROOT/case.XXXXXX")"
    FS_EVENTS="$FS_CASE/events"
    FS_PUBLISH_SNAPSHOT="$FS_CASE/root-owned-at-publish"
    RP_CHOWN_LOG="$FS_CASE/chown.log"
    RP_FENCE="$FS_CASE"
    FS_STORE_OWNER=4242:4243
    FS_POPULATE_ADDS=""
    FS_ENSURE_ADDS=""
    : > "$FS_EVENTS"
    : > "$RP_CHOWN_LOG"
    unset FS_CHOWN_FAIL FS_STAT_FAIL RP_CHOWN_FAIL_MATCH
    export FS_CASE FS_EVENTS RP_CHOWN_LOG RP_FENCE FS_STORE_OWNER
}

# fs_any_store -- the any-host stand-in final store: one entry "root" left
# from an earlier boot, one of dx's, and a "root" log bucket with one log.
fs_any_store() {
    mkdir -p "$FS_CASE/nix/store/r-aaaa-profile/bin" "$FS_CASE/nix/store/bbbb-dx-own" \
        "$FS_CASE/nix/var/log/nix/drvs/r-sy" "$FS_CASE/nix/var/nix/temproots"
    printf 'log\n' > "$FS_CASE/nix/var/log/nix/drvs/r-sy/r-x.drv.bz2"
}

# fs_shadow_phases -- (inside the boot's subshell) every documented phase
# becomes a recorder; hand_back_root_nix_paths becomes a recorder in front of
# the real one.
fs_phase() {
    printf 'phase %s\n' "$1" >> "$FS_EVENTS"
    printf 'PHASE %s\n' "$1"
}
fs_shadow_phases() {
    local name
    for name in $FS_PHASES; do
        eval "$name() { fs_phase $name; }"
    done
    dx_read_durable_identity_record() { :; }
    populate_prepared_nix_volume() {
        fs_phase populate_prepared_nix_volume
        [ -z "$FS_POPULATE_ADDS" ] || "$FS_POPULATE_ADDS"
    }
    ensure_essentials_valid() {
        fs_phase ensure_essentials_valid
        [ -z "$FS_ENSURE_ADDS" ] || "$FS_ENSURE_ADDS"
    }
    publish_nix_image_store_identity() {
        fs_phase publish_nix_image_store_identity
        fs_publish_snapshot
    }
    eval "fs_real_hand_back_root_nix_paths() $(declare -f hand_back_root_nix_paths | tail -n +2)"
    hand_back_root_nix_paths() {
        printf 'hand-back\n' >> "$FS_EVENTS"
        fs_real_hand_back_root_nix_paths "$@"
    }
}

# What is still "root-owned" when the boot moves on (any host: the r-* names
# no chown has been recorded for; root runner: real ownership).
fs_publish_snapshot() {
    if [ "$FS_MODE" = root ]; then
        rp_root_owned_left "$FS_CASE" > "$FS_PUBLISH_SNAPSHOT"
    else
        fs_any_unhanded > "$FS_PUBLISH_SNAPSHOT"
    fi
}
fs_any_unhanded() {
    local entry
    if [ -d "$FS_CASE/nix/store" ] && [ ! -L "$FS_CASE/nix/store" ]; then
        for entry in "$FS_CASE/nix/store"/r-*; do
            [ -e "$entry" ] || continue
            grep -Fqx "chown ${entry#"$FS_CASE"/}" "$FS_EVENTS" || printf '%s\n' "${entry#"$FS_CASE"/}"
        done
    fi
    return 0
}

# fs_run any|root -- runs bootstrap_phases as bootstrap.sh does (set -euo
# pipefail), with every phase shadowed, DX_ESSENTIALS_ROOT at this case and
# the mode's tools first on PATH; captures stdout, stderr and status.
fs_run() {
    FS_MODE="$1"
    (
        if [ "$FS_MODE" = root ]; then
            PATH="$STUB_DIR:$PATH"
            want="$STUB_DIR/chown"
        else
            PATH="$FAKE_DIR:$PATH"
            want="$FAKE_DIR/chown"
        fi
        DX_ESSENTIALS_ROOT="$FS_CASE"
        export PATH DX_ESSENTIALS_ROOT
        # Fail closed: never reach the code under test unless `chown` is this
        # mode's recording stub.
        [ "$(command -v chown)" = "$want" ] || exit 96
        declare -F bootstrap_phases >/dev/null || { echo "bootstrap_phases is not defined" >&2; exit 95; }
        declare -F hand_back_root_nix_paths >/dev/null || { echo "hand_back_root_nix_paths is not defined" >&2; exit 95; }
        fs_shadow_phases
        set -euo pipefail
        bootstrap_phases
    ) > "$FS_CASE/out" 2> "$FS_CASE/err"
    # Not `( ... ) || fs_rc=$?`: a subshell on the left of || runs with
    # errexit suppressed, so a hand-back failure that would stop the real boot
    # under set -e would pass unnoticed. This file has no `-e`, so a failing
    # boot only sets the status.
    fs_rc=$?
}

fs_check() {
    local label="$1"
    shift
    if "$@"; then
        test_pass "$label"
    else
        test_fail "$label"
        echo "    status: $fs_rc"
        echo "    stdout: $(tr '\n' '|' 2>/dev/null < "$FS_CASE/out")"
        echo "    stderr: $(tr '\n' '|' 2>/dev/null < "$FS_CASE/err")"
        echo "    events: $(tr '\n' '|' 2>/dev/null < "$FS_EVENTS")"
        echo "    fenced chown calls: $(tr '\n' ' ' 2>/dev/null < "$RP_CHOWN_LOG")"
        echo "    root-owned at publish: $(tr '\n' ' ' 2>/dev/null < "$FS_PUBLISH_SNAPSHOT")"
    fi
}

fs_phase_events() { grep -v '^chown ' "$FS_EVENTS"; }
fs_phases_in_order() { [ "$(fs_phase_events)" = "$FS_EXPECTED_EVENTS" ]; }
fs_out_is() { [ "$(cat "$FS_CASE/out")" = "$1" ]; }
fs_err_empty() { [ ! -s "$FS_CASE/err" ]; }
fs_warning_given() { grep -F -- 'Warning: could not hand root-owned Nix paths back to the store owner' "$FS_CASE/err" >/dev/null; }
fs_no_any_chown() { ! grep '^chown ' "$FS_EVENTS" >/dev/null; }
fs_nothing_left_at_publish() { [ -f "$FS_PUBLISH_SNAPSHOT" ] && [ ! -s "$FS_PUBLISH_SNAPSHOT" ]; }
# Every recorded chown sits strictly between the hand-back marker and
# publish_nix_image_store_identity, and the operands (sorted) are exactly $1.
fs_chowns_are() {
    local hand pub
    [ "$(grep -c -x 'hand-back' "$FS_EVENTS")" = 1 ] || return 1
    hand="$(grep -n -x 'hand-back' "$FS_EVENTS" | cut -d: -f1)"
    pub="$(grep -n -x 'phase publish_nix_image_store_identity' "$FS_EVENTS" | cut -d: -f1)"
    [ -n "$hand" ] && [ -n "$pub" ] || return 1
    [ "$(awk -v a="$hand" -v b="$pub" '/^chown / && (NR < a || NR > b) { n++ } END { print n + 0 }' "$FS_EVENTS")" = 0 ] || return 1
    [ "$(sed -n 's/^chown //p' "$FS_EVENTS" | LC_ALL=C sort)" = "$(printf '%s\n' "$1" | LC_ALL=C sort)" ]
}

# The stand-ins the shadowed steps add (any host).
fs_any_populate_adds() {
    mkdir -p "$FS_CASE/nix/store/r-zzzz-nix-ld-2.0.6/libexec"
    printf 'Derive()\n' > "$FS_CASE/nix/store/r-yyyy-dx-bootstrap-essentials.drv"
}
fs_any_ensure_adds() { mkdir -p "$FS_CASE/nix/store/r-xxxx-after-verify"; }

FS_ANY_HANDED="nix/store/r-aaaa-profile
nix/store/r-xxxx-after-verify
nix/store/r-yyyy-dx-bootstrap-essentials.drv
nix/store/r-zzzz-nix-ld-2.0.6
nix/var/log/nix/drvs/r-sy
nix/var/log/nix/drvs/r-sy/r-x.drv.bz2"

# =============================================================================
# Any host.
# =============================================================================

# --- A dx-owned final store: handed back once, after the closure is verified -
fs_new_case
fs_any_store
FS_POPULATE_ADDS=fs_any_populate_adds
FS_ENSURE_ADDS=fs_any_ensure_adds
fs_run any
fs_check "boot: every phase runs in order, and hand_back_root_nix_paths runs exactly once, right after ensure_essentials_valid and right before publish_nix_image_store_identity" \
    fs_phases_in_order
fs_check "boot: the hand-back sees the final store as the steps before it left it -- the entries already there, the import's (a .drv, a directory output) and anything added up to ensure_essentials_valid -- and hands each root-owned store and log entry back exactly once, all before the boot moves on" \
    fs_chowns_are "$FS_ANY_HANDED"
fs_check "boot: nothing root-owned is left in the store when publish_nix_image_store_identity runs" \
    fs_nothing_left_at_publish
fs_check "boot: stdout is the phases' own output with exactly one 'Handed 6 root-owned Nix path(s) back to the store owner 4242:4243.' line after ensure_essentials_valid's; nothing on stderr; returns 0" \
    eval '[ "$fs_rc" -eq 0 ] && fs_out_is "$(fs_stdout_with "Handed 6 root-owned Nix path(s) back to the store owner 4242:4243.")" && fs_err_empty'

# --- Guards: nothing to hand back to -----------------------------------------
fs_new_case
fs_any_store
FS_STORE_OWNER=0:0
FS_POPULATE_ADDS=fs_any_populate_adds
fs_run any
fs_check "boot, final store owned by root (no one to hand back to): the hand-back still runs once in its place, changes nothing (no chown), prints nothing, and the boot goes on (returns 0)" \
    eval '[ "$fs_rc" -eq 0 ] && fs_phases_in_order && fs_no_any_chown && fs_out_is "$(fs_stdout_with "")" && fs_err_empty'

fs_new_case
mkdir -p "$FS_CASE/elsewhere/store/r-aaaa-profile" "$FS_CASE/nix/var/log/nix/drvs/r-sy"
ln -s ../elsewhere/store "$FS_CASE/nix/store"
fs_run any
fs_check "boot, final store is a symlink: the hand-back runs once in its place and never follows it -- no chown anywhere (not even in the log directory), silent, the boot goes on" \
    eval '[ "$fs_rc" -eq 0 ] && fs_phases_in_order && fs_no_any_chown && fs_out_is "$(fs_stdout_with "")" && fs_err_empty'

fs_new_case
fs_run any
fs_check "boot, no store under the final /nix at all: the hand-back runs once in its place, does nothing, is silent, and the boot goes on" \
    eval '[ "$fs_rc" -eq 0 ] && fs_phases_in_order && fs_no_any_chown && fs_out_is "$(fs_stdout_with "")" && fs_err_empty'

# --- A failed hand-back never fails the boot ----------------------------------
fs_new_case
fs_any_store
FS_POPULATE_ADDS=fs_any_populate_adds
FS_CHOWN_FAIL=r-zzzz-nix-ld-2.0.6
export FS_CHOWN_FAIL
fs_run any
unset FS_CHOWN_FAIL
fs_check "boot, one chown fails: under set -euo pipefail the boot still runs every later phase in order and returns 0" \
    eval '[ "$fs_rc" -eq 0 ] && fs_phases_in_order'
fs_check "boot, one chown fails: every other root-owned entry is still handed back, the Handed line counts only those, and the hand-back's warning reaches stderr" \
    eval 'fs_chowns_are "nix/store/r-aaaa-profile
nix/store/r-yyyy-dx-bootstrap-essentials.drv
nix/store/r-zzzz-nix-ld-2.0.6
nix/var/log/nix/drvs/r-sy
nix/var/log/nix/drvs/r-sy/r-x.drv.bz2" && fs_out_is "$(fs_stdout_with "Handed 4 root-owned Nix path(s) back to the store owner 4242:4243.")" && fs_warning_given'

fs_new_case
fs_any_store
FS_STAT_FAIL=1
export FS_STAT_FAIL
fs_run any
unset FS_STAT_FAIL
fs_check "boot, the store owner cannot be read: the hand-back warns on stderr and runs no chown, and the boot still runs every later phase and returns 0" \
    eval '[ "$fs_rc" -eq 0 ] && fs_phases_in_order && fs_no_any_chown && fs_warning_given && fs_out_is "$(fs_stdout_with "")"'

# =============================================================================
# Real ownership (root runner only).
# =============================================================================

FS_REASON="$(rp_root_runner_reason)"
if [ -n "$FS_REASON" ]; then
    for fs_label in \
        "boot, real ownership: the full fixture's root-owned store and log entries belong to the store owner afterwards, nothing else changes" \
        "boot, real ownership: what the import and the steps up to ensure_essentials_valid leave root-owned is the store owner's before the boot moves on" \
        "boot, real ownership: a root-owned or symlinked final store is left exactly as it was"; do
        test_skip "$fs_label ($FS_REASON)"
    done
    print_summary
    exit_with_code
fi

fs_manifest_is() { [ "$(rp_manifest "$FS_CASE")" = "$1" ]; }
fs_no_fenced_chown() { [ "$(rp_chown_calls)" -eq 0 ] && ! rp_chown_refused; }
fs_fenced_chown_in_scope() {
    [ "$(rp_chown_calls)" -ge 1 ] && ! rp_chown_refused \
        && rp_chown_operands_in_scope "$FS_CASE/nix/store" "$FS_CASE/nix/var/log/nix"
}

# --- The full fixture as the final store ---------------------------------------
fs_new_case
rp_fixture_build "$FS_CASE"
fs_before="$(rp_manifest "$FS_CASE")"
fs_expected="$(printf '%s\n' "$fs_before" | rp_expect "$RP_DX_OWNER" "$RP_HANDED_STORE
$RP_HANDED_LOG")"
fs_run root
fs_check "boot, real ownership: exactly the root-owned direct store entries (with everything inside them, symlinks themselves) and the root-owned log entries now belong to the store owner; every other owner, every mode and every mtime is unchanged, nothing outside the store and log directories changed" \
    fs_manifest_is "$fs_expected"
fs_check "boot, real ownership: the hand-back ran once in its place, nothing root-owned was left when publish_nix_image_store_identity ran, and stdout carries exactly one 'Handed $RP_HANDED_COUNT ...' line after ensure_essentials_valid's; returns 0, stderr empty" \
    eval '[ "$fs_rc" -eq 0 ] && fs_phases_in_order && fs_nothing_left_at_publish && fs_out_is "$(fs_stdout_with "Handed $RP_HANDED_COUNT root-owned Nix path(s) back to the store owner $RP_DX_OWNER.")" && fs_err_empty'
fs_check "boot, real ownership: ownership changes only through the chown on PATH, never following a symlink, every operand strictly beneath the store or the log directory" \
    fs_fenced_chown_in_scope

# --- An apple-image boot: what the import and the steps after it leave -------
# The import as dx creates dx-owned paths, but auto-optimise replaces a new
# top-level .drv with a hard link to a root-owned .links inode of the same
# content; a root Nix call against the volume leaves root-owned directories;
# root's log bucket. All of it arrives after the hand-back's own position in
# run_root_nix and before ensure_essentials_valid returns.
fs_root_populate_adds() {
    local s="$FS_CASE/nix/store"
    mkdir -p "$s/zzzz-nix-ld-2.0.6/libexec" "$s/.links"
    printf 'loader\n' > "$s/zzzz-nix-ld-2.0.6/libexec/nix-ld"
    printf 'Derive([("out","/nix/store/w-dx-bootstrap-essentials")])\n' > "$s/.links/0drvhash"
    ln "$s/.links/0drvhash" "$s/yyyy-dx-bootstrap-essentials.drv"
    # The real chown: this is fixture setup, not the hand-back under test.
    "$RP_REAL_CHOWN" -h "$RP_DX_OWNER" "$s/.links"
    chmod 0555 "$s/zzzz-nix-ld-2.0.6/libexec/nix-ld" "$s/zzzz-nix-ld-2.0.6/libexec" "$s/zzzz-nix-ld-2.0.6"
    chmod 0444 "$s/.links/0drvhash"
    touch -h -d @1 "$s/zzzz-nix-ld-2.0.6/libexec/nix-ld" "$s/zzzz-nix-ld-2.0.6/libexec" "$s/zzzz-nix-ld-2.0.6" "$s/yyyy-dx-bootstrap-essentials.drv"
}
fs_root_ensure_adds() {
    mkdir -p "$FS_CASE/nix/var/log/nix/drvs/q9"
    printf 'log\n' > "$FS_CASE/nix/var/log/nix/drvs/q9/x.drv.bz2"
}
fs_new_case
rp_fixture_build_clean "$FS_CASE"
FS_POPULATE_ADDS=fs_root_populate_adds
FS_ENSURE_ADDS=fs_root_ensure_adds
fs_run root
fs_check "boot, real ownership: the import's root-owned .drv (a hard link to a root .links inode), a root-owned directory output and a root log bucket added before ensure_essentials_valid returns are the store owner's before publish_nix_image_store_identity runs, and none is left afterwards" \
    eval '[ "$fs_rc" -eq 0 ] && fs_phases_in_order && fs_nothing_left_at_publish && [ -z "$(rp_root_owned_left "$FS_CASE")" ] && fs_out_is "$(fs_stdout_with "Handed 4 root-owned Nix path(s) back to the store owner $RP_DX_OWNER.")"'
fs_check "boot, real ownership: the handed-back paths keep their read-only modes and mtimes, the .links inode the .drv shares is the store owner's too, and the out-of-scope root-owned sentinels stay root's" \
    eval '[ "$(stat -c "%u:%g %a %Y" "$FS_CASE/nix/store/zzzz-nix-ld-2.0.6")" = "$RP_DX_OWNER 555 1" ] && [ "$(stat -c "%u:%g %a %Y" "$FS_CASE/nix/store/zzzz-nix-ld-2.0.6/libexec/nix-ld")" = "$RP_DX_OWNER 555 1" ] && [ "$(stat -c "%u:%g %a %h" "$FS_CASE/nix/store/.links/0drvhash")" = "$RP_DX_OWNER 444 2" ] && [ "$(stat -c %u "$FS_CASE/nix/var/nix/profiles/per-user/root")" = 0 ] && [ "$(stat -c %u "$FS_CASE/nix/var/nix/temproots/110")" = 0 ]'

# --- Guards with real ownership --------------------------------------------
fs_new_case
rp_fixture_build "$FS_CASE"
chown -h 0:0 "$FS_CASE/nix/store"
fs_before="$(rp_manifest "$FS_CASE")"
fs_run root
fs_check "boot, real ownership, final store owned by root: the hand-back runs once in its place and nothing changes anywhere -- no chown, silent, returns 0" \
    eval '[ "$fs_rc" -eq 0 ] && fs_phases_in_order && fs_no_fenced_chown && fs_manifest_is "$fs_before" && fs_out_is "$(fs_stdout_with "")" && fs_err_empty'

fs_new_case
rp_fixture_build "$FS_CASE"
mkdir "$FS_CASE/elsewhere"
mv "$FS_CASE/nix/store" "$FS_CASE/elsewhere/store"
ln -s ../elsewhere/store "$FS_CASE/nix/store"
chown -h "$RP_DX_OWNER" "$FS_CASE/nix/store"
fs_before="$(rp_manifest "$FS_CASE")"
fs_run root
fs_check "boot, real ownership, final store is a symlink: the hand-back runs once in its place and nothing changes anywhere (not through the link, not in the log directory) -- no chown, silent, returns 0" \
    eval '[ "$fs_rc" -eq 0 ] && fs_phases_in_order && fs_no_fenced_chown && fs_manifest_is "$fs_before" && fs_out_is "$(fs_stdout_with "")" && fs_err_empty'

print_summary
exit_with_code
