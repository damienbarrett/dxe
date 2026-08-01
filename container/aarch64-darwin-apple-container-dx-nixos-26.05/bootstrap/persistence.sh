#!/usr/bin/env bash
# Source-only bootstrap persistence phase. Safe to source.

setup_persist() {
    if [ -d /persist ]; then
        chown dx:dx /persist
        chmod 0755 /persist
        install -d -o dx -g dx -m 0755 /persist/home /persist/home/dx
    fi
}

# 3. Configure SSH (Section 4)
setup_gh_persistence() {
    local persistent_config_dir="/persist/home/dx/.config"
    local persistent_gh="/persist/home/dx/.config/gh"
    local home_config_dir="/home/dx/.config"
    local home_gh="/home/dx/.config/gh"
    local timestamp=""
    local backup_path=""

    mkdir -p "$persistent_config_dir" "$home_config_dir"

    if [ -e "$persistent_gh" ] && [ ! -d "$persistent_gh" ]; then
        timestamp="$(date +%Y%m%d%H%M%S)"
        backup_path="$persistent_config_dir/gh.non-directory-backup.$timestamp"
        mv "$persistent_gh" "$backup_path"
        echo "Moved non-directory GitHub CLI config target to $backup_path"
    fi

    if [ -L "$home_gh" ]; then
        rm -f "$home_gh"
    elif [ -e "$home_gh" ]; then
        if [ ! -e "$persistent_gh" ]; then
            mv "$home_gh" "$persistent_gh"
        elif [ -d "$persistent_gh" ] && [ -z "$(ls -A "$persistent_gh" 2>/dev/null)" ]; then
            rmdir "$persistent_gh"
            mv "$home_gh" "$persistent_gh"
        else
            timestamp="$(date +%Y%m%d%H%M%S)"
            backup_path="$persistent_config_dir/gh.ephemeral-backup.$timestamp"
            mv "$home_gh" "$backup_path"
            echo "Moved ephemeral GitHub CLI config to $backup_path"
        fi
    fi

    mkdir -p "$persistent_gh"
    chown -R dx:dx /persist/home/dx "$home_config_dir"
    chmod 700 "$persistent_gh"
    run_as_dx "ln -sfnT /persist/home/dx/.config/gh /home/dx/.config/gh"
}

# Persist tmux-resurrect save data across container rebuilds. /persist is a
# runtime mount, so Home Manager cannot create this directory declaratively;
# home/tools.nix points resurrect at it via @resurrect-dir. install -d sets
# ownership on the directories it creates regardless of the later recursive
# chowns over /persist/home/dx.
setup_tmux_persistence() {
    install -d -o dx -g dx -m 0755 /persist/home/dx/.local/share/tmux/resurrect
}

# agy stores its known CLI state under ~/.gemini/antigravity-cli, which is
# persisted with ~/.gemini. Also provide D-Bus + gnome-keyring Secret Service
# compatibility for auth flows that request it; keyring data is linked to
# /persist so any Secret Service-backed tokens survive container rebuilds.
setup_keyring_service() {
    echo "Setting up D-Bus keyring service for credential persistence..."

    # 1. Persist keyring data across container rebuilds
    local persistent_keyrings="/persist/home/dx/.local/share/keyrings"
    local state_dir="/persist/home/dx/.local/state/dx"
    local address_file="$state_dir/keyring-address"
    local legacy_file="/home/dx/.dx-keyring-env"
    mkdir -p "$persistent_keyrings" "$state_dir"
    chown -R dx:dx /persist/home/dx/.local
    run_as_dx "mkdir -p ~/.local/share && ln -sfnT '$persistent_keyrings' ~/.local/share/keyrings"

    # 2. Reuse a live D-Bus session when available, otherwise start a fresh one.
    local dbus_config
    local dbus_bin
    local bus_addr
    bus_addr="$(dx_keyring_read_address "$address_file" 2>/dev/null || true)"
    if [ -z "$bus_addr" ] && [ -e "$legacy_file" ]; then
        bus_addr="$(dx_keyring_read_legacy_env "$legacy_file")" || {
            echo "Error: refusing malformed legacy keyring environment file $legacy_file." >&2
            return 1
        }
        dx_keyring_write_address "$address_file" "$bus_addr"
        chown dx:dx "$address_file"
        rm -f "$legacy_file"
    fi

    if ! dx_keyring_address_is_live "$bus_addr"; then
        dbus_bin="$(run_as_dx 'command -v dbus-daemon')"
        dbus_config="$(dx_keyring_session_config "$dbus_bin")"
        bus_addr="$(setpriv --reuid=dx --regid=dx --init-groups env HOME=/home/dx USER=dx "$dbus_bin" --config-file="$dbus_config" --fork --print-address)"
        dx_keyring_address_valid "$bus_addr" || { echo "Error: dbus-daemon returned an invalid bus address." >&2; return 1; }
    fi

    # 3. Start gnome-keyring-daemon (secret-service component) with an empty
    #    unlock password so it is immediately usable in this headless guest.
    printf '' | setpriv --reuid=dx --regid=dx --init-groups env HOME=/home/dx USER=dx DBUS_SESSION_BUS_ADDRESS="$bus_addr" gnome-keyring-daemon --unlock --start --components=secrets >/dev/null 2>&1 || true

    # 4. Persist only validated data, never executable shell text.
    dx_keyring_write_address "$address_file" "$bus_addr"
    chown dx:dx "$address_file"
    rm -f "$legacy_file"
}

# 5. Configure Shell & Tmux (Section 3/6)
