#!/bin/bash
# Guest Nix garbage-collection helpers for bin/dx-gc and bin/dx-reclaim
# (fix/gc-temproots). Safe to source: functions and constants only, nothing
# runs at import time; Bash 3.2. Relies on dx_runtime_exec
# (bin/lib/dx-runtime.sh) being loaded by the caller.
#
# Why: both entry points run Nix GC in the guest as dx (the store is
# single-user and dx-owned). Nix's collector opens EVERY file in
# /nix/var/nix/temproots to lock-test it, and one it cannot open aborts the
# whole collection ("opening temporary roots file ...: Permission denied").
# A root Nix process -- the bootstrap's essentials install -- leaves exactly
# such a file behind: root:root 0600, named after its own pid, because Nix
# 2.34's flake-building commands do not unlink it on exit. dx owns the
# directory, so dx can unlink a stale one without root.

# The guest side of dx_nix_gc_clear_stale_temproots, run as
#   bash -c PROGRAM bash TEMPROOTS_DIR PROC_ROOT
# ($1 = /nix/var/nix/temproots, $2 = /proc). One program rather than
# list-then-delete round trips, so each pid check and its unlink happen
# microseconds apart in the guest. Rules:
#   - If "$2/1" is not a directory, dx cannot see the process table (e.g.
#     hidepid) and liveness cannot be judged: remove nothing, exit non-zero.
#   - Only DIRECT entries of "$1" whose name is all decimal digits and that
#     are regular files (not symlinks, not directories -- never recursed
#     into) are candidates. Such a file is stale, and is unlinked, exactly
#     when "$2/<name>" does not exist; a live pid's file is never touched.
#     Readability is irrelevant: unlinking needs only write access to the
#     dx-owned directory. Nix itself decides staleness by taking a lock on
#     the file, which needs an open descriptor -- impossible for dx on the
#     root-only files that are the whole problem -- so this uses pid
#     liveness, which /proc answers without root.
#   - A missing directory is nothing to clear. `rm -f` never prompts on an
#     unwritable file and, without -r, cannot remove a directory that
#     replaced a file after the check.
#   - stdout is exactly one line, the count actually removed; an unlink
#     that fails is not counted and makes the program exit 1 after it has
#     tried every other candidate.
#   - `bash -c` is not a login shell (the host parses stdout, and a login
#     profile can print), so the exec's bare PATH is extended with the
#     GC-rooted root essentials profile, as bin/dx-reclaim's guest programs
#     do, for `rm`. Everything else is a bash builtin.
# Residuals: a stale file whose pid now belongs to an unrelated live process
# is kept (the safe direction: GC then fails as it did before this clear);
# a new process assigned exactly a dead pid that creates its temp-roots file
# between the /proc check and the unlink would lose it (one unlink wide).
#
# A heredoc rather than a multi-line quoted argument: kcov never traces a
# heredoc body, so the call below stays one instrumentable statement (see
# bin/lib/dx-bootstrap-sync.sh). `IFS= read -r -d ''` keeps the text
# byte-for-byte and returns 1 at EOF, hence `|| true`.
IFS= read -r -d '' dx_nix_gc_clear_temproots_program <<'DX_NIX_GC_CLEAR_TEMPROOTS' || true
PATH="/nix/var/nix/profiles/per-user/root/profile/bin:$PATH"
temproots=$1
proc=$2
if [ ! -d "$proc/1" ]; then
    echo "cannot see the process table ($proc/1 is not visible); not judging which temporary roots are stale" >&2
    exit 3
fi
removed=0
status=0
for path in "$temproots"/*; do
    name=${path##*/}
    case $name in
        ''|*[!0-9]*) continue ;;
    esac
    if [ -L "$path" ] || [ ! -f "$path" ] || [ -e "$proc/$name" ]; then
        continue
    fi
    if rm -f -- "$path"; then
        removed=$((removed + 1))
    else
        status=1
    fi
done
printf '%s\n' "$removed"
exit "$status"
DX_NIX_GC_CLEAR_TEMPROOTS

# dx_nix_gc_clear_stale_temproots CONTAINER
#
# Removes stale Nix temporary-roots files in the guest before a GC, with
# exactly one runtime call, as dx (never root). Prints
# "Cleared N stale Nix temporary roots file(s)." when N > 0 and nothing at
# all when N = 0, and returns 0. A failed clear -- the call exits non-zero,
# or does not print a lone count -- prints one warning on stderr and
# returns 1; callers carry on with the GC regardless (Nix stays the
# authority, so a failed clear is never worse than no clear).
dx_nix_gc_clear_stale_temproots() {
    local container="$1" output status=0
    output="$(dx_runtime_exec -u dx "$container" bash -c "$dx_nix_gc_clear_temproots_program" bash /nix/var/nix/temproots /proc)" || status=$?
    if [ "$status" -ne 0 ]; then
        echo "Warning: could not clear stale Nix temporary roots files (exit $status); garbage collection runs anyway." >&2
        return 1
    fi
    case "$output" in
        '' | *[!0-9]*)
            echo "Warning: could not clear stale Nix temporary roots files (the guest reported no count); garbage collection runs anyway." >&2
            return 1
            ;;
    esac
    if [ "$output" != 0 ]; then
        echo "Cleared $output stale Nix temporary roots file(s)."
    fi
    return 0
}
