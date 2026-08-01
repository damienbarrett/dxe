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

        # Start D-Bus + gnome-keyring so agy can persist OAuth tokens
        setup_keyring_service
    fi

    # Use Home Manager to manage dotfiles and user profile. This is bounded so
    # a wedged Nix substitute cannot leave the container alive but pre-SSH.
    run_home_manager_activation

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
