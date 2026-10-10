#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP0.2 implementer cases for tests/lib/persist-fixtures.sh that neither
# tests/test_persist_fixtures.sh nor tests/test_persist_fixtures_safety.sh
# pins. The guards must judge the same directory that the tools act on:
#  - a relative cleanup PATH is refused whatever the cwd, CDPATH or $OLDPWD
#    (the safety suite's rule (e)), including the cases an earlier guard
#    resolved against the cwd and accepted;
#  - a parent whose physical name ends in a newline is compared exactly
#    (command substitution must not strip it);
#  - a temp area spelled "//" is the root directory and refuses everything;
#  - a relative TMPDIR, NAS ROOT or builder DIR is never resolved from a
#    stale $PWD (cwd entered through a symlink since repointed), even where
#    bash's cd would fall back to the real cwd;
#  - the tree builder refuses a DIR that already holds one of the names it
#    creates, so it never rewrites or re-permissions an existing entry.
#
# Safety: every guard call here runs under the same kind of jail as the
# acceptance suites -- recording stubs for every destructive tool first on
# PATH, behind an interlock that does not run the call unless each tool
# resolves to its stub -- so a broken guard records a call instead of
# deleting anything. The builder runs with real tools only on directories
# inside this run's fresh mktemp directory, and nothing is created outside it.

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
test_section "persist-fixtures unit: a relative cleanup PATH is refused whatever the cwd"

relative_path_cases() {
    # "sub" exists both in the area (reachable through CDPATH) and in the
    # outside cwd, where rm would really act.
    mkdir -p "$AREA/sub" "$OUTSIDE/sub/dxe-x" "$OUTSIDE/-/dxe-y" "$AREA/sub/dxe-z" "$AREA/dxe-w"
    expect_refused "CDPATH pointing into the temp area does not make an outside relative PATH acceptable" \
        "$AREA" "$OUTSIDE" cleanup_with_cdpath "$AREA_P" sub/dxe-x
    expect_refused "a relative PATH under - is refused, \$OLDPWD inside the temp area or not" \
        "$AREA" "$OUTSIDE" cleanup_with_oldpwd "$AREA_P/sub" -/dxe-y
    expect_refused "a relative PATH is refused even with its parent inside the temp area (CDPATH set elsewhere)" \
        "$AREA" "$AREA" cleanup_with_cdpath "$OUTSIDE" sub/dxe-z
    expect_refused "a bare dxe- name is refused even with the cwd in the temp area" \
        "$AREA" "$AREA" persist_fixture_cleanup dxe-w
}
relative_path_cases

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

assert_eq() { # assert_eq DESC EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (expected [$2], got [$3])"; fi
}

mode_of() { # mode_of PATH: permission bits as four octal digits (lstat)
    perl -e 'my @s = lstat($ARGV[0]) or exit 1; printf "%04o", $s[2] & 07777' "$1"
}

REAL_LN="$(type -P ln)"
# from_stale_cwd LINK NEWTARGET CMD...: enters LINK logically (its current
# target becomes the real cwd), repoints LINK to NEWTARGET, then runs CMD:
# $PWD now spells a path that leads to NEWTARGET, the real cwd is the old
# one. Changes the cwd, so it only ever runs inside a subshell.
from_stale_cwd() {
    local link="$1" new="$2"
    shift 2
    cd -L -- "$link" || return 96
    "$REAL_LN" -sfn -- "$new" "$link" || return 95
    "$@"
}

# ---------------------------------------------------------------------------
test_section "persist-fixtures unit: nothing relative is resolved from a stale \$PWD"

stale_cwd_cases() {
    local s="$SCRATCH/stale" err rc
    mkdir -p "$s/real/area/dxe-t" "$s/fake/area/dxe-t" "$s/real/r" "$s/fake/r" "$s/tools" "$s/links"
    ln -s "$s/real" "$s/links/cwd"
    ln -s "$s/real" "$s/links/cwd2"
    expect_refused "a relative TMPDIR read from a stale \$PWD gives no temp area" \
        area "$SCRATCH" from_stale_cwd "$s/links/cwd" "$s/fake" persist_fixture_cleanup "$s/fake/area/dxe-t"
    expect_accepted "control: the same relative TMPDIR from a sound cwd is the cwd's ./area" \
        area "$s/fake" "$s/fake/area/dxe-t" persist_fixture_cleanup "$s/fake/area/dxe-t"

    err="$(builtin cd -- "$SCRATCH" && from_stale_cwd "$s/links/cwd2" "$s/fake" persist_fixture_nas_create r "$s/tools" 2>&1 >/dev/null)"
    rc=$?
    assert_eq "a relative NAS ROOT from a stale \$PWD: status 1" "1" "$rc"
    assert_eq "a relative NAS ROOT from a stale \$PWD: says it cannot be resolved" "yes" \
        "$(grep -Fq "cannot be resolved" <<<"$err" && echo yes || echo "no: $err")"
    assert_eq "a relative NAS ROOT from a stale \$PWD: no tool directory created" "" "$(ls -A "$s/tools")"

    # Only the real cwd has "victim": bash's cd -P then falls back to the
    # kernel and reports the right directory, but the rule is still to refuse
    # (real tools; every path involved is inside $s).
    mkdir -p "$s/real/victim"
    ln -s "$s/real" "$s/links/cwd3"
    err="$(
        TMPDIR="$s"
        export TMPDIR
        persist_fixture_euid() { echo 1000; }
        builtin cd -- "$SCRATCH" &&
            from_stale_cwd "$s/links/cwd3" "$s/fake" persist_fixture_tree_build victim 2>&1 >/dev/null
    )"
    rc=$?
    assert_eq "a relative DIR from a stale \$PWD that only the real cwd holds: status 1" "1" "$rc"
    assert_eq "a relative DIR from a stale \$PWD that only the real cwd holds: says refusing" "yes" \
        "$(grep -Fq refusing <<<"$err" && echo yes || echo "no: $err")"
    assert_eq "a relative DIR from a stale \$PWD that only the real cwd holds: nothing built" "|no" \
        "$(ls -A "$s/real/victim")|$(test -e "$s/fake/victim" && echo yes || echo no)"
}
stale_cwd_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures unit: the builder never rewrites an entry that was already there"

# build_as_user AREA DIR: the REAL builder (non-root path) with TMPDIR=AREA,
# from $SCRATCH. Interlock: DIR must be textually below $SCRATCH (status 99).
build_as_user() {
    case "$2" in
        *"/.."* | *"../"*) return 99 ;;
        "$SCRATCH"/?*) : ;;
        *) return 99 ;;
    esac
    (
        TMPDIR="$1"
        export TMPDIR
        builtin cd -- "$SCRATCH" || exit 97
        persist_fixture_euid() { echo 1000; }
        persist_fixture_tree_build "$2"
    )
}

existing_entry_cases() {
    local a="$SCRATCH/pre/area" err rc
    mkdir -p "$a/file" "$a/dir/nested" "$a/link"
    printf 'mine\n' > "$a/file/plain.txt"
    chmod 0640 "$a/file/plain.txt"
    chmod 0700 "$a/dir/nested"
    ln -s no-such-target "$a/link/links"

    err="$(build_as_user "$a" "$a/file" 2>&1 >/dev/null)"
    rc=$?
    assert_eq "DIR already holds plain.txt: status 1" "1" "$rc"
    assert_eq "DIR already holds plain.txt: says refusing" "yes" "$(grep -Fq refusing <<<"$err" && echo yes || echo "no: $err")"
    assert_eq "DIR already holds plain.txt: its content is unchanged" "mine" "$(cat "$a/file/plain.txt")"
    assert_eq "DIR already holds plain.txt: its mode is unchanged" "0640" "$(mode_of "$a/file/plain.txt")"
    assert_eq "DIR already holds plain.txt: nothing else is created" "plain.txt" "$(ls -A "$a/file")"

    build_as_user "$a" "$a/dir" >/dev/null 2>&1
    rc=$?
    assert_eq "DIR already holds a nested/ directory: status 1" "1" "$rc"
    assert_eq "DIR already holds a nested/ directory: its mode is unchanged" "0700" "$(mode_of "$a/dir/nested")"
    assert_eq "DIR already holds a nested/ directory: nothing is created in it or beside it" "nested|" \
        "$(ls -A "$a/dir")|$(ls -A "$a/dir/nested")"

    build_as_user "$a" "$a/link" >/dev/null 2>&1
    rc=$?
    assert_eq "DIR already holds a dangling symlink named links: status 1" "1" "$rc"
    assert_eq "DIR already holds a dangling symlink named links: it is unchanged, nothing else created" \
        "links|no-such-target" "$(ls -A "$a/link")|$(readlink "$a/link/links")"
}
existing_entry_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures unit: the builder refuses a directory swapped after validation"

# The validated path is replaced by a function-level seam that names a symlink
# (as if a component were swapped between validation and cd); no real race.
swapped_dir_cases() {
    local a="$SCRATCH/swap/area" err rc
    mkdir -p "$a/real" "$a/other"
    ln -s other "$a/link"
    err="$(
        TMPDIR="$a"
        export TMPDIR
        builtin cd -- "$SCRATCH" || exit 97
        persist_fixture_euid() { echo 1000; }
        _persist_fixture_build_dir() { printf '%s/link/' "$a"; }
        persist_fixture_tree_build "$a/real" 2>&1 >/dev/null
    )"
    rc=$?
    assert_eq "a validated path that now resolves elsewhere: status 1" "1" "$rc"
    assert_eq "a validated path that now resolves elsewhere: says no longer validated" "yes" \
        "$(grep -Fq 'no longer the directory' <<<"$err" && echo yes || echo "no: $err")"
    assert_eq "a validated path that now resolves elsewhere: nothing built in either" "|" \
        "$(ls -A "$a/other")|$(ls -A "$a/real")"
}
swapped_dir_cases

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    print_summary
    exit_with_code
fi
