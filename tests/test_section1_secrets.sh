#!/bin/bash
# Section 1: Protect Local Secrets And Generated Files
# Tests for: .gitignore setup, secret exclusion, DS_Store handling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

test_section "Section 1: Protect Local Secrets And Generated Files"

# Test: .gitignore exists
assert_file_exists "$BASE_DIR/.gitignore" ".gitignore exists"

# Test: dx_key in .gitignore
assert_file_contains "$BASE_DIR/.gitignore" "dx_key" "dx_key is in .gitignore"

# Test: dx_key.pub in .gitignore
assert_file_contains "$BASE_DIR/.gitignore" "dx_key.pub" "dx_key.pub is in .gitignore"

# Test: .DS_Store in .gitignore
assert_file_contains "$BASE_DIR/.gitignore" "\.DS_Store" ".DS_Store is in .gitignore"

# Test: *.swp in .gitignore
assert_file_contains "$BASE_DIR/.gitignore" "\*\.swp" "*.swp is in .gitignore"

# Test: dx-host-export*.tar in .gitignore
assert_file_contains "$BASE_DIR/.gitignore" "dx-host-export.*\.tar" "dx-host-export*.tar is in .gitignore"

# Test: dx_key not tracked by git
assert_git_not_tracked "$BASE_DIR/dx_key" "dx_key is not tracked by git"

# Test: dx_key.pub not tracked by git
assert_git_not_tracked "$BASE_DIR/dx_key.pub" "dx_key.pub is not tracked by git"

# Test: No .DS_Store files in working tree
if find "$BASE_DIR" -name ".DS_Store" 2>/dev/null | grep -q .; then
    test_fail "No .DS_Store files in working tree"
else
    test_pass "No .DS_Store files in working tree"
fi

# Test: git status does not show dx_key, dx_key.pub, or .DS_Store
GIT_STATUS=$(git -C "$BASE_DIR" status --short 2>/dev/null || echo "")
if echo "$GIT_STATUS" | grep -q "dx_key"; then
    test_fail "git status does not show dx_key"
else
    test_pass "git status does not show dx_key"
fi
if echo "$GIT_STATUS" | grep -q "dx_key.pub"; then
    test_fail "git status does not show dx_key.pub"
else
    test_pass "git status does not show dx_key.pub"
fi
if echo "$GIT_STATUS" | grep -q "\.DS_Store"; then
    test_fail "git status does not show .DS_Store"
else
    test_pass "git status does not show .DS_Store"
fi

print_summary
exit_with_code
