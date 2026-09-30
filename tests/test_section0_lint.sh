#!/bin/bash
# tier: unit
# bash32: no
# Section 0: Linting tests
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CI pins ShellCheck to 0.10.0 (cross-ref: .github/workflows/ci.yml's
# "ShellCheck" step, NIXPKGS_PIN=nixos-25.05 -- see that step's own comment
# for why 0.10.0 and not 0.11.x). This suite's own ShellCheck cases below run
# whatever `shellcheck` happens to already be on the LOCAL/runner PATH
# instead: there is no nix-pinned shellcheck available inside this
# container-free tier, so a stock CI runner image or a developer's own
# machine can easily have a different binary. A version other than the pin
# can disagree with it in either direction -- flag something 0.10.0 does
# not, or miss something it does -- so a mismatch is reported below as a
# skip (not a failure) naming both versions, unless the caller asked for
# --strict/DXE_LINT_STRICT=1, where any deviation from the pin is itself an
# error.
DXE_LINT_PINNED_SHELLCHECK_VERSION="0.10.0"

# Prints the installed `shellcheck`'s version (e.g. "0.10.0"), or nothing if
# it is missing or its `--version` output does not match the expected
# `version: X.Y.Z` line. Safe to call whether or not shellcheck is on PATH.
_dxe_lint_installed_shellcheck_version() {
    command -v shellcheck >/dev/null 2>&1 || return 0
    shellcheck --version 2>/dev/null | awk -F': ' '/^version:/ { print $2 }'
}

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

# DXE_LINT_VERSION_SELFTEST probes the version-mismatch branches below (skip
# when not --strict, error when --strict) against a real, if fake,
# `shellcheck` on PATH that deliberately reports a version other than the
# pin -- so the comparison is exercised end to end, not only unit-tested in
# isolation. Guarded and short-circuited exactly like the
# DXE_LINT_STRICT_SELFTEST probe above, before test_helpers.sh is sourced,
# for the same reason: this process's own exit status and stdout/stderr are
# the only signal the outer case reads, and it must never share the outer
# run's results-file bookkeeping.
if [ "${DXE_LINT_VERSION_SELFTEST:-0}" = "1" ]; then
    selftest_version="$(_dxe_lint_installed_shellcheck_version)"
    if [ -z "$selftest_version" ]; then
        echo "Error: version selftest expects a fake shellcheck on PATH reporting a version" >&2
        exit 2
    fi
    if [ "$selftest_version" = "$DXE_LINT_PINNED_SHELLCHECK_VERSION" ]; then
        echo "Error: version selftest fake must report a version other than the pin ($DXE_LINT_PINNED_SHELLCHECK_VERSION)" >&2
        exit 2
    fi
    if [ "${DXE_LINT_STRICT:-0}" = "1" ]; then
        echo "Error: local shellcheck ($selftest_version) does not match CI's pinned $DXE_LINT_PINNED_SHELLCHECK_VERSION (.github/workflows/ci.yml), and --strict/DXE_LINT_STRICT=1 treats a version mismatch as an error" >&2
        exit 1
    fi
    echo "SKIP: local shellcheck ($selftest_version) does not match CI's pinned $DXE_LINT_PINNED_SHELLCHECK_VERSION (.github/workflows/ci.yml); findings may differ by version, so this is not treated as a failure"
    exit 0
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

# Prove the version-mismatch branches (this WP) against a real, if fake,
# binary named `shellcheck` on PATH -- not by removing it (the --strict
# selftest above already covers "absent"), but by making it report a
# version other than the CI pin. version_probe_dir is prepended to PATH
# only for the nested invocations below, never for this outer run's own
# ShellCheck cases further down.
version_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-section0-version.XXXXXX")"
cat > "$version_probe_dir/shellcheck" <<'FAKE_SHELLCHECK'
#!/usr/bin/env bash
case "${1:-}" in
    --version)
        printf 'ShellCheck - shell script analysis tool\nversion: 9.9.9\nlicense: GNU General Public License, version 3\nwebsite: https://www.shellcheck.net\n'
        exit 0
        ;;
esac
echo "fake shellcheck: unexpected invocation: $*" >&2
exit 1
FAKE_SHELLCHECK
chmod 0755 "$version_probe_dir/shellcheck"

version_probe_out="$(mktemp "${TMPDIR:-/tmp}/dxe-section0-version.XXXXXX")"
version_probe_status=0
# DXE_LINT_STRICT=0 is set explicitly (not merely left unset), so this
# case's own claim -- "non-strict skips" -- holds regardless of whatever
# DXE_LINT_STRICT the caller of this whole suite already had in its
# ambient environment (env inheritance would otherwise let that leak into
# the nested run and flip its branch).
DXE_LINT_VERSION_SELFTEST=1 DXE_LINT_STRICT=0 PATH="$version_probe_dir:$PATH" \
    "$strict_probe_bash" "$SCRIPT_DIR/test_section0_lint.sh" >"$version_probe_out" 2>&1 || version_probe_status=$?
if [ "$version_probe_status" -eq 0 ] && grep -Fq 'SKIP' "$version_probe_out" \
    && grep -Fq '9.9.9' "$version_probe_out" && grep -Fq "$DXE_LINT_PINNED_SHELLCHECK_VERSION" "$version_probe_out"; then
    test_pass "a shellcheck whose --version differs from the CI pin ($DXE_LINT_PINNED_SHELLCHECK_VERSION) is skipped, naming both versions, rather than failed"
else
    test_fail "a shellcheck whose --version differs from the CI pin is skipped, naming both versions (status=$version_probe_status: $(cat "$version_probe_out"))"
fi
rm -f "$version_probe_out"

version_probe_strict_out="$(mktemp "${TMPDIR:-/tmp}/dxe-section0-version.XXXXXX")"
version_probe_strict_status=0
DXE_LINT_VERSION_SELFTEST=1 DXE_LINT_STRICT=1 PATH="$version_probe_dir:$PATH" \
    "$strict_probe_bash" "$SCRIPT_DIR/test_section0_lint.sh" >"$version_probe_strict_out" 2>&1 || version_probe_strict_status=$?
if [ "$version_probe_strict_status" -eq 1 ] && grep -Fq 'Error' "$version_probe_strict_out" \
    && grep -Fq '9.9.9' "$version_probe_strict_out" && grep -Fq "$DXE_LINT_PINNED_SHELLCHECK_VERSION" "$version_probe_strict_out"; then
    test_pass "--strict / DXE_LINT_STRICT=1 treats a shellcheck version mismatch as an error, naming both versions"
else
    test_fail "--strict / DXE_LINT_STRICT=1 treats a shellcheck version mismatch as an error (status=$version_probe_strict_status: $(cat "$version_probe_strict_out"))"
fi
rm -f "$version_probe_strict_out"
rm -rf "$version_probe_dir"

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

# Version-aware gate (this WP): the runner's own `shellcheck` binary is not
# necessarily CI's pinned 0.10.0 (see DXE_LINT_PINNED_SHELLCHECK_VERSION's
# own comment near the top of this file), and a different version can
# disagree with the pin's findings in either direction. Treat a mismatch as
# a skip -- not a failure -- unless --strict/DXE_LINT_STRICT=1 asked for the
# pin to be enforced exactly.
installed_shellcheck_version="$(_dxe_lint_installed_shellcheck_version)"
if [ -n "$installed_shellcheck_version" ] && [ "$installed_shellcheck_version" != "$DXE_LINT_PINNED_SHELLCHECK_VERSION" ]; then
    if [ "$DXE_LINT_STRICT" = "1" ]; then
        echo "Error: local shellcheck ($installed_shellcheck_version) does not match CI's pinned $DXE_LINT_PINNED_SHELLCHECK_VERSION (.github/workflows/ci.yml), and --strict/DXE_LINT_STRICT=1 treats a version mismatch as an error" >&2
        test_fail "ShellCheck version must match the CI pin ($DXE_LINT_PINNED_SHELLCHECK_VERSION) under --strict/DXE_LINT_STRICT=1, found $installed_shellcheck_version"
        print_summary
        exit_with_code
    fi
    test_skip "ShellCheck version mismatch: local $installed_shellcheck_version vs CI's pinned $DXE_LINT_PINNED_SHELLCHECK_VERSION (.github/workflows/ci.yml) -- findings may differ by version, so this is not treated as a failure"
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
