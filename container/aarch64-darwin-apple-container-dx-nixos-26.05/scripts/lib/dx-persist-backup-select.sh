#!/usr/bin/env bash
# Selection-rule library for the /persist backup (Branch 10, plan.md B1).
#
# Sourceable, pure function set: every function is parameterised by a root
# directory, so the exact same code runs two ways with no duplication --
#   1. Sourced directly on the host against a fixture tree (no container),
#      for the unit tests in tests/test_persist_backup_select.sh.
#   2. Shipped to the guest through the existing bootstrap-volume sync
#      (dx-sync-bootstrap publishes the whole container/.../ context tree,
#      including scripts/lib/*.sh, with no Nix rebuild -- exactly how
#      dx-opencode-persistence.sh already reaches the guest) and executed
#      directly there as $DX_BOOTSTRAP_PATH/current/scripts/lib/dx-persist-backup-select.sh,
#      invoked over `container exec` by bin/dx-backup and bin/dx-restore.
#
# This file is too large to be a one-screen guest-bash snippet (it is a
# small library: repo discovery, the at-risk-whole check, the deny-list
# matcher, hashing, the listing driver, and a --hash-paths mode for
# dx-restore's conflict check), so it is shipped as its own file rather than
# embedded inline -- the same reasoning dx-opencode-persistence.sh documents.
#
# Written in Bash-3.2-compatible style throughout (indexed arrays only, no
# associative arrays, no `${x,,}`) because bin/lib/dx-backup.sh sources this
# file directly for host-side use, and macOS's /bin/bash (which every bin/dx-*
# script runs under) is 3.2. The guest's own Bash is newer but happily runs
# this same subset.
#
# Known, deliberate limitations (documented rather than engineered around,
# consistent with this codebase's existing TSV/plumbing formats elsewhere,
# e.g. bin/lib/dx-container.sh's Nix-volume claim records):
#   - Paths containing a literal tab or newline are not supported: the
#     listing format is TSV, one record per line.
#   - A `.git` that is a FILE rather than a directory (a linked worktree or a
#     submodule pointer) is not recognised as a repository boundary. Such a
#     path falls through to "outside any repository -> always at-risk" (the
#     safe default: it is never silently dropped), and a warning is printed
#     to stderr so a live run surfaces it for a decision rather than quietly
#     picking one.

# ---------------------------------------------------------------------------
# Deny-list
# ---------------------------------------------------------------------------

# Built-in rebuildable-cache directory names, matched as a path COMPONENT at
# any depth (so "node_modules" also denies "a/b/node_modules/c"). Glob
# patterns (result-*) are supported.
DX_PBS_BUILTIN_COMPONENT_DENY="node_modules target .direnv result result-* __pycache__ .cache dist build .venv .tox .pytest_cache .mypy_cache"

# Built-in path-shaped deny patterns, matched as an ANCHORED glob against the
# full path relative to the backup root (e.g. /persist). Unlike the component
# list above, these describe a specific location, not a bare directory name.
DX_PBS_BUILTIN_PATH_DENY="home/dx/.local/state/dx-ai/generations/*/profile"

# Extra deny patterns from DX_BACKUP_EXCLUDE_FILE (one per line), passed in by
# the caller (bin/dx-backup) as extra positional arguments after the root.
# Matched the same way as DX_PBS_BUILTIN_PATH_DENY: an anchored glob against
# the full relative path. Stored in a global rather than threaded through
# every recursive call for the same reason DX_PBS_BUILTIN_* are globals.
DX_PBS_EXTRA_DENY=""

# True (0) if $1, a path relative to the backup root (no leading slash), is
# denied by the built-in deny-list or DX_PBS_EXTRA_DENY.
dx_pbs_path_denied() {
    local relpath="$1" pattern remainder component
    for pattern in $DX_PBS_BUILTIN_PATH_DENY $DX_PBS_EXTRA_DENY; do
        # $pattern is deliberately unquoted: it is a glob pattern (may
        # contain `*`), not a literal, and the deny-list's whole point is
        # glob matching (result-*, generations/*/profile, user patterns).
        # shellcheck disable=SC2254
        case "$relpath" in
            $pattern | $pattern/*) return 0 ;;
        esac
    done
    remainder="$relpath"
    while [ -n "$remainder" ]; do
        case "$remainder" in
            */*) component="${remainder%%/*}"; remainder="${remainder#*/}" ;;
            *) component="$remainder"; remainder="" ;;
        esac
        for pattern in $DX_PBS_BUILTIN_COMPONENT_DENY; do
            # See the disable above: $pattern is an intentional glob (result-*).
            # shellcheck disable=SC2254
            case "$component" in
                $pattern) return 0 ;;
            esac
        done
    done
    return 1
}

# ---------------------------------------------------------------------------
# Repository discovery and at-risk-whole determination
# ---------------------------------------------------------------------------

# Print (newline-delimited; repo directories never contain a raw newline in
# practice and this matches every other listing in this file) every directory
# under $1 that directly contains a `.git` DIRECTORY (not file -- see the
# module comment). Prunes descent into deny-listed directory names and does
# not descend past a discovered repo root's `.git` itself. `.git` FILES are
# reported to stderr as a warning and otherwise ignored (see module comment).
dx_pbs_find_repos() {
    local root="$1" entry
    find "$root" -name .git -print0 2>/dev/null | while IFS= read -r -d '' entry; do
        if [ -f "$entry" ]; then
            echo "Warning: $entry is a file, not a directory (a linked worktree or submodule); it is not treated as a repository boundary. See docs/lifecycle.md." >&2
            continue
        fi
        [ -d "$entry" ] || continue
        dirname "$entry"
    done
}

# True (0) if the repository at $1 is at-risk as a whole: it has commits on a
# local branch not reachable from any remote, or it has no remote at all.
dx_pbs_repo_at_risk_whole() {
    local repo="$1" remote_count unpushed
    remote_count="$(git -C "$repo" remote 2>/dev/null | wc -l | tr -d '[:space:]')"
    [ "${remote_count:-0}" -gt 0 ] || return 0
    unpushed="$(git -C "$repo" log --branches --not --remotes --oneline 2>/dev/null)"
    [ -n "$unpushed" ]
}

# Write (to $2) the sorted, newline-delimited set of paths (relative to the
# repository at $1) that are tracked AND unchanged from HEAD -- the set to
# EXCLUDE from a "safe" repository's backup, because that content is already
# reachable through a pushed commit. Every other file the repository walk
# finds (modified, staged, untracked, ignored) is included by construction:
# it is simply not in this set.
dx_pbs_repo_clean_set() {
    local repo="$1" outfile="$2" all_file diff_file
    all_file="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-all.XXXXXX")" || return 1
    diff_file="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-diff.XXXXXX")" || { rm -f "$all_file"; return 1; }
    git -C "$repo" ls-tree -r --name-only HEAD 2>/dev/null | LC_ALL=C sort > "$all_file"
    git -C "$repo" diff --name-only HEAD 2>/dev/null | LC_ALL=C sort > "$diff_file"
    comm -23 "$all_file" "$diff_file" > "$outfile"
    rm -f "$all_file" "$diff_file"
}

# ---------------------------------------------------------------------------
# Hashing
# ---------------------------------------------------------------------------

dx_pbs_sha256_stdin() {
    # `cut`, not awk: live-verified on dx-test (2026-09-27) that `awk` is
    # absent from the dx user's guest profile (coreutils/findutils are
    # declared packages; gawk is not -- see bootstrap/activation.sh's own
    # "Live defect: awk was absent..." comment for a related, earlier case).
    # `cut -d' ' -f1` extracts the same leading hash field from either tool's
    # "HASH<sep>name" output using only coreutils, already a hard guest
    # dependency of this file.
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

# size<TAB>mtime<TAB>sha256 for a real file, or for a symlink, the length and
# mtime of the LINK ITSELF (lstat semantics -- both GNU and BSD `stat` report
# the link, not its target, unless told to follow it) and the sha256 of its
# target string (not the target's content): a changed symlink target is then
# a detected change even when the target itself is unreadable or absent.
dx_pbs_hash_entry() {
    local path="$1" size mtime sha target
    if [ -L "$path" ]; then
        target="$(readlink "$path")" || return 1
        size="${#target}"
        mtime="$(dx_pbs_stat_mtime "$path")" || return 1
        sha="$(printf '%s' "$target" | dx_pbs_sha256_stdin)"
    elif [ -f "$path" ]; then
        size="$(dx_pbs_stat_size "$path")" || return 1
        mtime="$(dx_pbs_stat_mtime "$path")" || return 1
        sha="$(dx_pbs_sha256_stdin < "$path")"
    else
        return 1
    fi
    printf '%s\t%s\t%s\n' "$size" "$mtime" "$sha"
}

dx_pbs_stat_size() {
    stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null
}

dx_pbs_stat_mtime() {
    stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Walk drivers
# ---------------------------------------------------------------------------

# Print every regular file or symlink under $1 (a directory), relative to
# $1, NUL-delimited on stdout. Always prunes every deny-listed directory
# name; also prunes `.git` unless $2 is the literal string "keep-git" (the
# at-risk-whole case, which must mirror `.git` too). A single, shared walker
# for both dx_pbs_emit_repo_safe (prunes .git) and dx_pbs_emit_repo_whole
# (keeps it) avoids duplicating the deny-list a third time, and keeps every
# caller's `done < <(...)` a single line -- a multi-line quoted/command-
# substitution argument only registers a coverage hit on its first line.
dx_pbs_walk_repo_files() {
    local dir="$1" keep_git="${2:-}"
    ( cd "$dir" 2>/dev/null || exit 0
      if [ "$keep_git" = keep-git ]; then
          find . \( \
                -name node_modules -o -name target -o -name .direnv -o \
                -name result -o -name 'result-*' -o -name __pycache__ -o \
                -name .cache -o -name dist -o -name build -o -name .venv -o \
                -name .tox -o -name .pytest_cache -o -name .mypy_cache \
            \) -prune -o \( -type f -o -type l \) -print0 2>/dev/null
      else
          find . \( -name .git -o \( \
                -name node_modules -o -name target -o -name .direnv -o \
                -name result -o -name 'result-*' -o -name __pycache__ -o \
                -name .cache -o -name dist -o -name build -o -name .venv -o \
                -name .tox -o -name .pytest_cache -o -name .mypy_cache \
            \) \) -prune -o \( -type f -o -type l \) -print0 2>/dev/null
      fi | while IFS= read -r -d '' entry; do printf '%s\0' "${entry#./}"; done
    )
}

# Emit TSV listing lines (path relative to $DX_PBS_ROOT is $2 + "/" + found,
# unless $2 is empty) for every file under repo $1, unconditionally (the
# at-risk-whole case): everything in the work tree, including .git/**,
# except deny-listed paths.
dx_pbs_emit_repo_whole() {
    local repo="$1" relroot="$2" found relpath hashed
    while IFS= read -r -d '' found; do
        relpath="$relroot/$found"
        dx_pbs_path_denied "$relpath" && continue
        hashed="$(dx_pbs_hash_entry "$repo/$found")" || continue
        printf '%s\t%s\n' "$relpath" "$hashed"; done < <(dx_pbs_walk_repo_files "$repo" keep-git)
}

# Emit TSV listing lines for repo $1's at-risk files only: everything the
# working-tree walk finds MINUS the tracked-and-clean set, minus deny-listed
# paths. `.git` itself is pruned entirely -- a safe repo's history is, by
# definition, already reachable via its remote.
dx_pbs_emit_repo_safe() {
    local repo="$1" relroot="$2" clean_set found_file relpath hashed
    clean_set="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-clean.XXXXXX")" || return 1
    dx_pbs_repo_clean_set "$repo" "$clean_set"
    found_file="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-found.XXXXXX")" || { rm -f "$clean_set"; return 1; }
    dx_pbs_walk_repo_files "$repo" | while IFS= read -r -d '' entry; do printf '%s\n' "$entry"; done | LC_ALL=C sort > "$found_file"
    comm -23 "$found_file" "$clean_set" | while IFS= read -r found; do
        [ -n "$found" ] || continue
        relpath="$relroot/$found"
        dx_pbs_path_denied "$relpath" && continue
        hashed="$(dx_pbs_hash_entry "$repo/$found")" || continue
        printf '%s\t%s\n' "$relpath" "$hashed"
    done
    rm -f "$clean_set" "$found_file"
}

# Dispatch repo $1 (relative root $2) to the whole-repo or safe-repo emitter
# depending on dx_pbs_repo_at_risk_whole. A single dispatcher call, rather
# than an inline if/else, keeps dx_pbs_list's own per-repo loop a one-line
# body -- an if/else block ending in only its own `fi` keyword (no real
# command) does not give kcov anything to register a hit against on the
# line shared with `done`, the same class of issue as an empty case arm.
dx_pbs_emit_repo() {
    local repo="$1" relroot="$2"
    if dx_pbs_repo_at_risk_whole "$repo"; then
        dx_pbs_emit_repo_whole "$repo" "$relroot"
    else
        dx_pbs_emit_repo_safe "$repo" "$relroot"
    fi
}

# ---------------------------------------------------------------------------
# Main listing driver
# ---------------------------------------------------------------------------

# dx_pbs_list ROOT [EXTRA_DENY_PATTERN...]
#
# Prints the full at-risk TSV listing (path<TAB>size<TAB>mtime<TAB>sha256,
# path relative to ROOT) on stdout. Prints a one-line summary of skipped
# special files (sockets/fifos/devices) to stderr.
dx_pbs_list() {
    local root="$1" repos_file repo relroot special_count
    shift
    DX_PBS_EXTRA_DENY="$*"
    root="${root%/}"
    [ -d "$root" ] || { echo "Error: backup root $root does not exist or is not a directory." >&2; return 1; }

    repos_file="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-repos.XXXXXX")" || return 1
    dx_pbs_find_repos "$root" > "$repos_file"

    special_count="$(find "$root" \( -type s -o -type p -o -type b -o -type c \) 2>/dev/null | wc -l | tr -d '[:space:]')"

    # Outside-any-repository files: walk the whole tree, pruning at every
    # discovered repository root (each is handled by its own pass below) and
    # every deny-listed directory name.
    dx_pbs_list_outside_repos "$root" "$repos_file"

    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        relroot="${repo#"$root"/}"
        [ "$relroot" != "$repo" ] || relroot="."
        dx_pbs_emit_repo "$repo" "$relroot"; done < "$repos_file"

    rm -f "$repos_file"
    echo "Selector summary: ${special_count:-0} special file(s) (socket/fifo/device) skipped." >&2
}

dx_pbs_list_outside_repos() {
    local root="$1" repos_file="$2" prune_expr=() repo found relpath hashed
    # find's -path must match the exact string find itself will produce for
    # that entry, so this walk operates on absolute paths throughout (no
    # `cd`+relative form, unlike the per-repo walks below, which have no repo
    # paths to prune and so are free to use the simpler relative form).
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        if [ "${#prune_expr[@]}" -gt 0 ]; then prune_expr+=(-o); fi
        prune_expr+=(-path "$repo"); done < "$repos_file"

    if [ "${#prune_expr[@]}" -gt 0 ]; then
        find "$root" \( \( "${prune_expr[@]}" \) -o \
                -name node_modules -o -name target -o -name .direnv -o \
                -name result -o -name 'result-*' -o -name __pycache__ -o \
                -name .cache -o -name dist -o -name build -o -name .venv -o \
                -name .tox -o -name .pytest_cache -o -name .mypy_cache \
            \) -prune -o \( -type f -o -type l \) -print0 2>/dev/null
    else
        find "$root" \( \
                -name node_modules -o -name target -o -name .direnv -o \
                -name result -o -name 'result-*' -o -name __pycache__ -o \
                -name .cache -o -name dist -o -name build -o -name .venv -o \
                -name .tox -o -name .pytest_cache -o -name .mypy_cache \
            \) -prune -o \( -type f -o -type l \) -print0 2>/dev/null
    fi | while IFS= read -r -d '' found; do
        relpath="${found#"$root"/}"
        dx_pbs_path_denied "$relpath" && continue
        hashed="$(dx_pbs_hash_entry "$found")" || continue
        printf '%s\t%s\n' "$relpath" "$hashed"
    done
}

# ---------------------------------------------------------------------------
# --hash-paths mode: restore's conflict-check probe
# ---------------------------------------------------------------------------

# dx_pbs_hash_paths ROOT [RELPATH...]
#
# For each RELPATH (relative to ROOT), prints one line:
#   relpath<TAB>present<TAB>size<TAB>mtime<TAB>sha256
#   relpath<TAB>missing
dx_pbs_hash_paths() {
    local root="$1" relpath hashed
    shift
    root="${root%/}"
    for relpath in "$@"; do
        if [ -e "$root/$relpath" ] || [ -L "$root/$relpath" ]; then
            hashed="$(dx_pbs_hash_entry "$root/$relpath")" || { printf '%s\tmissing\n' "$relpath"; continue; }
            printf '%s\tpresent\t%s\n' "$relpath" "$hashed"
        else
            printf '%s\tmissing\n' "$relpath"
        fi
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

dx_pbs_main() {
    case "${1:-}" in
        --hash-paths)
            shift
            dx_pbs_hash_paths "$@"
            ;;
        '')
            echo "Usage: dx-persist-backup-select.sh ROOT [DENY_PATTERN...]" >&2
            echo "       dx-persist-backup-select.sh --hash-paths ROOT [RELPATH...]" >&2
            return 64
            ;;
        *)
            dx_pbs_list "$@"
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -uo pipefail; dx_pbs_main "$@"; fi
