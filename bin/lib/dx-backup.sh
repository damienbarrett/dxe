#!/bin/bash
# Host-side orchestration for the /persist backup and restore (Branch 10,
# plan.md B1): manifest bookkeeping, the diff against a fresh guest listing,
# the single incremental tar transfer, and restore's conflict check and push.
# Safe to source; performs no I/O merely by being sourced.
#
# The selection RULES themselves (what is at-risk, the deny-list, hashing)
# live in the guest selector, shipped through the bootstrap volume:
# container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib/dx-persist-backup-select.sh
# (see that file's header for why). This library sources it directly by path
# -- both live in the same repository checkout on the host -- to reuse its
# hashing/stat primitives for hashing the LOCAL mirror during restore's
# conflict check, rather than duplicating that logic.
#
# Every path list this file passes between functions is one path per LINE
# (never word-split), so a path containing spaces is handled correctly; only
# a literal newline inside a path is unsupported, consistent with the guest
# selector's own documented limitation.

DX_BACKUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DX_BACKUP_PROJECT_ROOT="$(cd "$DX_BACKUP_LIB_DIR/../.." && pwd)"
DX_BACKUP_SELECTOR_SOURCE="$DX_BACKUP_PROJECT_ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib/dx-persist-backup-select.sh"
# shellcheck source=../../container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib/dx-persist-backup-select.sh
source "$DX_BACKUP_SELECTOR_SOURCE"

# The path under /persist every real run targets. Not user-configurable (see
# plan.md B1 / checkout-consolidation-plan.md Q5): this backup exists
# specifically to protect /persist.
DX_BACKUP_GUEST_ROOT=/persist

# The actual per-container mirror directory: DX_BACKUP_DIR (a registered
# bin/lib/dx-config.sh field, default $HOME/Backups/dxe-persist, resolved by
# dx-lib.sh's dx_init_config before this is ever called -- like every other
# config-registry variable, this trusts that has already run) names only the
# BASE directory. /$DX_CONTAINER_NAME is always appended here, even when
# DX_BACKUP_DIR is overridden, so dx-host and dx-test can never share a
# mirror by accident.
dx_backup_resolve_dir() {
    printf '%s/%s\n' "${DX_BACKUP_DIR:?}" "${DX_CONTAINER_NAME:?}"
}

# The selector script's path as it appears INSIDE the guest (or, in tests,
# wherever DX_BOOTSTRAP_PATH's "current" is arranged to point) -- see this
# repository's dx-sync-bootstrap / dx-ai.sh for the same "current" convention.
dx_backup_selector_path() {
    printf '%s/current/scripts/lib/dx-persist-backup-select.sh\n' "${DX_BOOTSTRAP_PATH%/}"
}

# Resolve which exclude file (if any) to read (Branch 18): an explicit
# DX_BACKUP_EXCLUDE_FILE always wins (including its "must exist" error,
# still enforced by dx_backup_read_exclude_patterns, unchanged). Otherwise,
# if a file exists at the default location
# ${XDG_CONFIG_HOME:-$HOME/.config}/dxe/dx-backup-exclude, that one is used
# instead -- silently, since it is optional (unlike a nonexistent EXPLICIT
# override, which is still an error). Prints the resolved path, or nothing
# if there is none to read.
dx_backup_resolve_exclude_file() {
    if [ -n "${DX_BACKUP_EXCLUDE_FILE:-}" ]; then
        printf '%s\n' "$DX_BACKUP_EXCLUDE_FILE"
        return 0
    fi
    local default_file="${XDG_CONFIG_HOME:-$HOME/.config}/dxe/dx-backup-exclude"
    [ -f "$default_file" ] && printf '%s\n' "$default_file"
    return 0
}

# Read DX_BACKUP_EXCLUDE_FILE-style extra deny patterns: one per line, blank
# lines and full-line '#' comments skipped. Prints one pattern per line.
dx_backup_read_exclude_patterns() {
    local file="$1" line
    [ -n "$file" ] || return 0
    [ -f "$file" ] || { echo "Error: DX_BACKUP_EXCLUDE_FILE $file does not exist." >&2; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        printf '%s\n' "$line"; done < "$file"
}

# Run the guest selector over the container boundary and print its listing
# (unsorted) on stdout. Its own stderr (warnings, the skipped-special-files
# summary) passes straight through to our caller's stderr.
dx_backup_fetch_listing() {
    local container_name="$1"
    shift
    dx_runtime_exec -u dx "$container_name" "$(dx_backup_selector_path)" "$DX_BACKUP_GUEST_ROOT" "$@"
}

# Same as dx_backup_fetch_listing, but every line carries a 5th <TAB>reason
# column (modified-untracked, whole-repo, outside-repo, ignored-kept -- see
# the selector's own --with-reason comment). Used by
# `bin/dx-backup --dry-run --summary` (Branch 17): reviewing the at-risk
# selection's SIZE, not just transferring it, so the coordinating session
# and the user can decide deny-list additions (found live on dx-host: a
# first dry-run selected 51,262 files / 3.2 GB of a 6.3 GB /persist, which
# looked too large for "not reproducible elsewhere").
dx_backup_fetch_listing_with_reason() {
    local container_name="$1"
    shift
    dx_runtime_exec -u dx "$container_name" "$(dx_backup_selector_path)" --with-reason "$DX_BACKUP_GUEST_ROOT" "$@"
}

# Print the `--dry-run --summary` breakdown of a --with-reason listing file
# ($1): total files/bytes, then a breakdown by /persist's top-level
# directory (the listing's path column, first "/"-separated component), then
# a breakdown by selection reason. Pure host-side arithmetic (awk) over the
# guest selector's own output -- no selection rule is re-derived here.
dx_backup_summarize() {
    local listing="$1" total_count total_bytes
    total_count="$(wc -l < "$listing" | tr -d '[:space:]')"
    total_bytes="$(awk -F'\t' '{sum += $2} END {print sum + 0}' "$listing")"
    echo "Total at-risk under $DX_BACKUP_GUEST_ROOT: ${total_count:-0} files, ${total_bytes:-0} bytes."

    # Single line: this codebase's convention for a multi-statement quoted
    # awk/sh body (see bin/dx-put and dx_backup_restore_push above) -- a
    # multi-line quoted argument only registers a kcov coverage hit on its
    # first line, not each interior line.
    echo "By top-level directory:"
    awk -F'\t' '{ n = split($1, parts, "/"); top = (n > 1) ? parts[1] : $1; count[top]++; bytes[top] += $2 } END { for (t in count) printf "%s\t%d\t%d\n", t, count[t], bytes[t] }' "$listing" | LC_ALL=C sort | while IFS="$(printf '\t')" read -r top top_count top_bytes; do
        [ -n "$top" ] || continue
        printf '  %-30s %8s files  %14s bytes\n' "$top" "$top_count" "$top_bytes"
    done

    echo "By reason:"
    awk -F'\t' '{ count[$5]++; bytes[$5] += $2 } END { for (r in count) printf "%s\t%d\t%d\n", r, count[r], bytes[r] }' "$listing" | LC_ALL=C sort | while IFS="$(printf '\t')" read -r reason reason_count reason_bytes; do
        [ -n "$reason" ] || continue
        printf '  %-20s %8s files  %14s bytes\n' "$reason" "$reason_count" "$reason_bytes"
    done
}

# Diff a (possibly absent) old manifest against a fresh guest listing.
# Writes full TSV lines that are new or changed to $3, and bare paths that
# existed in the old manifest but not at all in the new listing to $4. Both
# inputs need not be pre-sorted; this sorts its own working copies.
dx_backup_diff() {
    local old_manifest="$1" new_listing="$2" fetch_out="$3" remove_out="$4"
    local old_sorted new_sorted old_paths new_paths
    old_sorted="$(mktemp "${TMPDIR:-/tmp}/dxe-backup-old.XXXXXX")"
    new_sorted="$(mktemp "${TMPDIR:-/tmp}/dxe-backup-new.XXXXXX")"
    old_paths="$(mktemp "${TMPDIR:-/tmp}/dxe-backup-old-paths.XXXXXX")"
    new_paths="$(mktemp "${TMPDIR:-/tmp}/dxe-backup-new-paths.XXXXXX")"
    if [ -f "$old_manifest" ]; then LC_ALL=C sort "$old_manifest" > "$old_sorted"; else : > "$old_sorted"; fi
    LC_ALL=C sort "$new_listing" > "$new_sorted"
    cut -f1 "$old_sorted" | LC_ALL=C sort > "$old_paths"
    cut -f1 "$new_sorted" | LC_ALL=C sort > "$new_paths"

    comm -13 "$old_sorted" "$new_sorted" > "$fetch_out"
    comm -23 "$old_paths" "$new_paths" > "$remove_out"

    rm -f "$old_sorted" "$new_sorted" "$old_paths" "$new_paths"
}

# Sum of the size column (2nd field) across every line of a TSV listing file.
dx_backup_sum_sizes() {
    awk -F'\t' '{sum += $2} END {print sum + 0}' "$1"
}

# ---------------------------------------------------------------------------
# Branch 17 (fix/dx-backup-transfer-stall): shipping a name list into the
# guest, unidirectionally
#
# `dx_backup_fetch_paths` originally pushed a large NUL-separated name list
# through one `-i` exec's stdin while streaming the archive back
# through that SAME exec's stdout -- live-verified on `dx-host` to deadlock
# on a large selection (51,262 files / 3.2 GB): the guest `tar` sat with no
# output, the host extractor had received 0 bytes, the same code having
# already passed Branch 10's live gate with a 240-file fixture. Whether that
# is Apple `container exec`'s bidirectional-pipe plumbing deadlocking, or
# stdin EOF never being delivered when the list is large, is not
# characterised further here (out of scope) -- every exec below is made
# unidirectional BY CONSTRUCTION instead: stdin-only (a regular file, never
# a pipe, so EOF is exactly "the file ended") or stdout-only (stdin
# explicitly /dev/null), never both live on the same exec.
#
# These two helpers implement that shape once, shared by
# dx_backup_fetch_paths (below) and dx_backup_restore_status's large-batch
# path: ship a host list file into a guest temp file via a single
# stdin-redirected `-i` exec (exactly bin/dx-put's file-push shape: run
# `sh -c 'cat > "$1"' -- DEST < SOURCE` through the runtime `-i` exec), then
# have the caller point a stdin-closed, non-`-i` exec at that same guest path.
# ---------------------------------------------------------------------------

# Copy host file $2 into a fresh guest temp file under /tmp and print that
# guest path on success. The guest path's random suffix comes from the
# HOST's own `mktemp -u` (no extra guest round trip to generate one, and
# `-u` never touches the host filesystem either -- it only prints a name).
dx_backup_ship_list_to_guest() {
    local container_name="$1" host_list="$2" guest_list
    guest_list="/tmp/dxe-backup-list.$(basename "$(mktemp -u "${TMPDIR:-/tmp}/XXXXXXXXXX")")"
    dx_runtime_exec -i -u dx "$container_name" sh -c 'cat > "$1"' -- "$guest_list" < "$host_list" || return 1
    printf '%s\n' "$guest_list"
}

# Best-effort removal of a guest temp file created by
# dx_backup_ship_list_to_guest. Never fails the caller: this is cleanup, not
# core logic, and running it after a prior step already failed must not
# mask that failure's exit status.
dx_backup_remove_guest_list() {
    local container_name="$1" guest_list="$2"
    dx_runtime_exec -u dx "$container_name" rm -f "$guest_list" >/dev/null 2>&1 || true
}

# One incremental tar transfer: everything named (one TSV line per file) in
# $3, read from $DX_BACKUP_GUEST_ROOT in the guest, landing in $2/current/.
#
# Two unidirectional execs (Branch 17; see this file's module comment
# above), never one bidirectional one:
#   1. Ship the NUL-separated name list into a guest temp file (stdin-only).
#   2. Archive it with `-T <guest temp file>` and stdin explicitly /dev/null
#      (stdout-only) -- the same shape dx-get already uses for a plain
#      guest-to-host tar stream, just with the file list coming from a
#      guest FILE instead of positional `tar` arguments.
# The guest temp file is removed afterward whether phase 2 succeeds or
# fails: both branches of the outer `if` set `rc` without letting `set -e`
# (active in every caller: bin/dx-backup, bin/dx-restore) abort the
# function before cleanup runs.
dx_backup_fetch_paths() {
    local container_name="$1" backup_dir="$2" fetch_lines="$3" count
    count="$(wc -l < "$fetch_lines" | tr -d '[:space:]')"
    [ "${count:-0}" -gt 0 ] || return 0
    mkdir -p "$backup_dir/current"

    local host_list guest_list rc=0
    host_list="$(mktemp "${TMPDIR:-/tmp}/dxe-backup-fetch-list.XXXXXX")" || return 1
    cut -f1 "$fetch_lines" | tr '\n' '\0' > "$host_list"

    if guest_list="$(dx_backup_ship_list_to_guest "$container_name" "$host_list")"; then
        if dx_runtime_exec -u dx "$container_name" tar -C "$DX_BACKUP_GUEST_ROOT" --exclude '._*' --null -T "$guest_list" -cf - </dev/null \
            | tar -xf - -C "$backup_dir/current"; then
            rc=0
        else
            rc=$?
        fi
        dx_backup_remove_guest_list "$container_name" "$guest_list"
    else
        rc=1
    fi

    rm -f "$host_list"
    return "$rc"
}

# Delete every path in $2 (one per line, relative to current/) from the
# mirror at $1/current/, then prune any directory left empty by that removal.
dx_backup_remove_paths() {
    local backup_dir="$1" remove_paths="$2" path
    [ -s "$remove_paths" ] || return 0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        rm -f -- "$backup_dir/current/$path"; done < "$remove_paths"
    # -mindepth 1 excludes current/ itself: it must survive even when the
    # mirror ends up holding nothing (the next backup still needs it to
    # exist, and dx-restore treats its absence as "no backup taken yet").
    find "$backup_dir/current" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

dx_backup_write_manifest_atomic() {
    local manifest="$1" content_file="$2" tmp
    tmp="$(mktemp "$(dirname "$manifest")/.manifest.XXXXXX")" || return 1
    LC_ALL=C sort "$content_file" > "$tmp"
    mv -f "$tmp" "$manifest"
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

# Validate a user-supplied restore PATH argument: relative, no `.` / `..`
# components, no leading slash.
dx_backup_restore_path_safe() {
    local path="$1" remainder component
    case "$path" in
        ''|/*) return 1 ;;
    esac
    remainder="$path"
    while [ -n "$remainder" ]; do
        case "$remainder" in
            */*) component="${remainder%%/*}"; remainder="${remainder#*/}" ;;
            *) component="$remainder"; remainder="" ;;
        esac
        case "$component" in
            ''|.|..) return 1 ;;
        esac
    done
    return 0
}

# Print (one per line, relative to current/) every file/symlink to restore:
# everything under current/ when no PATH arguments are given, or the exact
# named files/subtrees otherwise. The physical current/ mirror is the source
# of truth (not manifest.tsv, which is only dx-backup's own bookkeeping).
dx_backup_restore_targets() {
    local backup_dir="$1"
    shift
    if [ "$#" -eq 0 ]; then
        ( cd "$backup_dir/current" 2>/dev/null && find . -type f -o -type l ) | sed 's#^\./##'
        return
    fi
    local path
    for path in "$@"; do
        dx_backup_restore_path_safe "$path" || { echo "Error: refusing unsafe restore path '$path'." >&2; return 1; }
        if [ -L "$backup_dir/current/$path" ] || [ -f "$backup_dir/current/$path" ]; then
            printf '%s\n' "$path"
        elif [ -d "$backup_dir/current/$path" ]; then
            ( cd "$backup_dir/current/$path" 2>/dev/null && find . -type f -o -type l ) | sed "s#^\.#$path#"
        else
            echo "Error: $path is not present in $backup_dir/current." >&2
            return 1
        fi
    done
}

# Above this many targets in one dx-restore batch, `dx_backup_restore_status`
# ships the path list into the guest as a file (dx_backup_ship_list_to_guest
# + the selector's --hash-paths-file mode) instead of one `container exec`
# positional argument per path, the same reason and the same shape as
# dx_backup_fetch_paths's list (Branch 17; see this file's module comment).
# Threshold rationale: this codebase's /persist-relative paths are typically
# well under 100 bytes; even 1000 of them joined one-per-argv-slot sit far
# below any real host ARG_MAX (POSIX guarantees only 4096 bytes via
# _POSIX_ARG_MAX, but every real host here -- macOS and Linux -- reports at
# least several hundred KB, usually multiple MB), so the fast path (no extra
# guest round trip) is safe well past ordinary restore batches. Above it,
# the fast path risks failing outright on close to a full-tree restore --
# Branch 17's own defect surfaced at 51,262 paths on the FETCH side of this
# same size class.
DX_BACKUP_HASH_PATHS_ARG_THRESHOLD=1000

# For each relative path in $3 (one per line), compare the LOCAL mirror copy
# ($2/current/<path>) against the guest's current content, batched in one
# `--hash-paths` (or, above DX_BACKUP_HASH_PATHS_ARG_THRESHOLD,
# `--hash-paths-file`) call. Prints one line per target: path<TAB>STATUS,
# where STATUS is one of:
#   create    -- absent in the guest; restoring it is a plain create.
#   identical -- present in the guest with the SAME content already.
#   conflict  -- present in the guest with DIFFERENT content: dx-restore
#                refuses this target (and the whole run) without --force.
dx_backup_restore_status() {
    local container_name="$1" backup_dir="$2" targets="$3"
    local hashes local_hash guest_status guest_hash path line local_line
    local -a target_list=()
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        target_list+=("$path"); done < "$targets"
    [ "${#target_list[@]}" -gt 0 ] || return 0

    hashes="$(mktemp "${TMPDIR:-/tmp}/dxe-restore-hash.XXXXXX")"
    if [ "${#target_list[@]}" -gt "$DX_BACKUP_HASH_PATHS_ARG_THRESHOLD" ]; then
        local guest_list
        if guest_list="$(dx_backup_ship_list_to_guest "$container_name" "$targets")"; then
            dx_runtime_exec -u dx "$container_name" "$(dx_backup_selector_path)" --hash-paths-file "$DX_BACKUP_GUEST_ROOT" "$guest_list" </dev/null > "$hashes"
            dx_backup_remove_guest_list "$container_name" "$guest_list"
        else
            rm -f "$hashes"
            return 1
        fi
    else
        dx_runtime_exec -u dx "$container_name" "$(dx_backup_selector_path)" --hash-paths "$DX_BACKUP_GUEST_ROOT" "${target_list[@]}" > "$hashes"
    fi

    for path in "${target_list[@]}"; do
        # Exact match on field 1, not a substring search: a target path that
        # is a suffix of another target's path (e.g. repo/.gitignore vs.
        # other/repo/.gitignore) would otherwise let `grep -F` match the
        # OTHER target's line too, and `head -n1` could pick it -- silently
        # misclassifying this path with someone else's guest status/hash.
        line="$(awk -F'\t' -v p="$path" '$1 == p { print; exit }' "$hashes")"
        guest_status="$(printf '%s\n' "$line" | cut -f2)"
        if [ "$guest_status" != present ]; then
            printf '%s\tcreate\n' "$path"
            continue
        fi
        guest_hash="$(printf '%s\n' "$line" | cut -f5)"
        local_line="$(dx_pbs_hash_entry "$backup_dir/current/$path")" || { printf '%s\tconflict\n' "$path"; continue; }
        local_hash="$(printf '%s\n' "$local_line" | cut -f3)"
        if [ "$guest_hash" = "$local_hash" ]; then
            printf '%s\tidentical\n' "$path"
        else
            printf '%s\tconflict\n' "$path"
        fi
    done
    rm -f "$hashes"
}

# Push $3 (relative paths, one per line) from $2/current/ into the guest at
# $DX_BACKUP_GUEST_ROOT, preserving modes and restoring dx ownership.
dx_backup_restore_push() {
    local container_name="$1" backup_dir="$2" targets="$3"
    local path dir
    local -a target_list=() dir_list=()
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        target_list+=("$path"); done < "$targets"
    [ "${#target_list[@]}" -gt 0 ] || return 0

    for path in "${target_list[@]}"; do
        dir="$(dirname "$path")"
        while [ "$dir" != . ] && [ -n "$dir" ]; do
            case " ${dir_list[*]-} " in
                # `:` (not a bare `;;`) so this no-op branch is itself a
                # traceable command -- an empty case arm registers no
                # coverage hit even when selected, the same reason a bare
                # subshell-closing `)` doesn't (see run-coverage-linux.sh's
                # KCOV_SUBSHELL_TERMINATOR).
                *" $dir "*) : ;;
                *) dir_list+=("$dir") ;;
            esac
            dir="$(dirname "$dir")"
        done
    done
    if [ "${#dir_list[@]}" -gt 0 ]; then
        # Single line: this codebase's convention for a guest sh -c body (see
        # bin/dx-put) -- a multi-line quoted argument only registers a
        # coverage hit on its first line, not each interior line.
        dx_runtime_exec -u root "$container_name" sh -c 'root="$1"; shift; for d in "$@"; do mkdir -p "$root/$d" && chown dx:dx "$root/$d"; done' -- "$DX_BACKUP_GUEST_ROOT" "${dir_list[@]}"
    fi

    # COPYFILE_DISABLE=1: live-verified on dx-test (2026-09-27) that without
    # it, macOS tar embeds a com.apple.provenance xattr as a PAX extended
    # header GNU tar in the guest doesn't recognise ("Ignoring unknown
    # extended header keyword") -- harmless (extraction still succeeds) but
    # noisy. Same guard bin/dx-put already uses for the identical
    # host-to-guest tar-creation direction.
    printf '%s\n' "${target_list[@]}" | tr '\n' '\0' \
        | COPYFILE_DISABLE=1 tar -C "$backup_dir/current" --exclude '._*' --null -T - -cf - \
        | dx_runtime_exec -i -u dx "$container_name" tar -xf - -C "$DX_BACKUP_GUEST_ROOT"

    for path in "${target_list[@]}"; do
        dx_runtime_exec -u root "$container_name" chown dx:dx "$DX_BACKUP_GUEST_ROOT/$path"
    done
}
