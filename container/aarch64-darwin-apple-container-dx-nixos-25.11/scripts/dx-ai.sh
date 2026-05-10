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
mkdir -p /workspace/home/dx/.gemini /workspace/home/dx/.claude /workspace/home/dx/.codex
touch /workspace/home/dx/.claude.json
ln -sfn /workspace/home/dx/.gemini ~/.gemini
ln -sfn /workspace/home/dx/.claude ~/.claude
ln -sfn /workspace/home/dx/.claude.json ~/.claude.json
ln -sfn /workspace/home/dx/.codex ~/.codex

echo "AI tools installed:"
for tool in codex gemini claude; do
    printf "  %s -> " "$tool"
    command -v "$tool"
done
