#!/bin/bash
# WP1.5 (Fable D3, Muse D2, Astra R1): the coverage ratchet used to divide
# sourceable-scope TEXT lines by all shell text lines including tests, so
# adding tests lowered the number and adding comments inside a covered
# library raised it. tests/lib/coverage-metric.sh replaces that ratio with
# two numbers read from data the coverage run already produces:
# scope_exec_lines (a floor, kcov's own executable total_lines summed over
# the declared scope) and unscoped_prod_exec_lines (a ceiling, non-comment
# source lines over the exempt production set). This suite proves both are
# immune to test/comment growth and that moving executable lines out of the
# covered scope into an exempt entrypoint fires the ratchet.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/coverage-metric.sh"

test_section "Coverage metric (WP1.5): scope floor / unscoped-production ceiling"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-coverage-metric.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin/lib" "$fixture/tests" \
    "$fixture/container/dx-fixture/scripts/lib"

cat > "$fixture/bin/lib/x.sh" <<'EOF'
#!/bin/bash
# fixture library x
x_hello() {
    echo hello
}
EOF

cat > "$fixture/bin/dx-x" <<'EOF'
#!/bin/bash
# fixture entrypoint dx-x
echo one
echo two
EOF
chmod +x "$fixture/bin/dx-x"

cat > "$fixture/tests/t.sh" <<'EOF'
#!/bin/bash
echo test-fixture
EOF

cat > "$fixture/container/dx-fixture/bootstrap.sh" <<'EOF'
#!/bin/bash
# fixture bootstrap orchestrator
echo boot-one
echo boot-two
echo boot-three
EOF

cat > "$fixture/container/dx-fixture/scripts/one.sh" <<'EOF'
#!/bin/bash
# fixture guest script one
echo guest-one
EOF

cat > "$fixture/container/dx-fixture/scripts/lib/two.sh" <<'EOF'
#!/bin/bash
# fixture guest library two
two_hello() {
    echo two
}
EOF

# A hand-written kcov-shaped summary: only the two files kcov's
# --include-path would actually have instrumented (the scope library and
# the guest scripts/lib file) get entries. total_lines is kcov's own
# executable-line count, deliberately unrelated to the real line count of
# the fixture file it names, to prove dx_coverage_metric trusts kcov's
# number rather than recounting the file itself.
write_fixture_coverage_json() {
    local x_total="$1" two_total="$2" out="$3"
    cat > "$out" <<JSON
{
    "files": [
        {
            "file": "$fixture/bin/lib/x.sh",
            "percent_covered": "100.00",
            "covered_lines": $x_total,
            "total_lines": $x_total
        },
        {
            "file": "$fixture/container/dx-fixture/scripts/lib/two.sh",
            "percent_covered": "100.00",
            "covered_lines": $two_total,
            "total_lines": $two_total
        }
    ],
    "percent_covered": "100.00",
    "covered_lines": $((x_total + two_total)),
    "total_lines": $((x_total + two_total))
}
JSON
}

read_metric_field() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

coverage_json="$fixture/coverage.json"
write_fixture_coverage_json 12 8 "$coverage_json"

metric_baseline="$(dx_coverage_metric "$fixture" "$coverage_json")"
scope_baseline="$(read_metric_field "$metric_baseline" scope_exec_lines)"
unscoped_baseline="$(read_metric_field "$metric_baseline" unscoped_prod_exec_lines)"

if [ "$scope_baseline" = 20 ] && [ "$unscoped_baseline" = 6 ]; then
    test_pass "Baseline fixture: scope_exec_lines=20 (12+8 kcov total_lines), unscoped_prod_exec_lines=6 (2 dx-x + 3 bootstrap.sh + 1 scripts/one.sh)"
else
    test_fail "Baseline fixture: expected scope=20 unscoped=6, got scope=$scope_baseline unscoped=$unscoped_baseline"
fi

# (a) Appending 200 lines to a test file changes neither number: tests/ is
# outside both the kcov scope and the exempt production set.
i=1
while [ "$i" -le 200 ]; do
    echo "echo test-line-$i" >> "$fixture/tests/t.sh"
    i=$((i + 1))
done
metric_a="$(dx_coverage_metric "$fixture" "$coverage_json")"
scope_a="$(read_metric_field "$metric_a" scope_exec_lines)"
unscoped_a="$(read_metric_field "$metric_a" unscoped_prod_exec_lines)"
if [ "$scope_a" = "$scope_baseline" ] && [ "$unscoped_a" = "$unscoped_baseline" ]; then
    test_pass "(a) 200 lines appended to tests/t.sh changes neither number"
else
    test_fail "(a) expected scope=$scope_baseline unscoped=$unscoped_baseline, got scope=$scope_a unscoped=$unscoped_a"
fi

# (b) Appending 50 '#' comment lines to a scope library changes neither
# number: scope_exec_lines trusts kcov's total_lines (comments never appear
# in it), not a recount of the file's text.
i=1
while [ "$i" -le 50 ]; do
    echo "# fixture comment $i" >> "$fixture/bin/lib/x.sh"
    i=$((i + 1))
done
metric_b="$(dx_coverage_metric "$fixture" "$coverage_json")"
scope_b="$(read_metric_field "$metric_b" scope_exec_lines)"
unscoped_b="$(read_metric_field "$metric_b" unscoped_prod_exec_lines)"
if [ "$scope_b" = "$scope_baseline" ] && [ "$unscoped_b" = "$unscoped_baseline" ]; then
    test_pass "(b) 50 comment lines appended to bin/lib/x.sh changes neither number"
else
    test_fail "(b) expected scope=$scope_baseline unscoped=$unscoped_baseline, got scope=$scope_b unscoped=$unscoped_b"
fi

# (c) Simulate moving 10 executable lines out of the scope library and into
# the exempt entrypoint: lower the scope library's kcov total_lines by 10
# (the coverage.json a real kcov run would produce after the move) and add
# 10 real executable lines to bin/dx-x (the exempt entrypoint they landed
# in). scope_exec_lines must fall by 10, unscoped_prod_exec_lines must rise
# by 10, and the ratchet check must fire on both against the prior baseline.
write_fixture_coverage_json 2 8 "$coverage_json"
i=1
while [ "$i" -le 10 ]; do
    echo "echo moved-line-$i" >> "$fixture/bin/dx-x"
    i=$((i + 1))
done
metric_c="$(dx_coverage_metric "$fixture" "$coverage_json")"
scope_c="$(read_metric_field "$metric_c" scope_exec_lines)"
unscoped_c="$(read_metric_field "$metric_c" unscoped_prod_exec_lines)"
expected_scope_c=$((scope_baseline - 10))
expected_unscoped_c=$((unscoped_baseline + 10))
if [ "$scope_c" = "$expected_scope_c" ] && [ "$unscoped_c" = "$expected_unscoped_c" ]; then
    test_pass "(c) moving 10 exec lines out of scope lowers scope_exec_lines by 10 and raises unscoped_prod_exec_lines by 10"
else
    test_fail "(c) expected scope=$expected_scope_c unscoped=$expected_unscoped_c, got scope=$scope_c unscoped=$unscoped_c"
fi

ratchet_prev="$fixture/ratchet-prev.env"
printf 'scope_exec_lines_floor=%s\nunscoped_prod_exec_lines_ceiling=%s\n' "$scope_baseline" "$unscoped_baseline" > "$ratchet_prev"

ratchet_err="$fixture/ratchet-c.err"
if printf '%s\n' "$metric_c" | dx_coverage_ratchet_check - "$ratchet_prev" 2>"$ratchet_err"; then
    test_fail "(c) ratchet check unexpectedly passed after the simulated move"
else
    if grep -q 'scope_exec_lines' "$ratchet_err" && grep -q 'unscoped_prod_exec_lines' "$ratchet_err"; then
        test_pass "(c) ratchet check fails and names both regressed numbers"
    else
        test_fail "(c) ratchet check failed but did not name both numbers: $(cat "$ratchet_err")"
    fi
fi

# (d) The real tests/coverage/ratchet.env: exactly one non-comment line per
# key, no other keys, at most ten lines total. A comment line's first
# non-whitespace character is '#'; a blank line is neither.
real_ratchet="$BASE_DIR/tests/coverage/ratchet.env"
if [ -f "$real_ratchet" ]; then
    real_total_lines="$(wc -l < "$real_ratchet" | tr -d '[:space:]')"
    real_non_comment_count="$(grep -Ecv '^[[:space:]]*(#|$)' "$real_ratchet")"
    real_floor_count="$(grep -Ec '^scope_exec_lines_floor=' "$real_ratchet")"
    real_ceiling_count="$(grep -Ec '^unscoped_prod_exec_lines_ceiling=' "$real_ratchet")"
    if [ "$real_total_lines" -le 10 ] && [ "$real_non_comment_count" -eq 2 ] \
        && [ "$real_floor_count" -eq 1 ] && [ "$real_ceiling_count" -eq 1 ]; then
        test_pass "(d) tests/coverage/ratchet.env is $real_total_lines lines: exactly one scope_exec_lines_floor and one unscoped_prod_exec_lines_ceiling, no other keys"
    else
        test_fail "(d) tests/coverage/ratchet.env shape: total=$real_total_lines non_comment=$real_non_comment_count floor=$real_floor_count ceiling=$real_ceiling_count"
    fi
else
    test_fail "(d) tests/coverage/ratchet.env does not exist"
fi

# (e) The ratchet check passes when both numbers equal the baseline exactly
# (the boundary is inclusive: only strictly below the floor or strictly
# above the ceiling fails).
metric_equal="$(printf 'scope_exec_lines=%s\nunscoped_prod_exec_lines=%s\n' "$scope_baseline" "$unscoped_baseline")"
ratchet_eq_err="$fixture/ratchet-eq.err"
if printf '%s\n' "$metric_equal" | dx_coverage_ratchet_check - "$ratchet_prev" 2>"$ratchet_eq_err"; then
    test_pass "(e) ratchet check passes when both numbers equal the baseline exactly"
else
    test_fail "(e) ratchet check unexpectedly failed at exact baseline: $(cat "$ratchet_eq_err")"
fi

# (f) Blank lines (including whitespace-only) and the shebang are not
# counted as executable.
blank_check="$fixture/blank-check.sh"
printf '#!/bin/bash\n\n# comment\n   \necho code-one\n\necho code-two\n\t\n' > "$blank_check"
count_f="$(dx_coverage_count_exec_lines "$blank_check")"
if [ "$count_f" = 2 ]; then
    test_pass "(f) blank (including whitespace-only) and shebang lines are not counted as executable (got 2 real lines)"
else
    test_fail "(f) expected 2 executable lines, got $count_f"
fi

# Import purity: sourcing the library a second time, in isolation, produces
# no stdout, no stderr, and no non-zero exit -- the contract
# test_refactor_contracts.sh enforces on every sourceable library here.
purity_stderr="$fixture/purity.err"
purity_stdout="$( (source "$SCRIPT_DIR/lib/coverage-metric.sh") 2>"$purity_stderr" )"
purity_status=$?
if [ -z "$purity_stdout" ] && [ ! -s "$purity_stderr" ] && [ "$purity_status" -eq 0 ]; then
    test_pass "tests/lib/coverage-metric.sh sources with no output and exit 0"
else
    test_fail "tests/lib/coverage-metric.sh sourcing was not pure: stdout='$purity_stdout' stderr='$(cat "$purity_stderr")' status=$purity_status"
fi

print_summary
exit_with_code
