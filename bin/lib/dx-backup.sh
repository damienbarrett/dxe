#!/bin/bash
# Host-side orchestration for the /persist backup capture (Branch 10,
# plan.md B1): manifest bookkeeping, the diff against a fresh guest listing,
# and the single incremental tar transfer. Safe to source; performs no I/O
# merely by being sourced.
#
# The selection RULES themselves (what is at-risk, the deny-list, hashing)
# live in the guest selector, shipped through the bootstrap volume:
# container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib/dx-persist-backup-select.sh
# (see that file's header for why). This library sources it directly by path
# -- both live in the same repository checkout on the host -- to reuse its
# hashing/stat primitives for hashing local content.
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

dx_backup_default_dir() {
    printf '%s/Backups/dxe-persist/%s\n' "${HOME:?}" "${DX_CONTAINER_NAME:?}"
}

dx_backup_resolve_dir() {
    printf '%s\n' "${DX_BACKUP_DIR:-$(dx_backup_default_dir)}"
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

