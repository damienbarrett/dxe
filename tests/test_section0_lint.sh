#!/bin/bash
# tier: unit
# bash32: no
# Section 0: Linting tests
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fable E1 / Muse E2 (WP9.3): DXE_LINT_STRICT_SELFTEST is set only by this
# file's own Red/Green case below (search "DXE_LINT_STRICT_SELFTEST"), to
# probe the --strict/DXE_LINT_STRICT=1 shellcheck-missing branch under a
# fake, literally empty PATH in complete isolation. Exiting here, before
# test_helpers.sh (and so before any results-file bookkeeping) is even
# sourced, means the nested invocation neither re-enters this same probe
# (no recursion) nor leaks pass/fail records into the outer run's results
# file (no shared DXE_TEST_RESULTS bookkeeping is ever touched).
if [ "${DXE_LINT_STRICT_SELFTEST:-0}" = "1" ]; then
    if command -v shellcheck >/dev/null 2>&1; then
        echo "shellcheck is on PATH (selftest expected it absent)" >&2
        exit 2
    fi
    echo "Error: shellcheck is not installed on PATH, and --strict (or DXE_LINT_STRICT=1) requires it" >&2
    exit 1
fi

source "$SCRIPT_DIR/test_helpers.sh"

test_section "Linting Tests (ShellCheck)"

# --strict / DXE_LINT_STRICT=1: fail loudly instead of silently skipping when
# ShellCheck is absent. Local dev hosts commonly have no ShellCheck
# (docs/refactor/validation-matrix.md), so the default stays a skip and CI
# remains the only mandatory lint gate; --strict is for a caller that wants
# lint enforced right now and would rather see a named Error than a silent
# pass.
DXE_LINT_STRICT="${DXE_LINT_STRICT:-0}"
for lint_arg in "$@"; do
    [ "$lint_arg" = "--strict" ] && DXE_LINT_STRICT=1
done

# WP8.4b (Fable D7): the CI-workflow-literal checks that used to live here
# (CI's ShellCheck pin, and every gate the validation matrix calls
# CI-required) moved to tests/test_contracts_source.sh, alongside the other
# reviewed source-text contracts -- this file keeps only ShellCheck's own
# execution and the --strict self-test below.

# Fable E1 / Muse E2 (WP9.3): prove --strict/DXE_LINT_STRICT=1 fails loudly,
# naming shellcheck, under a fake PATH that genuinely has no shellcheck on it
# (a literally empty PATH, so no host's install location can leak in). The
# probe re-invokes this very file with DXE_LINT_STRICT_SELFTEST=1, which a
# guard near the top of this file intercepts before test_helpers.sh (and so
# before any results-file bookkeeping) is even sourced -- the nested run's
# own exit status and output are the only signal; it never touches this
# run's own pass/fail records.
strict_probe_out="$(mktemp "${TMPDIR:-/tmp}/dxe-section0-strict.XXXXXX")"
strict_probe_status=0
strict_probe_bash="$(command -v bash)"
DXE_LINT_STRICT_SELFTEST=1 PATH="" "$strict_probe_bash" "$SCRIPT_DIR/test_section0_lint.sh" >"$strict_probe_out" 2>&1 || strict_probe_status=$?
if [ "$strict_probe_status" -eq 1 ] && grep -Fq 'Error' "$strict_probe_out" && grep -Fq 'shellcheck' "$strict_probe_out"; then
    test_pass "--strict / DXE_LINT_STRICT=1 fails loudly, naming shellcheck, when the binary is absent"
else
    test_fail "--strict / DXE_LINT_STRICT=1 fails loudly, naming shellcheck, when the binary is absent (status=$strict_probe_status: $(cat "$strict_probe_out"))"
fi
rm -f "$strict_probe_out"

if ! command -v shellcheck >/dev/null 2>&1; then
    if [ "$DXE_LINT_STRICT" = "1" ]; then
        echo "Error: shellcheck is not installed on PATH, and --strict (or DXE_LINT_STRICT=1) requires it" >&2
        test_fail "ShellCheck is required under --strict/DXE_LINT_STRICT=1 but is not installed"
        print_summary
        exit_with_code
    fi
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
