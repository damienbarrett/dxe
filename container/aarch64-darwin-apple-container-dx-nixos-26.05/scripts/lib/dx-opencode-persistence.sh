#!/usr/bin/env bash
# Source-only OpenCode persistence helpers shared by dx-ai and activation.

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

dx_opencode_prepare_directory() {
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

dx_opencode_unused_path() {
    local prefix="$1" candidate="$1.$$" suffix=0
    while [ -e "$candidate" ] || [ -L "$candidate" ]; do
        suffix=$((suffix + 1))
        candidate="$prefix.$$.$suffix"
    done
    printf '%s\n' "$candidate"
}

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

dx_opencode_publish_link() {
    local target="$1" live="$2" temporary
    if [ -L "$live" ] && [ "$(readlink "$live")" = "$target" ]; then return 0; fi
    [ ! -e "$live" ] && [ ! -L "$live" ] || return 1
    temporary="$(dx_opencode_unused_path "$live.dxe-link")" || return 1
    ln -s "$target" "$temporary" || return 1
    if ! mv -f "$temporary" "$live"; then rm -f "$temporary"; return 1; fi
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
