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
#
# An indexed array, not a space-separated string: a `for pattern in $VAR`
# word list undergoes BOTH word-splitting AND pathname (glob) expansion
# against the current directory, so an unquoted string here would silently
# let a CWD entry that happens to match one of these globs (e.g. a file
# actually named "result-bin") replace the pattern word itself before it is
# ever compared -- breaking the deny check for every OTHER path that pattern
# was meant to match. Iterated with "${arr[@]}" (quoted), which performs
# neither. See dx_pbs_path_denied.
DX_PBS_BUILTIN_COMPONENT_DENY=(node_modules target .direnv result 'result-*' __pycache__ .cache dist build .venv .tox .pytest_cache .mypy_cache .pnpm-store '.Trash-*' .tmp)

# The SAME list, rendered ONCE as a `find` prune predicate:
# ( -name a -o -name b -o ... ). Generated here, from
# DX_PBS_BUILTIN_COMPONENT_DENY, rather than hand-duplicated as a literal
# `-name`/`-o` chain at each of the four `find` call sites below
# (dx_pbs_walk_repo_files's two branches, dx_pbs_list_outside_repos's two
# branches): five independent hand-synced copies (the four plus this
# variable) can silently drift the moment one is edited and the others are
# not -- exactly the failure mode the matcher/walker equivalence property
# test in tests/test_persist_backup_select.sh guards against. Every `find`
# site below wraps this in its OWN `\( ... \)` group (a `-prune` predicate
# needs the parens at the use site, not baked into the array, so a site
# that ALSO prunes `.git` or nested-repo paths can `-o` them into the same
# group).
DX_PBS_COMPONENT_PRUNE=()
for _dx_pbs_p in "${DX_PBS_BUILTIN_COMPONENT_DENY[@]}"; do
    [ "${#DX_PBS_COMPONENT_PRUNE[@]}" -eq 0 ] || DX_PBS_COMPONENT_PRUNE+=(-o)
    DX_PBS_COMPONENT_PRUNE+=(-name "$_dx_pbs_p")
done
unset _dx_pbs_p

# Built-in path-shaped deny patterns, matched as an ANCHORED glob against the
# full path relative to the backup root (e.g. /persist). Unlike the component
# list above, these describe a specific location, not a bare directory name.
# home/dx/.gemini/antigravity-cli is the `agy` binary/state bundle `dx-ai`
# reinstalls (see scripts/dx-ai.sh and bootstrap/activation.sh); its sibling
# config/credentials elsewhere under .gemini stay in.
#
# An indexed array for the same CWD-glob-expansion reason as
# DX_PBS_BUILTIN_COMPONENT_DENY above.
DX_PBS_BUILTIN_PATH_DENY=('home/dx/.local/state/dx-ai/generations/*/profile' home/dx/.gemini/antigravity-cli)

# Extra deny patterns from DX_BACKUP_EXCLUDE_FILE (one per line) or extra
# positional arguments, passed in by the caller (bin/dx-backup) after the
# root. Matched the same way as DX_PBS_BUILTIN_PATH_DENY: an anchored glob
# against the full relative path. Stored in a global rather than threaded
# through every recursive call for the same reason DX_PBS_BUILTIN_* are
# globals.
#
# An indexed array, one element per pattern -- for the same CWD-glob-
# expansion reason as DX_PBS_BUILTIN_COMPONENT_DENY above, AND so that
# dx_pbs_list_driver's `DX_PBS_EXTRA_DENY=("$@")` keeps every extra pattern
# its own element (never a `$*`-joined string): a pattern containing a
# space, or a sibling pattern passed alongside it, can then never bleed
# into another.
DX_PBS_EXTRA_DENY=()

# True (0) if $1, a path relative to the backup root (no leading slash), is
# denied by the built-in deny-list or DX_PBS_EXTRA_DENY.
dx_pbs_path_denied() {
    local relpath="$1" pattern remainder component
    # "${DX_PBS_EXTRA_DENY[@]+"${DX_PBS_EXTRA_DENY[@]}"}", not a bare
    # "${DX_PBS_EXTRA_DENY[@]}": Bash 3.2 (this file's own floor -- see the
    # module header) treats a zero-element array as unset when expanded
    # under `set -u`, so a bare expansion would abort every caller with no
    # extra deny patterns (the common case) with "unbound variable". Same
    # idiom this file already uses at dx_pbs_walk_repo_files's nested_prune.
    # DX_PBS_BUILTIN_PATH_DENY is never empty (a fixed built-in list), so it
    # needs no such guard.
    for pattern in "${DX_PBS_BUILTIN_PATH_DENY[@]}" "${DX_PBS_EXTRA_DENY[@]+"${DX_PBS_EXTRA_DENY[@]}"}"; do
        # $pattern is deliberately unquoted HERE (inside the case pattern):
        # it is a glob pattern (may contain `*`), not a literal, and the
        # deny-list's whole point is glob matching (result-*,
        # generations/*/profile, user patterns). A case pattern position
        # does not undergo word-splitting or pathname expansion, only the
        # `for` loop above did (fixed by quoting the array expansion there).
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
        for pattern in "${DX_PBS_BUILTIN_COMPONENT_DENY[@]}"; do
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
#
# $3, if given, is a file listing OTHER discovered repositories nested
# inside $1 (one absolute path per line, from dx_pbs_nested_repos_for):
# each is pruned as its own boundary too, in BOTH branches. Without this, a
# repo containing another independent repo as a plain subdirectory (not a
# submodule -- found live, 2026-09-27: git/shopping/scraper nested inside
# git/shopping) would have its content walked twice: once here (as plain
# files, or as .git contents in keep-git mode) and again by the nested
# repo's own, separate dx_pbs_emit_repo pass -- producing a duplicate path
# in the listing (which broke the guest's tar: a repeated path is
# indistinguishable from a hardlink to itself). The nested repo's own pass
# is the sole, correct source for its content either way (its own
# safe/whole-repo status, evaluated independently).
dx_pbs_walk_repo_files() {
    local dir="$1" keep_git="${2:-}" nested_file="${3:-}"
    local -a nested_prune=()
    if [ -n "$nested_file" ] && [ -s "$nested_file" ]; then
        local nrepo
        while IFS= read -r nrepo; do
            [ -n "$nrepo" ] || continue
            case "$nrepo" in
                "$dir"/*) nested_prune+=(-o -path "./${nrepo#"$dir"/}") ;;
            esac; :; done < "$nested_file"
    fi
    ( cd "$dir" 2>/dev/null || exit 0
      if [ "$keep_git" = keep-git ]; then
          find . \( \
                "${DX_PBS_COMPONENT_PRUNE[@]}" \
                "${nested_prune[@]+"${nested_prune[@]}"}" \
            \) -prune -o \( -type f -o -type l \) -print0 2>/dev/null
      else
          find . \( -name .git -o \( \
                "${DX_PBS_COMPONENT_PRUNE[@]}" \
                "${nested_prune[@]+"${nested_prune[@]}"}" \
            \) \) -prune -o \( -type f -o -type l \) -print0 2>/dev/null
      fi | while IFS= read -r -d '' entry; do printf '%s\0' "${entry#./}"; done
    ) # KCOV_SUBSHELL_TERMINATOR
}

# Write (to $3), one absolute path per line, every OTHER repository in
# REPOS_FILE $2 that is strictly nested inside repo $1 (a proper
# descendant, never $1 itself). Used to make dx_pbs_walk_repo_files prune
# at every nested repository's boundary, so its content is handled exactly
# once, by its own pass.
dx_pbs_nested_repos_for() {
    local repo="$1" repos_file="$2" outfile="$3" other
    : > "$outfile"
    while IFS= read -r other; do
        [ -n "$other" ] || continue
        case "$other" in
            "$repo"/*) printf '%s\n' "$other" >> "$outfile" ;;
        esac; :; done < "$repos_file"
}

# Emit one TSV listing line per newline-delimited relative path in list-file
# $3 (already denied-filtered by the caller): path<TAB>size<TAB>mtime<TAB>sha256,
# plus a 5th <TAB>reason column when $4 is non-empty. A single emitter shared
# by the whole-repo, safe-repo and outside-repo cases (below) so the reason
# column has exactly one place it is appended, rather than three.
dx_pbs_emit_found_list() {
    local repo="$1" relroot="$2" list_file="$3" reason="${4:-}" found relpath hashed
    while IFS= read -r found; do
        [ -n "$found" ] || continue
        relpath="$relroot/$found"
        dx_pbs_path_denied "$relpath" && continue
        hashed="$(dx_pbs_hash_entry "$repo/$found")" || continue
        # Single line (this file's own convention, see
        # dx_pbs_walk_repo_files's comment): a bare `fi`/`done` keyword
        # starts no traceable command of its own, so kcov never registers a
        # hit on a `fi` (or `done < FILE`) line by itself -- the whole
        # if/else/fi, AND `done < FILE`, must share a line with a real
        # command (either printf here) to be measured as covered.
        if [ -n "$reason" ]; then printf '%s\t%s\t%s\n' "$relpath" "$hashed" "$reason"; else printf '%s\t%s\n' "$relpath" "$hashed"; fi; done < "$list_file"
}

# Emit TSV listing lines (path relative to $DX_PBS_ROOT is $2 + "/" + found,
# unless $2 is empty) for every file under repo $1, unconditionally (the
# at-risk-whole case): everything in the work tree, including .git/**,
# except deny-listed paths. $3 non-empty selects --with-reason mode (reason
# is always "whole-repo" here: the entire repo is at risk, not just a subset
# of its files).
dx_pbs_emit_repo_whole() {
    local repo="$1" relroot="$2" reason_mode="${3:-}" nested_file="${4:-}" list_file
    list_file="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-whole.XXXXXX")" || return 1
    dx_pbs_walk_repo_files "$repo" keep-git "$nested_file" | while IFS= read -r -d '' entry; do printf '%s\n' "$entry"; done > "$list_file"
    if [ -n "$reason_mode" ]; then
        dx_pbs_emit_found_list "$repo" "$relroot" "$list_file" whole-repo
    else
        dx_pbs_emit_found_list "$repo" "$relroot" "$list_file"
    fi
    rm -f "$list_file"
}

# Emit TSV listing lines for repo $1's at-risk files only: everything the
# working-tree walk finds MINUS the tracked-and-clean set, minus deny-listed
# paths. `.git` itself is pruned entirely -- a safe repo's history is, by
# definition, already reachable via its remote.
#
# $3 non-empty selects --with-reason mode. The at-risk delta is then split
# into two further reasons by set membership against `git ls-files --others
# --ignored --exclude-standard` (files this walk includes precisely BECAUSE
# it does not consult .gitignore, unlike a plain `git status`):
#   ignored-kept        -- gitignored, kept anyway (never silently dropped).
#   modified-untracked  -- tracked+modified, staged, or untracked-not-ignored.
# Both splits are plain `comm` set operations over already-sorted files, not
# a per-file check: the guest's dx profile has no `awk` (see
# dx_pbs_sha256_stdin's own comment), and a per-file subprocess for
# classification would double this function's already-per-file hashing cost.
dx_pbs_emit_repo_safe() {
    local repo="$1" relroot="$2" reason_mode="${3:-}" nested_file="${4:-}"
    local clean_set found_file delta_set ignored_set ik_set mu_set
    clean_set="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-clean.XXXXXX")" || return 1
    dx_pbs_repo_clean_set "$repo" "$clean_set"
    found_file="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-found.XXXXXX")" || { rm -f "$clean_set"; return 1; }
    dx_pbs_walk_repo_files "$repo" "" "$nested_file" | while IFS= read -r -d '' entry; do printf '%s\n' "$entry"; done | LC_ALL=C sort > "$found_file"
    delta_set="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-delta.XXXXXX")" || { rm -f "$clean_set" "$found_file"; return 1; }
    comm -23 "$found_file" "$clean_set" > "$delta_set"

    if [ -n "$reason_mode" ]; then
        ignored_set="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-ignored.XXXXXX")" || { rm -f "$clean_set" "$found_file" "$delta_set"; return 1; }
        git -C "$repo" ls-files --others --ignored --exclude-standard 2>/dev/null | LC_ALL=C sort > "$ignored_set"
        ik_set="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-ik.XXXXXX")" || { rm -f "$clean_set" "$found_file" "$delta_set" "$ignored_set"; return 1; }
        mu_set="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-mu.XXXXXX")" || { rm -f "$clean_set" "$found_file" "$delta_set" "$ignored_set" "$ik_set"; return 1; }
        comm -12 "$delta_set" "$ignored_set" > "$ik_set"
        comm -23 "$delta_set" "$ignored_set" > "$mu_set"
        dx_pbs_emit_found_list "$repo" "$relroot" "$ik_set" ignored-kept
        dx_pbs_emit_found_list "$repo" "$relroot" "$mu_set" modified-untracked
        rm -f "$ignored_set" "$ik_set" "$mu_set"
    else
        dx_pbs_emit_found_list "$repo" "$relroot" "$delta_set"
    fi

    rm -f "$clean_set" "$found_file" "$delta_set"
}

# Dispatch repo $1 (relative root $2) to the whole-repo or safe-repo emitter
# depending on dx_pbs_repo_at_risk_whole. A single dispatcher call, rather
# than an inline if/else, keeps dx_pbs_list's own per-repo loop a one-line
# body -- an if/else block ending in only its own `fi` keyword (no real
# command) does not give kcov anything to register a hit against on the
# line shared with `done`, the same class of issue as an empty case arm.
dx_pbs_emit_repo() {
    local repo="$1" relroot="$2" reason_mode="${3:-}" repos_file="${4:-}" nested_file=""
    if [ -n "$repos_file" ]; then
        nested_file="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-nested.XXXXXX")" || return 1
        dx_pbs_nested_repos_for "$repo" "$repos_file" "$nested_file"
    fi
    if dx_pbs_repo_at_risk_whole "$repo"; then
        dx_pbs_emit_repo_whole "$repo" "$relroot" "$reason_mode" "$nested_file"
    else
        dx_pbs_emit_repo_safe "$repo" "$relroot" "$reason_mode" "$nested_file"
    fi
    [ -z "$nested_file" ] || rm -f "$nested_file"
}

# ---------------------------------------------------------------------------
# Main listing driver
# ---------------------------------------------------------------------------

# Shared driver for dx_pbs_list and dx_pbs_list_with_reason (below): $1 is
# the reason_mode flag (empty for the plain listing, non-empty for
# --with-reason), $2 is ROOT, and the rest are EXTRA_DENY_PATTERNs. Prints
# the full at-risk TSV listing on stdout -- path<TAB>size<TAB>mtime<TAB>sha256,
# plus a 5th <TAB>reason column in --with-reason mode -- and a one-line
# summary of skipped special files (sockets/fifos/devices) to stderr.
dx_pbs_list_driver() {
    local reason_mode="$1" root="$2" repos_file repo relroot special_count
    shift 2
    # DX_PBS_EXTRA_DENY=("$@"), not DX_PBS_EXTRA_DENY="$*": "$*" joins every
    # remaining positional argument into ONE space-separated string,
    # flattening N separate extra-deny patterns (DX_BACKUP_EXCLUDE_FILE is
    # one pattern per line, each its own positional argument by the time it
    # reaches here -- see bin/dx-backup) into a single record before
    # dx_pbs_path_denied ever sees them. That breaks a pattern containing a
    # space (it silently merges with whichever pattern follows it) and,
    # even for space-free patterns, makes it impossible to tell where one
    # pattern ends and the next begins. An array preserves each argument as
    # its own element, matched one at a time, exactly like
    # DX_PBS_BUILTIN_PATH_DENY above.
    DX_PBS_EXTRA_DENY=("$@")
    root="${root%/}"
    [ -d "$root" ] || { echo "Error: backup root $root does not exist or is not a directory." >&2; return 1; }

    repos_file="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-repos.XXXXXX")" || return 1
    dx_pbs_find_repos "$root" > "$repos_file"

    special_count="$(find "$root" \( -type s -o -type p -o -type b -o -type c \) 2>/dev/null | wc -l | tr -d '[:space:]')"

    # Outside-any-repository files: walk the whole tree, pruning at every
    # discovered repository root (each is handled by its own pass below) and
    # every deny-listed directory name.
    dx_pbs_list_outside_repos "$root" "$repos_file" "$reason_mode"

    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        relroot="${repo#"$root"/}"
        [ "$relroot" != "$repo" ] || relroot="."
        dx_pbs_emit_repo "$repo" "$relroot" "$reason_mode" "$repos_file"; done < "$repos_file"

    rm -f "$repos_file"
    echo "Selector summary: ${special_count:-0} special file(s) (socket/fifo/device) skipped." >&2
}

# dx_pbs_list ROOT [EXTRA_DENY_PATTERN...]
#
# Prints the full at-risk TSV listing (path<TAB>size<TAB>mtime<TAB>sha256,
# path relative to ROOT) on stdout. Prints a one-line summary of skipped
# special files (sockets/fifos/devices) to stderr.
dx_pbs_list() {
    dx_pbs_list_driver "" "$@"
}

# dx_pbs_list_with_reason ROOT [EXTRA_DENY_PATTERN...]
#
# Same as dx_pbs_list, but each line carries a 5th <TAB>reason column:
# modified-untracked, whole-repo, outside-repo, or ignored-kept (see this
# file's module header and dx_pbs_emit_repo_safe's comment). Used by
# `bin/dx-backup --dry-run --summary` (Branch 17) to aggregate the at-risk
# selection by reason without dx-backup.sh duplicating any selection rule.
dx_pbs_list_with_reason() {
    dx_pbs_list_driver reason "$@"
}

dx_pbs_list_outside_repos() {
    local root="$1" repos_file="$2" reason_mode="${3:-}" prune_expr=() repo found relpath hashed
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
                "${DX_PBS_COMPONENT_PRUNE[@]}" \
            \) -prune -o \( -type f -o -type l \) -print0 2>/dev/null
    else
        find "$root" \( \
                "${DX_PBS_COMPONENT_PRUNE[@]}" \
            \) -prune -o \( -type f -o -type l \) -print0 2>/dev/null
    fi | while IFS= read -r -d '' found; do
        relpath="${found#"$root"/}"
        dx_pbs_path_denied "$relpath" && continue
        hashed="$(dx_pbs_hash_entry "$found")" || continue
        if [ -n "$reason_mode" ]; then
            printf '%s\t%s\toutside-repo\n' "$relpath" "$hashed"
        else
            printf '%s\t%s\n' "$relpath" "$hashed"
        fi
    done
}

# ---------------------------------------------------------------------------
# --hash-paths / --hash-paths-file mode: restore's conflict-check probe
# ---------------------------------------------------------------------------

# Print one line for RELPATH $2 (relative to ROOT $1):
#   relpath<TAB>present<TAB>size<TAB>mtime<TAB>sha256
#   relpath<TAB>missing
# Shared by dx_pbs_hash_paths (argv) and dx_pbs_hash_paths_file (a file, one
# path per line -- for a batch large enough that argv risks the host's
# ARG_MAX; see bin/lib/dx-backup.sh's DX_BACKUP_HASH_PATHS_ARG_THRESHOLD).
dx_pbs_hash_one() {
    local root="$1" relpath="$2" hashed
    if [ -e "$root/$relpath" ] || [ -L "$root/$relpath" ]; then
        hashed="$(dx_pbs_hash_entry "$root/$relpath")" || { printf '%s\tmissing\n' "$relpath"; return; }
        printf '%s\tpresent\t%s\n' "$relpath" "$hashed"
    else
        printf '%s\tmissing\n' "$relpath"
    fi
}

# dx_pbs_hash_paths ROOT [RELPATH...]
dx_pbs_hash_paths() {
    local root="$1" relpath
    shift
    root="${root%/}"
    for relpath in "$@"; do
        dx_pbs_hash_one "$root" "$relpath"
    done
}

# dx_pbs_hash_paths_file ROOT LISTFILE
#
# Same output as dx_pbs_hash_paths, but reads RELPATHs one per line from
# LISTFILE instead of argv.
dx_pbs_hash_paths_file() {
    local root="$1" listfile="$2" relpath
    root="${root%/}"
    while IFS= read -r relpath || [ -n "$relpath" ]; do
        [ -n "$relpath" ] || continue
        # See dx_pbs_emit_found_list's comment: `done < FILE` shares the
        # loop's last real command's line so kcov can register a hit on it.
        dx_pbs_hash_one "$root" "$relpath"; done < "$listfile"
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
        --hash-paths-file)
            shift
            dx_pbs_hash_paths_file "$@"
            ;;
        --with-reason)
            shift
            dx_pbs_list_with_reason "$@"
            ;;
        '')
            echo "Usage: dx-persist-backup-select.sh ROOT [DENY_PATTERN...]" >&2
            echo "       dx-persist-backup-select.sh --with-reason ROOT [DENY_PATTERN...]" >&2
            echo "       dx-persist-backup-select.sh --hash-paths ROOT [RELPATH...]" >&2
            echo "       dx-persist-backup-select.sh --hash-paths-file ROOT LISTFILE" >&2
            return 64
            ;;
        *)
            dx_pbs_list "$@"
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -uo pipefail; dx_pbs_main "$@"; fi
