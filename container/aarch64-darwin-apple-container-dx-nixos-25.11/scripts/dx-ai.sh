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
mkdir -p /workspace/home/dx/.gemini /workspace/home/dx/.claude /workspace/home/dx/.codex
if [ ! -s /workspace/home/dx/.claude.json ]; then
    printf '%s\n' '{}' > /workspace/home/dx/.claude.json
fi
ln -sfn /workspace/home/dx/.gemini ~/.gemini
ln -sfn /workspace/home/dx/.claude ~/.claude
ln -sfn /workspace/home/dx/.claude.json ~/.claude.json
ln -sfn /workspace/home/dx/.codex ~/.codex

# Persist keyring data (used by agy for OAuth tokens via D-Bus Secret Service)
mkdir -p /workspace/home/dx/.local/share/keyrings
mkdir -p ~/.local/share
ln -sfnT /workspace/home/dx/.local/share/keyrings ~/.local/share/keyrings

# Start D-Bus session + gnome-keyring if not already running, so agy can
# persist OAuth tokens via the Secret Service API (zalando/go-keyring).
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    env_file="$HOME/.dx-keyring-env"
    if command -v dbus-daemon >/dev/null 2>&1 && command -v gnome-keyring-daemon >/dev/null 2>&1; then
        dbus-daemon --config-file="$(dbus_session_config)" --fork --print-address > "$env_file.addr"
        export DBUS_SESSION_BUS_ADDRESS="$(cat "$env_file.addr")"
        rm -f "$env_file.addr"
        echo -n '' | gnome-keyring-daemon --unlock --start --components=secrets 2>/dev/null || true
        printf "export DBUS_SESSION_BUS_ADDRESS='%s'\n" "$DBUS_SESSION_BUS_ADDRESS" > "$env_file"
        echo "D-Bus keyring service started for agy credential persistence."
    else
        echo "Warning: dbus-daemon or gnome-keyring-daemon not found. agy auth may not persist."
    fi
fi

# Seed the dx-claude-statusline hook in Claude's settings.json without
# clobbering existing keys. Only sets statusLine if it isn't already configured.
claude_settings=/workspace/home/dx/.claude/settings.json
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
