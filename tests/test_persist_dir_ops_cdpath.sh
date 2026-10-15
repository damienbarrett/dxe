#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP4.2b acceptance: the NAS directory operations ignore CDPATH.
#
# Interface contract (pinned by this file; extends tests/test_persist_dir_ops.sh):
#
#   The four constant NAS scripts behind dx_runtime_host_dir_{probe,create,
#   marker_write,usage} must behave identically whatever CDPATH the NAS shell
#   inherits. ROOT and PATH may be relative (the NAS shell resolves them from
#   its cwd), and a relative `cd` operand such as "share" or
#   "share/dxe/<guest>/persist" would otherwise be searched through CDPATH
#   first (landing in the wrong directory, and printing the new directory on
#   stdout).
#   With CDPATH exported to a decoy directory that holds a matching tree:
#     - probe reports the REAL fixture's state and marker, with exactly the
#       pinned stdout (no stray path line);
#     - create makes the leaf and the marker in the REAL root, prints nothing
#       on stdout and returns 0;
#     - marker_write replaces the REAL marker, prints nothing on stdout;
#     - usage prints exactly what `du -sk -- PATH` prints for the real PATH;
#     - the decoy tree and every file byte in it are unchanged by every op.
#   Accepted fix shapes (either satisfies this file): every script begins with
#   `unset CDPATH;`, or every relative cd operand is made "./"-prefixed. The
#   behaviour is what is pinned; the scripts stay constant, single-line POSIX
#   sh programs reading their data from "$@".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-persist-dir.sh"

test_section "WP4.2b: NAS directory operations ignore CDPATH"

SCRATCH="$(persist_fixture_root_create)" || exit 1
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac

unset DX_PERSIST_HOST_MOUNT_SENTINEL CDPATH
NL='
'
MARKER_NAME=".dxe-persist-dir"
GUEST="dx-fix"
MARKER_OLD="$(dx_persist_marker_format "$GUEST" ready "" 2026-10-11T08:00:00Z)"
MARKER_NEW="$(dx_persist_marker_format "$GUEST" retired "" 2026-10-11T08:00:00Z "" 2026-10-12T09:30:00Z)"
MARKER_DECOY="$(dx_persist_marker_format "$GUEST" ready "" 2020-01-01T00:00:00Z)"

eq() { # LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (expected [$2], got [$3])"; fi
}
file_eq() { # LABEL FILE EXPECTED-TEXT
    local want="$SCRATCH/.want"
    printf '%s' "$3" >"$want"
    if cmp -s "$want" "$2"; then test_pass "$1"; else test_fail "$1 (got: $(cat "$2" 2>/dev/null))"; fi
}
physical() { (cd -P -- "$1" && pwd -P); }
# snap DIR: every path under DIR plus a checksum of every regular file.
snap() { (cd "$1" && { find . | LC_ALL=C sort; find . -type f -exec cksum {} + | LC_ALL=C sort; }); }

# NAS fake: cwd is the fixture root, remote commands run for real. The fixture
# root is a fresh directory inside this run's scratch; the decoys likewise.

# Each case builds <fixture root>/share and a decoy directory D with the
# matching D/share/dxe/<guest>/persist tree; the ops address "share" relatively.
new_root() { persist_fixture_root_create "$SCRATCH" || return 1; }

HAVE_DASH=0
command -v dash >/dev/null 2>&1 && HAVE_DASH=1
SHELL_MODES="sh"
DASH_SHIM="$SCRATCH/dash-shim-bin"
DASH_LOG="$SCRATCH/dash-shim.log"
if [ "$HAVE_DASH" = 1 ]; then
    SHELL_MODES="sh dash"
    fake_tool_write "$DASH_SHIM" sh "$(printf 'printf "dash\\n" >> %q\nexec %q "$@"' "$DASH_LOG" "$(command -v dash)")"
fi
in_shell() {
    local mode="$1"
    shift
    : >"$DASH_LOG"
    if [ "$mode" = dash ]; then PATH="$DASH_SHIM:$PATH" "$@"; else "$@"; fi
}
ran_under() { # LABEL MODE
    if [ "$2" = dash ]; then
        if [ -s "$DASH_LOG" ]; then test_pass "$1: the NAS shell was dash"; else test_fail "$1: the NAS shell was dash"; fi
    fi
}

# nas_in ROOT DECOY CMD...: run a runtime op against the NAS fake whose cwd is
# ROOT, with CDPATH exported to DECOY.
nas_in() {
    local root="$1" decoy="$2" tools
    shift 2
    tools="$(persist_fixture_nas_create "$root" "$SCRATCH")" || return 1
    (
        export DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$PERSIST_FIXTURE_NAS_HOST"
        CDPATH="$decoy"
        export CDPATH
        PATH="$tools:$PATH"
        export PATH
        "$@" </dev/null
    )
}

# decoy_build DIR [with-leaf]: DIR/share/dxe/<guest>[/persist + marker]
decoy_build() {
    local d="$1" leaf="${2:-leaf}"
    mkdir -p "$d/share/dxe/$GUEST"
    if [ "$leaf" = leaf ]; then
        mkdir "$d/share/dxe/$GUEST/persist"
        printf '%s\n' "$MARKER_DECOY" >"$d/share/dxe/$GUEST/persist/$MARKER_NAME"
        printf 'decoy payload\n' >"$d/share/dxe/$GUEST/persist/decoy.txt"
    fi
}
# real_build ROOT: ROOT/share/dxe/<guest>/persist with the old marker and data
real_build() {
    mkdir -p "$1/share/dxe/$GUEST/persist"
    printf '%s\n' "$MARKER_OLD" >"$1/share/dxe/$GUEST/persist/$MARKER_NAME"
    head -c 65536 /dev/zero >"$1/share/dxe/$GUEST/persist/blob.bin"
}

for mode in $SHELL_MODES; do
    test_section "WP4.2b: probe with CDPATH set [$mode]"
    root="$(new_root)" || exit 1; decoy="$(new_root)" || exit 1
    real_build "$root"; decoy_build "$decoy"
    before="$(snap "$decoy")"
    canon="$(physical "$root/share")"
    out="$(in_shell "$mode" nas_in "$root" "$decoy" dx_runtime_host_dir_probe share "$GUEST" 2>"$SCRATCH/err")"
    rc=$?
    eq "probe: status 0" "0" "$rc"
    eq "probe: reports the real root, state and marker, no stray path line" \
        "root=$canon${NL}mounted=unknown${NL}state=nonempty${NL}marker=present${NL}$MARKER_OLD" "$out"
    eq "probe: the decoy is untouched" "$before" "$(snap "$decoy")"
    ran_under "probe" "$mode"

    test_section "WP4.2b: create with CDPATH set [$mode]"
    for shape in leaf noleaf; do
        root="$(new_root)" || exit 1; decoy="$(new_root)" || exit 1
        mkdir "$root/share"; decoy_build "$decoy" "$shape"
        before="$(snap "$decoy")"
        out="$(in_shell "$mode" nas_in "$root" "$decoy" dx_runtime_host_dir_create share "$GUEST" "$MARKER_NEW" 2>"$SCRATCH/err")"
        rc=$?
        eq "create (decoy $shape): status 0" "0" "$rc"
        eq "create (decoy $shape): nothing on stdout" "" "$out"
        file_eq "create (decoy $shape): the marker landed in the real leaf" \
            "$root/share/dxe/$GUEST/persist/$MARKER_NAME" "$MARKER_NEW$NL"
        eq "create (decoy $shape): the real tree holds exactly the new levels" \
            ".${NL}./share${NL}./share/dxe${NL}./share/dxe/$GUEST${NL}./share/dxe/$GUEST/persist${NL}./share/dxe/$GUEST/persist/$MARKER_NAME" \
            "$(cd "$root" && find . | LC_ALL=C sort)"
        eq "create (decoy $shape): the decoy is untouched" "$before" "$(snap "$decoy")"
        ran_under "create ($shape)" "$mode"
    done

    test_section "WP4.2b: marker_write with CDPATH set [$mode]"
    root="$(new_root)" || exit 1; decoy="$(new_root)" || exit 1
    real_build "$root"; decoy_build "$decoy"
    before="$(snap "$decoy")"
    out="$(in_shell "$mode" nas_in "$root" "$decoy" dx_runtime_host_dir_marker_write "share/dxe/$GUEST/persist" "$MARKER_NEW" 2>"$SCRATCH/err")"
    rc=$?
    eq "marker_write: status 0" "0" "$rc"
    eq "marker_write: nothing on stdout" "" "$out"
    file_eq "marker_write: the real marker was replaced" \
        "$root/share/dxe/$GUEST/persist/$MARKER_NAME" "$MARKER_NEW$NL"
    eq "marker_write: no temp file left in the real directory" \
        "$MARKER_NAME${NL}blob.bin" "$(ls -A "$root/share/dxe/$GUEST/persist" | LC_ALL=C sort)"
    eq "marker_write: the decoy is untouched" "$before" "$(snap "$decoy")"
    ran_under "marker_write" "$mode"

    test_section "WP4.2b: usage with CDPATH set [$mode]"
    root="$(new_root)" || exit 1; decoy="$(new_root)" || exit 1
    real_build "$root"; decoy_build "$decoy"
    before="$(snap "$decoy")"
    want="$(cd "$root" && du -sk -- "share/dxe/$GUEST/persist")"
    out="$(in_shell "$mode" nas_in "$root" "$decoy" dx_runtime_host_dir_usage "share/dxe/$GUEST/persist" 2>"$SCRATCH/err")"
    rc=$?
    eq "usage: status 0" "0" "$rc"
    eq "usage: exactly the du line of the real directory" "$want" "$out"
    eq "usage: the decoy is untouched" "$before" "$(snap "$decoy")"
    ran_under "usage" "$mode"
done

print_summary
exit_with_code
