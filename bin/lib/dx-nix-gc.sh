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

# dx_nix_gc_guest_count USER CONTAINER WHAT PROGRAM ARG...
#
# Runs one guest program with exactly one runtime call,
#   dx_runtime_exec -u USER CONTAINER bash -c PROGRAM bash ARG...
# and prints the lone decimal count it reported on stdout. A call that exits
# non-zero, or that does not print a lone count, prints one
#   Warning: could not WHAT (exit N|the guest reported no count); garbage collection runs anyway.
# line on stderr and returns 1.
dx_nix_gc_guest_count() {
    local user="$1" container="$2" what="$3" program="$4" output status=0
    shift 4
    output="$(dx_runtime_exec -u "$user" "$container" bash -c "$program" bash "$@")" || status=$?
    if [ "$status" -ne 0 ]; then
        echo "Warning: could not $what (exit $status); garbage collection runs anyway." >&2
        return 1
    fi
    case "$output" in
        '' | *[!0-9]*)
            echo "Warning: could not $what (the guest reported no count); garbage collection runs anyway." >&2
            return 1
            ;;
    esac
    printf '%s\n' "$output"
}

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
    local count
    count="$(dx_nix_gc_guest_count dx "$1" "clear stale Nix temporary roots files" "$dx_nix_gc_clear_temproots_program" /nix/var/nix/temproots /proc)" || return 1
    if [ "$count" != 0 ]; then
        echo "Cleared $count stale Nix temporary roots file(s)."
    fi
    return 0
}

# Root-owned store paths (fix/gc-rootpaths). Nix must make a store directory
# writable before it can empty it, and dx cannot chmod a root-owned one, so a
# single root-owned garbage directory aborts dx's whole collection
#   error: fchmodat2 "/nix/store/...-profile": Operation not permitted
# Every path a root Nix call adds to dx's store is root-owned (Nix
# canonicalises a new path to the calling user): the bootstrap's essentials
# install and upgrade, a root shell from dx-enter, any future root Nix call.
# The same calls leave root-owned log buckets under /nix/var/log/nix, which
# stop dx's builds ("creating log file ...: Permission denied"). GC as root is
# not the answer (a root nix re-owns the store's state); chown is not Nix.
#
# The guest side of dx_nix_gc_hand_back_root_paths, run AS ROOT as
#   bash -c PROGRAM bash STORE LOG
# ($1 = /nix/store, $2 = /nix/var/log/nix). The bootstrap's own
# hand_back_root_nix_paths (container/dx-nixos-26.05/bootstrap/common.sh)
# applies exactly the same rule after each root Nix call. Rules:
#   - Nothing at all when STORE is missing, is a symlink or is owned by uid 0
#     (the image's own store, or a volume before its one-time ownership
#     migration: there is no one to hand back to); the count is 0.
#   - Otherwise OWNER is STORE's own numeric uid:gid. Every DIRECT entry of
#     STORE owned by uid 0 (dot-entries included) goes to OWNER with
#     `chown -R -P`: everything inside it too, a symlink re-owned itself and
#     never followed. Only a root-owned top-level entry stops dx's GC (a root
#     inode inside a dx path is harmless), so no non-root entry is ever
#     looked into: no full-store walk.
#   - When LOG is a real directory (not a symlink), every entry beneath it
#     owned by uid 0 goes to OWNER with `chown -h` (a symlink itself).
#   - chown changes no mode and no mtime; nothing else is touched (STORE and
#     LOG themselves, /nix/var/nix, anything outside the two trees).
#   - stdout is exactly one line, the count handed back (one per root-owned
#     direct store entry, one per root-owned log entry); a chown that fails
#     is not counted and makes it exit 1 after it has tried every other
#     entry. stat, find or chown missing: exit 127 before changing anything,
#     never a silent "nothing to hand back".
#   - `bash -c` is not a login shell, so the GC-rooted root essentials
#     profile and the image's default profile are APPENDED to the exec's PATH
#     as fallbacks (find comes from the default profile): the exec's own PATH
#     stays first and decides which tool runs. An empty exec PATH gets no
#     empty element (one would mean the current directory).
# Residual: a root Nix process running at this very moment re-owns its own
# new output to root when it finishes; GC then fails as before until the
# next hand-back.
#
# A heredoc constant, like the temp-roots program above (kcov never traces a
# heredoc body).
IFS= read -r -d '' dx_nix_gc_hand_back_root_paths_program <<'DX_NIX_GC_HAND_BACK_ROOT_PATHS' || true
PATH="${PATH:+$PATH:}/nix/var/nix/profiles/per-user/root/profile/bin:/nix/var/nix/profiles/default/bin"
store=$1
log=$2
if [ -L "$store" ] || [ ! -d "$store" ]; then
    printf '0\n'
    exit 0
fi
for tool in stat find chown; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool not found; not handing root-owned Nix paths back" >&2
        exit 127
    fi
done
owner=$(stat -c '%u:%g' -- "$store") || exit 1
if [ "${owner%%:*}" = 0 ]; then
    printf '0\n'
    exit 0
fi
handed=0
status=0
while IFS= read -r -d '' path; do
    if chown -R -P -- "$owner" "$path"; then
        handed=$((handed + 1))
    else
        status=1
    fi
done < <(find "$store" -mindepth 1 -maxdepth 1 -uid 0 -print0)
if [ -d "$log" ] && [ ! -L "$log" ]; then
    while IFS= read -r -d '' path; do
        if chown -h -- "$owner" "$path"; then
            handed=$((handed + 1))
        else
            status=1
        fi
    done < <(find "$log" -mindepth 1 -uid 0 -print0)
fi
printf '%s\n' "$handed"
exit "$status"
DX_NIX_GC_HAND_BACK_ROOT_PATHS

# dx_nix_gc_hand_back_root_paths CONTAINER
#
# Hands root-owned store and log paths back to the store's owner before a GC,
# with exactly one runtime call, as root. Prints
# "Handed N root-owned Nix path(s) back to the store owner." when N > 0 and
# nothing at all when N = 0, and returns 0. A failed hand-back -- the call
# exits non-zero, or does not print a lone count -- prints one warning on
# stderr and returns 1; callers carry on with the GC regardless (it then
# fails exactly as it would have without the hand-back).
dx_nix_gc_hand_back_root_paths() {
    local count
    count="$(dx_nix_gc_guest_count root "$1" "hand root-owned Nix paths back to the store owner" "$dx_nix_gc_hand_back_root_paths_program" /nix/store /nix/var/log/nix)" || return 1
    if [ "$count" != 0 ]; then
        echo "Handed $count root-owned Nix path(s) back to the store owner."
    fi
    return 0
}

# dx_nix_gc_prepare CONTAINER
#
# What bin/dx-gc and bin/dx-reclaim run immediately before their GC command:
# the stale temp-roots clear (as dx), then the root-owned paths hand-back (as
# root). Each is best effort -- a failure warns and the next step and the GC
# still run -- so this always returns 0.
dx_nix_gc_prepare() {
    dx_nix_gc_clear_stale_temproots "$1" || true
    dx_nix_gc_hand_back_root_paths "$1" || true
}
