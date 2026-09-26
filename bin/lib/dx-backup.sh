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
    container exec -u dx "$container_name" "$(dx_backup_selector_path)" "$DX_BACKUP_GUEST_ROOT" "$@"
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

# One incremental tar transfer: everything named (one TSV line per file) in
# $3, read from $DX_BACKUP_GUEST_ROOT in the guest, landing in $2/current/.
dx_backup_fetch_paths() {
    local container_name="$1" backup_dir="$2" fetch_lines="$3" count
    count="$(wc -l < "$fetch_lines" | tr -d '[:space:]')"
    [ "${count:-0}" -gt 0 ] || return 0
    mkdir -p "$backup_dir/current"
    cut -f1 "$fetch_lines" | tr '\n' '\0' \
        | container exec -i -u dx "$container_name" tar -C "$DX_BACKUP_GUEST_ROOT" --exclude '._*' --null -T - -cf - \
        | tar -xf - -C "$backup_dir/current"
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

# For each relative path in $3 (one per line), compare the LOCAL mirror copy
# ($2/current/<path>) against the guest's current content, batched in one
# `--hash-paths` call. Prints one line per target: path<TAB>STATUS, where
# STATUS is one of:
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
    container exec -u dx "$container_name" "$(dx_backup_selector_path)" --hash-paths "$DX_BACKUP_GUEST_ROOT" "${target_list[@]}" > "$hashes"

    for path in "${target_list[@]}"; do
        line="$(grep -F -- "$(printf '%s\t' "$path")" "$hashes" | head -n1)"
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
        container exec -u root "$container_name" sh -c 'root="$1"; shift; for d in "$@"; do mkdir -p "$root/$d" && chown dx:dx "$root/$d"; done' -- "$DX_BACKUP_GUEST_ROOT" "${dir_list[@]}"
    fi

    # COPYFILE_DISABLE=1: live-verified on dx-test (2026-09-27) that without
    # it, macOS tar embeds a com.apple.provenance xattr as a PAX extended
    # header GNU tar in the guest doesn't recognise ("Ignoring unknown
    # extended header keyword") -- harmless (extraction still succeeds) but
    # noisy. Same guard bin/dx-put already uses for the identical
    # host-to-guest tar-creation direction.
    printf '%s\n' "${target_list[@]}" | tr '\n' '\0' \
        | COPYFILE_DISABLE=1 tar -C "$backup_dir/current" --exclude '._*' --null -T - -cf - \
        | container exec -i -u dx "$container_name" tar -xf - -C "$DX_BACKUP_GUEST_ROOT"

    for path in "${target_list[@]}"; do
        container exec -u root "$container_name" chown dx:dx "$DX_BACKUP_GUEST_ROOT/$path"
    done
}
