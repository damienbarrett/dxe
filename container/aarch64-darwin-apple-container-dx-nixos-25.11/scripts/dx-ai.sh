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
  - antigravity
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

echo "Updating nixpkgs-unstable..."
nix flake update "${NIX_FLAGS[@]}" nixpkgs-unstable

if nix profile list | grep -q "dx-ai-tools"; then
    echo "Upgrading optional AI tools..."
    nix profile upgrade "${NIX_FLAGS[@]}" dx-ai-tools
else
    echo "Installing optional AI tools..."
    nix profile add "${NIX_FLAGS[@]}" .#ai-tools
fi

echo "Setting up AI credentials persistence..."
mkdir -p /workspace/home/dx/.gemini /workspace/home/dx/.claude /workspace/home/dx/.codex /workspace/home/dx/.antigravity
if [ ! -s /workspace/home/dx/.claude.json ]; then
    printf '%s\n' '{}' > /workspace/home/dx/.claude.json
fi
ln -sfn /workspace/home/dx/.gemini ~/.gemini
ln -sfn /workspace/home/dx/.claude ~/.claude
ln -sfn /workspace/home/dx/.claude.json ~/.claude.json
ln -sfn /workspace/home/dx/.codex ~/.codex
ln -sfn /workspace/home/dx/.antigravity ~/.antigravity

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
for tool in codex gemini claude antigravity; do
    printf "  %s -> " "$tool"
    command -v "$tool"
done
