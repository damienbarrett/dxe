#!/bin/bash
# Section 0: Linting tests
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Linting Tests (ShellCheck)"

# The CI contract is asserted before the local-toolchain gate below, because it
# must hold on a developer host that has no ShellCheck installed -- which is
# exactly the host that cannot otherwise notice a broken lint gate.
WORKFLOW="$BASE_DIR/.github/workflows/ci.yml"
assert_file_exists "$WORKFLOW" "CI workflow exists"

# ShellCheck must stay pinned. 0.11.0 aborts with "Non-exhaustive patterns in
# checkCmd" on x="$(source f)", the construct test_refactor_contracts.sh uses to
# prove libraries are import-pure, so taking whatever the runner image ships
# turns a mandatory gate into a version lottery.
assert_file_not_contains "$WORKFLOW" 'apt-get install -y shellcheck' "CI does not take ShellCheck from the runner image"
assert_file_contains_literal "$WORKFLOW" 'nixpkgs/${NIXPKGS_PIN}#shellcheck' "CI runs a pinned ShellCheck"
assert_file_contains "$WORKFLOW" 'NIXPKGS_PIN: nixos-' "CI records the ShellCheck pin"

# Every gate the validation matrix calls CI-required must be present. A dropped
# step would otherwise leave CI green while enforcing less than it claims.
for required in \
    'bash -n' \
    'tests/run_all_tests.sh --skip-integration' \
    'tests/run-coverage-linux.sh' \
    'nix flake check --no-build' \
    'tests/run-bash32-tests.sh'
do
    assert_file_contains_literal "$WORKFLOW" "$required" "CI enforces: $required"
done

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
