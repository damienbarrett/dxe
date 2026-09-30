#!/bin/bash
# Host-side orchestration for the /persist backup and restore (Branch 10,
# plan.md B1): manifest bookkeeping, the diff against a fresh guest listing,
# the single incremental tar transfer, and restore's conflict check and push.
# Safe to source; performs no I/O merely by being sourced.
#
# The selection RULES themselves (what is at-risk, the deny-list, hashing)
# live in the guest selector, shipped through the bootstrap volume:
# container/dx-nixos-26.05/scripts/lib/dx-persist-backup-select.sh
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
DX_BACKUP_SELECTOR_SOURCE="$DX_BACKUP_PROJECT_ROOT/container/dx-nixos-26.05/scripts/lib/dx-persist-backup-select.sh"
# shellcheck source=../../container/dx-nixos-26.05/scripts/lib/dx-persist-backup-select.sh
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
#
# qnap-dxe-plan.md Phase 2 item 7: for DX_RUNTIME=docker-ssh, one more
# segment -- dx_runtime_host_identity's own "docker-ssh:<alias>:<daemon-id>"
# (colons replaced with underscores; only cosmetic, both characters are
# valid in a Unix path, but colons read oddly in a directory listing) --
# so two docker-ssh profiles that happen to share a container name (two
# different NASs, or the same alias resolving to a different daemon) can
# never mix their /persist backups under the same local directory: unlike
# a stale tunnel socket, cross-contaminating backup data is a real
# data-integrity hazard, not just a minor mixup. Apple's own path is
# BYTE-FOR-BYTE unchanged (there is only ever one local Apple runtime, so
# it never needed disambiguating).
#
# Optional $1 (qnap-dxe-plan.md Phase 7 / docs/refactor/qnap-promotion.md
# section B): a container-name OVERRIDE for the segment above, used ONLY by
# dx-restore's --source-container=NAME flag to read a DIFFERENT profile's
# mirror on purpose. Omitted (the only way every other caller, and every
# call before this flag existed, ever uses this function), it is exactly
# ${DX_CONTAINER_NAME:?} -- byte-for-byte the prior behaviour. The identity
# segment (docker-ssh only) is NEVER overridden by $1: it still always
# comes from the CURRENT profile's own resolved DX_REMOTE_HOST, so this can
# only ever cross profiles on the SAME NAS (a name that only exists under a
# different NAS's identity segment fails closed as "no backup mirror",
# never a wrong-host read -- see the design note for why that limitation is
# accepted rather than solved here).
dx_backup_resolve_dir() {
    local container_name="${1:-${DX_CONTAINER_NAME:?}}"
    if [ "${DX_RUNTIME:-apple}" = docker-ssh ]; then
        local identity
        identity="$(dx_profile_state_segment)" || return 1
        printf '%s/%s/%s\n' "${DX_BACKUP_DIR:?}" "$container_name" "${identity//:/_}"
    else
        printf '%s/%s\n' "${DX_BACKUP_DIR:?}" "$container_name"
    fi
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
# $3, read from $DX_BACKUP_GUEST_ROOT in the guest, landing in $2.
#
# $2 is a plain destination directory, extracted into directly -- NEVER the
# published `current/` mirror itself (Astra F5 / WP6.6): every caller now
# passes a fresh, not-yet-published generation directory (see
# dx_backup_generation_commit below), so a truncated or failed transfer
# never touches anything a reader of `current` can observe.
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
    local container_name="$1" dest_dir="$2" fetch_lines="$3" count
    count="$(wc -l < "$fetch_lines" | tr -d '[:space:]')"
    [ "${count:-0}" -gt 0 ] || return 0
    mkdir -p "$dest_dir"

    local host_list guest_list rc=0
    host_list="$(mktemp "${TMPDIR:-/tmp}/dxe-backup-fetch-list.XXXXXX")" || return 1
    cut -f1 "$fetch_lines" | tr '\n' '\0' > "$host_list"

    if guest_list="$(dx_backup_ship_list_to_guest "$container_name" "$host_list")"; then
        # --hard-dereference: a duplicate path in $fetch_lines (found live on
        # the primary guest, 2026-09-27: a nested git repository selected
        # twice, once by its own pass and once by an outer whole-repo walk
        # that did not yet prune at its boundary -- fixed at the selector
        # level too, see dx-persist-backup-select.sh) is otherwise the same
        # (device, inode) archived twice, which GNU tar treats exactly like a
        # real hardlink: it emits the second occurrence as a hardlink record
        # pointing at the first, which is indistinguishable from "a hardlink
        # to itself" once the path is identical -- and the host's tar refuses
        # to extract that. --hard-dereference makes every occurrence a full,
        # independent regular-file copy instead, so a duplicate can never
        # produce a self-referential hardlink record.
        if dx_runtime_exec -u dx "$container_name" tar -C "$DX_BACKUP_GUEST_ROOT" --exclude '._*' --hard-dereference --null -T "$guest_list" -cf - </dev/null \
            | tar -xf - -C "$dest_dir"; then
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

dx_backup_write_manifest_atomic() {
    local manifest="$1" content_file="$2" tmp
    tmp="$(mktemp "$(dirname "$manifest")/.manifest.XXXXXX")" || return 1
    LC_ALL=C sort "$content_file" > "$tmp"
    mv -f "$tmp" "$manifest"
}

# ---------------------------------------------------------------------------
# Astra F5 / WP6.6: generations, so a backup is a single all-or-nothing
# publish
#
# Before this, dx-backup extracted changed files straight over current/ and
# only manifest.tsv was published atomically (dx_backup_write_manifest_atomic
# above) -- a stream failure partway through extraction left current/
# partly overwritten under the OLD manifest, concurrent runs could interleave
# their own extraction/removal/manifest-replacement, and dx-restore read
# that same physical mirror, so it could observe the intermediate state too.
#
# Now every run that has anything to change (fetch_count or remove_count > 0)
# builds a WHOLE NEW generations/<id>/ directory: every unchanged entry is
# carried forward from the previous generation as a hard link (never
# copying, and never mutating the previous generation's own files), only the
# fetched files' fresh bytes land there, each fetched file's hash is
# verified against the selection's own listing (a file that changed between
# listing and transfer must never be silently committed), and that
# generation's own manifest.tsv is written -- all BEFORE the generation is
# published (the `current` symlink is flipped to point at it). A truncated
# transfer, a hash mismatch, or a failed publish all leave the PREVIOUS
# generation -- still the one `current` points at -- untouched. dx-backup
# and dx-restore share one lock (bin/lib/dx-host-util.sh's dx_lock_acquire)
# over the mirror directory itself, so two overlapping backups (or a backup
# and a restore) can never interleave their own reads/writes of `current` or
# the generation being built.
# ---------------------------------------------------------------------------

# A fresh, sortable, effectively-unique generation id -- matches this
# codebase's established guest-side bootstrap generation id shape exactly
# (bin/lib/dx-bootstrap-sync.sh: `date -u +%Y%m%dT%H%M%SZ`-$$).
dx_backup_generation_new_id() {
    printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

# Prints the bare generation id (no "generations/" prefix) BACKUP_DIR/current
# currently points at. Fails (prints nothing) when there is no current
# generation yet (the very first backup), the pointer is missing, or its
# target does not look like one of ours (`generations/<id>`, never trusted
# further than that shape) -- every one of those is an ordinary "nothing
# published yet" case to this function's callers, never an error here.
dx_backup_generation_current() {
    local backup_dir="$1" target
    [ -L "$backup_dir/current" ] || return 1
    target="$(readlink "$backup_dir/current")" || return 1
    case "$target" in
        generations/*) printf '%s\n' "${target#generations/}" ;;
        *) return 1 ;;
    esac
}

# The path to the CURRENTLY PUBLISHED generation's own manifest.tsv, or a
# nonexistent path under generations/ when there is no current generation
# yet -- dx_backup_diff already treats a missing old_manifest as "empty", so
# the call site never needs its own separate first-run branch.
dx_backup_generation_manifest_path() {
    local backup_dir="$1" id
    if id="$(dx_backup_generation_current "$backup_dir")"; then
        printf '%s/generations/%s/manifest.tsv\n' "$backup_dir" "$id"
    else
        printf '%s/generations/.none/manifest.tsv\n' "$backup_dir"
    fi
}

# A legacy manifest's own timestamp turned into a generation id
# ("legacy-<epoch>"), or -- when there is no old manifest to read a
# timestamp from at all (a mirror directory that exists but never completed
# a successful run) -- "legacy-" plus the CURRENT time. Shares
# dx-persist-backup-select.sh's own stat primitive (dx_pbs_stat_mtime,
# already sourced above) rather than duplicating its GNU/BSD `stat`
# fallback.
dx_backup_generation_legacy_id() {
    local backup_dir="$1" mtime=""
    if [ -f "$backup_dir/manifest.tsv" ]; then
        mtime="$(dx_pbs_stat_mtime "$backup_dir/manifest.tsv" 2>/dev/null)" || mtime=""
    fi
    [ -n "$mtime" ] || mtime="$(date -u +%s)"
    printf 'legacy-%s\n' "$mtime"
}

# One-time, idempotent adoption of a mirror created before this generation
# model existed (Astra F5 / WP6.9 follow-up: the loud "exists and is not a
# symlink" refusal in dx_backup_generation_publish below cannot ship
# as-is -- a real, already-deployed mirror has exactly this shape, and a
# hand migration is not acceptable): `current/` a real directory (every run
# extracted straight over it), with manifest.tsv sitting directly under
# BACKUP_DIR instead of inside a generation. Called by bin/dx-backup only
# for a real run, right after acquiring the mirror lock and before ever
# contacting the guest, so a concurrent backup or restore can never observe
# (or race) a half-migrated mirror.
#
# The OLD content is RENAMED (never copied) into generations/<legacy-id>/ --
# the very same inodes carried across, byte-identical by construction,
# never re-transferred -- and its manifest.tsv (absent on a mirror that
# exists but never completed a successful run) moves alongside it if
# present. `current` is then repointed at that generation with the exact
# same `ln -sfn` dx_backup_generation_publish uses below, so every
# subsequent read (dx-restore, another dx-backup's own diff) sees it as an
# ordinary, already-published generation -- the very next successful backup
# publishes forward from it and retains it as the one generation before,
# exactly like any other.
#
# Idempotent: a mirror with no `current` at all (nothing to migrate -- the
# very first backup ever) or one where `current` is ALREADY a symlink (this
# mirror was created by, or has already been touched by, this generation
# model) is a no-op. Refuses -- before ever touching anything -- only when
# `current` exists and is neither a symlink nor a plain directory (some
# other, unrecognised shape): the same guard dx_backup_generation_publish
# enforces at publish time, surfaced here first so it fails before a wasted
# guest round trip.
dx_backup_generation_migrate_legacy() {
    local backup_dir="$1" legacy_id
    [ -e "$backup_dir/current" ] || return 0
    [ ! -L "$backup_dir/current" ] || return 0
    if [ ! -d "$backup_dir/current" ]; then
        echo "Error: $backup_dir/current exists and is neither a symlink nor a directory; refusing to migrate or publish over it." >&2
        return 1
    fi
    legacy_id="$(dx_backup_generation_legacy_id "$backup_dir")"
    mkdir -p "$backup_dir/generations" || return 1
    if [ -e "$backup_dir/generations/$legacy_id" ] || [ -L "$backup_dir/generations/$legacy_id" ]; then
        echo "Error: legacy generation id $legacy_id already exists; refusing to migrate." >&2
        return 1
    fi
    mv "$backup_dir/current" "$backup_dir/generations/$legacy_id" || return 1
    if [ -f "$backup_dir/manifest.tsv" ]; then
        mv "$backup_dir/manifest.tsv" "$backup_dir/generations/$legacy_id/manifest.tsv" || return 1
    fi
    ln -sfn "generations/$legacy_id" "$backup_dir/current"
}

# Hard-link every regular file/symlink under PREV_DIR into the same relative
# path under NEW_DIR, except any path listed (one per line, relative) in
# SKIP_FILE -- the paths this run is fetching fresh or has removed, which
# must never be linked to the previous generation's own copy (mutating a
# hard-linked file in place would corrupt that previous, supposedly
# immutable, generation too). `ln -P` (not the bare default `ln`): a mirrored
# SYMLINK entry's target is a guest-side path that most often does not
# exist, or means something else entirely, on the HOST -- the default `ln`
# hard-links to a symlink's RESOLVED target (confirmed directly while
# designing this function), which would fail outright or link to the wrong
# file; `-P` hard-links the symlink directory entry itself, exactly like
# every other file here. `cp -al`'s recursive hard-link copy (the common GNU
# idiom for exactly this generation-snapshot shape) does not exist on
# macOS's `cp` -- hence the explicit per-file `ln` here instead, at the cost
# of one process per carried-forward file/directory (this is local
# filesystem work, not a remote round trip -- Astra R4's own concern -- so
# that cost is not the same class of problem).
#
# Never mutates PREV_DIR. NEW_DIR's own parent directories are created as
# needed; PREV_DIR's directory structure is otherwise not replicated for
# directories that end up carrying nothing forward (an entirely-removed
# subtree therefore never reappears as an empty directory in NEW_DIR).
dx_backup_generation_carry_forward() {
    local prev_dir="$1" new_dir="$2" skip_file="$3"
    [ -d "$prev_dir" ] || return 0
    local all_sorted skip_sorted carry rc=0
    all_sorted="$(mktemp "${TMPDIR:-/tmp}/dxe-backup-carry-all.XXXXXX")" || return 1
    skip_sorted="$(mktemp "${TMPDIR:-/tmp}/dxe-backup-carry-skip.XXXXXX")" || { rm -f "$all_sorted"; return 1; }
    carry="$(mktemp "${TMPDIR:-/tmp}/dxe-backup-carry-list.XXXXXX")" || { rm -f "$all_sorted" "$skip_sorted"; return 1; }
    ( cd "$prev_dir" && find . -type f -o -type l ) | sed 's#^\./##' | LC_ALL=C sort > "$all_sorted"
    LC_ALL=C sort "$skip_file" > "$skip_sorted"
    comm -23 "$all_sorted" "$skip_sorted" > "$carry"

    if [ -s "$carry" ]; then
        # Ancestor directories, precreated in one pass (same awk dirname-
        # levels idiom as dx_backup_restore_push's own directory pass
        # below): never a per-file `dirname` fork, and `mkdir -p` is only
        # ever asked for a directory that some carried-forward file actually
        # needs.
        local dirs
        dirs="$(mktemp "${TMPDIR:-/tmp}/dxe-backup-carry-dirs.XXXXXX")" || { rm -f "$all_sorted" "$skip_sorted" "$carry"; return 1; }
        awk -F/ '{ n = split($0, parts, "/"); prefix = ""; for (i = 1; i < n; i++) { prefix = (prefix == "" ? parts[i] : prefix "/" parts[i]); print prefix } }' "$carry" | LC_ALL=C sort -u > "$dirs"
        while IFS= read -r d || [ -n "$d" ]; do
            [ -n "$d" ] || continue
            mkdir -p "$new_dir/$d" || { rc=1; break; }
        done < "$dirs" # KCOV_LOOP_TERMINATOR
        rm -f "$dirs"
        if [ "$rc" -eq 0 ]; then
            local rel
            while IFS= read -r rel || [ -n "$rel" ]; do
                [ -n "$rel" ] || continue
                ln -P "$prev_dir/$rel" "$new_dir/$rel" || { rc=1; break; }
            done < "$carry" # KCOV_LOOP_TERMINATOR
        fi
    fi
    rm -f "$all_sorted" "$skip_sorted" "$carry"
    return "$rc"
}

# For each path in FETCH_LINES (path<TAB>size<TAB>mtime<TAB>sha256, the same
# listing format dx_backup_diff/dx_backup_sum_sizes use), verify the copy
# just extracted under DEST_DIR/<path> hashes to the SAME sha256 the
# selection recorded at listing time (Astra F5, RED 4). A path that changed
# on the guest between the listing pass and the archive transfer -- however
# briefly -- must never be silently committed as part of a snapshot that
# claims to be that listing; every mismatch is named on stderr, and the
# whole check fails (so the generation is never published) rather than
# stopping at the first one, so an operator sees every affected path at once.
dx_backup_verify_fetched() {
    local dest_dir="$1" fetch_lines="$2" path expected_hash actual_line actual_hash rc=0
    while IFS="$(printf '\t')" read -r path _ _ expected_hash || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        actual_line="$(dx_pbs_hash_entry "$dest_dir/$path" 2>/dev/null)" || actual_line=""
        actual_hash="$(printf '%s\n' "$actual_line" | cut -f3)"
        if [ -z "$actual_hash" ] || [ "$actual_hash" != "$expected_hash" ]; then
            echo "Error: $path changed between listing and transfer; refusing to commit an inconsistent snapshot." >&2
            rc=1
        fi
    done < "$fetch_lines" # KCOV_LOOP_TERMINATOR
    return "$rc"
}

# Point BACKUP_DIR/current at generations/GENERATION (Astra F5's publish
# step). `ln -sfn`, not `mv`: this codebase's guest-side bootstrap generation
# publish (bin/lib/dx-bootstrap-sync.sh) uses a temp symlink plus `mv -Tf`,
# but that -T (no-target-directory) flag is GNU-only and the guest there is
# always Linux; this runs on the HOST, which is routinely macOS, where `mv`
# has no such flag and, when the destination is a symlink TO A DIRECTORY
# (exactly what `current` already is after the first publish), silently
# moves the source INSIDE that directory instead of replacing the symlink,
# reporting success -- confirmed directly against this host's own `mv` while
# designing this function. `ln -sfn` (`-f`: replace an existing destination;
# `-n`: treat that destination as the plain file/symlink it is, never
# descend into it as a directory) is the standard portable idiom for this
# exact swap on both BSD and GNU, at the cost of true single-syscall
# atomicity (`-f` unlinks, then a fresh `symlink()` -- two syscalls, not one
# `rename()`): every reader of `current` in this codebase (dx-backup,
# dx-restore) holds the very same lock this publish runs under, so no such
# reader can ever observe that narrow a window.
#
# Refuses -- rather than calling `ln -sfn` at all -- when `current` already
# exists and is NOT a symlink: that is exactly the shape every mirror this
# generation model predates has (every run used to extract straight over a
# real current/ directory), and `ln -sfn` against a real directory was
# confirmed, while designing this function, to silently place the new
# symlink INSIDE it (reporting success) rather than replacing it -- silently
# leaving `current` on the OLD content forever while polluting it with a
# stray entry on every subsequent run. A pre-existing mirror in that shape
# needs an explicit one-time migration before it can be published into
# again; this function fails loudly instead of guessing.
dx_backup_generation_publish() {
    local backup_dir="$1" generation="$2"
    [ -d "$backup_dir/generations/$generation" ] || { echo "Error: generation $generation does not exist; refusing to publish it." >&2; return 1; }
    if [ -e "$backup_dir/current" ] && [ ! -L "$backup_dir/current" ]; then
        echo "Error: $backup_dir/current exists and is not a symlink (a pre-generation-model mirror?); refusing to publish over it." >&2
        return 1
    fi
    ln -sfn "generations/$generation" "$backup_dir/current"
}

# Delete every directory under BACKUP_DIR/generations/ EXCEPT the id(s) named
# in "$@" (current, and -- until the NEXT successful backup -- the
# generation it replaced, per Astra F5's recommendation to retain the
# previous generation). Never touches `current` itself, and never touches
# anything outside generations/.
dx_backup_generation_prune() {
    local backup_dir="$1"; shift
    local gens_dir="$backup_dir/generations" entry name keep found
    [ -d "$gens_dir" ] || return 0
    for entry in "$gens_dir"/*; do
        [ -e "$entry" ] || continue
        name="${entry##*/}"
        found=0
        for keep in "$@"; do
            [ "$name" = "$keep" ] && { found=1; break; }
        done
        [ "$found" -eq 1 ] || rm -rf "$entry"
    done
}

# The whole "build the next generation, verify it, publish it, retire the one
# before it" sequence (Astra F5), called by bin/dx-backup only when there is
# something to change (fetch_count or remove_count > 0 -- a no-op run never
# reaches here, so `current` and every existing generation are untouched).
# LISTING is the fresh, full guest listing (written into the new
# generation's own manifest.tsv); FETCH_LINES/REMOVE_LINES are
# dx_backup_diff's own outputs. Prints the new generation id on success.
# Every failure path removes the not-yet-published new generation directory
# and returns nonzero with nothing printed, leaving the previously published
# generation -- and its manifest -- exactly as they were.
dx_backup_generation_commit() {
    local container_name="$1" backup_dir="$2" listing="$3" fetch_lines="$4" remove_lines="$5"
    local prev_id new_id new_dir skip_file rc=0
    prev_id="$(dx_backup_generation_current "$backup_dir" || true)"
    new_id="$(dx_backup_generation_new_id)"
    new_dir="$backup_dir/generations/$new_id"
    [ ! -e "$new_dir" ] && [ ! -L "$new_dir" ] || { echo "Error: generation $new_id already exists." >&2; return 1; }
    mkdir -p "$new_dir" || return 1

    skip_file="$(mktemp "${TMPDIR:-/tmp}/dxe-backup-skip.XXXXXX")" || { rm -rf "$new_dir"; return 1; }
    cut -f1 "$fetch_lines" > "$skip_file"
    [ ! -s "$remove_lines" ] || cat "$remove_lines" >> "$skip_file"

    if [ -n "$prev_id" ]; then
        dx_backup_generation_carry_forward "$backup_dir/generations/$prev_id" "$new_dir" "$skip_file" || rc=1
    fi
    rm -f "$skip_file"
    [ "$rc" -eq 0 ] || { rm -rf "$new_dir"; return 1; }

    if [ -s "$fetch_lines" ]; then
        dx_backup_fetch_paths "$container_name" "$new_dir" "$fetch_lines" || { rm -rf "$new_dir"; return 1; }
        dx_backup_verify_fetched "$new_dir" "$fetch_lines" || { rm -rf "$new_dir"; return 1; }
    fi

    dx_backup_write_manifest_atomic "$new_dir/manifest.tsv" "$listing" || { rm -rf "$new_dir"; return 1; }

    dx_backup_generation_publish "$backup_dir" "$new_id" || { rm -rf "$new_dir"; return 1; }

    if [ -n "$prev_id" ]; then
        dx_backup_generation_prune "$backup_dir" "$new_id" "$prev_id"
    else
        dx_backup_generation_prune "$backup_dir" "$new_id"
    fi
    printf '%s\n' "$new_id"
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

# List (one per line) every file/symlink under DIR, each joined to PREFIX AS
# DATA -- never by building a dynamic sed/awk program out of PREFIX (Astra
# F9: the old `sed "s#^\.#$path#"` spliced a user-supplied directory name
# straight into a sed replacement program, and `&`, backslashes, and `#` are
# all special to sed's own replacement syntax even though every one of them
# is an ordinary, valid filename byte -- `a&b` corrupted a real selection
# into `a.b`). A `while read` + `case`/`printf` join instead treats PREFIX
# purely as a string, so it can never be reinterpreted as part of a program.
# PREFIX "" lists DIR itself with bare relative names (the whole-mirror
# case); a nonempty PREFIX is the directory-argument case, joined with `/`.
# The single caller below routes ALL THREE restore shapes (explicit file,
# explicit directory, whole-mirror) through this one enumeration.
dx_backup_restore_list_prefixed() {
    local dir="$1" prefix="$2" rel
    ( cd "$dir" 2>/dev/null && find . -type f -o -type l ) | while IFS= read -r rel || [ -n "$rel" ]; do
        rel="${rel#./}"
        if [ -n "$prefix" ]; then
            printf '%s/%s\n' "$prefix" "$rel"
        else
            printf '%s\n' "$rel"
        fi
    done
}

# Print (one per line, relative to current/) every file/symlink to restore:
# everything under current/ when no PATH arguments are given, or the exact
# named files/subtrees otherwise. The physical current/ mirror is the source
# of truth (not manifest.tsv, which is only dx-backup's own bookkeeping).
#
# A path argument carrying a literal tab or newline is refused explicitly
# (Astra F9's recommendation): this file's own convention is one path per
# LINE with no other delimiter in use, so either character would either be
# misread as a field/record separator downstream or silently merge with a
# neighboring entry -- never silently misparsed.
#
# Overlapping arguments (e.g. a directory AND one of its own files named
# separately) are de-duplicated once, after every argument has been
# enumerated, rather than trusted not to collide -- a caller cannot know in
# advance whether two PATH arguments happen to overlap on disk.
dx_backup_restore_targets() {
    local backup_dir="$1"
    shift
    if [ "$#" -eq 0 ]; then
        dx_backup_restore_list_prefixed "$backup_dir/current" ""
        return
    fi
    local path scratch rc=0
    scratch="$(mktemp "${TMPDIR:-/tmp}/dxe-restore-targets.XXXXXX")" || return 1
    for path in "$@"; do
        case "$path" in
            *$'\t'*|*$'\n'*)
                echo "Error: restore path '$path' contains a tab or newline character; refusing to guess its meaning." >&2
                rc=1
                break
                ;;
        esac
        dx_backup_restore_path_safe "$path" || { echo "Error: refusing unsafe restore path '$path'." >&2; rc=1; break; }
        if [ -L "$backup_dir/current/$path" ] || [ -f "$backup_dir/current/$path" ]; then
            printf '%s\n' "$path" >> "$scratch"
        elif [ -d "$backup_dir/current/$path" ]; then
            dx_backup_restore_list_prefixed "$backup_dir/current/$path" "$path" >> "$scratch"
        else
            echo "Error: $path is not present in $backup_dir/current." >&2
            rc=1
            break
        fi
    done
    if [ "$rc" -eq 0 ]; then
        awk '!seen[$0]++' "$scratch"
    fi
    rm -f "$scratch"
    return "$rc"
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

# Shared threshold decision (Astra R4 / WP6.9): given $3 (a count of items
# $2's file holds, one per line), decide whether that batch should ship $2
# into the guest as a file via dx_backup_ship_list_to_guest, or stay small
# enough for the caller's own positional-argument fast path. Prints nothing
# (success, rc 0) at or under DX_BACKUP_HASH_PATHS_ARG_THRESHOLD -- the
# caller takes the positional path. Above it, ships $2 and prints the
# resulting guest path (success, rc 0); a ship failure is never masked --
# it propagates as a non-zero return with no output, so a caller must never
# fall back to the positional path on a failed ship (the very ARG_MAX risk
# this threshold exists to avoid). Shared by dx_backup_restore_status's
# hash-paths batching and dx_backup_restore_push's directory-precreation and
# ownership batching below.
dx_backup_ship_list() {
    local container_name="$1" host_list="$2" count="$3"
    [ "$count" -gt "$DX_BACKUP_HASH_PATHS_ARG_THRESHOLD" ] || return 0
    dx_backup_ship_list_to_guest "$container_name" "$host_list"
}

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
    local hashes local_hashes present_list path local_line
    local -a target_list=()
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        target_list+=("$path"); done < "$targets"
    [ "${#target_list[@]}" -gt 0 ] || return 0

    hashes="$(mktemp "${TMPDIR:-/tmp}/dxe-restore-hash.XXXXXX")"
    local guest_list
    if guest_list="$(dx_backup_ship_list "$container_name" "$targets" "${#target_list[@]}")"; then
        if [ -n "$guest_list" ]; then
            dx_runtime_exec -u dx "$container_name" "$(dx_backup_selector_path)" --hash-paths-file "$DX_BACKUP_GUEST_ROOT" "$guest_list" </dev/null > "$hashes"
            dx_backup_remove_guest_list "$container_name" "$guest_list"
        else
            dx_runtime_exec -u dx "$container_name" "$(dx_backup_selector_path)" --hash-paths "$DX_BACKUP_GUEST_ROOT" "${target_list[@]}" > "$hashes"
        fi
    else
        rm -f "$hashes"
        return 1
    fi

    # Only a target the guest batch reports "present" can ever need a local
    # hash: a "missing" target classifies "create" unconditionally below,
    # regardless of what (if anything) the local mirror holds, so hashing it
    # would be pure waste. A live 60,168-target dry run against a mirror the
    # guest held NONE of (a full restore of a retained-but-unpushed backup)
    # still did not finish in 15 minutes after the O(n^2) guest-hash join
    # above was fixed -- every one of those dx_pbs_hash_entry forks was
    # wasted, since every target was going to classify "create" regardless
    # of its local hash. One awk pass extracts the present subset from
    # $hashes (never a per-target grep/scan -- the same O(n^2) mistake this
    # whole item exists to fix).
    present_list="$(mktemp "${TMPDIR:-/tmp}/dxe-restore-present.XXXXXX")"
    awk -F'\t' '$2 == "present" { print $1 }' "$hashes" > "$present_list"

    # One local hash per PRESENT target only (unavoidable, O(present-count)
    # now rather than O(n): a target absent from the guest never reaches
    # this loop at all). An empty local_hash (dx_pbs_hash_entry failed --
    # could not read/hash the local mirror copy) means this target must
    # classify "conflict" below, same as the old per-target failure branch.
    #
    # Seeded with one sentinel line whose path field ("") can never match a
    # real target (target paths are never empty, filtered above) before the
    # loop below is guaranteed to be the case that matters most -- EVERY
    # target absent from the guest, present_list empty, zero real lines
    # written. Without this sentinel, an awk reading two files where the
    # FIRST is completely empty still sees `NR == FNR` hold true through
    # the START of the SECOND file too (both begin at 1), silently
    # misrouting $hashes's own lines into the join's array-population
    # branch below and producing NO output at all -- caught by both the
    # existing 1001-target ARG_MAX test (its guest fixture is emptied
    # before the dry-run, so every target reports missing) and the new
    # all-absent fixture below.
    local_hashes="$(mktemp "${TMPDIR:-/tmp}/dxe-restore-local.XXXXXX")"
    printf '\t\n' > "$local_hashes"
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        local_line="$(dx_pbs_hash_entry "$backup_dir/current/$path" 2>/dev/null)" || local_line=""
        # Single line (this file's own convention, see dx_backup_restore_push's
        # sh -c body below): a bare `done` starts no traceable command of its
        # own, so kcov never registers a hit on a "done > FILE" line by itself
        # -- it must share a line with a real command to be measured as covered.
        printf '%s\t%s\n' "$path" "$(printf '%s\n' "$local_line" | cut -f3)"; done < "$present_list" >> "$local_hashes"

    # Single pass joining the two lists: $hashes (EVERY target, present or
    # missing) drives the output so every target still gets exactly one
    # output line; $local_hashes (present targets only, from the loop above)
    # is the lookup array. Exact match on field 1 throughout, never a
    # substring search (Branch 17's rule): a target path that is a suffix
    # of another target's path (e.g. repo/.gitignore vs.
    # other/repo/.gitignore) must never let the OTHER target's line answer
    # for it. A present target missing from $local_hashes, or present there
    # with an empty hash, means dx_pbs_hash_entry could not read the local
    # mirror copy -- still "conflict", same as an explicit empty local_hash
    # always has been. Single line (this file's own convention, see
    # dx-put's sh -c body): a multi-line quoted argument only registers a
    # coverage hit on its first line, not each interior line.
    awk -F'\t' 'NR == FNR { lhash[$1] = $2; next } { path = $1; if ($2 != "present") { print path "\tcreate"; next }; if (!(path in lhash) || lhash[path] == "") { print path "\tconflict"; next }; if ($5 == lhash[path]) { print path "\tidentical"; next }; print path "\tconflict" }' "$local_hashes" "$hashes"

    rm -f "$hashes" "$local_hashes" "$present_list"
}

# Push $3 (relative paths, one per line) from $2/current/ into the guest at
# $DX_BACKUP_GUEST_ROOT, preserving modes and restoring dx ownership.
#
# Astra R4 / WP6.9: rewritten to bound the number of `container exec` calls
# regardless of the target count -- the old shape forked one `chown` exec
# PER restored file (2,000 targets meant 2,000 execs; live-measured at
# ~2,005 total against a 2,000-file fixture with bin/dx-restore's old,
# unfiltered push list). Every phase below is now at most ONE exec at or
# under DX_BACKUP_HASH_PATHS_ARG_THRESHOLD items, or ships the list and pays
# exactly one more batched exec (plus best-effort cleanup) above it -- the
# same shape Branch 17 already established for the fetch/status paths,
# reused here via dx_backup_ship_list.
dx_backup_restore_push() {
    local container_name="$1" backup_dir="$2" targets="$3"
    local path rc=0
    local -a target_list=()
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        target_list+=("$path"); done < "$targets"
    [ "${#target_list[@]}" -gt 0 ] || return 0

    # --- Ancestor directories: one awk pass over the targets file (never a
    # per-path `dirname` fork) emits every ancestor of every target -- the
    # same set the old per-path dirname-walk loop collected, just without
    # forking `dirname` twice per path per level to do it -- deduped with
    # this file's own LC_ALL=C sort -u convention (see dx_backup_diff,
    # dx_backup_write_manifest_atomic above). mkdir -p + chown dx:dx each
    # one, batched into a single exec, or, above the threshold, shipped and
    # run through one `xargs -0` exec. Single line (this file's own
    # convention, see dx-put and this file's other sh -c bodies): a
    # multi-line quoted argument only registers a kcov coverage hit on its
    # first line.
    local dirs_file dir_count
    dirs_file="$(mktemp "${TMPDIR:-/tmp}/dxe-restore-push-dirs.XXXXXX")" || return 1
    awk -F/ '{ n = split($0, parts, "/"); prefix = ""; for (i = 1; i < n; i++) { prefix = (prefix == "" ? parts[i] : prefix "/" parts[i]); print prefix } }' "$targets" | LC_ALL=C sort -u > "$dirs_file"
    dir_count="$(wc -l < "$dirs_file" | tr -d '[:space:]')"
    if [ "${dir_count:-0}" -gt 0 ]; then
        local dirs_guest_list
        if dirs_guest_list="$(dx_backup_ship_list "$container_name" "$dirs_file" "$dir_count")"; then
            if [ -n "$dirs_guest_list" ]; then
                dx_runtime_exec -u root "$container_name" sh -c 'root="$1"; list="$2"; tr "\n" "\0" < "$list" | xargs -0 sh -c '\''r="$1"; shift; for d; do mkdir -p "$r/$d" && chown dx:dx "$r/$d"; done'\'' -- "$root"' -- "$DX_BACKUP_GUEST_ROOT" "$dirs_guest_list" || rc=$?
                dx_backup_remove_guest_list "$container_name" "$dirs_guest_list"
            else
                local -a dir_list=()
                while IFS= read -r path; do dir_list+=("$path"); done < "$dirs_file"
                dx_runtime_exec -u root "$container_name" sh -c 'root="$1"; shift; for d; do mkdir -p "$root/$d" && chown dx:dx "$root/$d"; done' -- "$DX_BACKUP_GUEST_ROOT" "${dir_list[@]}" || rc=$?
            fi
        else
            rc=1
        fi
    fi
    rm -f "$dirs_file"
    [ "$rc" -eq 0 ] || return "$rc"

    # --- One incremental tar transfer, unchanged (Branch 17's own
    # unidirectional shape: stdin-only host tar create, stdout-only guest
    # extract, never both live on the same exec). COPYFILE_DISABLE=1:
    # live-verified on dx-test (2026-09-27) that without it, macOS tar
    # embeds a com.apple.provenance xattr as a PAX extended header GNU tar
    # in the guest doesn't recognise ("Ignoring unknown extended header
    # keyword") -- harmless (extraction still succeeds) but noisy. Same
    # guard bin/dx-put already uses for the identical host-to-guest
    # tar-creation direction.
    printf '%s\n' "${target_list[@]}" | tr '\n' '\0' \
        | COPYFILE_DISABLE=1 tar -C "$backup_dir/current" --exclude '._*' --null -T - -cf - \
        | dx_runtime_exec -i -u dx "$container_name" tar -xf - -C "$DX_BACKUP_GUEST_ROOT" || return $?

    # --- Ownership: one batched `chown -h dx:dx` (never plain `chown`,
    # which follows a symlink's target instead of re-owning the symlink
    # itself -- a real restore target can be a symlink, see
    # dx_backup_restore_list_prefixed's `-type f -o -type l`) over
    # pre-joined full guest paths, positional at or under the threshold or
    # shipped and run through one `xargs -0` exec above it, same shape as
    # the directory pass above.
    local files_file
    files_file="$(mktemp "${TMPDIR:-/tmp}/dxe-restore-push-files.XXXXXX")" || return 1
    for path in "${target_list[@]}"; do printf '%s/%s\n' "$DX_BACKUP_GUEST_ROOT" "$path"; done > "$files_file"
    local files_guest_list
    if files_guest_list="$(dx_backup_ship_list "$container_name" "$files_file" "${#target_list[@]}")"; then
        if [ -n "$files_guest_list" ]; then
            dx_runtime_exec -u root "$container_name" sh -c 'tr "\n" "\0" < "$1" | xargs -0 chown -h dx:dx' -- "$files_guest_list" || rc=$?
            dx_backup_remove_guest_list "$container_name" "$files_guest_list"
        else
            local -a full_paths=()
            while IFS= read -r path; do full_paths+=("$path"); done < "$files_file"
            dx_runtime_exec -u root "$container_name" chown -h dx:dx "${full_paths[@]}" || rc=$?
        fi
    else
        rc=1
    fi
    rm -f "$files_file"
    return "$rc"
}
