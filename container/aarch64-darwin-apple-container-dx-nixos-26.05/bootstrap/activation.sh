#!/usr/bin/env bash
# Source-only bootstrap activation phase. Safe to source.

run_home_manager_activation() {
    validate_positive_integer DX_GUEST_ACTIVATION_TIMEOUT "$DX_GUEST_ACTIVATION_TIMEOUT"
    validate_positive_integer DX_GUEST_ACTIVATION_ATTEMPTS "$DX_GUEST_ACTIVATION_ATTEMPTS"
    validate_positive_integer DX_GUEST_ACTIVATION_RETRY_DELAY "$DX_GUEST_ACTIVATION_RETRY_DELAY"

    local attempt=1
    local status=0
    local activation_flake
    activation_flake="$DX_BOOTSTRAP_ROOT#homeConfigurations.dx.activationPackage"

    while [ "$attempt" -le "$DX_GUEST_ACTIVATION_ATTEMPTS" ]; do
        echo "Running Home Manager activation (attempt $attempt/$DX_GUEST_ACTIVATION_ATTEMPTS, timeout ${DX_GUEST_ACTIVATION_TIMEOUT}s)..."
        if run_as_dx_with_timeout "$DX_GUEST_ACTIVATION_TIMEOUT" nix run \
            --option connect-timeout 15 --option stalled-download-timeout 60 \
            --option download-attempts 2 --extra-experimental-features "nix-command flakes" \
            "$activation_flake"; then
            return 0
        else
            status=$?
        fi

        if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
            echo "Warning: Home Manager activation timed out after ${DX_GUEST_ACTIVATION_TIMEOUT}s." >&2
        else
            echo "Warning: Home Manager activation failed with exit status $status." >&2
        fi

        if [ "$attempt" -ge "$DX_GUEST_ACTIVATION_ATTEMPTS" ]; then
            echo "Error: Home Manager activation failed after $DX_GUEST_ACTIVATION_ATTEMPTS attempt(s)." >&2
            return "$status"
        fi

        echo "Retrying Home Manager activation in ${DX_GUEST_ACTIVATION_RETRY_DELAY}s..."
        sleep "$DX_GUEST_ACTIVATION_RETRY_DELAY"
        attempt=$((attempt + 1))
    done
}

ensure_nix_ownership() {
    local sentinel="/nix/.dx-owner-set"
    local dx_owner
    local sentinel_owner
    local needs_chown=0

    dx_owner="$(id -u dx):$(id -g dx)"
    sentinel_owner="$(stat -c '%u:%g' "$sentinel" 2>/dev/null || true)"

    if [ ! -f "$sentinel" ]; then
        needs_chown=1
    elif [ "$sentinel_owner" != "$dx_owner" ]; then
        echo "Nix ownership marker needs repair."
        needs_chown=1
    elif ! run_as_dx "test -w /nix/store && test -w /nix/var/nix"; then
        echo "Nix store is not writable by dx."
        needs_chown=1
    fi

    if [ "$needs_chown" -eq 1 ]; then
        echo "Granting Nix ownership to dx..."
        chown -R dx:dx /nix
        touch "$sentinel"
        chown dx:dx "$sentinel"
    else
        echo "Nix ownership already set. Skipping chown."
    fi
}

configure_guest() {
    echo "Configuring guest environment with Home Manager..."
    local ai_tools_enabled=false

    # Hand over Nix ownership to dx for true single-user operation (§7)
    ensure_nix_ownership
    chown -R dx:dx /home/dx

    # Create persistent Nix cache dir on volume to speed up evaluations
    mkdir -p /nix/cache/nix
    chown -R dx:dx /nix/cache
    run_as_dx "mkdir -p ~/.cache && ln -sf /nix/cache/nix ~/.cache/nix"

    # Expose persistent /persist volume at a stable path inside $HOME.
    run_as_dx "ln -sfnT /persist /home/dx/persist"

    # Persist GitHub CLI credentials/configuration across container rebuilds.
    setup_gh_persistence

    # Persist tmux-resurrect save data across container rebuilds.
    setup_tmux_persistence

    # Persist AI CLI tool credentials/configuration across container rebuilds
    # Only restore these links if the user has opted into the AI tools
    if [ -x /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex ] \
        || run_as_dx "nix profile list" | grep -qE "Flake attribute:[[:space:]]+packages\.[^.]+\.ai-tools$"; then
        mkdir -p /persist/home/dx/.gemini/antigravity-cli /persist/home/dx/.claude /persist/home/dx/.codex
        if [ ! -s /persist/home/dx/.claude.json ]; then
            printf '%s\n' '{}' > /persist/home/dx/.claude.json
        fi
        chown -R dx:dx /persist/home/dx
        run_as_dx "ln -sfn /persist/home/dx/.gemini ~/.gemini"
        run_as_dx "ln -sfn /persist/home/dx/.claude ~/.claude"
        run_as_dx "ln -sfn /persist/home/dx/.claude.json ~/.claude.json"
        run_as_dx "ln -sfn /persist/home/dx/.codex ~/.codex"

        # D-Bus + gnome-keyring (so agy can persist OAuth tokens) start below,
        # once Home Manager activation has installed dbus-daemon into dx's
        # profile: setup_keyring_service looks it up on dx's PATH, and on a
        # fresh recreate /home/dx is ephemeral, so calling it here -- before
        # Home Manager has run -- would find no dbus-daemon at all.
        ai_tools_enabled=true
    fi

    # Activate Herdr persistence and seed config unconditionally (F4). This is
    # a guest-invariant layout (herdr-plan.md H4/H9), not an AI-tools opt-in
    # side effect: gating it on the AI-tools guard above meant a fresh guest's
    # first Herdr session wrote into ordinary /home/dx directories, and the
    # *next* bootstrap would then migrate or relocate them into a timestamped
    # backup, silently changing where the user's first session lived.
    # Non-fatal by design. Seeding an optional tool's configuration must never
    # stop the guest from booting: sshd runs as the foreground process, so an
    # aborted bootstrap means no guest at all. A failure here is loud in the
    # log and leaves Herdr unconfigured, which is strictly better than a guest
    # that will not start. (Live defect: awk was absent from the early
    # essentials profile, so seeding failed, the failure propagated, and
    # bootstrap died.)
    dx_activate_herdr || echo "Warning: Herdr activation failed; continuing bootstrap without it." >&2

    # Use Home Manager to manage dotfiles and user profile. This is bounded so
    # a wedged Nix substitute cannot leave the container alive but pre-SSH.
    run_home_manager_activation

    # Start D-Bus + gnome-keyring so agy can persist OAuth tokens. Must run
    # after run_home_manager_activation (above): dbus-daemon is only installed
    # into dx's profile by Home Manager, so calling this any earlier finds
    # nothing on dx's PATH to start.
    if [ "$ai_tools_enabled" = true ]; then
        setup_keyring_service
    fi

    # Set nushell as default shell
    NU_PATH="/home/dx/.nix-profile/bin/nu"
    if [ -f "$NU_PATH" ]; then
        echo "Setting nushell as the default shell..."
        touch /etc/shells
        if ! grep -q "$NU_PATH" /etc/shells; then
            echo "$NU_PATH" >> /etc/shells
        fi
        usermod -s "$NU_PATH" dx
    fi
}

verify_guest_tools() {
    echo "Verifying guest tools..."
    if ! run_as_dx 'command -v nvim >/dev/null && command -v tmux >/dev/null && command -v nix >/dev/null && command -v yazi >/dev/null'; then
        echo "Error: DX guest tools are not available in the dx login shell." >&2
        exit 1
    fi
}

# Seed the repository-owned Herdr defaults into the persisted, mutable
# config.toml (H10). The merge itself lives in bootstrap/herdr-config.sh rather
# than inline here. The defaults now carry `[[keys.command]]` binding blocks,
# and merging an array of tables is well outside what the previous two-key
# seeder could express: it rejected array tables outright and so failed closed
# on every config that carried a key binding at all.
#
# The contract that seeder established is preserved by the merger: explicit
# user values win, an occupied binding is never duplicated, unrelated tables
# and comments survive, publication is atomic via a same-directory temp file,
# a second run is byte-identical, and TOML it cannot update safely leaves the
# original untouched rather than risking a partial rewrite.
dx_seed_herdr_config() {
    local config_file="$1"
    local template="${2:-}"
    local bootstrap_root

    bootstrap_root="${DX_BOOTSTRAP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    [ -n "$template" ] || template="$bootstrap_root/bootstrap/herdr-config.toml"
    if ! declare -F dx_herdr_seed_config >/dev/null; then
        echo "Error: Herdr config merger is unavailable; bootstrap/herdr-config.sh was not sourced." >&2
        return 1
    fi
    dx_herdr_seed_config "$template" "$config_file"
}

dx_activate_herdr() {
    local persist_home="${1:-/persist/home/dx}"
    local home="${2:-/home/dx}"
    local template="${3:-}"
    local persistent_config_file="$persist_home/.config/herdr/config.toml"
    local persistent_config_dir="$persist_home/.config/herdr"
    local persistent_state_dir="$persist_home/.local/state/herdr"
    local ready_marker="$persistent_config_dir/.dxe-persistence-ready"
    local ready_tmp=""

    setup_herdr_persistence "$persist_home" "$home" || return 1
    dx_seed_herdr_config "$persistent_config_file" "$template" || return 1
    if ! chown -R dx:dx "$persistent_config_dir" "$persistent_state_dir"; then
        echo "Error: could not set dx:dx ownership on Herdr's persisted config/state directories; refusing to leave a root-owned config.toml the dx user cannot read." >&2
        return 1
    fi
    if ! [ -L "$home/.config/herdr" ] \
        || ! [ "$(readlink "$home/.config/herdr")" = "$persistent_config_dir" ] \
        || ! [ -L "$home/.local/state/herdr" ] \
        || ! [ "$(readlink "$home/.local/state/herdr")" = "$persistent_state_dir" ] \
        || ! [ -f "$persistent_config_file" ]; then
        echo "Error: Herdr persistence links or configuration did not verify after activation." >&2
        return 1
    fi
    ready_tmp="$(mktemp "$persistent_config_dir/.dxe-persistence-ready.XXXXXX")" || return 1
    if ! chown dx:dx "$ready_tmp" || ! chmod 0600 "$ready_tmp" || ! mv -f "$ready_tmp" "$ready_marker"; then
        rm -f "$ready_tmp"
        return 1
    fi
}
