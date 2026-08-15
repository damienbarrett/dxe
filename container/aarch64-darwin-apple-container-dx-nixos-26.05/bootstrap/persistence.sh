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
        timestamp="$(date +%Y%m%d%H%M%S)" || return 1
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
            timestamp="$(date +%Y%m%d%H%M%S)" || return 1
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
        dbus_bin="$(run_as_dx 'command -v dbus-daemon')" || {
            echo "Error: dbus-daemon not found on dx's PATH; cannot start the keyring service. Home Manager activation must install it before setup_keyring_service runs." >&2
            return 1
        }
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

# Persist herdr configuration, sessions, history, and state across container
# rebuilds. Takes the persistent and home base directories as optional
# parameters (defaulting to the real guest paths) purely so behavior tests can
# drive this function against a disposable fixture tree instead of the real
# host filesystem; production callers always invoke it with zero arguments.
#
# F5/R1: both persistent targets, their home-/persist-side parents, and their
# user-controlled ancestors are rejected with `[ -L ... ]` *before* any
# mutation if any of them is a
# symlink. `-d` dereferences, so without this a symlink-to-directory would
# have passed the old "is it a real directory" guard, and root would then
# `mkdir -p`/`chown -R`/`chmod 0700` (and later seed config.toml) straight
# through it to wherever it points. `home_config`/`home_state` are
# deliberately excluded from that reject list: being a symlink there is the
# normal steady state this function itself creates on a successful run, and
# is handled explicitly below rather than rejected.
setup_herdr_persistence() {
    local persist_home="${1:-/persist/home/dx}"
    local home="${2:-/home/dx}"
    local persist_home_parent="${persist_home%/*}"
    local persist_mount="${persist_home_parent%/*}"
    local persistent_config="$persist_home/.config/herdr"
    local persistent_state="$persist_home/.local/state/herdr"
    local home_config="$home/.config/herdr"
    local home_state="$home/.local/state/herdr"
    local persistent_config_parent="$persist_home/.config"
    local persistent_state_parent="$persist_home/.local/state"
    local home_config_parent="$home/.config"
    local home_state_parent="$home/.local/state"
    local ready_marker="$persistent_config/.dxe-persistence-ready"
    local timestamp=""
    local backup_path=""
    local unsafe_path=""

    for unsafe_path in \
        "$persist_mount" "$persist_home_parent" \
        "$persist_home" "$persist_home/.local" \
        "$home" "$home/.local" \
        "$persistent_config_parent" "$persistent_state_parent" \
        "$home_config_parent" "$home_state_parent" \
        "$persistent_config" "$persistent_state"
    do
        if [ -L "$unsafe_path" ]; then
            echo "Error: refusing to activate Herdr persistence: $unsafe_path is a symlink, not the directory it must be. Remove it manually and re-run bootstrap." >&2
            return 1
        fi
    done

    # Invalidate a prior successful activation only after every persistent
    # component has been proven non-symlinked. In particular, do not touch a
    # marker through a hostile persistent_config symlink. When the config
    # target is absent or a regular file there is no directory to traverse;
    # any marker is necessarily absent and the config migration below handles
    # that target first.
    if [ -d "$persistent_config" ]; then
        if [ -L "$ready_marker" ]; then
            echo "Error: refusing to activate Herdr persistence: readiness marker is a symlink." >&2
            return 1
        fi
        rm -f "$ready_marker" || return 1
    fi

    # Home-side parents may already exist (setup_gh_persistence, which runs
    # before Herdr activation in configure_guest, already creates and chowns
    # ~/.config) or may not (nothing creates ~/.local/state before this on a
    # fresh guest). Record which is which *before* mkdir -p so the mode
    # change below can be scoped correctly.
    local home_config_parent_created=1
    local home_state_parent_created=1
    [ ! -d "$home_config_parent" ] || home_config_parent_created=0
    [ ! -d "$home_state_parent" ] || home_state_parent_created=0

    mkdir -p "$persistent_config_parent" "$persistent_state_parent" "$home_config_parent" "$home_state_parent" || return 1

    # Live defect: mkdir -p above runs as root, so a freshly created
    # home-side parent is root-owned; the later `run_as_dx "ln -sfnT ..."`
    # calls below then fail with "Permission denied" (observed live on a
    # fresh dx-recreate). herdr-plan.md requires both persistent targets
    # *and* their home-side parents to be dx:dx -- only the persistent side
    # was implemented.
    # Ownership is repaired unconditionally (idempotent either way). Mode
    # 0700 is applied only to a parent this call actually created: ~/.config
    # in particular is shared with other tools (gh, Home Manager, ...), and
    # forcing it private here would clobber a pre-existing, intentionally
    # shared mode out from under them.
    chown dx:dx "$home_config_parent" "$home_state_parent" || return 1
    if [ "$home_config_parent_created" -eq 1 ]; then
        chmod 0700 "$home_config_parent" || return 1
    fi
    if [ "$home_state_parent_created" -eq 1 ]; then
        chmod 0700 "$home_state_parent" || return 1
    fi

    # 1. Config directory persistence
    if [ -e "$persistent_config" ] && [ ! -d "$persistent_config" ]; then
        timestamp="$(date +%Y%m%d%H%M%S)" || return 1
        backup_path="$persistent_config_parent/herdr.non-directory-backup.$timestamp"
        mv "$persistent_config" "$backup_path" || return 1
        chown -h dx:dx "$backup_path" || return 1
        chmod 0700 "$backup_path" || return 1
        echo "Moved non-directory herdr config target to $backup_path"
    fi

    if [ -L "$home_config" ]; then
        rm -f "$home_config" || return 1
    elif [ -e "$home_config" ]; then
        if [ ! -e "$persistent_config" ]; then
            mv "$home_config" "$persistent_config" || return 1
        elif [ -d "$persistent_config" ] && [ -z "$(ls -A "$persistent_config" 2>/dev/null)" ]; then
            rmdir "$persistent_config" || return 1
            mv "$home_config" "$persistent_config" || return 1
        else
            timestamp="$(date +%Y%m%d%H%M%S)" || return 1
            backup_path="$persistent_config_parent/herdr.ephemeral-backup.$timestamp"
            mv "$home_config" "$backup_path" || return 1
            chown -h dx:dx "$backup_path" || return 1
            chmod 0700 "$backup_path" || return 1
            echo "Moved ephemeral herdr config to $backup_path"
        fi
    fi

    mkdir -p "$persistent_config" || return 1
    chown -R dx:dx "$persistent_config" || return 1
    chmod 0700 "$persistent_config" || return 1

    # The config target might have been created above or populated by moving
    # an existing home directory. Re-check its marker after that migration:
    # an old/user-supplied marker must not survive into a later state-side
    # failure and falsely advertise a complete activation.
    if ! [ -d "$persistent_config" ] || [ -L "$persistent_config" ]; then
        echo "Error: Herdr persistent config target did not become a real directory." >&2
        return 1
    fi
    if [ -L "$ready_marker" ]; then
        echo "Error: refusing to activate Herdr persistence: readiness marker is a symlink." >&2
        return 1
    fi
    rm -f "$ready_marker" || return 1
    run_as_dx "ln -sfnT '$persistent_config' '$home_config'" || return 1

    # 2. State directory persistence
    if [ -e "$persistent_state" ] && [ ! -d "$persistent_state" ]; then
        timestamp="$(date +%Y%m%d%H%M%S)" || return 1
        backup_path="$persistent_state_parent/herdr.non-directory-backup.$timestamp"
        mv "$persistent_state" "$backup_path" || return 1
        chown -h dx:dx "$backup_path" || return 1
        chmod 0700 "$backup_path" || return 1
        echo "Moved non-directory herdr state target to $backup_path"
    fi

    if [ -L "$home_state" ]; then
        rm -f "$home_state" || return 1
    elif [ -e "$home_state" ]; then
        if [ ! -e "$persistent_state" ]; then
            mv "$home_state" "$persistent_state" || return 1
        elif [ -d "$persistent_state" ] && [ -z "$(ls -A "$persistent_state" 2>/dev/null)" ]; then
            rmdir "$persistent_state" || return 1
            mv "$home_state" "$persistent_state" || return 1
        else
            timestamp="$(date +%Y%m%d%H%M%S)" || return 1
            backup_path="$persistent_state_parent/herdr.ephemeral-backup.$timestamp"
            mv "$home_state" "$backup_path" || return 1
            chown -h dx:dx "$backup_path" || return 1
            chmod 0700 "$backup_path" || return 1
            echo "Moved ephemeral herdr state to $backup_path"
        fi
    fi

    mkdir -p "$persistent_state" || return 1
    chown -R dx:dx "$persistent_state" || return 1
    chmod 0700 "$persistent_state" || return 1
    run_as_dx "ln -sfnT '$persistent_state' '$home_state'" || return 1
}
