#!/usr/bin/env bash
# Source-only bootstrap activation phase. Safe to source.

run_home_manager_activation() {
    local phase_started=$SECONDS
    local status
    if validate_positive_integer DX_GUEST_ACTIVATION_TIMEOUT "$DX_GUEST_ACTIVATION_TIMEOUT"; then :; else
        status=$?
        echo "Bootstrap phase: Home Manager activation failed after $((SECONDS - phase_started))s (invalid timeout)." >&2
        return "$status"
    fi
    if validate_positive_integer DX_GUEST_ACTIVATION_ATTEMPTS "$DX_GUEST_ACTIVATION_ATTEMPTS"; then :; else
        status=$?
        echo "Bootstrap phase: Home Manager activation failed after $((SECONDS - phase_started))s (invalid attempt count)." >&2
        return "$status"
    fi
    if validate_positive_integer DX_GUEST_ACTIVATION_RETRY_DELAY "$DX_GUEST_ACTIVATION_RETRY_DELAY"; then :; else
        status=$?
        echo "Bootstrap phase: Home Manager activation failed after $((SECONDS - phase_started))s (invalid retry delay)." >&2
        return "$status"
    fi

    local attempt=1
    status=0
    local activation_flake
    activation_flake="$DX_BOOTSTRAP_ROOT#homeConfigurations.dx.activationPackage"

    while [ "$attempt" -le "$DX_GUEST_ACTIVATION_ATTEMPTS" ]; do
        echo "Running Home Manager activation (attempt $attempt/$DX_GUEST_ACTIVATION_ATTEMPTS, timeout ${DX_GUEST_ACTIVATION_TIMEOUT}s)..."
        if run_as_dx_with_timeout "$DX_GUEST_ACTIVATION_TIMEOUT" nix run \
            --option connect-timeout 15 --option stalled-download-timeout 60 \
            --option download-attempts 2 --extra-experimental-features "nix-command flakes" \
            "$activation_flake"; then
            echo "Bootstrap phase: Home Manager activation completed in $((SECONDS - phase_started))s."
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
            echo "Bootstrap phase: Home Manager activation failed after $((SECONDS - phase_started))s (exit $status)." >&2
            return "$status"
        fi

        echo "Retrying Home Manager activation in ${DX_GUEST_ACTIVATION_RETRY_DELAY}s..."
        sleep "$DX_GUEST_ACTIVATION_RETRY_DELAY"
        attempt=$((attempt + 1))
    done
}

# `.dx-owner-layout-v1` records the ownership *layout* migration. It is not
# superseded by base-and-storage.sh's `.dx-durable-identity-v1`, which records a
# separate one-time migration on the same volume; the two are versioned
# independently. Both publish the shared `.dx-owner-set` legacy sentinel.
publish_nix_ownership_marker() {
    local content_validated="${1:-false}"
    local root="${DX_NIX_OWNERSHIP_ROOT:-/nix}"
    local sentinel="$root/.dx-owner-set"
    local marker="$root/.dx-owner-layout-v1"
    local sentinel_tmp=""
    local marker_tmp=""
    local dx_owner

    dx_owner="$(id -u dx):$(id -g dx)"
    dx_validate_atomic_marker_path "$sentinel" "Nix ownership sentinel" || return 1
    dx_validate_atomic_marker_path "$marker" "Nix ownership layout marker" || return 1
    if ! run_as_dx "test -w '$root/store' && test -w '$root/var/nix'"; then
        echo "Error: cannot publish Nix ownership marker; dx cannot write the Nix roots." >&2
        return 1
    fi
    if declare -F essentials_store_valid >/dev/null \
        && [ "$content_validated" != true ] \
        && ! essentials_store_valid; then
        echo "Error: refusing to publish Nix ownership marker before the essentials closure is content-valid." >&2
        return 1
    fi

    # Publish the old sentinel first. Older bootstrap generations understand
    # only this regular file; creating it after content validation keeps them
    # compatible without making a mature store look unowned.
    if [ ! -f "$sentinel" ] || [ "$(stat -c '%u:%g' "$sentinel" 2>/dev/null || true)" != "$dx_owner" ]; then
        sentinel_tmp="$sentinel.tmp.$$"
        if ! : > "$sentinel_tmp" \
            || ! chown dx:dx "$sentinel_tmp" \
            || ! chmod 0600 "$sentinel_tmp" \
            || ! dx_publish_atomic_marker "$sentinel_tmp" "$sentinel" "Nix ownership sentinel"; then
            rm -f "$sentinel_tmp"
            return 1
        fi
    fi

    marker_tmp="$marker.tmp.$$"
    if ! publish_nix_ownership_marker_file "$marker_tmp" "$marker" "$dx_owner"; then
        rm -f "$marker_tmp"
        echo "Warning: Nix ownership marker publication did not complete; retrying on the next bootstrap." >&2
        return 1
    fi
    echo "Nix ownership layout marker published for $dx_owner."
}

publish_nix_ownership_marker_file() {
    local marker_tmp="$1"
    local marker="$2"
    local dx_owner="$3"
    printf 'ownership-layout=1\nowner=%s\n' "$dx_owner" > "$marker_tmp" \
        && chown dx:dx "$marker_tmp" \
        && chmod 0600 "$marker_tmp" \
    && dx_publish_atomic_marker "$marker_tmp" "$marker" "Nix ownership layout marker"
}

ensure_nix_ownership_impl() {
    local content_validated="${1:-false}"
    local root="${DX_NIX_OWNERSHIP_ROOT:-/nix}"
    local sentinel="$root/.dx-owner-set"
    local marker="$root/.dx-owner-layout-v1"
    local dx_owner
    local sentinel_owner
    local marker_owner
    local marker_contents

    dx_owner="$(id -u dx):$(id -g dx)"
    dx_validate_atomic_marker_path "$sentinel" "Nix ownership sentinel" || return 1
    dx_validate_atomic_marker_path "$marker" "Nix ownership layout marker" || return 1
    sentinel_owner="$(stat -c '%u:%g' "$sentinel" 2>/dev/null || true)"
    marker_owner="$(stat -c '%u:%g' "$marker" 2>/dev/null || true)"
    marker_contents="$(cat "$marker" 2>/dev/null || true)"

    if [ "$marker_owner" = "$dx_owner" ] \
        && printf '%s\n' "$marker_contents" | grep -q '^ownership-layout=1$' \
        && printf '%s\n' "$marker_contents" | grep -q "^owner=$dx_owner$" \
        && run_as_dx "test -w '$root/store' && test -w '$root/var/nix'"; then
        echo "Nix ownership already set. Skipping recursive ownership repair."
        [ -f "$sentinel" ] || publish_nix_ownership_marker "$content_validated"
        return 0
    fi

    # A valid legacy sentinel plus writable roots is enough to upgrade without
    # walking the store. This is the common first boot after the refactor.
    if [ -f "$sentinel" ] && [ "$sentinel_owner" = "$dx_owner" ] \
        && run_as_dx "test -w '$root/store' && test -w '$root/var/nix'"; then
        echo "Upgrading legacy Nix ownership marker without recursive repair."
        publish_nix_ownership_marker "$content_validated"
        return
    fi

    # A freshly imported volume has already passed bounded essentials-content
    # validation. Its owner-mapped roots need only marker publication.
    if [ "$content_validated" = true ] \
        && run_as_dx "test -w '$root/store' && test -w '$root/var/nix'"; then
        publish_nix_ownership_marker true
        return
    fi

    echo "Migrating legacy Nix ownership (one time)..."
    chown -R dx:dx "$root"
    if ! run_as_dx "test -w '$root/store' && test -w '$root/var/nix'"; then
        echo "Error: Nix ownership migration did not make the store writable by dx." >&2
        return 1
    fi
    publish_nix_ownership_marker "$content_validated"
}

ensure_nix_ownership() {
    local phase_started=$SECONDS
    local status
    if ensure_nix_ownership_impl "$@"; then
        echo "Bootstrap phase: Nix ownership check/migration completed in $((SECONDS - phase_started))s."
        return 0
    else
        status=$?
    fi
    echo "Bootstrap phase: Nix ownership check/migration failed after $((SECONDS - phase_started))s (exit $status)." >&2
    return "$status"
}

configure_guest() {
    local content_validated="${1:-false}"
    echo "Configuring guest environment with Home Manager..."
    local ai_tools_enabled=false
    local phase_started

    # Hand over Nix ownership to dx for true single-user operation (§7)
    ensure_nix_ownership "$content_validated"
    phase_started=$SECONDS
    dx_ensure_tree_owner /home/dx /home/dx/.dxe-owner-v1 "guest home" || return 1
    echo "Bootstrap phase: guest home ownership setup completed in $((SECONDS - phase_started))s."

    # Create persistent Nix cache dir on volume to speed up evaluations
    phase_started=$SECONDS
    dx_ensure_tree_owner /nix/cache /nix/cache/.dxe-owner-v1 "Nix cache" || return 1
    dx_prepare_owned_directory /nix/cache/nix 0755 || return 1
    echo "Bootstrap phase: Nix cache ownership setup completed in $((SECONDS - phase_started))s."
    run_as_dx "mkdir -p ~/.cache && ln -sf /nix/cache/nix ~/.cache/nix"

    # Expose persistent /persist volume at a stable path inside $HOME.
    run_as_dx "ln -sfnT /persist /home/dx/persist"

    # Persist GitHub CLI credentials/configuration across container rebuilds.
    phase_started=$SECONDS
    setup_gh_persistence
    echo "Bootstrap phase: GitHub persistence completed in $((SECONDS - phase_started))s."

    # Persist tmux-resurrect save data across container rebuilds.
    phase_started=$SECONDS
    setup_tmux_persistence
    echo "Bootstrap phase: tmux persistence completed in $((SECONDS - phase_started))s."

    # Persist AI CLI tool credentials/configuration across container rebuilds
    # Only restore these links if the user has opted into the AI tools
    if [ -x /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex ] \
        || run_as_dx "nix profile list" | grep -qE "Flake attribute:[[:space:]]+packages\.[^.]+\.ai-tools$"; then
        phase_started=$SECONDS
        dx_ensure_tree_owner /persist/home/dx /persist/home/dx/.dxe-owner-v1 "persisted guest home" || return 1
        dx_prepare_owned_directory /persist/home/dx/.gemini/antigravity-cli 0700 || return 1
        dx_prepare_owned_directory /persist/home/dx/.claude 0700 || return 1
        dx_prepare_owned_directory /persist/home/dx/.codex 0700 || return 1
        if [ ! -s /persist/home/dx/.claude.json ]; then
            printf '%s\n' '{}' > /persist/home/dx/.claude.json
            chown dx:dx /persist/home/dx/.claude.json
            chmod 0600 /persist/home/dx/.claude.json
        fi
        echo "Bootstrap phase: AI persistence ownership setup completed in $((SECONDS - phase_started))s."
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
    phase_started=$SECONDS
    dx_activate_herdr || echo "Warning: Herdr activation failed; continuing bootstrap without it." >&2
    echo "Bootstrap phase: Herdr persistence completed in $((SECONDS - phase_started))s."

    # Use Home Manager to manage dotfiles and user profile. This is bounded so
    # a wedged Nix substitute cannot leave the container alive but pre-SSH.
    run_home_manager_activation

    # Start D-Bus + gnome-keyring so agy can persist OAuth tokens. Must run
    # after run_home_manager_activation (above): dbus-daemon is only installed
    # into dx's profile by Home Manager, so calling this any earlier finds
    # nothing on dx's PATH to start.
    if [ "$ai_tools_enabled" = true ]; then
        phase_started=$SECONDS
        setup_keyring_service
        echo "Bootstrap phase: keyring persistence completed in $((SECONDS - phase_started))s."
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
    local phase_started=$SECONDS
    echo "Verifying guest tools..."
    if ! run_as_dx 'command -v nvim >/dev/null && command -v tmux >/dev/null && command -v nix >/dev/null && command -v yazi >/dev/null'; then
        echo "Error: DX guest tools are not available in the dx login shell." >&2
        echo "Bootstrap phase: final guest tool verification failed after $((SECONDS - phase_started))s." >&2
        return 1
    fi
    echo "Bootstrap phase: final guest tool verification completed in $((SECONDS - phase_started))s."
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
    if ! chown dx:dx "$persistent_config_file"; then
        echo "Error: could not set dx:dx ownership on Herdr's persisted config.toml; refusing to leave a root-owned config.toml the dx user cannot read." >&2
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
    if ! chown dx:dx "$ready_tmp" || ! chmod 0600 "$ready_tmp" \
        || ! dx_publish_atomic_marker "$ready_tmp" "$ready_marker" "Herdr persistence readiness marker"; then
        rm -f "$ready_tmp"
        return 1
    fi
}
