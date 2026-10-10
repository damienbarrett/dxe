#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP0.2 implementer cases for persist_fixture_cleanup's temp-area guard
# (tests/lib/persist-fixtures.sh) that tests/test_persist_fixtures.sh does
# not pin. The guard must judge the same directory that rm will act on:
#  - a relative parent is resolved against the cwd only -- never through
#    CDPATH, and a parent spelled "-" is a directory named "-", not $OLDPWD;
#  - a parent whose physical name ends in a newline is compared exactly
#    (command substitution must not strip it);
#  - a temp area spelled "//" is the root directory and refuses everything.
#
# Safety: every call here runs under the same kind of jail as the acceptance
# suite -- recording stubs for every destructive tool first on PATH, behind
# an interlock that does not run the call unless each tool resolves to its
# stub -- so a broken guard records a call instead of deleting anything.
# Nothing is created outside this run's fresh mktemp directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pfx-unit.XXXXXX")" || exit 1
case "$SCRATCH" in
    */dxe-pfx-unit.*) : ;;
    *) exit 1 ;;
esac
if [ ! -d "$SCRATCH" ] || [ -L "$SCRATCH" ]; then exit 1; fi
trap 'chmod -R u+rwx "$SCRATCH" 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

NL=$'\n'
DESTRUCTIVE_TOOLS="rm chmod chown mv find rmdir unlink rsync"
AREA="$SCRATCH/area"
OUTSIDE="$SCRATCH/outside"
mkdir -p "$AREA" "$OUTSIDE"
# The area spelled physically, as cd -P would print it (macOS: /var -> /private/var).
AREA_P="$(cd -P -- "$AREA" && pwd -P)"

# stubs_create: a new directory with a recording stub for each destructive
# tool; each appends "tool arg..." to DIR/calls.log and exits 0.
stubs_create() {
    local d t
    d="$(mktemp -d "$SCRATCH/stubs.XXXXXX")" || return 1
    : > "$d/calls.log"
    for t in $DESTRUCTIVE_TOOLS; do
        printf '#!/usr/bin/env bash\n{ printf %%s %s; printf " %%s" "$@"; printf "\\n"; } >> %s\nexit 0\n' \
            "$t" "'$d/calls.log'" > "$d/$t" || return 1
        chmod 0755 "$d/$t" || return 1
    done
    printf '%s\n' "$d"
}

# jailed STUBS AREA CWD CMD...: CMD in a subshell with STUBS first on PATH,
# TMPDIR=AREA and cwd=CWD; not run at all (status 98) unless every
# destructive tool resolves to its stub.
jailed() {
    local stubs="$1" area="$2" cwd="$3"
    shift 3
    (
        PATH="$stubs:$PATH"
        export PATH
        hash -r
        TMPDIR="$area"
        export TMPDIR
        cd "$cwd" || exit 97
        for tool in $DESTRUCTIVE_TOOLS; do
            [ "$(command -v "$tool")" = "$stubs/$tool" ] || exit 98
        done
        "$@"
    )
}

# Wrappers run inside the jail's subshell, so their settings do not leak.
cleanup_with_cdpath() { # CDPATH PATH...
    CDPATH="$1"
    export CDPATH
    shift
    persist_fixture_cleanup "$@"
}
cleanup_with_oldpwd() { # OLDPWD PATH...
    OLDPWD="$1"
    export OLDPWD
    shift
    persist_fixture_cleanup "$@"
}

# expect_refused DESC AREA CWD CMD...: status 1, "refusing" on stderr, and
# not one destructive call recorded.
expect_refused() {
    local desc="$1" area="$2" cwd="$3" stubs err rc
    shift 3
    stubs="$(stubs_create)" || { test_fail "$desc: stubs could not be created"; return 0; }
    err="$(jailed "$stubs" "$area" "$cwd" "$@" 2>&1 >/dev/null)"
    rc=$?
    if [ "$rc" = 1 ] && grep -Fq refusing <<<"$err" && [ ! -s "$stubs/calls.log" ]; then
        test_pass "$desc"
    else
        test_fail "$desc (status $rc; stderr [$err]; calls [$(cat "$stubs/calls.log")])"
    fi
}

# log_has_rm_of LOG TARGET: LOG records an rm call whose last argument is
# TARGET. TARGET may hold a newline, so the log is matched as a whole.
log_has_rm_of() {
    case "$NL$(cat "$1")$NL" in
        *"${NL}rm "*" $2$NL"*) return 0 ;;
    esac
    return 1
}

# expect_accepted DESC AREA CWD TARGET CMD...: status 0 and a recorded rm
# call whose last argument is TARGET (the stubs remove nothing).
expect_accepted() {
    local desc="$1" area="$2" cwd="$3" target="$4" stubs rc
    shift 4
    stubs="$(stubs_create)" || { test_fail "$desc: stubs could not be created"; return 0; }
    jailed "$stubs" "$area" "$cwd" "$@" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 0 ] && log_has_rm_of "$stubs/calls.log" "$target"; then
        test_pass "$desc"
    else
        test_fail "$desc (status $rc; calls [$(cat "$stubs/calls.log")])"
    fi
}

# ---------------------------------------------------------------------------
test_section "persist-fixtures unit: a relative parent is resolved against the cwd only"

relative_parent_cases() {
    # "sub" exists both in the area (reachable through CDPATH) and in the
    # outside cwd, where rm would really act.
    mkdir -p "$AREA/sub" "$OUTSIDE/sub/dxe-x" "$OUTSIDE/-/dxe-y" "$AREA/sub/dxe-z" "$AREA/dxe-w"
    expect_refused "CDPATH pointing into the temp area does not make an outside relative parent acceptable" \
        "$AREA" "$OUTSIDE" cleanup_with_cdpath "$AREA_P" sub/dxe-x
    expect_refused "a parent named - is the cwd's ./-, not \$OLDPWD inside the temp area" \
        "$AREA" "$OUTSIDE" cleanup_with_oldpwd "$AREA_P/sub" -/dxe-y
    expect_accepted "a relative parent inside the temp area is accepted (CDPATH set elsewhere)" \
        "$AREA" "$AREA" sub/dxe-z cleanup_with_cdpath "$OUTSIDE" sub/dxe-z
    expect_accepted "a bare dxe- name with the cwd in the temp area is accepted" \
        "$AREA" "$AREA" dxe-w persist_fixture_cleanup dxe-w
}
relative_parent_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures unit: physical names are compared exactly"

exact_name_cases() {
    local base="$SCRATCH/nl"
    # The temp area is base/a; base/a<newline> is a sibling OUTSIDE it.
    mkdir -p "$base/a" "$base/a${NL}/dxe-v" "$base/b${NL}/dxe-u"
    expect_refused "a sibling whose name is the temp area's plus a trailing newline is outside" \
        "$base/a" "$SCRATCH" persist_fixture_cleanup "$base/a${NL}/dxe-v"
    expect_accepted "a temp area whose own name ends in a newline still works" \
        "$base/b${NL}" "$SCRATCH" "$base/b${NL}/dxe-u" persist_fixture_cleanup "$base/b${NL}/dxe-u"
}
exact_name_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures unit: the root directory is never a temp area"

root_area_cases() {
    expect_refused "TMPDIR=// refuses a PATH directly under it" "//" "$SCRATCH" \
        persist_fixture_cleanup ///dxe-x
    expect_refused "TMPDIR=// refuses a PATH in a real temp directory too" "//" "$SCRATCH" \
        persist_fixture_cleanup "$AREA/dxe-w"
}
root_area_cases

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    print_summary
    exit_with_code
fi
