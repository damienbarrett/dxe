#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: dx-ai

Install or update the optional AI CLI bundle in this DX guest.

This updates nixpkgs-unstable in /guest-bootstrap, then installs or upgrades:
  - codex
  - gemini
  - claude
  - agy (Antigravity CLI)
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -ne 0 ]; then
    usage >&2
    exit 64
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "Error: run dx-ai as the dx user, not root." >&2
    exit 1
fi

if [ ! -f /guest-bootstrap/flake.nix ]; then
    echo "Error: /guest-bootstrap/flake.nix is missing." >&2
    exit 1
fi

cd /guest-bootstrap

export SSL_CERT_FILE="${SSL_CERT_FILE:-$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt}"
export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-$SSL_CERT_FILE}"
NIX_FLAGS=(--extra-experimental-features "nix-command flakes" --accept-flake-config)
AGY_MANIFEST_URL="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json"

dbus_session_config() {
    local dbus_bin
    local dbus_real
    local dbus_prefix

    dbus_bin="$(command -v dbus-daemon)"
    dbus_real="$(readlink -f "$dbus_bin")"
    dbus_prefix="${dbus_real%/bin/dbus-daemon}"

    if [ -f "$dbus_prefix/share/dbus-1/session.conf" ]; then
        printf '%s\n' "$dbus_prefix/share/dbus-1/session.conf"
    elif [ -f "$dbus_prefix/etc/dbus-1/session.conf" ]; then
        printf '%s\n' "$dbus_prefix/etc/dbus-1/session.conf"
    else
        echo "Error: could not locate dbus session.conf for $dbus_bin." >&2
        return 1
    fi
}

dbus_socket_from_address() {
    local address="${1:-}"
    local socket=""

    case "$address" in
        unix:path=*)
            socket="${address#unix:path=}"
            socket="${socket%%,*}"
            printf '%s\n' "$socket"
            ;;
    esac
}

dbus_address_is_live() {
    local socket
    socket="$(dbus_socket_from_address "${1:-}")"
    [ -n "$socket" ] && [ -S "$socket" ]
}

ensure_keyring_service() {
    local env_file="$HOME/.dx-keyring-env"

    if ! dbus_address_is_live "${DBUS_SESSION_BUS_ADDRESS:-}" && [ -f "$env_file" ]; then
        # shellcheck disable=SC1090
        . "$env_file"
    fi

    if ! dbus_address_is_live "${DBUS_SESSION_BUS_ADDRESS:-}"; then
        if command -v dbus-daemon >/dev/null 2>&1 && command -v gnome-keyring-daemon >/dev/null 2>&1; then
            dbus-daemon --config-file="$(dbus_session_config)" --fork --print-address > "$env_file.addr"
            export DBUS_SESSION_BUS_ADDRESS="$(cat "$env_file.addr")"
            rm -f "$env_file.addr"
            printf "export DBUS_SESSION_BUS_ADDRESS='%s'\n" "$DBUS_SESSION_BUS_ADDRESS" > "$env_file"
            echo "D-Bus keyring service started for agy credential compatibility."
        else
            echo "Warning: dbus-daemon or gnome-keyring-daemon not found. agy auth may not persist."
            return 0
        fi
    else
        printf "export DBUS_SESSION_BUS_ADDRESS='%s'\n" "$DBUS_SESSION_BUS_ADDRESS" > "$env_file"
        echo "D-Bus keyring service already available for agy credential compatibility."
    fi

    # Keep the Secret Service component available for auth flows that request it.
    echo -n '' | gnome-keyring-daemon --unlock --start --components=secrets 2>/dev/null || true
}

refresh_agy_pin() {
    local manifest=""
    local version=""
    local url=""
    local sha512_hex=""
    local hash=""

    echo "Refreshing Antigravity CLI manifest..."
    if ! manifest="$(curl -fsSL "$AGY_MANIFEST_URL")"; then
        echo "Warning: could not fetch agy manifest. Keeping checked-in agy pin." >&2
        return 0
    fi

    version="$(printf '%s' "$manifest" | jq -r '.version // empty')"
    url="$(printf '%s' "$manifest" | jq -r '.url // empty')"
    sha512_hex="$(printf '%s' "$manifest" | jq -r '.sha512 // empty')"
    if [ -z "$version" ] || [ -z "$url" ] || [ -z "$sha512_hex" ]; then
        echo "Warning: agy manifest is missing version, url, or sha512. Keeping checked-in agy pin." >&2
        return 0
    fi

    if ! hash="$(nix hash convert --hash-algo sha512 --to sri "$sha512_hex")"; then
        echo "Warning: could not convert agy manifest hash. Keeping checked-in agy pin." >&2
        return 0
    fi

    sed -i -E \
        -e "/agy = pkgs\\.stdenv\\.mkDerivation rec \\{/,/^      \\};$/ s#version = \"[0-9.]+\";#version = \"$version\";#" \
        -e "/agy = pkgs\\.stdenv\\.mkDerivation rec \\{/,/^      \\};$/ s#url = \"https://storage.googleapis.com/antigravity-public/antigravity-cli/[^\"]+\";#url = \"$url\";#" \
        -e "/agy = pkgs\\.stdenv\\.mkDerivation rec \\{/,/^      \\};$/ s#hash = \"sha512-[^\"]+\";#hash = \"$hash\";#" \
        flake.nix
    echo "Pinned agy $version from upstream manifest."
}

refresh_agy_pin

echo "Updating nixpkgs-unstable..."
nix flake update "${NIX_FLAGS[@]}" nixpkgs-unstable

if nix profile list | grep -qE "Flake attribute:[[:space:]]+packages\.[^.]+\.ai-tools$"; then
    echo "Upgrading optional AI tools..."
    nix profile upgrade "${NIX_FLAGS[@]}" ai-tools
else
    echo "Installing optional AI tools..."
    nix profile add "${NIX_FLAGS[@]}" .#ai-tools
fi

echo "Setting up AI credentials persistence..."
persist_home=/persist/home/dx
mkdir -p "$persist_home/.gemini/antigravity-cli" "$persist_home/.claude" "$persist_home/.codex"
if [ ! -s "$persist_home/.claude.json" ]; then
    printf '%s\n' '{}' > "$persist_home/.claude.json"
fi
ln -sfn "$persist_home/.gemini" ~/.gemini
ln -sfn "$persist_home/.claude" ~/.claude
ln -sfn "$persist_home/.claude.json" ~/.claude.json
ln -sfn "$persist_home/.codex" ~/.codex

# agy stores its known CLI state under ~/.gemini/antigravity-cli. Persist
# keyring data too for Secret Service compatibility in auth flows that request it.
mkdir -p "$persist_home/.local/share/keyrings"
mkdir -p ~/.local/share
ln -sfnT "$persist_home/.local/share/keyrings" ~/.local/share/keyrings

ensure_keyring_service

# Seed the dx-claude-statusline hook in Claude's settings.json without
# clobbering existing keys. Only sets statusLine if it isn't already configured.
claude_settings="$persist_home/.claude/settings.json"
if [ ! -s "$claude_settings" ]; then
    printf '%s\n' '{}' > "$claude_settings"
fi
if ! jq -e '.statusLine' "$claude_settings" >/dev/null 2>&1; then
    tmp="$claude_settings.tmp.$$"
    jq '. + {statusLine: {type: "command", command: "dx-claude-statusline"}}' \
        "$claude_settings" > "$tmp"
    mv "$tmp" "$claude_settings"
fi

echo "AI tools installed:"
for tool in codex gemini claude agy; do
    printf "  %s -> " "$tool"
    command -v "$tool"
done
