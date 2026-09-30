#!/usr/bin/env bash
# Source-only OpenCode persistence helpers shared by dx-ai and activation.

# This file is sourced directly by two independent entry points (dx-ai's
# dx_ai_load_opencode_persistence and bootstrap/activation.sh's own,
# separate loader), neither of which is guaranteed to have already loaded
# scripts/lib/dx-ai-loader.sh's dx_ai_load_library -- so this is its own
# small, self-contained three-candidate loader, sibling-relative rather
# than lib/-relative (this file already lives inside scripts/lib itself;
# see dx-ai.sh's own dx_ai_bootstrap_load for the same reasoning).
dx_opencode_bootstrap_load_persist_relocate() {
    declare -F dx_persist_relocate_dir >/dev/null && return 0
    local script_directory candidate
    script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    for candidate in \
        "$script_directory/dx-persist-relocate.sh" \
        "$HOME/.local/lib/dx/dx-persist-relocate.sh" \
        "${DX_BOOTSTRAP_ROOT:-/guest-bootstrap}/scripts/lib/dx-persist-relocate.sh"; do
        [ -r "$candidate" ] || continue
        # shellcheck source=dx-persist-relocate.sh
        source "$candidate" || return 1
        declare -F dx_persist_relocate_dir >/dev/null && return 0
    done
    echo "Error: persist-relocate library is unavailable." >&2
    return 1
}
dx_opencode_bootstrap_load_persist_relocate \
    || { echo "Error: OpenCode persistence could not load the shared persist-relocate library." >&2; return 1 2>/dev/null || exit 1; }

dx_opencode_validate_directory_path() {
    local path="$1" description="$2" remainder component current=""
    case "$path" in
        /*) : ;;
        *) echo "Error: $description must be an absolute path: $path" >&2; return 1 ;;
    esac
    case "$path" in
        /|*//*|*/./*|*/../*|*/.|*/..) echo "Error: $description is not a normalized directory path: $path" >&2; return 1 ;;
    esac
    remainder="${path#/}"
    while [ -n "$remainder" ]; do
        component="${remainder%%/*}"
        if [ "$component" = "$remainder" ]; then remainder=""; else remainder="${remainder#*/}"; fi
        current="$current/$component"
        if [ -L "$current" ]; then
            echo "Error: refusing symlinked $description component: $current" >&2
            return 1
        fi
        if [ -e "$current" ] && [ ! -d "$current" ]; then
            echo "Error: refusing non-directory $description component: $current" >&2
            return 1
        fi
    done
}

# Fable B9: identical body to scripts/lib/dx-persist-relocate.sh's
# dx_persist_prepare_directory (gh/Herdr/the AI-credential sites' own copy
# of this same primitive) -- delegated rather than duplicated.
dx_opencode_prepare_directory() {
    dx_persist_prepare_directory "$@"
}

# This is deliberately an activation-only operation.  `dx-ai` runs as dx and
# must never attempt to take ownership of persisted paths.  Activation runs at
# the established root privilege boundary, where it can repair the shared XDG
# ancestors that a previous root-run setup may have left as root:root 0755.
# Validate every path before that boundary performs any mkdir, chmod, or chown.
dx_ai_opencode_prepare_activation_ancestors() {
    local persist_home="$1"
    declare -F dx_prepare_owned_directory >/dev/null || {
        echo "Error: OpenCode activation ownership helper is unavailable." >&2
        return 1
    }
    dx_opencode_validate_directory_path "$persist_home/.config" "persistent OpenCode ancestor" || return 1
    dx_opencode_validate_directory_path "$persist_home/.local" "persistent OpenCode ancestor" || return 1
    dx_opencode_validate_directory_path "$persist_home/.local/share" "persistent OpenCode ancestor" || return 1
    dx_prepare_owned_directory "$persist_home/.config" 0755 || return 1
    dx_prepare_owned_directory "$persist_home/.local" 0755 || return 1
    dx_prepare_owned_directory "$persist_home/.local/share" 0755 || return 1
}

# Fable B9: identical body to dx-persist-relocate.sh's dx_persist_unused_path
# -- delegated rather than duplicated.
dx_opencode_unused_path() {
    dx_persist_unused_path "$@"
}

# Kept as OpenCode's own copy rather than delegated to dx-persist-relocate.sh's
# generalized, label-parameterized dx_persist_migrate_live_path: this exact
# function name and its exact `.dxe-conflict-<item>`/`.dxe-conflict-
# live-opencode` backup naming (no label segment) are pinned by direct unit
# tests in tests/test_sourceable_coverage.sh, outside this work package's
# edit scope.
dx_opencode_migrate_live_path() {
    local live="$1" persistent="$2" item destination backup
    [ ! -L "$live" ] || return 0
    if [ -d "$live" ] && [ ! -L "$live" ]; then
        for item in "$live"/* "$live"/.[!.]* "$live"/..?*; do
            [ -e "$item" ] || [ -L "$item" ] || continue
            destination="$persistent/${item##*/}"
            if [ -e "$destination" ] || [ -L "$destination" ]; then
                backup="$(dx_opencode_unused_path "$persistent/.dxe-conflict-${item##*/}")" || return 1
                mv "$item" "$backup" || return 1
            else
                mv "$item" "$destination" || return 1
            fi
        done
        rmdir "$live" || return 1
    elif [ -e "$live" ]; then
        backup="$(dx_opencode_unused_path "$persistent/.dxe-conflict-live-opencode")" || return 1
        mv "$live" "$backup" || return 1
    fi
}

# Fable B9: identical body to dx-persist-relocate.sh's
# dx_persist_publish_link -- delegated rather than duplicated.
dx_opencode_publish_link() {
    dx_persist_publish_link "$@"
}

dx_ai_opencode_persistence() {
    local persist_home="$1" home="$2" relative live target
    # Preflight every ancestor and both link leaves before creating, moving,
    # chmodding, or chowning anything. Validation walks top-down and therefore
    # never probes through an ancestor it has not already accepted.
    dx_opencode_validate_directory_path "$persist_home/.config/opencode" "persistent OpenCode path" || return 1
    dx_opencode_validate_directory_path "$persist_home/.local/share/opencode" "persistent OpenCode path" || return 1
    dx_opencode_validate_directory_path "$home/.config" "live OpenCode parent" || return 1
    dx_opencode_validate_directory_path "$home/.local/share" "live OpenCode parent" || return 1
    for relative in .config/opencode .local/share/opencode; do
        live="$home/$relative"; target="$persist_home/$relative"
        if [ -L "$live" ] && [ "$(readlink "$live")" != "$target" ]; then
            echo "Error: refusing unexpected OpenCode link: $live" >&2
            return 1
        fi
    done

    dx_opencode_prepare_directory "$persist_home/.config" 0755 || return 1
    dx_opencode_prepare_directory "$persist_home/.local" 0755 || return 1
    dx_opencode_prepare_directory "$persist_home/.local/share" 0755 || return 1
    dx_opencode_prepare_directory "$home/.config" 0755 || return 1
    dx_opencode_prepare_directory "$home/.local" 0755 || return 1
    dx_opencode_prepare_directory "$home/.local/share" 0755 || return 1
    for relative in .config/opencode .local/share/opencode; do
        live="$home/$relative"; target="$persist_home/$relative"
        dx_opencode_prepare_directory "$target" 0700 || return 1
        dx_opencode_migrate_live_path "$live" "$target" || return 1
        dx_opencode_publish_link "$target" "$live" || return 1
    done
}
