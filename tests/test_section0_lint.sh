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

# List of files to check without passing literal unmatched globs.
FILES=()
while IFS= read -r file; do FILES+=("$file"); done < <(
    find "$BASE_DIR/bin" "$BASE_DIR/tests" "$CONTAINER_DIR" -type f \
        \( -name '*.sh' -o -path "$BASE_DIR/bin/dx*" \) -print
)

for file in "${FILES[@]}"; do
    if [ -f "$file" ]; then
        # Errors and warnings are release-blocking. ShellCheck's info/style
        # findings include intentional remote programs and test fixtures.
        if shellcheck --severity=warning "$file"; then
            test_pass "ShellCheck: $(basename "$file")"
        else
            test_fail "ShellCheck: $(basename "$file")"
        fi
    fi
done

print_summary
exit_with_code
