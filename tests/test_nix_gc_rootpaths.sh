#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# No `-e`: cases capture non-zero exit statuses by hand (`... || rc=$?`),
# the same convention as tests/test_nix_gc_temproots.sh.
set -uo pipefail

# Root-owned store paths abort guest garbage collection (fix/gc-rootpaths,
# observed live 2026-10-12).
#
# bin/dx-gc and bin/dx-reclaim run Nix GC in the guest as dx (the store is
# single-user and dx-owned). Live on a QNAP guest, once the stale temp-roots
# file was cleared, `nix-collect-garbage -d` deleted 1,647 paths and then
# aborted:
#   error: ... while making directory "/nix/store/c0dj6b...-profile" accessible for deletion
#          error: fchmodat2 "/nix/store/c0dj6b...-profile": Operation not permitted
# Nix must chmod a store directory before it can empty it, and dx cannot
# chmod a root-owned one. The store held 26 root-owned top-level entries: the
# bootstrap's root Nix calls for the root essentials profile create every
# path they add root-owned (see tests/test_bootstrap_nix_rootpaths.sh, which
# stops new ones). c0dj6b...-profile is the empty profile environment
# `nix profile remove` creates -- reproduced byte for byte against Nix
# 2.34.8. GC as root is not the answer (a root nix may re-own /nix/store and
# its state), but chown is not nix: this hands those paths back, as root,
# before dx's GC, healing existing guests with no restart and no bootstrap
# sync, whatever left the paths there.
#
# Interface contract:
#
#   Module: bin/lib/dx-nix-gc.sh (safe to source; Bash 3.2), as for
#   dx_nix_gc_clear_stale_temproots; relies on dx_runtime_exec.
#
#   dx_nix_gc_hand_back_root_paths CONTAINER
#     Makes exactly ONE runtime call, as ROOT, through the neutral boundary:
#       dx_runtime_exec -u root CONTAINER bash -c PROGRAM bash /nix/store /nix/var/log/nix
#     PROGRAM (author's text) runs in the guest as root with $1 = STORE and
#     $2 = LOG and applies exactly the rule hand_back_root_nix_paths applies
#     in the bootstrap (tests/test_bootstrap_nix_rootpaths.sh's contract):
#     nothing at all when STORE is missing, a symlink or owned by uid 0;
#     otherwise every root-owned DIRECT entry of STORE (with everything
#     inside it, symlinks re-owned themselves and never followed) and every
#     root-owned entry beneath LOG (unless LOG is a symlink) is handed to
#     STORE's own uid:gid; modes, mtimes, every non-root-owned entry and
#     everything inside one, STORE and LOG themselves and everything
#     elsewhere are left alone; chown (found on PATH, never with -L, -H or
#     --dereference) is the only tool that changes anything. Its stdout is
#     exactly one line: the decimal count handed back (one per root-owned
#     direct store entry, one per root-owned log entry); exit 0 on success.
#     A chown that fails does not stop the rest and makes it exit non-zero.
#     Host side, after the call:
#       - count > 0: prints exactly
#           Handed <count> root-owned Nix path(s) back to the store owner.
#         on stdout; returns 0.
#       - count = 0: prints nothing at all; returns 0.
#       - the call exits non-zero: prints a line containing
#           Warning: could not hand root-owned Nix paths back to the store owner
#         and "(exit <status>)" on stderr, nothing on stdout; returns 1.
#       - the call exits 0 without a lone decimal count: prints a line
#         containing that same warning on stderr, nothing on stdout;
#         returns 1.
#
#   bin/dx-gc and bin/dx-reclaim call it once, immediately before their GC
#   command and immediately after the stale temp-roots clear (so: header,
#   [rule,] clear, hand-back, GC). A failed hand-back never stops the GC or
#   changes the exit status. Every other line of output and every other
#   guest command is unchanged; with nothing root-owned the output is
#   byte-for-byte the previous output.
#
# Residual (documented, not tested): a root Nix process running at the very
# moment of the hand-back re-owns its own output to root when it finishes
# (Nix canonicalises a new path to the calling user); GC then fails as it
# did before until the next hand-back.
#
# The cases that run PROGRAM for real need root (rp_root_runner_reason) and
# run in tests/run-coverage-linux.sh's isolated root runner; elsewhere the
# fake guest answers the call with a scripted result instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=lib/nix-rootpaths-fixture.sh
source "$SCRIPT_DIR/lib/nix-rootpaths-fixture.sh"
# shellcheck source=../bin/lib/dx-runtime.sh
source "$BASE_DIR/bin/lib/dx-runtime.sh"
# shellcheck source=../bin/lib/dx-nix-gc.sh
source "$BASE_DIR/bin/lib/dx-nix-gc.sh"
test_section "Nix GC: root-owned store paths are handed back to the store owner before collection"

dxe_test_mktemp_dir RG_ROOT "${TMPDIR:-/tmp}/dxe-nix-gc-rootpaths.XXXXXX"
rg_cleanup() {
    case "$RG_ROOT" in
        "${TMPDIR:-/tmp}"/dxe-nix-gc-rootpaths.?*) chmod -R u+rwx "$RG_ROOT" 2>/dev/null; rm -rf "$RG_ROOT" ;;
    esac
}
trap rg_cleanup EXIT

FAKE_DIR="$(fake_tool_dir_create "$RG_ROOT")" || exit 1
STUB_DIR="$RG_ROOT/stubs"
rp_write_chown_stub "$STUB_DIR"
RP_REAL_CHOWN="$(command -v chown)"
RG_STUB_DIR="$STUB_DIR"
export RP_REAL_CHOWN RG_STUB_DIR
RG_CONTAINER=dxe-gc-rootpaths-test
RG_RULE="------------------------------------------------------------"

# The guest boundary, shared by the `container` (Apple) and `docker`
# (docker-ssh, behind the fake ssh) fakes. Records one transcript line per
# call -- "exec [arg] [arg] ..." -- with the argument after a lone `-c`
# written as <program> and any other multi-line argument as <script>. Then:
#   - the hand-back call (exact argv from the contract) records PROGRAM's
#     checksum and, per RG_MODE, prints a scripted count ("count:N"), fails
#     with 125 ("fail"), prints something that is not a count ("garbage"),
#     or ("real", root runner only) runs PROGRAM for real with /nix/store and
#     /nix/var/log/nix remapped to this case's fixture and the recording,
#     fenced chown first on PATH;
#   - the stale temp-roots clear (fix/gc-temproots) reports nothing stale;
#   - a GC/optimise call snapshots the fixture's manifest at that moment
#     (proving what GC would see) and prints "FAKE-GC <command>";
#   - anything else (dx-reclaim's reports and trims) succeeds silently.
fake_tool_write "$FAKE_DIR" rg-guest-exec '
record="exec"
prev=""
nl="
"
for a in "$@"; do
    if [ "$prev" = "-c" ]; then
        record="$record [<program>]"
    else
        case "$a" in
            *"$nl"*) record="$record [<script>]" ;;
            *) record="$record [$a]" ;;
        esac
    fi
    prev="$a"
done
printf "%s\n" "$record" >> "$RG_TRANSCRIPT"
[ "${1:-}" != -i ] || shift
user=root
if [ "${1:-}" = -u ]; then user="$2"; shift 2; fi
shift
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    nix-collect-garbage*|"nix-store --optimise")
        n=0
        [ -f "$RG_CASE/gc-count" ] && n="$(cat "$RG_CASE/gc-count")"
        n=$((n + 1))
        printf "%s\n" "$n" > "$RG_CASE/gc-count"
        if [ "${RG_MODE:-}" = real ]; then
            (cd "$RG_CASE" && find nix outside -printf "%p\t%U:%G\t%m\t%T@\n" | LC_ALL=C sort) > "$RG_CASE/gc-saw-$n"
        fi
        printf "FAKE-GC %s\n" "$last"
        exit 0
        ;;
esac
if [ "$user" = dx ] && [ "$#" -eq 6 ] && [ "$1" = bash ] && [ "$2" = -c ] && [ "$4" = bash ] \
    && [ "$5" = /nix/var/nix/temproots ] && [ "$6" = /proc ]; then
    printf "0\n"
    exit 0
fi
if [ "$user" = root ] && [ "$#" -eq 6 ] && [ "$1" = bash ] && [ "$2" = -c ] && [ "$4" = bash ] \
    && [ "$5" = /nix/store ] && [ "$6" = /nix/var/log/nix ]; then
    printf "%s" "$3" | cksum > "$RG_CASE/program-cksum"
    case "${RG_MODE:-count:0}" in
        count:*) printf "%s\n" "${RG_MODE#count:}"; exit 0 ;;
        fail) exit 125 ;;
        garbage) printf "%s\n" "handed some paths back"; exit 0 ;;
        real) PATH="$RG_STUB_DIR:$PATH" exec bash -c "$3" "$4" "$RG_CASE/nix/store" "$RG_CASE/nix/var/log/nix" ;;
    esac
fi
exit 0'

fake_tool_write "$FAKE_DIR" container '
case "${1:-}" in
    list) printf "%s\n" "$DX_CONTAINER_NAME"; exit 0 ;;
    exec) shift; exec rg-guest-exec "$@" ;;
esac
exit 1'

fake_qnap_ssh_write "$FAKE_DIR"
fake_tool_write "$FAKE_DIR" docker '
case "${1:-}" in
    exec) shift; exec rg-guest-exec "$@" ;;
esac
echo "UNMATCHED docker: $*" >&2
exit 99'

# rg_new_case MODE [full|clean|none] -- a fresh case directory and mode.
rg_new_case() {
    RG_MODE="$1"
    dxe_test_mktemp_dir RG_CASE "$RG_ROOT/case.XXXXXX"
    RG_TRANSCRIPT="$RG_CASE/transcript"
    RP_CHOWN_LOG="$RG_CASE/chown.log"
    RP_FENCE="$RG_CASE"
    : > "$RG_TRANSCRIPT"
    : > "$RP_CHOWN_LOG"
    unset RP_CHOWN_FAIL_MATCH
    export RG_MODE RG_CASE RG_TRANSCRIPT RP_CHOWN_LOG RP_FENCE
    case "${2:-none}" in
        full) rp_fixture_build "$RG_CASE" ;;
        clean) rp_fixture_build_clean "$RG_CASE" ;;
        none) : ;;
    esac
}

# rg_unit [runtime] -- calls the library function directly (in a subshell),
# capturing stdout/stderr/status into $RG_CASE/{out,err} and $rg_rc.
rg_unit() {
    local runtime="${1:-apple}"
    rg_rc=0
    (
        PATH="$FAKE_DIR:$PATH"
        HOME="$RG_CASE/home"
        DX_RUNTIME="$runtime"
        if [ "$runtime" = docker-ssh ]; then
            DX_REMOTE_HOST=dxe-fixture-nas.invalid
            DXE_RUNTIME_DOCKER_BIN=docker
            export DX_REMOTE_HOST DXE_RUNTIME_DOCKER_BIN
        fi
        export PATH HOME DX_RUNTIME
        if ! declare -F dx_nix_gc_hand_back_root_paths >/dev/null; then
            echo "dx_nix_gc_hand_back_root_paths is not defined" >&2
            exit 95
        fi
        dx_nix_gc_hand_back_root_paths "$RG_CONTAINER"
    ) > "$RG_CASE/out" 2> "$RG_CASE/err" || rg_rc=$?
}

# rg_entry dx-gc|dx-reclaim -- runs the real entry point as a process.
rg_entry() {
    local entry="$1"
    mkdir -p "$RG_CASE/home"
    rg_rc=0
    env PATH="$FAKE_DIR:$PATH" HOME="$RG_CASE/home" \
        DX_RUNTIME=apple DX_CONTAINER_NAME="$RG_CONTAINER" \
        DX_NIX_MOUNT=/nix DX_NIX_VOLUME=dxe-rg-nix DX_PERSIST_VOLUME=dxe-rg-persist \
        "$BASE_DIR/bin/$entry" > "$RG_CASE/out" 2> "$RG_CASE/err" || rg_rc=$?
}

rg_check() {
    local label="$1"
    shift
    if "$@"; then
        test_pass "$label"
    else
        test_fail "$label"
        echo "    status: $rg_rc"
        echo "    stdout: $(cat "$RG_CASE/out" 2>/dev/null)"
        echo "    stderr: $(cat "$RG_CASE/err" 2>/dev/null)"
        echo "    transcript: $(cat "$RG_TRANSCRIPT" 2>/dev/null)"
        echo "    chown calls: $(tr '\n' ' ' < "$RP_CHOWN_LOG" 2>/dev/null)"
    fi
}

rg_out_is() { [ "$(cat "$RG_CASE/out")" = "$1" ]; }
rg_out_empty() { [ ! -s "$RG_CASE/out" ]; }
rg_err_empty() { [ ! -s "$RG_CASE/err" ]; }
rg_warning_line_has() {
    grep -F -- 'Warning: could not hand root-owned Nix paths back to the store owner' "$RG_CASE/err" | grep -F -- "$1" >/dev/null
}
rg_warning_given() { grep -F -- 'Warning: could not hand root-owned Nix paths back to the store owner' "$RG_CASE/err" >/dev/null; }
rg_transcript_is() { [ "$(cat "$RG_TRANSCRIPT")" = "$1" ]; }
rg_no_handed_line() { ! grep -F 'Handed' "$RG_CASE/out" >/dev/null; }

RG_CLEAR_RECORD="exec [-u] [dx] [$RG_CONTAINER] [bash] [-c] [<program>] [bash] [/nix/var/nix/temproots] [/proc]"
RG_HANDBACK_RECORD="exec [-u] [root] [$RG_CONTAINER] [bash] [-c] [<program>] [bash] [/nix/store] [/nix/var/log/nix]"
RG_GC_TRANSCRIPT="$RG_CLEAR_RECORD
$RG_HANDBACK_RECORD
exec [-u] [dx] [$RG_CONTAINER] [bash] [-lc] [nix-collect-garbage --delete-older-than 14d]
exec [-u] [dx] [$RG_CONTAINER] [bash] [-lc] [nix-store --optimise]"
RG_RECLAIM_TRANSCRIPT="exec [$RG_CONTAINER] [/usr/bin/bash] [-lc] [<script>] [bash] [/nix] [/persist]
$RG_CLEAR_RECORD
$RG_HANDBACK_RECORD
exec [-u] [dx] [$RG_CONTAINER] [/usr/bin/bash] [-lc] [nix-collect-garbage -d]
exec [$RG_CONTAINER] [/usr/bin/bash] [-lc] [<script>] [bash] [/nix]
exec [$RG_CONTAINER] [/usr/bin/bash] [-lc] [<script>] [bash] [/persist]
exec [$RG_CONTAINER] [/usr/bin/bash] [-lc] [<script>] [bash] [/nix] [/persist]"

# The stdout segment of dx-reclaim from the GC header through the GC's own output.
rg_reclaim_gc_segment() {
    awk '/^Running Nix garbage collection in guest\.\.\.$/ { on = 1 } on { print } on && /^FAKE-GC / { exit }' "$RG_CASE/out"
}
rg_reclaim_gc_segment_is() { [ "$(rg_reclaim_gc_segment)" = "$1" ]; }

# =============================================================================
# The library function, any host (the guest answers with a scripted result).
# =============================================================================

if declare -F dx_nix_gc_hand_back_root_paths >/dev/null; then
    test_pass "dx_nix_gc_hand_back_root_paths is defined by bin/lib/dx-nix-gc.sh"
else
    test_fail "dx_nix_gc_hand_back_root_paths is defined by bin/lib/dx-nix-gc.sh"
fi

rg_new_case count:7
rg_unit apple
rg_check "hand-back (apple): exactly one exec, as root, with the exact guest argv -u root <name> bash -c <program> bash /nix/store /nix/var/log/nix" \
    rg_transcript_is "$RG_HANDBACK_RECORD"
rg_check "hand-back (apple): reports the guest's count on stdout, exactly one line" \
    rg_out_is "Handed 7 root-owned Nix path(s) back to the store owner."
rg_check "hand-back (apple): returns 0 with nothing on stderr" \
    eval '[ "$rg_rc" -eq 0 ] && rg_err_empty'
# Read inside the eval'd docker-ssh check below.
# shellcheck disable=SC2034
RG_APPLE_CKSUM="$(cat "$RG_CASE/program-cksum" 2>/dev/null)"

rg_new_case count:0
rg_unit apple
rg_check "hand-back (nothing root-owned): prints nothing at all and returns 0" \
    eval '[ "$rg_rc" -eq 0 ] && rg_out_empty && rg_err_empty'
rg_check "hand-back (nothing root-owned): still exactly one guest call, as root" \
    rg_transcript_is "$RG_HANDBACK_RECORD"

rg_new_case fail
rg_unit apple
rg_check "hand-back (guest call fails with 125): warns with the exit status, returns 1, prints nothing on stdout" \
    eval '[ "$rg_rc" -eq 1 ] && rg_out_empty && rg_warning_line_has "(exit 125)"'

rg_new_case garbage
rg_unit apple
rg_check "hand-back (guest call succeeds but prints no lone count): warns, returns 1, prints nothing on stdout" \
    eval '[ "$rg_rc" -eq 1 ] && rg_out_empty && rg_warning_given'

rg_new_case count:7
rg_unit docker-ssh
rg_check "hand-back (docker-ssh): docker exec receives the same argv, as root" \
    rg_transcript_is "$RG_HANDBACK_RECORD"
rg_check "hand-back (docker-ssh): the program arrives byte for byte as under apple, through the ssh quoting" \
    eval '[ -n "$RG_APPLE_CKSUM" ] && [ "$(cat "$RG_CASE/program-cksum" 2>/dev/null)" = "$RG_APPLE_CKSUM" ]'
rg_check "hand-back (docker-ssh): reports the count and returns 0" \
    eval '[ "$rg_rc" -eq 0 ] && rg_out_is "Handed 7 root-owned Nix path(s) back to the store owner." && rg_err_empty'

# =============================================================================
# bin/dx-gc and bin/dx-reclaim end to end, any host.
# =============================================================================

rg_new_case count:26
rg_entry dx-gc
rg_check "dx-gc: clears stale temp roots, hands root-owned paths back as root, then collects and optimises as dx -- four exec calls in that order" \
    rg_transcript_is "$RG_GC_TRANSCRIPT"
rg_check "dx-gc: output is the existing output plus one Handed line after the GC header, before the GC output" \
    rg_out_is "Running Nix garbage collection in guest...
Handed 26 root-owned Nix path(s) back to the store owner.
FAKE-GC nix-collect-garbage --delete-older-than 14d
Running Nix store optimization in guest...
FAKE-GC nix-store --optimise
Nix maintenance complete."
rg_check "dx-gc: exits 0 with nothing on stderr" \
    eval '[ "$rg_rc" -eq 0 ] && rg_err_empty'

rg_new_case count:0
rg_entry dx-gc
rg_check "dx-gc (nothing root-owned): output is byte-for-byte the pre-fix output" \
    rg_out_is "Running Nix garbage collection in guest...
FAKE-GC nix-collect-garbage --delete-older-than 14d
Running Nix store optimization in guest...
FAKE-GC nix-store --optimise
Nix maintenance complete."
rg_check "dx-gc (nothing root-owned): the hand-back call still precedes GC" \
    rg_transcript_is "$RG_GC_TRANSCRIPT"

rg_new_case fail
rg_entry dx-gc
rg_check "dx-gc (hand-back fails): GC and optimisation still run, in order" \
    rg_transcript_is "$RG_GC_TRANSCRIPT"
rg_check "dx-gc (hand-back fails): exits 0, warns on stderr with the exit status, prints no Handed line" \
    eval '[ "$rg_rc" -eq 0 ] && rg_warning_line_has "(exit 125)" && rg_no_handed_line'

rg_new_case count:26
rg_entry dx-reclaim
rg_check "dx-reclaim: the hand-back sits between the temp-roots clear and GC; every other guest call is unchanged" \
    rg_transcript_is "$RG_RECLAIM_TRANSCRIPT"
rg_check "dx-reclaim: the Handed line follows the GC header's rule and precedes the GC output" \
    rg_reclaim_gc_segment_is "Running Nix garbage collection in guest...
$RG_RULE
Handed 26 root-owned Nix path(s) back to the store owner.
FAKE-GC nix-collect-garbage -d"
rg_check "dx-reclaim: completes and exits 0" \
    eval '[ "$rg_rc" -eq 0 ] && grep -Fx "Reclaim complete." "$RG_CASE/out" >/dev/null'

rg_new_case count:0
rg_entry dx-reclaim
rg_check "dx-reclaim (nothing root-owned): the GC segment is byte-for-byte the pre-fix output" \
    rg_reclaim_gc_segment_is "Running Nix garbage collection in guest...
$RG_RULE
FAKE-GC nix-collect-garbage -d"

rg_new_case fail
rg_entry dx-reclaim
rg_check "dx-reclaim (hand-back fails): GC, trims and the final report still run" \
    rg_transcript_is "$RG_RECLAIM_TRANSCRIPT"
rg_check "dx-reclaim (hand-back fails): exits 0 and warns on stderr" \
    eval '[ "$rg_rc" -eq 0 ] && rg_warning_line_has "(exit 125)" && grep -Fx "Reclaim complete." "$RG_CASE/out" >/dev/null'

# =============================================================================
# PROGRAM for real (root runner only).
# =============================================================================

RG_REASON="$(rp_root_runner_reason)"
if [ -n "$RG_REASON" ]; then
    for rg_label in \
        "hand-back program (apple and docker-ssh): exactly the root-owned direct store entries and log entries go to the store owner" \
        "hand-back program: nothing root-owned, store owned by root, symlinked store, symlinked log directory, no store, a failing chown" \
        "dx-gc with the real program: GC sees the handed-back store"; do
        test_skip "$rg_label ($RG_REASON)"
    done
    print_summary
    exit_with_code
fi

rg_manifest_is() { [ "$(rp_manifest "$RG_CASE")" = "$1" ]; }
rg_no_chown() { [ "$(rp_chown_calls)" -eq 0 ] && ! rp_chown_refused; }
rg_chown_used_in_scope() {
    [ "$(rp_chown_calls)" -ge 1 ] && ! rp_chown_refused \
        && rp_chown_operands_in_scope "$RG_CASE/nix/store" "$RG_CASE/nix/var/log/nix"
}
RG_REAL_LINE="Handed $RP_HANDED_COUNT root-owned Nix path(s) back to the store owner."

# The fixture itself: without this, the "nothing changes" cases below could
# pass vacuously.
rg_new_case real full
rg_check "fixture: the full fixture really holds the 5 root-owned direct store entries and 4 root-owned log entries the rule names" \
    eval '[ "$(rp_root_owned_left "$RG_CASE" | LC_ALL=C sort)" = "$(printf "%s\n" log:drvs/ab/cd-root-built.drv.bz2 log:drvs/sy log:drvs/sy/bfh-bootstrap-essentials.drv.bz2 log:drvs/zz-link store:.hidden-root store:aaaa-profile store:bbbb-bootstrap-essentials.drv store:cccc-source store:dddd-link | LC_ALL=C sort)" ]'

for rg_runtime in apple docker-ssh; do
    rg_new_case real full
    rg_before="$(rp_manifest "$RG_CASE")"
    rg_expected="$(printf '%s\n' "$rg_before" | rp_expect "$RP_DX_OWNER" "$RP_HANDED_STORE
$RP_HANDED_LOG")"
    rg_unit "$rg_runtime"
    rg_check "hand-back program ($rg_runtime): exactly the root-owned direct store entries (with everything inside them, symlinks themselves) and root-owned log entries now belong to the store owner; every other owner, every mode and every mtime is unchanged" \
        rg_manifest_is "$rg_expected"
    rg_check "hand-back program ($rg_runtime): the host reports '$RG_REAL_LINE' and returns 0" \
        eval '[ "$rg_rc" -eq 0 ] && rg_out_is "$RG_REAL_LINE" && rg_err_empty'
    rg_check "hand-back program ($rg_runtime): ownership changes only through the chown on PATH, never following a symlink, every operand strictly beneath the store or the log directory" \
        rg_chown_used_in_scope
done

# Read inside the eval'd check below.
# shellcheck disable=SC2034
rg_after="$(rp_manifest "$RG_CASE")"
: > "$RP_CHOWN_LOG"
rg_unit apple
rg_check "hand-back program again with nothing root-owned left: prints nothing, returns 0, runs no chown, changes nothing" \
    eval '[ "$rg_rc" -eq 0 ] && rg_out_empty && rg_err_empty && rg_no_chown && rg_manifest_is "$rg_after"'

rg_new_case real full
chown -h 0:0 "$RG_CASE/nix/store"
rg_before="$(rp_manifest "$RG_CASE")"
rg_unit apple
rg_check "hand-back program, store owned by root: nothing changes anywhere, prints nothing, returns 0, no chown" \
    eval '[ "$rg_rc" -eq 0 ] && rg_out_empty && rg_err_empty && rg_no_chown && rg_manifest_is "$rg_before"'

rg_new_case real full
mkdir "$RG_CASE/elsewhere"
mv "$RG_CASE/nix/store" "$RG_CASE/elsewhere/store"
ln -s ../elsewhere/store "$RG_CASE/nix/store"
chown -h "$RP_DX_OWNER" "$RG_CASE/nix/store"
rg_before="$(rp_manifest "$RG_CASE")"
rg_unit apple
rg_check "hand-back program, symlinked store: nothing changes anywhere, prints nothing, returns 0, no chown" \
    eval '[ "$rg_rc" -eq 0 ] && rg_out_empty && rg_err_empty && rg_no_chown && rg_manifest_is "$rg_before"'

rg_new_case real full
mkdir "$RG_CASE/elsewhere"
mv "$RG_CASE/nix/var/log/nix" "$RG_CASE/elsewhere/log"
ln -s ../../../elsewhere/log "$RG_CASE/nix/var/log/nix"
chown -h "$RP_DX_OWNER" "$RG_CASE/nix/var/log/nix"
rg_before="$(rp_manifest "$RG_CASE")"
rg_expected="$(printf '%s\n' "$rg_before" | rp_expect "$RP_DX_OWNER" "$RP_HANDED_STORE")"
rg_unit apple
rg_check "hand-back program, symlinked log directory: the store's root-owned entries are handed back, nothing behind the link changes, and only they are counted" \
    eval 'rg_manifest_is "$rg_expected" && [ "$rg_rc" -eq 0 ] && rg_out_is "Handed $RP_HANDED_STORE_COUNT root-owned Nix path(s) back to the store owner." && rg_err_empty'

rg_new_case real none
rg_unit apple
rg_check "hand-back program, no store at all: nothing to hand back -- prints nothing, returns 0, no chown" \
    eval '[ "$rg_rc" -eq 0 ] && rg_out_empty && rg_err_empty && rg_no_chown'

rg_new_case real full
rg_before="$(rp_manifest "$RG_CASE")"
rg_expected="$(printf '%s\n' "$rg_before" | rp_expect "$RP_DX_OWNER" "$(printf '%s\n' "$RP_HANDED_STORE
$RP_HANDED_LOG" | grep -v cccc-source)")"
RP_CHOWN_FAIL_MATCH=cccc-source
export RP_CHOWN_FAIL_MATCH
rg_unit apple
unset RP_CHOWN_FAIL_MATCH
rg_check "hand-back program, one chown fails: every other root-owned entry is still handed back" \
    rg_manifest_is "$rg_expected"
rg_check "hand-back program, one chown fails: the host warns with the program's non-zero exit and returns 1, no Handed line" \
    eval '[ "$rg_rc" -eq 1 ] && rg_warning_given && rg_out_empty'

rg_new_case real full
rg_before="$(rp_manifest "$RG_CASE")"
rg_expected="$(printf '%s\n' "$rg_before" | rp_expect "$RP_DX_OWNER" "$RP_HANDED_STORE
$RP_HANDED_LOG")"
rg_entry dx-gc
rg_check "dx-gc with the real program: by the time GC runs, the root-owned paths already belong to the store owner" \
    eval '[ -f "$RG_CASE/gc-saw-1" ] && [ "$(cat "$RG_CASE/gc-saw-1")" = "$rg_expected" ]'
rg_check "dx-gc with the real program: reports the count after the GC header and exits 0" \
    eval '[ "$rg_rc" -eq 0 ] && [ "$(sed -n 2p "$RG_CASE/out")" = "$RG_REAL_LINE" ]'

print_summary
exit_with_code
