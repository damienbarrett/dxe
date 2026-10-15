#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# No `-e`: cases capture non-zero exit statuses by hand (`... || rc=$?`),
# the same convention as tests/test_runtime_boundary_characterisation.sh.
set -uo pipefail

# Stale Nix temporary-roots files block guest garbage collection
# (fix/gc-temproots, observed live 2026-10-12).
#
# bin/dx-gc and bin/dx-reclaim run Nix GC in the guest as dx (the store is
# single-user and dx-owned). Nix's collector opens EVERY file in
# /nix/var/nix/temproots to lock-test it; one file it cannot open aborts the
# whole collection:
#   error: opening temporary roots file "/nix/var/nix/temproots/110": Permission denied
# The bootstrap's root `nix profile install` leaves exactly such a file behind
# (root:root 0600, named after its own pid) -- Nix 2.34's flake-building
# commands do not unlink their temp-roots file on exit, even on success
# (reproduced in nixos/nix:2.34.8; see the Red commit message). dx owns the
# directory, so dx can unlink a root-owned file in it without root.
#
# Interface contract:
#
#   Module: bin/lib/dx-nix-gc.sh -- safe to source (functions/constants only,
#   no I/O at import time; Bash 3.2). Loaded by bin/dx-gc and bin/dx-reclaim.
#   It relies on dx_runtime_exec (bin/lib/dx-runtime.sh) being loaded by the
#   caller and never calls a runtime adapter or `container`/`docker` directly.
#
#   dx_nix_gc_clear_stale_temproots CONTAINER
#     Makes exactly ONE runtime call, as dx (never root), through the neutral
#     boundary:
#       dx_runtime_exec -u dx CONTAINER bash -c PROGRAM bash /nix/var/nix/temproots /proc
#     i.e. the adapter receives the argv
#       -u dx CONTAINER bash -c PROGRAM bash /nix/var/nix/temproots /proc
#     PROGRAM is a guest-side bash program (author's choice of text; it must
#     also run under Bash 3.2, because these tests run it on the host's bash)
#     with $1 = the temp-roots directory and $2 = the process-table root
#     (/proc). Guest rule, applied by PROGRAM:
#       - It refuses to clear anything when "$2/1" is not a directory (the
#         process table is not visible to dx, e.g. hidepid): it then exits
#         non-zero and removes nothing.
#       - A missing temp-roots directory is "nothing to clear" (count 0).
#       - It considers only the DIRECT entries of "$1" whose name is all
#         decimal digits and which are regular files (not symlinks, not
#         directories). Dot-files, non-numeric names, directories (never
#         recursed into) and symlinks (and their targets) are never touched.
#       - Such a file is stale, and is removed, exactly when "$2/<name>" does
#         not exist (no live process with that pid). A file whose pid is live
#         is NEVER removed, readable or not.
#       - Readability is irrelevant: a file dx cannot open (root:root 0600 in
#         the guest; modelled here as mode 000 on a file the test owns) is
#         removed when stale -- unlinking needs only write access to the
#         dx-owned directory.
#       - Its stdout is exactly one line: the decimal count of files it
#         removed. Exit 0 on success.
#     Host side, after the call:
#       - count > 0: prints exactly "Cleared <count> stale Nix temporary roots
#         file(s)." on stdout; returns 0.
#       - count = 0: prints nothing at all; returns 0.
#       - the call exits non-zero: prints a line containing "Warning: could
#         not clear stale Nix temporary roots" and "(exit <status>)" on
#         stderr; returns 1.
#       - the call exits 0 but its stdout is not a lone decimal count: prints
#         a line containing "Warning: could not clear stale Nix temporary
#         roots" on stderr; prints nothing on stdout; returns 1.
#
#   bin/dx-gc and bin/dx-reclaim call it once, immediately before their
#   existing GC command, after printing their existing "Running Nix garbage
#   collection in guest..." header (dx-reclaim: after the rule line that
#   follows that header). A failed clear never stops the GC or changes the
#   exit status: GC still runs, Nix itself stays the authority. Every other
#   line of output and every other guest command is unchanged.
#
#   Residual (documented, not tested): a stale file whose pid has been reused
#   by an unrelated live process is kept (safe direction; Nix then reports it
#   as before); and a new process that is assigned exactly a dead pid and
#   creates its temp-roots file between PROGRAM's /proc check and its unlink
#   would lose that file -- a window of one unlink, per file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=../bin/lib/dx-runtime.sh
source "$BASE_DIR/bin/lib/dx-runtime.sh"
GC_LIB="$BASE_DIR/bin/lib/dx-nix-gc.sh"
test_section "Nix GC: stale temporary-roots files are cleared before collection"

if [ -f "$GC_LIB" ]; then
    test_pass "bin/lib/dx-nix-gc.sh exists"
    # shellcheck source=../bin/lib/dx-nix-gc.sh
    source "$GC_LIB"
else
    test_fail "bin/lib/dx-nix-gc.sh exists"
fi

dxe_test_mktemp_dir GCT_ROOT "${TMPDIR:-/tmp}/dxe-nix-gc-temproots.XXXXXX"
gct_cleanup() {
    case "$GCT_ROOT" in
        "${TMPDIR:-/tmp}"/dxe-nix-gc-temproots.?*) chmod -R u+rwx "$GCT_ROOT" 2>/dev/null; rm -rf "$GCT_ROOT" ;;
    esac
}
trap gct_cleanup EXIT

FAKE_DIR="$(fake_tool_dir_create "$GCT_ROOT")" || exit 1
GCT_CONTAINER=dxe-gc-temproots-test
GCT_RULE="------------------------------------------------------------"

# The guest boundary, shared by the `container` (Apple) and `docker`
# (docker-ssh, behind the fake ssh) fakes below. Receives the exec argv after
# the verb. Records one transcript line per call -- "exec [arg] [arg] ..." --
# with the argument that follows a lone `-c` written as <program> and any
# other multi-line argument written as <script>. Then:
#   - the clear-temproots call (exact argv shape from the contract) runs
#     PROGRAM for real with the guest paths remapped to this case's fixture
#     (GCT_TEMPROOTS, GCT_PROC), or simulates a failure (GCT_PROGRAM_MODE);
#   - a GC/optimise call snapshots the fixture temp-roots directory at that
#     moment (proving what GC would see) and prints "FAKE-GC <command>";
#   - the root-owned paths hand-back (fix/gc-rootpaths; its own suite,
#     tests/test_nix_gc_rootpaths.sh, runs its program) reports nothing
#     root-owned ("0");
#   - anything else (dx-reclaim's reports and trims) succeeds silently.
fake_tool_write "$FAKE_DIR" gct-guest-exec '
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
printf "%s\n" "$record" >> "$GCT_TRANSCRIPT"
[ "${1:-}" != -i ] || shift
user=root
if [ "${1:-}" = -u ]; then user="$2"; shift 2; fi
shift
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    nix-collect-garbage*|"nix-store --optimise")
        n=0
        [ -f "$GCT_CASE/gc-count" ] && n="$(cat "$GCT_CASE/gc-count")"
        n=$((n + 1))
        printf "%s\n" "$n" > "$GCT_CASE/gc-count"
        gct-listing "$GCT_TEMPROOTS" > "$GCT_CASE/gc-saw-$n"
        printf "FAKE-GC %s\n" "$last"
        exit 0
        ;;
esac
if [ "$user" = dx ] && [ "$#" -eq 6 ] && [ "$1" = bash ] && [ "$2" = -c ] && [ "$4" = bash ] \
    && [ "$5" = /nix/var/nix/temproots ] && [ "$6" = /proc ]; then
    case "${GCT_PROGRAM_MODE:-run}" in
        fail) exit 125 ;;
        garbage) printf "%s\n" "removed some files"; exit 0 ;;
    esac
    exec bash -c "$3" "$4" "$GCT_TEMPROOTS" "$GCT_PROC"
fi
if [ "$user" = root ] && [ "$#" -eq 6 ] && [ "$1" = bash ] && [ "$2" = -c ] && [ "$4" = bash ] \
    && [ "$5" = /nix/store ] && [ "$6" = /nix/var/log/nix ]; then
    printf "0\n"
    exit 0
fi
exit 0'

# One line per direct entry of $1 (dot-files included), C-sorted, as
# "name:f" (regular file), "name:d" (directory) or "name:l" (symlink).
fake_tool_write "$FAKE_DIR" gct-listing '
dir="$1"
[ -d "$dir" ] || exit 0
ls -A1 "$dir" | LC_ALL=C sort | while IFS= read -r name; do
    if [ -L "$dir/$name" ]; then kind=l
    elif [ -d "$dir/$name" ]; then kind=d
    else kind=f
    fi
    printf "%s:%s\n" "$name" "$kind"
done'

fake_tool_write "$FAKE_DIR" container '
case "${1:-}" in
    list) printf "%s\n" "$DX_CONTAINER_NAME"; exit 0 ;;
    exec) shift; exec gct-guest-exec "$@" ;;
esac
exit 1'

fake_qnap_ssh_write "$FAKE_DIR"
fake_tool_write "$FAKE_DIR" docker '
case "${1:-}" in
    exec) shift; exec gct-guest-exec "$@" ;;
esac
echo "UNMATCHED docker: $*" >&2
exit 99'

# gct_new_case [stale|clean|absent|hidden-proc] -- a fresh fixture for one
# case: $GCT_CASE/temproots (the guest's /nix/var/nix/temproots) and
# $GCT_CASE/proc (the guest's /proc), exported for the fakes.
#   stale:       the full mix below.
#   clean:       only the files that must survive (nothing stale).
#   absent:      no temproots directory at all.
#   hidden-proc: the full mix, but /proc/1 is not visible.
gct_new_case() {
    local kind="${1:-stale}"
    dxe_test_mktemp_dir GCT_CASE "$GCT_ROOT/case.XXXXXX"
    GCT_TEMPROOTS="$GCT_CASE/temproots"
    GCT_PROC="$GCT_CASE/proc"
    GCT_TRANSCRIPT="$GCT_CASE/transcript"
    : > "$GCT_TRANSCRIPT"
    export GCT_CASE GCT_TEMPROOTS GCT_PROC GCT_TRANSCRIPT
    mkdir -p "$GCT_PROC/4242" "$GCT_PROC/4243" "$GCT_CASE/outside"
    [ "$kind" = hidden-proc ] || mkdir -p "$GCT_PROC/1"
    printf 'outside content\n' > "$GCT_CASE/outside/target"
    [ "$kind" != absent ] || return 0
    mkdir -p "$GCT_TEMPROOTS/777"
    # Live processes: never removed, readable (4242) or not (4243).
    printf '/nix/store/aaaa-live\0' > "$GCT_TEMPROOTS/4242"
    printf '/nix/store/bbbb-live\0' > "$GCT_TEMPROOTS/4243"
    chmod 0000 "$GCT_TEMPROOTS/4243"
    # Never temp-roots files: a dot-file, a non-numeric name, a numeric
    # directory (never recursed into: it holds a stale-looking pid file of
    # its own, 999, that a recursing implementation would remove), and a
    # numeric symlink pointing outside the directory.
    printf 'keep\n' > "$GCT_TEMPROOTS/.hidden-123"
    printf 'keep\n' > "$GCT_TEMPROOTS/notapid"
    printf '/nix/store/eeee-nested\0' > "$GCT_TEMPROOTS/777/999"
    ln -s "$GCT_CASE/outside/target" "$GCT_TEMPROOTS/888"
    [ "$kind" != clean ] || return 0
    # Stale (no such pid): the root-owned file of the bug (modelled as mode
    # 000: unreadable to the caller), and two readable stale files.
    printf '/nix/store/cccc-gone\0' > "$GCT_TEMPROOTS/110"
    chmod 0000 "$GCT_TEMPROOTS/110"
    printf '/nix/store/dddd-gone\0' > "$GCT_TEMPROOTS/545"
    chmod 0600 "$GCT_TEMPROOTS/545"
    printf '' > "$GCT_TEMPROOTS/546"
}

GCT_SURVIVORS=".hidden-123:f
4242:f
4243:f
777:d
888:l
notapid:f"
GCT_FULL_MIX=".hidden-123:f
110:f
4242:f
4243:f
545:f
546:f
777:d
888:l
notapid:f"
GCT_CLEAR_RECORD="exec [-u] [dx] [$GCT_CONTAINER] [bash] [-c] [<program>] [bash] [/nix/var/nix/temproots] [/proc]"
# fix/gc-rootpaths: dx-gc and dx-reclaim hand root-owned store paths back,
# as root, right after the clear and before GC.
GCT_HANDBACK_RECORD="exec [-u] [root] [$GCT_CONTAINER] [bash] [-c] [<program>] [bash] [/nix/store] [/nix/var/log/nix]"

gct_listing() { PATH="$FAKE_DIR:$PATH" gct-listing "$1"; }

# Survivors that are not plain entries in the listing: the numeric
# directory's own content and the symlink's target outside the directory.
gct_untouched_extras() {
    [ -f "$GCT_TEMPROOTS/777/999" ] && [ ! -L "$GCT_TEMPROOTS/777/999" ] \
        && [ -f "$GCT_CASE/outside/target" ] && [ "$(cat "$GCT_CASE/outside/target")" = "outside content" ]
}

# gct_unit [runtime] -- calls the library function directly (in a subshell),
# capturing stdout/stderr/status into $GCT_CASE/{out,err} and $gct_rc.
gct_unit() {
    local runtime="${1:-apple}"
    gct_rc=0
    (
        PATH="$FAKE_DIR:$PATH"
        HOME="$GCT_CASE/home"
        DX_RUNTIME="$runtime"
        if [ "$runtime" = docker-ssh ]; then
            DX_REMOTE_HOST=dxe-fixture-nas.invalid
            DXE_RUNTIME_DOCKER_BIN=docker
            export DX_REMOTE_HOST DXE_RUNTIME_DOCKER_BIN
        fi
        export PATH HOME DX_RUNTIME
        dx_nix_gc_clear_stale_temproots "$GCT_CONTAINER"
    ) > "$GCT_CASE/out" 2> "$GCT_CASE/err" || gct_rc=$?
}

# gct_entry dx-gc|dx-reclaim -- runs the real entry point as a process.
gct_entry() {
    local entry="$1"
    mkdir -p "$GCT_CASE/home"
    gct_rc=0
    env PATH="$FAKE_DIR:/usr/bin:/bin" HOME="$GCT_CASE/home" \
        DX_RUNTIME=apple DX_CONTAINER_NAME="$GCT_CONTAINER" \
        DX_NIX_MOUNT=/nix DX_NIX_VOLUME=dxe-gct-nix DX_PERSIST_VOLUME=dxe-gct-persist \
        "$BASE_DIR/bin/$entry" > "$GCT_CASE/out" 2> "$GCT_CASE/err" || gct_rc=$?
}

gct_check() {
    local label="$1"
    shift
    if "$@"; then
        test_pass "$label"
    else
        test_fail "$label"
        echo "    status: $gct_rc"
        echo "    stdout: $(cat "$GCT_CASE/out" 2>/dev/null)"
        echo "    stderr: $(cat "$GCT_CASE/err" 2>/dev/null)"
        echo "    transcript: $(cat "$GCT_TRANSCRIPT" 2>/dev/null)"
        echo "    temproots now: $(gct_listing "$GCT_TEMPROOTS" | tr '\n' ' ')"
    fi
}

gct_out_is() { [ "$(cat "$GCT_CASE/out")" = "$1" ]; }
gct_err_empty() { [ ! -s "$GCT_CASE/err" ]; }
gct_out_empty() { [ ! -s "$GCT_CASE/out" ]; }
gct_err_has() { grep -F -- "$1" "$GCT_CASE/err" >/dev/null; }
gct_warning_line_has() {
    grep -F -- 'Warning: could not clear stale Nix temporary roots' "$GCT_CASE/err" | grep -F -- "$1" >/dev/null
}
gct_transcript_is() { [ "$(cat "$GCT_TRANSCRIPT")" = "$1" ]; }
gct_listing_is() { [ "$(gct_listing "$GCT_TEMPROOTS")" = "$1" ]; }
gct_gc_saw_is() { [ -f "$GCT_CASE/gc-saw-$1" ] && [ "$(cat "$GCT_CASE/gc-saw-$1")" = "$2" ]; }

# =============================================================================
# The library function, Apple runtime.
# =============================================================================

gct_new_case stale
gct_unit apple
gct_check "clear (apple): one exec, as dx, with the exact guest argv -u dx <name> bash -c <program> bash /nix/var/nix/temproots /proc" \
    gct_transcript_is "$GCT_CLEAR_RECORD"
gct_check "clear (apple): removes only the stale pid files (unreadable 110, readable 545/546); keeps live pids, dot-files, non-numeric names, the numeric directory and the numeric symlink" \
    gct_listing_is "$GCT_SURVIVORS"
gct_check "clear (apple): never recurses into a numeric directory and never touches a symlink's target outside the directory" \
    gct_untouched_extras
gct_check "clear (apple): reports the count on stdout, exactly one line" \
    gct_out_is "Cleared 3 stale Nix temporary roots file(s)."
gct_check "clear (apple): succeeds silently on stderr" \
    gct_err_empty
gct_check "clear (apple): returns 0 after clearing" \
    [ "$gct_rc" -eq 0 ]

gct_new_case clean
gct_unit apple
gct_check "clear (nothing stale): prints nothing at all and returns 0" \
    eval '[ "$gct_rc" -eq 0 ] && gct_out_empty && gct_err_empty'
gct_check "clear (nothing stale): every file survives, including the live unreadable one" \
    gct_listing_is "$GCT_SURVIVORS"
gct_check "clear (nothing stale): still exactly one guest call, as dx" \
    gct_transcript_is "$GCT_CLEAR_RECORD"

gct_new_case absent
gct_unit apple
gct_check "clear (no temproots directory): nothing to clear -- prints nothing, returns 0" \
    eval '[ "$gct_rc" -eq 0 ] && gct_out_empty && gct_err_empty'
gct_check "clear (no temproots directory): does not create it" \
    [ ! -e "$GCT_TEMPROOTS" ]

gct_new_case hidden-proc
gct_unit apple
gct_check "clear (process table not visible to dx): removes nothing" \
    gct_listing_is "$GCT_FULL_MIX"
gct_check "clear (process table not visible to dx): warns on stderr and returns 1, with no Cleared line" \
    eval '[ "$gct_rc" -eq 1 ] && gct_out_empty && gct_err_has "Warning: could not clear stale Nix temporary roots"'

gct_new_case stale
GCT_PROGRAM_MODE=fail
export GCT_PROGRAM_MODE
gct_unit apple
gct_check "clear (guest call fails with 125): warns with the exit status, returns 1, prints nothing on stdout" \
    eval '[ "$gct_rc" -eq 1 ] && gct_out_empty && gct_warning_line_has "(exit 125)"'

gct_new_case stale
GCT_PROGRAM_MODE=garbage
export GCT_PROGRAM_MODE
gct_unit apple
gct_check "clear (guest call succeeds but prints no lone count): warns, returns 1, prints nothing on stdout" \
    eval '[ "$gct_rc" -eq 1 ] && gct_out_empty && gct_err_has "Warning: could not clear stale Nix temporary roots"'
unset GCT_PROGRAM_MODE

# =============================================================================
# The library function, docker-ssh runtime: the same argv reaches
# `docker exec` on the far side of ssh, and PROGRAM survives the ssh quoting
# intact (it is run for real by the fake docker).
# =============================================================================

gct_new_case stale
gct_unit docker-ssh
gct_check "clear (docker-ssh): docker exec receives the same argv, as dx" \
    gct_transcript_is "$GCT_CLEAR_RECORD"
gct_check "clear (docker-ssh): the program survives ssh quoting and clears exactly the stale files" \
    eval 'gct_listing_is "$GCT_SURVIVORS" && gct_untouched_extras'
gct_check "clear (docker-ssh): reports the count and returns 0" \
    eval '[ "$gct_rc" -eq 0 ] && gct_out_is "Cleared 3 stale Nix temporary roots file(s)." && gct_err_empty'

# =============================================================================
# bin/dx-gc end to end.
# =============================================================================

gct_new_case stale
gct_entry dx-gc
gct_check "dx-gc: clears stale temp roots (as dx), hands root-owned paths back (as root), then collects and optimises (as dx) -- four exec calls in that order" \
    gct_transcript_is "$GCT_CLEAR_RECORD
$GCT_HANDBACK_RECORD
exec [-u] [dx] [$GCT_CONTAINER] [bash] [-lc] [nix-collect-garbage --delete-older-than 14d]
exec [-u] [dx] [$GCT_CONTAINER] [bash] [-lc] [nix-store --optimise]"
gct_check "dx-gc: by the time GC runs, the stale files (including the unreadable one) are already gone" \
    gct_gc_saw_is 1 "$GCT_SURVIVORS"
gct_check "dx-gc: output is the existing output plus one Cleared line after the GC header" \
    gct_out_is "Running Nix garbage collection in guest...
Cleared 3 stale Nix temporary roots file(s).
FAKE-GC nix-collect-garbage --delete-older-than 14d
Running Nix store optimization in guest...
FAKE-GC nix-store --optimise
Nix maintenance complete."
gct_check "dx-gc: exits 0 with nothing on stderr" \
    eval '[ "$gct_rc" -eq 0 ] && gct_err_empty'

gct_new_case clean
gct_entry dx-gc
gct_check "dx-gc (nothing stale): output is byte-for-byte the pre-fix output" \
    gct_out_is "Running Nix garbage collection in guest...
FAKE-GC nix-collect-garbage --delete-older-than 14d
Running Nix store optimization in guest...
FAKE-GC nix-store --optimise
Nix maintenance complete."
gct_check "dx-gc (nothing stale): the clear call still precedes GC" \
    gct_transcript_is "$GCT_CLEAR_RECORD
$GCT_HANDBACK_RECORD
exec [-u] [dx] [$GCT_CONTAINER] [bash] [-lc] [nix-collect-garbage --delete-older-than 14d]
exec [-u] [dx] [$GCT_CONTAINER] [bash] [-lc] [nix-store --optimise]"

gct_new_case stale
GCT_PROGRAM_MODE=fail
export GCT_PROGRAM_MODE
gct_entry dx-gc
unset GCT_PROGRAM_MODE
gct_check "dx-gc (clear fails): GC and optimisation still run, in order" \
    gct_transcript_is "$GCT_CLEAR_RECORD
$GCT_HANDBACK_RECORD
exec [-u] [dx] [$GCT_CONTAINER] [bash] [-lc] [nix-collect-garbage --delete-older-than 14d]
exec [-u] [dx] [$GCT_CONTAINER] [bash] [-lc] [nix-store --optimise]"
gct_check "dx-gc (clear fails): exits 0, warns on stderr, prints no Cleared line" \
    eval '[ "$gct_rc" -eq 0 ] && gct_warning_line_has "(exit 125)" && ! grep -F Cleared "$GCT_CASE/out" >/dev/null'

# =============================================================================
# bin/dx-reclaim end to end (Apple: reports, clear, hand-back, GC, trims, reports).
# =============================================================================

GCT_RECLAIM_TRANSCRIPT="exec [$GCT_CONTAINER] [/usr/bin/bash] [-lc] [<script>] [bash] [/nix] [/persist]
$GCT_CLEAR_RECORD
$GCT_HANDBACK_RECORD
exec [-u] [dx] [$GCT_CONTAINER] [/usr/bin/bash] [-lc] [nix-collect-garbage -d]
exec [$GCT_CONTAINER] [/usr/bin/bash] [-lc] [<script>] [bash] [/nix]
exec [$GCT_CONTAINER] [/usr/bin/bash] [-lc] [<script>] [bash] [/persist]
exec [$GCT_CONTAINER] [/usr/bin/bash] [-lc] [<script>] [bash] [/nix] [/persist]"

# The stdout segment from the GC header through the GC's own output.
gct_reclaim_gc_segment() {
    awk '/^Running Nix garbage collection in guest\.\.\.$/ { on = 1 } on { print } on && /^FAKE-GC / { exit }' "$GCT_CASE/out"
}
gct_reclaim_gc_segment_is() { [ "$(gct_reclaim_gc_segment)" = "$1" ]; }

gct_new_case stale
gct_entry dx-reclaim
gct_check "dx-reclaim: the clear call is followed only by the root-owned paths hand-back, then GC; every other guest call is unchanged" \
    gct_transcript_is "$GCT_RECLAIM_TRANSCRIPT"
gct_check "dx-reclaim: by the time GC runs, the stale files are already gone" \
    gct_gc_saw_is 1 "$GCT_SURVIVORS"
gct_check "dx-reclaim: the Cleared line follows the GC header's rule and precedes the GC output" \
    gct_reclaim_gc_segment_is "Running Nix garbage collection in guest...
$GCT_RULE
Cleared 3 stale Nix temporary roots file(s).
FAKE-GC nix-collect-garbage -d"
gct_check "dx-reclaim: completes and exits 0" \
    eval '[ "$gct_rc" -eq 0 ] && grep -Fx "Reclaim complete." "$GCT_CASE/out" >/dev/null'

gct_new_case clean
gct_entry dx-reclaim
gct_check "dx-reclaim (nothing stale): the GC segment is byte-for-byte the pre-fix output" \
    gct_reclaim_gc_segment_is "Running Nix garbage collection in guest...
$GCT_RULE
FAKE-GC nix-collect-garbage -d"

gct_new_case stale
GCT_PROGRAM_MODE=fail
export GCT_PROGRAM_MODE
gct_entry dx-reclaim
unset GCT_PROGRAM_MODE
gct_check "dx-reclaim (clear fails): GC, trims and the final report still run" \
    gct_transcript_is "$GCT_RECLAIM_TRANSCRIPT"
gct_check "dx-reclaim (clear fails): exits 0 and warns on stderr" \
    eval '[ "$gct_rc" -eq 0 ] && gct_warning_line_has "(exit 125)" && grep -Fx "Reclaim complete." "$GCT_CASE/out" >/dev/null'

print_summary
exit_with_code
