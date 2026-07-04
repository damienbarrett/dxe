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

# Test: Containerfile's single non-blank line is EXACTLY the adopted
# official base reference (nix-base-plan.md change 1). This is a fixed-
# string, full-line equality check, not a pattern through
# assert_file_contains (that helper runs plain `grep -q`, i.e. BASIC
# regular expressions - an ERE like `+`/`{64}` could never match a
# sha256 digest through it). One string comparison is sufficient to
# catch every corruption mode: a wrong tag, a changed digest, a
# digest-only reference (no tag), `latest`, an extra instruction line,
# and an extra non-blank line all produce a captured value that differs
# from the expected line below (the extra-line case also already fails
# the one-non-blank-line check above, and is captured here as well
# since `$(...)` would embed a newline that cannot equal the single-line
# expectation).
DX_EXPECTED_CONTAINERFILE_LINE="FROM nixos/nix:2.31.5@sha256:4ae3542b89e38bf739a98d9e1ffd082c3c7b8a6455ec0c2331560b9440aec442"
actual_containerfile_line="$(grep -ve '^[[:space:]]*$' "$CONTAINERFILE")"
if [ "$actual_containerfile_line" = "$DX_EXPECTED_CONTAINERFILE_LINE" ]; then
    test_pass "Containerfile's non-blank line exactly matches the adopted official base reference"
else
    test_fail "Containerfile's non-blank line exactly matches the adopted official base reference (got: '$actual_containerfile_line')"
fi

print_summary
exit_with_code
