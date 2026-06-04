#!/bin/bash
# Section 2: Make The Containerfile Lightweight
# Tests for: lightweight Containerfile, no tool installation in Containerfile

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 2: Make The Containerfile Lightweight"

# Test: Containerfile exists
assert_file_exists "$CONTAINERFILE" "Containerfile exists"

# Test: Containerfile does not have RUN nix profile install
assert_file_not_contains "$CONTAINERFILE" "RUN nix profile install" "Containerfile does not install tools via nix profile"
assert_file_not_contains "$CONTAINERFILE" "^RUN " "Containerfile does not run build-time commands"

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
assert_file_not_contains "$CONTAINERFILE" "^ENV " "Containerfile does not configure runtime environment"

# Test: Containerfile does not bake bootstrap files into the image
assert_file_not_contains "$CONTAINERFILE" "^COPY " "Containerfile does not copy repo files"
assert_file_not_contains "$CONTAINERFILE" "^CMD " "Containerfile does not define runtime bootstrap command"
assert_file_not_contains "$CONTAINERFILE" ".dx-bootstrap-ready" "Containerfile does not contain bootstrap sync logic"

# Test: Containerfile is only the base image selection
if [ "$(grep -cve '^[[:space:]]*$' "$CONTAINERFILE")" -eq 1 ]; then
    test_pass "Containerfile only selects the base image"
else
    test_fail "Containerfile only selects the base image"
fi

print_summary
exit_with_code
