#!/usr/bin/env bash
# Shared "relocate a live directory into /persist and link" primitive
# (Fable B9): before this, gh (bootstrap/persistence.sh), Herdr config and
# Herdr state (also bootstrap/persistence.sh, byte-identical to each other
# apart from names), OpenCode (scripts/lib/dx-opencode-persistence.sh), and
# both AI-credential sites (bootstrap/activation.sh's root-context `ln -sfn`,
# scripts/dx-ai.sh's dx-context `ln -sfnT`) each implemented this migrate/
# link/conflict-rename shape by hand, with a behavioral divergence between
# the two AI-credential sites: activation.sh's `ln -sfn` (no -T) nested a
# symlink inside a pre-existing real ~/.claude instead of refusing, and
# dx-ai.sh's `ln -sfnT` correctly refused but in a `||` context whose failure
# never surfaced. Safe to source (import-only).
#
# Root/dx-agnostic: this file never checks or changes user identity by
# itself. A conflict backup's ownership/mode is fixed up only when `dx`
# actually exists as a user (`id -u dx`/`id -g dx`, the same inline test
# dx_prepare_owned_directory already uses elsewhere in this codebase) --
# true for a root bootstrap caller, harmlessly true-and-a-no-op for a
# dx-native caller already running as dx, and false (skipped) in a plain
# unit-test sandbox with no such account. Directory creation goes through
# dx_prepare_owned_directory when THAT function is in scope (declare -F),
# exactly as dx-opencode-persistence.sh's own dx_opencode_prepare_directory
# already did before this consolidation; publishing the symlink itself goes
# through run_as_dx (a root bootstrap caller's own privilege-drop primitive)
# the same way when THAT is in scope, so a root caller's symlink ends up
# dx-owned exactly as it did before this consolidation -- a dx-native caller
# (dx-ai.sh) has no such function in scope and just links directly.
#
# OpenCode (dx-opencode-persistence.sh) is NOT rewired to call
# dx_persist_relocate_dir/dx_persist_migrate_live_path directly: its own
# dx_opencode_migrate_live_path is pinned, by name and by its exact
# `.dxe-conflict-<item>`/`.dxe-conflict-live-opencode` backup naming (no
# label segment), to direct unit tests in tests/test_sourceable_coverage.sh
# (out of this work package's edit scope). It keeps its own copy of that one
# orchestration function, but delegates its three sub-primitives --
# dx_opencode_unused_path, dx_opencode_prepare_directory,
# dx_opencode_publish_link -- to the shared ones below, which have the
# identical algorithm under the identical 2-argument contract those direct
# tests already exercise.

# Returns an unused path under $1's own directory -- $1 itself, then
# $1.<pid>, then $1.<pid>.<n> -- so a conflict backup never overwrites an
# earlier one, even across repeated calls within the same process.
dx_persist_unused_path() {
    local prefix="$1" candidate="$1.$$" suffix=0
    while [ -e "$candidate" ] || [ -L "$candidate" ]; do
        suffix=$((suffix + 1))
        candidate="$prefix.$$.$suffix"
    done
    printf '%s\n' "$candidate"
}

# Ensures $1 exists as a plain, non-symlink directory at mode $2.
dx_persist_prepare_directory() {
    local directory="$1" mode="$2"
    if [ ! -d "$directory" ]; then
        if declare -F dx_prepare_owned_directory >/dev/null; then
            dx_prepare_owned_directory "$directory" "$mode" || return 1
        else
            mkdir "$directory" || return 1
        fi
    elif [ "$mode" = 0700 ] && declare -F dx_prepare_owned_directory >/dev/null; then
        dx_prepare_owned_directory "$directory" "$mode" || return 1
    fi
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    [ "$mode" != 0700 ] || chmod 0700 "$directory"
}

# A conflict backup may hold data that used to live under a private (0700)
# directory; give it the same privacy regardless of what it displaced,
# handing it dx:dx ownership only where a `dx` account actually exists.
dx_persist_secure_backup() {
    local backup="$1"
    if id -u dx >/dev/null 2>&1 && id -g dx >/dev/null 2>&1; then
        chown -h dx:dx "$backup" || return 1
    fi
    chmod 0700 "$backup" || return 1
}

# Ensures $1 (the persistent target) exists as a plain, non-symlink
# directory at mode 0700, backing up anything else already occupying that
# exact path (a stray non-directory, e.g. a legacy config target) aside
# under $2, labeled with $3, first. Idempotent and safe to call on every
# activation, not just the first: a repeat run with nothing to repair is a
# no-op past dx_persist_prepare_directory's own mode/ownership repair.
dx_persist_prepare_relocate_target() {
    local persistent="$1" backup_parent="$2" label="$3" backup
    if [ -e "$persistent" ] && [ ! -d "$persistent" ] && [ ! -L "$persistent" ]; then
        backup="$(dx_persist_unused_path "$backup_parent/.dxe-conflict-$label-target")" || return 1
        mv "$persistent" "$backup" || return 1
        dx_persist_secure_backup "$backup" || return 1
    fi
    dx_persist_prepare_directory "$persistent" 0700
}

# Moves $1's own content into $2 (renaming any name already occupying the
# destination aside, under $3, labeled with $4, rather than overwriting it),
# then removes $1 itself -- but does nothing when $1 is already a symlink
# (whether or not it points at $2; dx_persist_publish_link is what refuses
# one pointing anywhere else). Assumes $2 already exists as a plain
# directory (dx_persist_prepare_relocate_target's job, called first by
# dx_persist_relocate_dir below) -- deliberately not repeated here, so a
# repeat call whose only work is mode/ownership repair does not also pay
# for re-checking every already-migrated item.
dx_persist_migrate_live_path() {
    local live="$1" persistent="$2" backup_parent="$3" label="$4" item destination backup
    [ ! -L "$live" ] || return 0
    if [ -d "$live" ] && [ ! -L "$live" ]; then
        for item in "$live"/* "$live"/.[!.]* "$live"/..?*; do
            [ -e "$item" ] || [ -L "$item" ] || continue
            destination="$persistent/${item##*/}"
            if [ -e "$destination" ] || [ -L "$destination" ]; then
                backup="$(dx_persist_unused_path "$backup_parent/.dxe-conflict-$label-${item##*/}")" || return 1
                mv "$item" "$backup" || return 1
                dx_persist_secure_backup "$backup" || return 1
            else
                mv "$item" "$destination" || return 1
            fi
        done
        rmdir "$live" || return 1
    elif [ -e "$live" ]; then
        backup="$(dx_persist_unused_path "$backup_parent/.dxe-conflict-$label-live")" || return 1
        mv "$live" "$backup" || return 1
        dx_persist_secure_backup "$backup" || return 1
    fi
}

# Publishes $2 as a symlink to $1: a no-op if it already is one, an atomic
# temp-then-rename otherwise (never leaving a stray temp link behind on
# failure), and a refusal -- not a silent nested symlink -- when $2 is
# occupied by anything else (a real directory/file, or a symlink elsewhere).
#
# $3 (as_dx, default 0/unset): when true AND run_as_dx (bootstrap/common.sh's
# own privilege-drop primitive) is in scope, publishes the link through it,
# exactly as gh/Herdr's own prior `run_as_dx "ln -sfnT ..."` calls did --
# an explicit, caller-chosen opt-in rather than an automatic declare -F
# check, because this file is sourced into test processes that source
# bootstrap/common.sh for unrelated reasons (bringing the REAL run_as_dx,
# which shells out to setpriv, into scope) without themselves wanting a
# privilege-dropped publish; OpenCode's own dx_opencode_publish_link (which
# delegates here) is one such caller and always leaves this unset,
# preserving its pre-existing, always-direct behavior byte for byte. A
# dx-native caller (dx-ai.sh) also leaves it unset, since it is already
# running as dx.
dx_persist_publish_link() {
    local target="$1" live="$2" as_dx="${3:-0}" temporary
    if [ -L "$live" ] && [ "$(readlink "$live")" = "$target" ]; then return 0; fi
    [ ! -e "$live" ] && [ ! -L "$live" ] || return 1
    if [ "$as_dx" = 1 ] && declare -F run_as_dx >/dev/null; then
        run_as_dx "ln -sfnT '$target' '$live'"
        return $?
    fi
    temporary="$(dx_persist_unused_path "$live.dxe-link")" || return 1
    ln -s "$target" "$temporary" || return 1
    if ! mv -f "$temporary" "$live"; then rm -f "$temporary"; return 1; fi
}

# The combined operation gh/the AI-credential sites actually want: prepare
# $2 (the persistent target), relocate $1's content into it, and leave $1
# linked to it. $5 is dx_persist_publish_link's own as_dx. Herdr's own config
# side calls the three steps (dx_persist_prepare_relocate_target,
# dx_persist_migrate_live_path, dx_persist_publish_link) directly instead,
# because it needs a seam between migration and publishing to re-validate a
# readiness marker; its state side uses this combined form, as gh and the
# root-context AI-credential site do.
dx_persist_relocate_dir() {
    local live="$1" persistent="$2" backup_parent="$3" label="$4" as_dx="${5:-0}"
    dx_persist_prepare_relocate_target "$persistent" "$backup_parent" "$label" || return 1
    dx_persist_migrate_live_path "$live" "$persistent" "$backup_parent" "$label" || return 1
    dx_persist_publish_link "$persistent" "$live" "$as_dx" || return 1
}
