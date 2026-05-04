#!/bin/bash
# Section 2: Make The Containerfile Lightweight
# Tests for: lightweight Containerfile, no tool installation in Containerfile

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINERFILE="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-25.11/Containerfile"

test_section "Section 2: Make The Containerfile Lightweight"

# Test: Containerfile exists
assert_file_exists "$CONTAINERFILE" "Containerfile exists"

# Test: Containerfile does not have RUN nix profile install
assert_file_not_contains "$CONTAINERFILE" "RUN nix profile install" "Containerfile does not install tools via nix profile"

# Test: Containerfile does not install git
assert_file_not_contains "$CONTAINERFILE" "nixpkgs#git" "Containerfile does not install git"

# Test: Containerfile does not install openssh
assert_file_not_contains "$CONTAINERFILE" "nixpkgs#openssh" "Containerfile does not install openssh"

# Test: Containerfile does not install sudo
assert_file_not_contains "$CONTAINERFILE" "nixpkgs#sudo" "Containerfile does not install sudo"

# Test: Containerfile does not install shadow
assert_file_not_contains "$CONTAINERFILE" "nixpkgs#shadow" "Containerfile does not install shadow"

# Test: Containerfile does not install tar
assert_file_not_contains "$CONTAINERFILE" "nixpkgs#gnutar" "Containerfile does not install tar"

# Test: Containerfile does not install gzip
assert_file_not_contains "$CONTAINERFILE" "nixpkgs#gzip" "Containerfile does not install gzip"

# Test: Containerfile has FROM statement
assert_file_contains "$CONTAINERFILE" "^FROM " "Containerfile has base image"

# Test: Containerfile copies bootstrap files
assert_file_contains "$CONTAINERFILE" "COPY . /guest-bootstrap/" "Containerfile copies bootstrap files"

# Test: Containerfile has CMD
assert_file_contains "$CONTAINERFILE" "^CMD " "Containerfile has default command"

# Test: Containerfile creates /workspace
assert_file_contains "$CONTAINERFILE" "mkdir -p /workspace" "Containerfile creates /workspace"

print_summary
exit_with_code
