#!/bin/bash
# Coverage metric: two ratcheted numbers instead of a share ratio.
#
# The old `scope_share_basis_points` metric (retired 2026-09-30, WP1.5 /
# decision D-1; full rebaseline history at
# docs/evidence/20260930/coverage-ratchet-history.md) divided sourceable-
# scope TEXT lines by ALL shell text lines, including tests: adding tests
# lowered the ratio (looked like a regression) and adding comments inside a
# covered library raised it (looked like an improvement) without either one
# touching a single line of executable behavior.
#
# These two numbers replace it, both read from data the coverage run
# already produces:
#
#   scope_exec_lines          Sum of kcov's own executable `total_lines`
#                              (never a text-line count) over the declared
#                              kcov scope: bin/lib, container/*/bootstrap,
#                              container/*/scripts/lib. A FLOOR -- it must
#                              not fall. Comments inside scope files never
#                              appear in kcov's total_lines, and test files
#                              are outside the scope entirely, so neither
#                              can move this number.
#
#   unscoped_prod_exec_lines  Non-blank, non-comment source lines over the
#                              exempt production set named in
#                              tests/coverage/exclusions.txt: bin/dx*,
#                              container/*/bootstrap.sh,
#                              container/*/scripts/*.sh (not recursing into
#                              scripts/lib). A CEILING -- it must not rise.
#                              This is what makes moving logic out of the
#                              covered scope and into an exempt entrypoint,
#                              to dodge the 100% gate, show up as a
#                              regression instead of vanishing from every
#                              measurement.
#
# Sourcing this file has no side effects: no `set`, no output, nothing
# executed at source time. See tests/test_refactor_contracts.sh's `$-`/
# stdout/stderr purity check, which every sourceable library in this repo
# must pass, and tests/test_coverage_metric.sh's own copy of it.

# dx_coverage_json_file_totals COVERAGE_JSON
#
# Prints one "<file>\t<total_lines>" line per entry in kcov's `files`
# array. kcov's coverage.json is one key per line (the same assumption
# run-coverage-linux.sh's own parser makes); a per-file object's
# "total_lines" line is paired with the "file" line most recently seen, so
# the top-level summary's trailing "total_lines" -- which has no unconsumed
# "file" line before it -- is dropped rather than double-counted.
dx_coverage_json_file_totals() {
    local coverage_json="$1"
    awk '
        /"file"[ \t]*:/ {
            val = $0
            sub(/^[^"]*"file"[ \t]*:[ \t]*"/, "", val)
            sub(/".*$/, "", val)
            current = val
            have = 1
            next
        }
        /"total_lines"[ \t]*:/ {
            if (have) {
                val = $0
                sub(/^[^:]*:[ \t]*/, "", val)
                gsub(/[^0-9]/, "", val)
                printf "%s\t%s\n", current, val
                have = 0
            }
            next
        }
    ' "$coverage_json"
}

# dx_coverage_guest_dir_is_alias ROOT PATH
#
# True when PATH's container/<guest> component under ROOT is a symlink: a
# compatibility alias of another guest directory (WP9.4 keeps the old
# architecture-named path as a symlink for one release). Both numbers must
# count a guest tree once, so every container/* glob skips aliases.
dx_coverage_guest_dir_is_alias() {
    local root="$1"
    local rel="${2#"$1"/container/}"
    [ -L "$root/container/${rel%%/*}" ]
}

# dx_coverage_scope_exec_lines ROOT COVERAGE_JSON
#
# Sum of kcov total_lines over files whose path falls under one of the
# scope directories: ROOT/bin/lib, ROOT/container/*/bootstrap,
# ROOT/container/*/scripts/lib. A scope directory that does not exist in
# ROOT (e.g. a fixture with no bootstrap/ modules) contributes nothing.
dx_coverage_scope_exec_lines() {
    local root="$1"
    local coverage_json="$2"

    local scope_dirs
    scope_dirs=("$root/bin/lib")
    local d
    for d in "$root"/container/*/bootstrap; do
        dx_coverage_guest_dir_is_alias "$root" "$d" && continue
        [ -d "$d" ] && scope_dirs+=("$d")
    done
    for d in "$root"/container/*/scripts/lib; do
        dx_coverage_guest_dir_is_alias "$root" "$d" && continue
        [ -d "$d" ] && scope_dirs+=("$d")
    done

    local ifs_tab
    ifs_tab="$(printf '\t')"

    local total
    total=0
    local path lines prefix matched
    while IFS="$ifs_tab" read -r path lines; do
        [ -n "$path" ] || continue
        matched=0
        for prefix in "${scope_dirs[@]}"; do
            case "$path" in
                "$prefix"/*) matched=1 ;;
            esac
            [ "$matched" -eq 1 ] && break
        done
        [ "$matched" -eq 1 ] && total=$((total + lines))
    done < <(dx_coverage_json_file_totals "$coverage_json")

    printf '%d' "$total"
}

# dx_coverage_count_exec_lines FILE...
#
# Non-blank, non-comment source lines across the given files. A comment
# line is one whose first non-whitespace character is '#' (so the `#!`
# shebang counts as a comment); a whitespace-only or empty line is blank.
dx_coverage_count_exec_lines() {
    awk '
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            if (line == "") next
            if (substr(line, 1, 1) == "#") next
            count++
        }
        END { print count + 0 }
    ' "$@"
}

# dx_coverage_unscoped_prod_lines ROOT
#
# Non-blank, non-comment lines over the exempt production set:
# ROOT/bin/dx*, ROOT/container/*/bootstrap.sh, ROOT/container/*/scripts/*.sh
# (deliberately not recursing into scripts/lib, which is in scope).
dx_coverage_unscoped_prod_lines() {
    local root="$1"

    local files
    files=()
    local f
    for f in "$root"/bin/dx*; do
        [ -f "$f" ] && files+=("$f")
    done
    for f in "$root"/container/*/bootstrap.sh; do
        dx_coverage_guest_dir_is_alias "$root" "$f" && continue
        [ -f "$f" ] && files+=("$f")
    done
    for f in "$root"/container/*/scripts/*.sh; do
        dx_coverage_guest_dir_is_alias "$root" "$f" && continue
        [ -f "$f" ] && files+=("$f")
    done

    if [ "${#files[@]}" -eq 0 ]; then
        printf '0'
    else
        dx_coverage_count_exec_lines "${files[@]}"
    fi
}

# dx_coverage_metric ROOT COVERAGE_JSON
#
# Prints two lines:
#   scope_exec_lines=<N>
#   unscoped_prod_exec_lines=<N>
#
# COVERAGE_JSON may be empty or missing (e.g. before the first kcov run has
# ever produced one); scope_exec_lines is then 0. unscoped_prod_exec_lines
# never depends on COVERAGE_JSON -- it reads the exempt files directly.
dx_coverage_metric() {
    local root="$1"
    local coverage_json="$2"

    local scope_total
    scope_total=0
    if [ -n "$coverage_json" ] && [ -f "$coverage_json" ]; then
        scope_total="$(dx_coverage_scope_exec_lines "$root" "$coverage_json")"
    fi

    local unscoped_total
    unscoped_total="$(dx_coverage_unscoped_prod_lines "$root")"

    printf 'scope_exec_lines=%s\n' "$scope_total"
    printf 'unscoped_prod_exec_lines=%s\n' "$unscoped_total"
}

# dx_coverage_ratchet_check METRIC_SOURCE RATCHET_ENV
#
# METRIC_SOURCE is a file holding dx_coverage_metric's two output lines, or
# "-" (or empty) to read them from stdin. RATCHET_ENV holds
# scope_exec_lines_floor= and unscoped_prod_exec_lines_ceiling=.
#
# Fails (returns 1) with a named, directional "Error: ..." message on
# stderr for each number that regressed -- both are checked and both are
# named when both regress, never short-circuited after the first. Returns 0
# only when scope_exec_lines >= floor AND unscoped_prod_exec_lines <=
# ceiling; exact equality with the baseline passes.
dx_coverage_ratchet_check() {
    local metric_source="$1"
    local ratchet_env="$2"

    local metric_text
    if [ -z "$metric_source" ] || [ "$metric_source" = "-" ]; then
        metric_text="$(cat)"
    else
        metric_text="$(cat "$metric_source")"
    fi

    local scope_exec_lines
    scope_exec_lines="$(printf '%s\n' "$metric_text" | sed -n 's/^scope_exec_lines=//p' | tail -1)"
    local unscoped_prod_exec_lines
    unscoped_prod_exec_lines="$(printf '%s\n' "$metric_text" | sed -n 's/^unscoped_prod_exec_lines=//p' | tail -1)"

    if [ -z "$scope_exec_lines" ] || [ -z "$unscoped_prod_exec_lines" ]; then
        echo "Error: coverage metric output from '$metric_source' is missing scope_exec_lines or unscoped_prod_exec_lines." >&2
        return 1
    fi

    local floor
    floor="$(sed -n 's/^scope_exec_lines_floor=//p' "$ratchet_env" | tail -1)"
    local ceiling
    ceiling="$(sed -n 's/^unscoped_prod_exec_lines_ceiling=//p' "$ratchet_env" | tail -1)"

    if [ -z "$floor" ] || [ -z "$ceiling" ]; then
        echo "Error: $ratchet_env is missing scope_exec_lines_floor or unscoped_prod_exec_lines_ceiling." >&2
        return 1
    fi

    local failed
    failed=0
    if [ "$scope_exec_lines" -lt "$floor" ]; then
        echo "Error: scope_exec_lines dropped below its floor: $scope_exec_lines < $floor (production logic left the covered scope; if intentional, lower the floor in $ratchet_env with a recorded reason)." >&2
        failed=1
    fi
    if [ "$unscoped_prod_exec_lines" -gt "$ceiling" ]; then
        echo "Error: unscoped_prod_exec_lines rose above its ceiling: $unscoped_prod_exec_lines > $ceiling (executable logic grew in the exempt production set; if intentional, raise the ceiling in $ratchet_env with a recorded reason)." >&2
        failed=1
    fi

    [ "$failed" -eq 0 ]
}
