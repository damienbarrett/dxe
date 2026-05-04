#!/bin/bash
# Section 0: Linting tests
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Linting Tests (ShellCheck)"

if ! command -v shellcheck >/dev/null 2>&1; then
    test_skip "ShellCheck not installed"
    print_summary
    exit_with_code
fi

# List of files to check
# shellcheck disable=SC2206
FILES=(
    "$BASE_DIR"/bin/*
    "$BASE_DIR"/tests/*.sh
    "$CONTAINER_DIR"/bootstrap.sh
)

for file in "${FILES[@]}"; do
    if [ -f "$file" ]; then
        if shellcheck "$file"; then
            test_pass "ShellCheck: $(basename "$file")"
        else
            test_fail "ShellCheck: $(basename "$file")"
        fi
    fi
done

print_summary
exit_with_code
