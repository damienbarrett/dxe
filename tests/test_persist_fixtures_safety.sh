#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP0.2 safety hardening: acceptance tests for tests/lib/persist-fixtures.sh
# written after the independent safety review of bf36e56 (findings B1-B3,
# A1, A3-A5). They extend tests/test_persist_fixtures.sh; where the two
# differ, THIS file's contract wins.
#
# Interface contract (all of it pinned by this file):
#
#  Temp area -- ONE rule, shared by persist_fixture_cleanup and
#  persist_fixture_tree_build:
#    AREA is ${TMPDIR:-/tmp} as set at the moment of the call, resolved
#    physically. There is NO usable temp area, and every call of either
#    function is refused, when AREA does not resolve, is the root directory,
#    or equals or contains (is an ancestor of) either of:
#      - the ACCOUNT HOME: the home-directory field of the passwd entry of
#        the effective uid (perl: (getpwuid($>))[7]), resolved physically;
#        ignored when there is none or it does not resolve. It is NOT $HOME:
#        suites isolate HOME in a fixture under the temp area (the
#        established pattern of tests/test_docker_adapter_*.sh), and the
#        fixtures must keep working there;
#      - the CHECKOUT ROOT: the directory two levels above the sourced
#        tests/lib/persist-fixtures.sh file, resolved physically.
#    Paths are compared physically and by whole components: X is inside
#    AREA when X's physical path is AREA's physical path followed by "/"
#    and at least one more component.
#
#  persist_fixture_cleanup PATH...
#    (e) A PATH that does not begin with "/" is refused like any other bad
#        PATH (status 1, "refusing" on stderr, no destructive command for any
#        PATH of the call), whatever the cwd. A relative PATH lets the guard
#        and rm judge different directories (cwd entered through a symlink
#        that was later repointed: bash's cd -P / pwd -P then start from the
#        stale $PWD string, rm from the real cwd).
#    Removal of an accepted PATH:
#      - a symbolic link PATH: exactly one destructive command,
#        `rm -f -- PATH`, and nothing else (no chmod, no find);
#      - otherwise, before the `rm -rf`, u+rwx is added to DIRECTORIES only
#        -- every directory under PATH, PATH included -- never to a regular
#        file or a symlink, and never by a recursive chmod (no -R): a hard
#        link inside PATH shares its inode, so its mode, with a file that
#        may live outside the temp area. The walk does not follow symlinks.
#        chmod is still reached through PATH, directly or through find/xargs
#        (e.g. `find -P PATH -type d -exec chmod u+rwx {} \;`).
#
#  persist_fixture_tree_build DIR
#    1. DIR is not an existing directory: status 1, "does not exist" on
#       stderr (unchanged; checked first, so a missing DIR outside the temp
#       area still says "does not exist").
#    2. Otherwise DIR is refused -- status 1, "refusing" on stderr, nothing
#       created in DIR or anywhere else, no mode or owner changed, no
#       destructive command run -- unless there is a usable temp area and
#       DIR, resolved physically, lies strictly inside it (DIR == AREA is
#       refused).
#    3. A relative DIR is resolved against the shell's actual current
#       directory only -- entered as ./DIR, or made absolute first -- so
#       CDPATH never applies and "-" is the directory named "-", not
#       $OLDPWD. When $PWD does not name the current directory
#       ([ "$PWD" -ef . ] is false: the cwd was entered through a symlink
#       that has since been repointed) a relative DIR is refused.
#    4. It reaches DIR only by changing into it with the shell's `cd` as
#       normally looked up (so a shell function named cd intercepts it --
#       never `builtin cd`, `command cd`, pushd or a subprocess), and creates
#       every entry relative to the directory that cd left it in, never
#       through an absolute "$DIR/..." path. (The jail below relies on this
#       to stop a broken guard before anything is written.)
#    5. It sets the pinned modes on the entries it creates and never changes
#       the mode or content of an entry that existed under DIR before it ran
#       (no sweep over the whole tree). DIR's own mode is not pinned.
#    6. Root path: every chown target, resolved from chown's working
#       directory, is the DIR/owners/<name> entry -- for a relative DIR too.
#       (For an absolute DIR the argv stays exactly "$DIR/owners/<name>", as
#       tests/test_persist_fixtures.sh pins.)
#
#  persist_fixture_nas_create ROOT [PARENT]
#    A relative ROOT is stored and used as its absolute physical path,
#    `cd -P -- ./ROOT && pwd -P`: DXE_FIXTURE_NAS_ROOT is exactly that path
#    and the remote command runs there, from any cwd and whatever CDPATH
#    holds, at creation and at ssh time; "-" is the directory named "-".
#    (An absolute ROOT is kept as given, as already pinned.)
#
#  Safety design of THIS suite (incident 2026-10-11: a mutation probe that
#  disabled a guard let the old refusal cases run the real `chmod -R u+rwx /`).
#  Real destructive commands only ever see paths this run created inside its
#  own fresh mktemp directory ($SCRATCH). Everything else runs in a JAIL: a
#  subshell with recording stubs first on PATH (each appends its argv to a
#  log, exits 0 and does nothing), an interlock that does not run the call
#  unless every stubbed tool resolves to its stub, and TMPDIR/cwd set to
#  scratch directories. The jail stubs:
#    - cleanup cases:    rm chmod chown mv find rmdir unlink rsync;
#    - builder cases:    the same, plus a shell function `cd` that lets the
#                        shell into a directory only when it is inside
#                        $SCRATCH (judged by the external pwd, so a stale
#                        $PWD cannot fool it); any other destination is
#                        swapped for an empty scratch "cd trap", so a broken
#                        guard builds into the trap, never into $HOME, the
#                        checkout or /. Contract item 4 makes this airtight
#                        and the "cd interception" case validates it;
#    - $HOME, checkout, / builder cases: additionally mkdir ln mkfifo mknod
#                        touch cp install tee.
#  The account-home and checkout cases of the temp-area rule hand the cleanup
#  only dxe- names that do not exist there, under the stubs; the checkout
#  rule is otherwise exercised on a decoy checkout (a copy of the library in
#  $SCRATCH), so a broken rule acts on scratch directories only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
LIB="$SCRIPT_DIR/lib/persist-fixtures.sh"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pfx-safety.XXXXXX")" || exit 1
# Never arm the recursive trap on anything but the fresh mktemp directory.
case "$SCRATCH" in
    */dxe-pfx-safety.*) : ;;
    *) exit 1 ;;
esac
if [ ! -d "$SCRATCH" ] || [ -L "$SCRATCH" ]; then exit 1; fi
trap 'chmod -R u+rwx "$SCRATCH" 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

SCRATCH_P="$(cd -P -- "$SCRATCH" && pwd -P)"
# The external pwd asks the kernel (getcwd), so a stale $PWD cannot fool it.
PWD_BIN="$(type -P pwd)"
REAL_LN="$(type -P ln)"
NL=$'\n'
CHECKOUT_P="$(cd -P -- "$BASE_DIR" && pwd -P)"
# The account home as the contract defines it ("" when there is none).
ACCOUNT_HOME="$(perl -e 'my $h = (getpwuid($>))[7]; print $h if defined $h' 2>/dev/null)"
if [ -n "$ACCOUNT_HOME" ] && [ -d "$ACCOUNT_HOME" ]; then
    ACCOUNT_HOME="$(cd -P -- "$ACCOUNT_HOME" && pwd -P)"
else
    ACCOUNT_HOME=""
fi

SANDBOX="$SCRATCH/sandbox"   # empty cwd for jailed calls; must stay empty
mkdir -p "$SANDBOX"

DESTRUCTIVE_TOOLS="rm chmod chown mv find rmdir unlink rsync"
CREATION_TOOLS="mkdir ln mkfifo mknod touch cp install tee"

# --- local helpers ----------------------------------------------------------
lstat_field() { # lstat_field FIELD PATH: nlink | mode | owner
    perl -e '
        my @s = lstat($ARGV[1]) or exit 1;
        my $f = $ARGV[0];
        if    ($f eq "nlink") { print $s[3] }
        elsif ($f eq "mode")  { printf "%04o", $s[2] & 07777 }
        elsif ($f eq "owner") { print "$s[4]:$s[5]" }
        else { exit 2 }' "$1" "$2"
}

assert_eq() { # assert_eq DESC EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (expected [$2], got [$3])"; fi
}

assert_true() { # assert_true DESC CMD...
    local d="$1"; shift
    if "$@"; then test_pass "$d"; else test_fail "$d"; fi
}

assert_false() { # assert_false DESC CMD...
    local d="$1"; shift
    if "$@"; then test_fail "$d"; else test_pass "$d"; fi
}

# need FN: fails the current case (once) when the helper function is missing.
need() {
    if type "$1" >/dev/null 2>&1; then return 0; fi
    test_fail "$1 is not defined (tests/lib/persist-fixtures.sh)"
    return 1
}

exists() { test -e "$1" || test -L "$1"; }

physical() { (cd -P -- "$1" && pwd -P); }

listing() { ls -A "$1" 2>&1; }

# --- the jail (see "Safety design" above) -----------------------------------

# stubs_create TOOLS: prints a new directory holding a recording stub for each
# tool in TOOLS. Each stub appends ONE line "tool arg1 arg2 ..." to
# DIR/calls.log and exits 0 WITHOUT doing anything; the chown stub also
# appends its physical cwd, each argument, and "--", one per line, to
# DIR/chown.log. Self-contained on purpose: the jail must not depend on the
# library (or the fake-tools.sh it pulls in) that it protects the machine from.
stubs_create() {
    local d t
    d="$(mktemp -d "$SCRATCH/stubs.XXXXXX")" || return 1
    : > "$d/calls.log" || return 1
    : > "$d/chown.log" || return 1
    for t in $1; do
        {
            printf '#!/usr/bin/env bash\n'
            printf '{ printf %%s %s; printf " %%s" "$@"; printf "\\n"; } >> %q\n' "$t" "$d/calls.log"
            if [ "$t" = chown ]; then
                printf '{ %q -P; printf "%%s\\n" "$@"; echo --; } >> %q\n' "$PWD_BIN" "$d/chown.log"
            fi
            printf 'exit 0\n'
        } > "$d/$t" || return 1
        chmod 0755 "$d/$t" || return 1
    done
    printf '%s\n' "$d"
}

# classifying_chmod_write DIR: replaces DIR/chmod with a stub that changes
# nothing and records, one line each in DIR/chmod.log, "flag OPT" for every
# option (any argument starting with "-" before a "--"), "mode MODE", and
# "op TYPE PATH" for every operand: TYPE l (symlink), d (directory; PATH is
# then its physical path), f (regular file) or o (anything else), judged at
# the moment chmod ran.
classifying_chmod_write() {
    local d="$1"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'log=%q\npwd_bin=%q\n' "$d/chmod.log" "$PWD_BIN"
        cat <<'STUB'
opts=1 mode=""
for a in "$@"; do
    if [ "$opts" = 1 ]; then
        case "$a" in
            --) opts=0; continue ;;
            -?*) printf 'flag %s\n' "$a" >> "$log"; continue ;;
        esac
    fi
    if [ -z "$mode" ]; then
        mode="$a"
        printf 'mode %s\n' "$a" >> "$log"
        continue
    fi
    if [ -L "$a" ]; then
        printf 'op l %s\n' "$a"
    elif [ -d "$a" ]; then
        printf 'op d %s\n' "$(cd -P -- "$a" && "$pwd_bin" -P)"
    elif [ -f "$a" ]; then
        printf 'op f %s\n' "$a"
    else
        printf 'op o %s\n' "$a"
    fi >> "$log"
done
exit 0
STUB
    } > "$d/chmod" && : > "$d/chmod.log" && chmod 0755 "$d/chmod"
}

# jail_cd ARGS...: the builder jail's `cd`. It works out where `builtin cd
# ARGS` would land (physically, by the external pwd) and goes there only when
# that is inside $SCRATCH; any other destination is replaced by the jail's
# empty cd trap ($JAIL_CD_TRAP). A destination equal to $JAIL_CD_FROM (when
# set) is replaced by $JAIL_CD_TO -- the interception check. Every swap is
# logged to $JAIL_CD_LOG.
jail_cd() {
    local dest
    if ! dest="$(builtin cd "$@" >/dev/null 2>&1 && "$PWD_BIN" -P)"; then
        printf 'jail: cd %s: cannot change directory\n' "$*" >&2
        return 1
    fi
    if [ -n "${JAIL_CD_FROM:-}" ] && [ "$dest" = "$JAIL_CD_FROM" ]; then
        printf 'cd %s -> %s (redirected)\n' "$dest" "$JAIL_CD_TO" >> "$JAIL_CD_LOG"
        builtin cd -P -- "$JAIL_CD_TO" || return 1
        return 0
    fi
    case "$dest/" in
        "$SCRATCH_P"/*) : ;;
        *)
            printf 'cd %s -> trap (outside the scratch directory)\n' "$dest" >> "$JAIL_CD_LOG"
            builtin cd -P -- "$JAIL_CD_TRAP" || return 1
            return 0
            ;;
    esac
    builtin cd "$@" || return 1
}

# jail STUBS TOOLS CDMODE AREA CWD CMD...: runs CMD in a subshell with STUBS
# first on PATH, TMPDIR=AREA and cwd=CWD. CDMODE "cd" installs jail_cd as
# the shell function cd (its trap is STUBS/cd-trap, its log STUBS/cd.log);
# "-" leaves cd alone. Interlock: CMD is NOT run (status 98) unless every
# tool in TOOLS resolves to its stub (and, with CDMODE cd, cd is the jail's).
jail() {
    local stubs="$1" tools="$2" cdmode="$3" area="$4" cwd="$5" tool
    shift 5
    (
        PATH="$stubs:$PATH"
        export PATH
        hash -r
        TMPDIR="$area"
        export TMPDIR
        builtin cd -- "$cwd" || exit 97
        if [ "$cdmode" = cd ]; then
            JAIL_CD_TRAP="$stubs/cd-trap"
            JAIL_CD_LOG="$stubs/cd.log"
            cd() { jail_cd "$@"; }
            if [ "$(type -t cd)" != function ] || [ ! -d "$JAIL_CD_TRAP" ]; then
                echo "jail interlock: cd is not the jail's; $1 NOT run" >&2
                exit 98
            fi
        fi
        for tool in $tools; do
            if [ "$(command -v "$tool")" != "$stubs/$tool" ]; then
                echo "stub interlock: $tool is not the recording stub; $1 NOT run" >&2
                exit 98
            fi
        done
        "$@"
    )
}

# run_jailed TOOLS CDMODE AREA CWD CMD...: jail with fresh stubs. Sets JRC
# (status), JERR (stderr), JLOG (the stub log) and JSTUBS (the stub
# directory; JSTUBS/cd-trap is the cd trap). Stdout is discarded.
run_jailed() {
    local tools="$1" cdmode="$2" area="$3" cwd="$4"
    shift 4
    JRC=96 JERR="jail not set up" JLOG="" JSTUBS=""
    JSTUBS="$(stubs_create "$tools")" || return 1
    if ! mkdir "$JSTUBS/cd-trap" || ! : > "$JSTUBS/cd.log"; then
        return 0
    fi
    JERR="$(jail "$JSTUBS" "$tools" "$cdmode" "$area" "$cwd" "$@" 2>&1 >/dev/null </dev/null)"
    JRC=$?
    JLOG="$(cat "$JSTUBS/calls.log")"
}

# expect_refused DESC: the last run_jailed call refused -- status 1,
# "refusing" on stderr -- and no stubbed command was run at all.
expect_refused() {
    assert_eq "$1: status 1" "1" "$JRC"
    assert_true "$1: stderr says refusing" grep -Fq "refusing" <<<"$JERR"
    assert_eq "$1: no stubbed command run (stub log empty)" "" "$JLOG"
}

# Wrappers for CMD inside a jail (its subshell keeps their settings local).
with_cdpath() { # CDPATH CMD...
    CDPATH="$1"
    export CDPATH
    shift
    "$@"
}
with_oldpwd() { # OLDPWD CMD...
    OLDPWD="$1"
    export OLDPWD
    shift
    "$@"
}
as_root() { # CMD...: the builder takes its root path (chown is stubbed)
    persist_fixture_euid() { echo 0; }
    "$@"
}
as_user() { # CMD...: the builder takes its non-root path
    persist_fixture_euid() { echo 1000; }
    "$@"
}
cd_redirected() { # FROM TO CMD...: the jail's cd swaps destination FROM for TO
    JAIL_CD_FROM="$1"
    JAIL_CD_TO="$2"
    shift 2
    "$@"
}
# from_stale_cwd LINK NEWTARGET CMD...: enters LINK logically (its current
# target becomes the real cwd), repoints LINK to NEWTARGET, then runs CMD:
# $PWD now spells a path that leads to NEWTARGET, the real cwd is the old one.
from_stale_cwd() {
    local link="$1" new="$2"
    shift 2
    cd -L -- "$link" || return 96
    "$REAL_LN" -sfn -- "$new" "$link" || return 95
    "$@"
}

# real_cleanup AREA PATH...: the REAL cleanup with TMPDIR=AREA. Interlock: it
# does not call the cleanup at all (status 99) unless every PATH is textually
# below this run's $SCRATCH with no ".." component.
real_cleanup() {
    local area="$1" p
    shift
    for p in "$@"; do
        case "$p" in
            *"/.."* | *"../"*)
                test_fail "real_cleanup interlock: [$p] has a .. component; NOT run"
                return 99
                ;;
            "$SCRATCH"/?*) : ;;
            *)
                test_fail "real_cleanup interlock: [$p] is not inside \$SCRATCH; NOT run"
                return 99
                ;;
        esac
    done
    (
        TMPDIR="$area"
        export TMPDIR
        persist_fixture_cleanup "$@"
    )
}

# real_build AREA CWD DIR: the REAL builder (non-root path) with TMPDIR=AREA
# from CWD. Interlock: AREA, CWD and DIR must be textually below $SCRATCH with
# no ".." component (status 99).
real_build() {
    local area="$1" cwd="$2" dir="$3" p
    for p in "$area" "$cwd" "$dir"; do
        case "$p" in
            *"/.."* | *"../"*) : ;;
            "$SCRATCH"/?*) continue ;;
        esac
        test_fail "real_build interlock: [$area] [$cwd] [$dir] not all inside \$SCRATCH; NOT run"
        return 99
    done
    (
        TMPDIR="$area"
        export TMPDIR
        builtin cd -- "$cwd" || exit 97
        as_user persist_fixture_tree_build "$dir"
    )
}

# ---------------------------------------------------------------------------
test_section "persist-fixtures safety: library presence"

if [ -f "$LIB" ]; then
    test_pass "tests/lib/persist-fixtures.sh exists"
    # shellcheck source=lib/persist-fixtures.sh
    source "$LIB"
else
    test_fail "tests/lib/persist-fixtures.sh exists"
fi

# ---------------------------------------------------------------------------
test_section "persist-fixtures safety: no temp area that is or contains the account home or the checkout (A1, jailed)"

# cleanup_area_refused DESC AREA PATH: PATH must not exist; under the stubs,
# with TMPDIR=AREA, the cleanup must refuse it.
cleanup_area_refused() {
    if exists "$3"; then
        test_fail "$1: precondition: [$3] must not exist"
        return 0
    fi
    run_jailed "$DESTRUCTIVE_TOOLS" - "$2" "$SANDBOX" persist_fixture_cleanup "$3"
    expect_refused "$1"
}

area_sanity_cases() {
    need persist_fixture_cleanup || return 0
    local absent="dxe-pfx-absent.$$" parent link="$SCRATCH/a1-links/home-link"
    if [ -n "$ACCOUNT_HOME" ]; then
        cleanup_area_refused "TMPDIR is the account home" "$ACCOUNT_HOME" "$ACCOUNT_HOME/$absent"
        parent="$(dirname "$ACCOUNT_HOME")"
        cleanup_area_refused "TMPDIR is the account home's parent" "$parent" "${parent%/}/$absent"
        mkdir -p "${link%/*}"
        ln -s "$ACCOUNT_HOME" "$link"
        cleanup_area_refused "TMPDIR is a symlink to the account home" "$link" "$link/$absent"
        rm -f -- "$link"
    fi
    cleanup_area_refused "TMPDIR is the checkout root" "$BASE_DIR" "$BASE_DIR/$absent"
    parent="$(dirname "$CHECKOUT_P")"
    cleanup_area_refused "TMPDIR is the checkout's parent" "$parent" "${parent%/}/$absent"
}
area_sanity_cases

# run_decoy LIB TOOLS AREA CWD CMD...: like run_jailed (no cd function), but
# in a separate bash that sources LIB -- a copy of the library at a decoy
# checkout inside $SCRATCH -- first.
run_decoy() {
    local lib="$1" tools="$2" area="$3" cwd="$4" probe="$SCRATCH/decoy-probe.sh"
    shift 4
    JRC=96 JERR="decoy not set up" JLOG="" JSTUBS=""
    if [ ! -f "$probe" ]; then
        cat > "$probe" <<'PROBE'
#!/bin/bash
# Decoy-checkout probe: source LIB, then run CMD... jailed (see run_decoy).
set -u
lib="$1" stubs="$2" tools="$3" area="$4" cwd="$5"
shift 5
source "$lib" || exit 96
PATH="$stubs:$PATH"
export PATH
hash -r
TMPDIR="$area"
export TMPDIR
cd -- "$cwd" || exit 97
for tool in $tools; do
    if [ "$(command -v "$tool")" != "$stubs/$tool" ]; then
        echo "stub interlock: $tool is not the recording stub; $1 NOT run" >&2
        exit 98
    fi
done
"$@"
PROBE
    fi
    JSTUBS="$(stubs_create "$tools")" || return 1
    JERR="$("${BASH:-bash}" "$probe" "$lib" "$JSTUBS" "$tools" "$area" "$cwd" "$@" 2>&1 >/dev/null </dev/null)"
    JRC=$?
    JLOG="$(cat "$JSTUBS/calls.log")"
}

decoy_checkout_cases() {
    need persist_fixture_cleanup || return 0
    local d="$SCRATCH/decoy" lib
    mkdir -p "$d/checkout/tests/lib" "$d/dxe-target" "$d/build" "$d/checkout/dxe-in-checkout" "$d/side/dxe-control"
    : > "$d/dxe-target/keep"
    cp "$LIB" "$SCRIPT_DIR/lib/fake-tools.sh" "$d/checkout/tests/lib/"
    lib="$d/checkout/tests/lib/persist-fixtures.sh"

    run_decoy "$lib" "$DESTRUCTIVE_TOOLS" "$d" "$SANDBOX" persist_fixture_cleanup "$d/dxe-target"
    expect_refused "decoy checkout: cleanup refuses when the temp area contains the library's checkout"
    run_decoy "$lib" "$DESTRUCTIVE_TOOLS" "$d" "$SANDBOX" persist_fixture_tree_build "$d/build"
    expect_refused "decoy checkout: the builder refuses when the temp area contains the library's checkout"
    assert_eq "decoy checkout: nothing built" "" "$(listing "$d/build")"
    run_decoy "$lib" "$DESTRUCTIVE_TOOLS" "$d/checkout" "$SANDBOX" persist_fixture_cleanup "$d/checkout/dxe-in-checkout"
    expect_refused "decoy checkout: cleanup refuses when the temp area is the library's checkout"
    assert_true "decoy checkout: the refused target is untouched" test -f "$d/dxe-target/keep"

    # Control: the same decoy library, with a temp area that does not contain
    # its checkout, does remove (so the refusals above are the checkout rule).
    run_decoy "$lib" "$DESTRUCTIVE_TOOLS" "$d/side" "$SANDBOX" persist_fixture_cleanup "$d/side/dxe-control"
    assert_eq "decoy checkout control: a temp area beside the checkout still works (status 0)" "0" "$JRC"
    assert_true "decoy checkout control: rm was called for the target" grep -Fq "rm " <<<"$JLOG"
    assert_true "decoy checkout control: the call names the target" grep -Fq "$d/side/dxe-control" <<<"$JLOG"
}
decoy_checkout_cases

# HOME isolated in a fixture under the temp area (tests/test_docker_adapter_*.sh)
# must not disable the fixtures: the rule is about the ACCOUNT home.
home_isolation_cases() {
    need persist_fixture_root_create || return 0
    need persist_fixture_cleanup || return 0
    need persist_fixture_tree_build || return 0
    local iso="$SCRATCH/iso/area" r rc
    mkdir -p "$iso/dxe-home" "$iso/build"
    r="$(persist_fixture_root_create "$iso")" || exit 1
    (
        HOME="$iso/dxe-home"
        export HOME
        real_cleanup "$iso" "$r"
    ) 2>/dev/null
    rc=$?
    assert_eq "HOME isolated inside the temp area: cleanup still succeeds" "0" "$rc"
    assert_false "HOME isolated inside the temp area: the root is removed" exists "$r"
    (
        HOME="$iso/dxe-home"
        export HOME
        real_build "$iso" "$SANDBOX" "$iso/build"
    ) >/dev/null 2>&1
    rc=$?
    assert_eq "HOME isolated inside the temp area: the builder still succeeds" "0" "$rc"
    assert_true "HOME isolated inside the temp area: the tree is built" test -f "$iso/build/plain.txt"
}
home_isolation_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures safety: the builder refuses \$HOME, the checkout and / (B1, jailed incl. creation tools)"

builder_danger_cases() {
    need persist_fixture_tree_build || return 0
    local area="$SCRATCH/b1d/area" desc p
    mkdir -p "$area"
    while IFS='|' read -r desc p; do
        run_jailed "$DESTRUCTIVE_TOOLS $CREATION_TOOLS" cd "$area" "$SANDBOX" persist_fixture_tree_build "$p"
        expect_refused "builder refuses $desc"
        assert_eq "builder refuses $desc: nothing written in the jail's cd trap" "" "$(listing "$JSTUBS/cd-trap")"
    done <<EOF
\$HOME|$HOME
the checkout root|$BASE_DIR
/|/
EOF
    run_jailed "$DESTRUCTIVE_TOOLS $CREATION_TOOLS" cd "$area" "$SANDBOX" persist_fixture_tree_build ""
    assert_eq "builder refuses an empty DIR: status 1" "1" "$JRC"
    assert_eq "builder refuses an empty DIR: no stubbed command run" "" "$JLOG"
    assert_eq "builder refuses an empty DIR: nothing written in the jail's cd trap" "" "$(listing "$JSTUBS/cd-trap")"
    assert_eq "the jail's cwd sandbox is still empty" "" "$(listing "$SANDBOX")"
}
builder_danger_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures safety: the builder stays inside the temp area (B1, jailed)"

# build_refused DESC AREA CWD WATCH... -- CMD...: CMD in the builder jail
# (TMPDIR=AREA, cwd=CWD) must refuse with no stubbed command run, and every
# WATCH directory must still be empty afterwards.
build_refused() {
    local desc="$1" area="$2" cwd="$3" w
    local -a watch=()
    shift 3
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        watch+=("$1")
        shift
    done
    shift
    run_jailed "$DESTRUCTIVE_TOOLS" cd "$area" "$cwd" "$@"
    expect_refused "$desc"
    for w in "${watch[@]+"${watch[@]}"}"; do
        assert_eq "$desc: nothing created in ${w#"$SCRATCH"/}" "" "$(listing "$w")"
    done
}

builder_refusal_cases() {
    need persist_fixture_tree_build || return 0
    local c="$SCRATCH/b1r" A O
    A="$c/area"
    O="$c/outside"
    mkdir -p "$A/sub" "$A/inside-1" "$A/inside-2" "$A/dash-old" "$A/cdp/victim" "$A/stale-fake/victim" \
        "$O/out-dir" "$O/via-link" "$O/dotdot" "$O/rel-out" "$O/dot" "$O/dash/-" "$O/cd-cwd/victim" \
        "$O/stale-real/victim" "$c/eq-area" "$c/links"
    ln -s "$O/via-link" "$A/link-out"
    ln -s "$O/stale-real" "$c/links/cl"

    build_refused "refuses an existing directory outside the temp area" "$A" "$SANDBOX" "$O/out-dir" -- \
        persist_fixture_tree_build "$O/out-dir"
    build_refused "refuses the temp area itself" "$c/eq-area" "$SANDBOX" "$c/eq-area" -- \
        persist_fixture_tree_build "$c/eq-area"
    build_refused "refuses a symlink in the temp area that points outside it" "$A" "$SANDBOX" "$O/via-link" -- \
        persist_fixture_tree_build "$A/link-out"
    build_refused "refuses a .. escape out of the temp area" "$A" "$SANDBOX" "$O/dotdot" -- \
        persist_fixture_tree_build "$A/sub/../../outside/dotdot"
    build_refused "refuses a relative DIR that resolves outside the temp area" "$A" "$A" "$O/rel-out" -- \
        persist_fixture_tree_build ../outside/rel-out
    build_refused "refuses . when the cwd is outside the temp area" "$A" "$O/dot" "$O/dot" -- \
        persist_fixture_tree_build .
    build_refused "refuses - from a cwd outside the temp area (it is ./-, not \$OLDPWD inside it)" "$A" "$O/dash" \
        "$O/dash/-" "$A/dash-old" -- with_oldpwd "$A/dash-old" persist_fixture_tree_build -
    build_refused "refuses a relative name that CDPATH would redirect into the temp area" "$A" "$O/cd-cwd" \
        "$O/cd-cwd/victim" "$A/cdp/victim" -- with_cdpath "$A/cdp" persist_fixture_tree_build victim
    build_refused "refuses everything when the temp area does not exist" "$c/no-such-area" "$SANDBOX" "$A/inside-1" -- \
        persist_fixture_tree_build "$A/inside-1"
    build_refused "refuses everything when the temp area is /" "/" "$SANDBOX" "$A/inside-2" -- \
        persist_fixture_tree_build "$A/inside-2"
    build_refused "refuses a relative DIR when \$PWD is stale (cwd entered through a since-repointed symlink)" "$A" "$SANDBOX" \
        "$O/stale-real/victim" "$A/stale-fake/victim" -- \
        from_stale_cwd "$c/links/cl" "$A/stale-fake" persist_fixture_tree_build victim
    assert_eq "the jail's cwd sandbox is still empty" "" "$(listing "$SANDBOX")"
}
builder_refusal_cases

builder_relative_accept_cases() {
    need persist_fixture_tree_build || return 0
    need persist_fixture_tree_list || return 0
    local c="$SCRATCH/b1a" A O
    A="$c/area"
    O="$c/outside"
    mkdir -p "$A/rel-ok" "$A/abs-ok" "$A/victim" "$A/dash-cwd/-" "$A/real-in" "$O/cdp/victim" "$O/dash-old"
    ln -s "$A" "$c/area-link"

    run_jailed "$DESTRUCTIVE_TOOLS" cd "$A" "$A" persist_fixture_tree_build rel-ok
    assert_eq "a relative DIR inside the temp area, from the area: status 0" "0" "$JRC"
    run_jailed "$DESTRUCTIVE_TOOLS" cd "$A" "$SANDBOX" persist_fixture_tree_build "$A/abs-ok"
    persist_fixture_tree_list "$A/rel-ok" > "$c/rel.list"
    persist_fixture_tree_list "$A/abs-ok" > "$c/abs.list"
    assert_true "a relative DIR yields the same entries as the absolute DIR" cmp -s "$c/rel.list" "$c/abs.list"
    assert_true "a relative DIR: entries are created (plain.txt)" test -f "$A/rel-ok/plain.txt"

    run_jailed "$DESTRUCTIVE_TOOLS" cd "$A" "$A" with_cdpath "$O/cdp" persist_fixture_tree_build victim
    assert_eq "CDPATH pointing elsewhere: status 0" "0" "$JRC"
    assert_true "CDPATH pointing elsewhere: built in the cwd's victim" test -f "$A/victim/plain.txt"
    assert_eq "CDPATH pointing elsewhere: nothing created in the CDPATH directory" "" "$(listing "$O/cdp/victim")"

    run_jailed "$DESTRUCTIVE_TOOLS" cd "$A" "$A/dash-cwd" with_oldpwd "$O/dash-old" persist_fixture_tree_build -
    assert_eq "DIR - from inside the temp area: status 0" "0" "$JRC"
    assert_true "DIR - from inside the temp area: built in ./-" test -f "$A/dash-cwd/-/plain.txt"
    assert_eq "DIR - from inside the temp area: nothing created in \$OLDPWD" "" "$(listing "$O/dash-old")"

    run_jailed "$DESTRUCTIVE_TOOLS" cd "$A" "$SANDBOX" persist_fixture_tree_build "$c/area-link/real-in"
    assert_eq "DIR spelled through a symlink to the temp area: status 0" "0" "$JRC"
    assert_true "DIR spelled through a symlink to the temp area: built" test -f "$A/real-in/plain.txt"
    assert_eq "the jail's cwd sandbox is still empty" "" "$(listing "$SANDBOX")"
}
builder_relative_accept_cases

# The cd jail is a stand-in for "a broken guard cannot write outside": check
# that it really intercepts the builder (contract item 4). The jail swaps the
# directory DIR for another scratch directory; everything must land there.
builder_cd_intercept_case() {
    need persist_fixture_tree_build || return 0
    local c="$SCRATCH/b1cd" A
    A="$c/area"
    mkdir -p "$A/target" "$A/elsewhere"
    run_jailed "$DESTRUCTIVE_TOOLS" cd "$A" "$SANDBOX" \
        cd_redirected "$(physical "$A/target")" "$(physical "$A/elsewhere")" persist_fixture_tree_build "$A/target"
    assert_eq "cd interception: the builder reports success" "0" "$JRC"
    assert_eq "cd interception: nothing is written into DIR except through cd" "" "$(listing "$A/target")"
    assert_true "cd interception: the tree landed where the jail's cd sent it" test -f "$A/elsewhere/plain.txt"
    assert_true "cd interception: special/sock too (created after a cd into special)" test -S "$A/elsewhere/special/sock"
}
builder_cd_intercept_case

# ---------------------------------------------------------------------------
test_section "persist-fixtures safety: the builder never re-permissions existing entries (B1, real tools in scratch)"

builder_preexisting_cases() {
    need persist_fixture_tree_build || return 0
    local A="$SCRATCH/b1pre/area" D rc
    D="$A/pre"
    mkdir -p "$D/keep-0700" "$D/shared-0750"
    printf 'key\n' > "$D/keep-0700/key-0600"
    printf '#!/bin/sh\n' > "$D/tool-0755"
    printf 'ro\n' > "$D/ro-0400"
    chmod 0600 "$D/keep-0700/key-0600"
    chmod 0700 "$D/keep-0700"
    chmod 0750 "$D/shared-0750"
    chmod 0755 "$D/tool-0755"
    chmod 0400 "$D/ro-0400"
    real_build "$A" "$SANDBOX" "$D" >/dev/null 2>&1
    rc=$?
    assert_eq "DIR with existing content: the builder succeeds" "0" "$rc"
    assert_eq "existing 0700 directory keeps its mode" "0700" "$(lstat_field mode "$D/keep-0700")"
    assert_eq "existing 0600 file keeps its mode" "0600" "$(lstat_field mode "$D/keep-0700/key-0600")"
    assert_eq "existing 0750 directory keeps its mode" "0750" "$(lstat_field mode "$D/shared-0750")"
    assert_eq "existing 0755 executable keeps its exec bits" "0755" "$(lstat_field mode "$D/tool-0755")"
    assert_eq "existing 0400 file keeps its mode" "0400" "$(lstat_field mode "$D/ro-0400")"
    assert_eq "existing file contents unchanged" "key|#!/bin/sh|ro" \
        "$(cat "$D/keep-0700/key-0600")|$(cat "$D/tool-0755")|$(cat "$D/ro-0400")"
    assert_eq "the builder still sets its own modes (plain.txt)" "0644" "$(lstat_field mode "$D/plain.txt")"
    assert_eq "the builder still sets its own modes (secret-0600.txt)" "0600" "$(lstat_field mode "$D/secret-0600.txt")"
    assert_eq "the builder still sets its own modes (private-0700)" "0700" "$(lstat_field mode "$D/private-0700")"
    assert_eq "the builder still sets its own modes (nested/a/b)" "0755" "$(lstat_field mode "$D/nested/a/b")"
    assert_eq "the builder still sets its own modes (links/a-one)" "0644" "$(lstat_field mode "$D/links/a-one")"
}
builder_preexisting_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures safety: the inner cd is CDPATH-proof (B4, real tools in scratch)"

# CDPATH names a scratch directory holding a directory of every name the
# builder ever changes into (bash searches CDPATH before the literal name).
# The builder must still put the socket in DIR/special and write nothing into
# the CDPATH directory, nor anything to stdout.
builder_cdpath_inner_cd_cases() {
    need persist_fixture_tree_build || return 0
    local A="$SCRATCH/b4/area" cdp="$SCRATCH/b4/cdp" n before after out rc entry
    mkdir -p "$A/abs" "$cdp"
    for n in special nested links private-0700 names owners a b c; do
        mkdir -p "$cdp/$n"
    done
    before="$(cd -P -- "$cdp" && find . | sort)"

    out="$(CDPATH="$cdp"; export CDPATH; real_build "$A" "$SANDBOX" "$A/abs" 2>&1)"
    rc=$?
    assert_eq "CDPATH set, absolute DIR: status 0" "0" "$rc"
    assert_eq "CDPATH set, absolute DIR: builder stdout/stderr empty" "" "$out"
    assert_true "CDPATH set: DIR/special/sock is a socket" test -S "$A/abs/special/sock"
    assert_true "CDPATH set: DIR/special/fifo is a fifo" test -p "$A/abs/special/fifo"
    for entry in plain.txt empty-file secret-0600.txt private-0700/inner.txt ._root-meta \
        nested/a/b/c/deep.txt links/a-one links/to-plain names/-dash.txt; do
        assert_true "CDPATH set: DIR/$entry exists" exists "$A/abs/$entry"
    done
    after="$(cd -P -- "$cdp" && find . | sort)"
    assert_eq "CDPATH directory untouched (no socket or other entry created there)" "$before" "$after"

    mkdir -p "$A/rel"
    # Relative DIR: cwd and TMPDIR are the scratch area (real_build's interlock
    # wants an absolute DIR, so the call is spelled out; all of it in $SCRATCH).
    out="$(CDPATH="$cdp"; TMPDIR="$A"; export CDPATH TMPDIR; builtin cd -- "$A" && as_user persist_fixture_tree_build rel 2>&1)"
    rc=$?
    assert_eq "CDPATH set, relative DIR: builder stdout/stderr empty" "" "$out"
    assert_eq "CDPATH set, relative DIR: status 0" "0" "$rc"
    assert_true "CDPATH set, relative DIR: DIR/special/sock is a socket" test -S "$A/rel/special/sock"
    after="$(cd -P -- "$cdp" && find . | sort)"
    assert_eq "CDPATH directory untouched by the relative-DIR build" "$before" "$after"
}
builder_cdpath_inner_cd_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures safety: chown targets for a relative DIR (A5)"

builder_chown_cases() {
    need persist_fixture_tree_build || return 0
    local A="$SCRATCH/a5/area" i cwd target ok
    local -a l=() names=(uid30033 uid0 dir30033) specs=(30033:30033 0:0 30033:30033)
    mkdir -p "$A/rel-root"
    run_jailed "$DESTRUCTIVE_TOOLS" cd "$A" "$A" as_root persist_fixture_tree_build rel-root
    assert_eq "relative DIR, root path (chown stubbed): status 0" "0" "$JRC"
    while IFS= read -r ok; do l+=("$ok"); done < "$JSTUBS/chown.log"
    assert_eq "relative DIR, root path: exactly three chown calls of two arguments each" "12" "${#l[@]}"
    if [ "${#l[@]}" = 12 ]; then
        for i in 0 1 2; do
            cwd="${l[$((i * 4))]}"
            target="${l[$((i * 4 + 2))]}"
            assert_eq "relative DIR, root path: chown $((i + 1)) owner spec" "${specs[$i]}" "${l[$((i * 4 + 1))]}"
            assert_eq "relative DIR, root path: chown $((i + 1)) argv ends its call" "--" "${l[$((i * 4 + 3))]}"
            if (builtin cd -- "$cwd" 2>/dev/null && [ "$target" -ef "$A/rel-root/owners/${names[$i]}" ]); then ok=yes; else ok=no; fi
            assert_eq "relative DIR, root path: chown $((i + 1)) target [$target] (from [$cwd]) is DIR/owners/${names[$i]}" "yes" "$ok"
        done
    fi
}
builder_chown_cases

# The recording chown above stands in for a privilege boundary: validate the
# same relative-DIR path against the real chown whenever this suite really
# runs as root (the Linux coverage container).
builder_real_root_chown_case() {
    [ "$(id -u)" = 0 ] || return 0
    need persist_fixture_tree_build || return 0
    local A="$SCRATCH/a5real/area"
    mkdir -p "$A/rel-real"
    (
        TMPDIR="$A"
        export TMPDIR
        builtin cd -- "$A" || exit 97
        persist_fixture_tree_build rel-real
    ) >/dev/null 2>&1
    assert_eq "real root, relative DIR: owners/uid30033 owned by 30033:30033" "30033:30033" "$(lstat_field owner "$A/rel-real/owners/uid30033")"
    assert_eq "real root, relative DIR: owners/dir30033 owned by 30033:30033" "30033:30033" "$(lstat_field owner "$A/rel-real/owners/dir30033")"
    assert_eq "real root, relative DIR: owners/uid0 owned by 0:0" "0:0" "$(lstat_field owner "$A/rel-real/owners/uid0")"
}
builder_real_root_chown_case

# ---------------------------------------------------------------------------
test_section "persist-fixtures safety: cleanup refuses every relative PATH (B2, jailed)"

cleanup_relative_cases() {
    need persist_fixture_cleanup || return 0
    local c="$SCRATCH/b2" A O
    A="$c/area"
    O="$c/outside"
    mkdir -p "$A/dxe-rel" "$A/sub/dxe-rel2" "$A/sub2" "$A/dxe-abs" \
        "$O/realcwd/dxe-victim" "$A/fakecwd/dxe-victim" "$O/realcwd2/dxe-victim" "$A/fakecwd2/dxe-victim" "$c/links"
    ln -s "$O/realcwd" "$c/links/cl"
    ln -s "$O/realcwd2" "$c/links/cl2"

    run_jailed "$DESTRUCTIVE_TOOLS" - "$A" "$A" persist_fixture_cleanup dxe-rel
    expect_refused "refuses a bare dxe- name even with the cwd in the temp area"
    run_jailed "$DESTRUCTIVE_TOOLS" - "$A" "$A" persist_fixture_cleanup ./dxe-rel
    expect_refused "refuses ./dxe-name"
    run_jailed "$DESTRUCTIVE_TOOLS" - "$A" "$A" persist_fixture_cleanup sub/dxe-rel2
    expect_refused "refuses a relative path with a parent inside the temp area"
    run_jailed "$DESTRUCTIVE_TOOLS" - "$A" "$A/sub2" persist_fixture_cleanup ../dxe-rel
    expect_refused "refuses ../dxe-name"
    run_jailed "$DESTRUCTIVE_TOOLS" - "$A" "$A" persist_fixture_cleanup "$A/dxe-abs" dxe-rel
    expect_refused "refuses the whole call when one PATH is relative"
    run_jailed "$DESTRUCTIVE_TOOLS" - "$A" "$SANDBOX" \
        from_stale_cwd "$c/links/cl" "$A/fakecwd" persist_fixture_cleanup dxe-victim
    expect_refused "refuses dxe-name from a stale \$PWD (cwd entered through a since-repointed symlink)"
    run_jailed "$DESTRUCTIVE_TOOLS" - "$A" "$SANDBOX" \
        from_stale_cwd "$c/links/cl2" "$A/fakecwd2" persist_fixture_cleanup ./dxe-victim
    expect_refused "refuses ./dxe-name from a stale \$PWD"
    assert_true "refused relative targets are untouched" test -d "$A/dxe-rel" -a -d "$A/sub/dxe-rel2" -a -d "$A/dxe-abs"
    assert_true "the stale-cwd victims are untouched" test -d "$O/realcwd/dxe-victim" -a -d "$A/fakecwd/dxe-victim"
}
cleanup_relative_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures safety: cleanup adds u+rwx to directories only (B3)"

cleanup_hardlink_real_case() {
    need persist_fixture_cleanup || return 0
    local c="$SCRATCH/b3" A O rc
    A="$c/area"
    O="$c/outside"
    mkdir -p "$A/dxe-hl/sub" "$O/odir"
    printf 'victim\n' > "$O/victim-0400"
    chmod 0400 "$O/victim-0400"
    ln "$O/victim-0400" "$A/dxe-hl/hard"
    printf 'x\n' > "$A/dxe-hl/sub/f"
    chmod 0500 "$A/dxe-hl/sub"
    ln -s "$O/odir" "$A/dxe-hl/to-odir"
    chmod 0500 "$O/odir"
    real_cleanup "$A" "$A/dxe-hl" 2>/dev/null
    rc=$?
    assert_eq "hard link to an outside file: cleanup succeeds" "0" "$rc"
    assert_false "hard link to an outside file: the dxe- tree (incl. a 0500 directory) is removed" exists "$A/dxe-hl"
    assert_eq "hard link to an outside file: the outside file keeps mode 0400" "0400" "$(lstat_field mode "$O/victim-0400")"
    assert_eq "hard link to an outside file: its content is intact" "victim" "$(cat "$O/victim-0400" 2>/dev/null)"
    assert_eq "hard link to an outside file: its link count is back to 1" "1" "$(lstat_field nlink "$O/victim-0400")"
    assert_eq "symlink inside the tree: the outside directory keeps mode 0500" "0500" "$(lstat_field mode "$O/odir")"
}
cleanup_hardlink_real_case

# B3 jailed: find is REAL (so `find ... -exec chmod` really walks the tree),
# every other destructive tool is a stub, and chmod is the classifying stub.
cleanup_hardlink_jailed_case() {
    need persist_fixture_cleanup || return 0
    local c="$SCRATCH/b3j" A O P tools="rm chmod chown mv rmdir unlink rsync" line bad="" nonrec=yes sawp=no sawsub=no
    A="$c/area"
    O="$c/outside"
    P="$A/dxe-hj"
    mkdir -p "$P/sub/deeper" "$O/odir"
    printf 'victim\n' > "$O/victim-0400"
    chmod 0400 "$O/victim-0400"
    ln "$O/victim-0400" "$P/hard"
    printf 'plain\n' > "$P/sub/plain"
    ln -s "$O/odir" "$P/to-odir"
    JRC=96 JERR="" JSTUBS=""
    JSTUBS="$(stubs_create "$tools")" || {
        test_fail "B3 jailed: stubs could not be created"
        return 1
    }
    if ! classifying_chmod_write "$JSTUBS" || ! mkdir "$JSTUBS/cd-trap"; then
        test_fail "B3 jailed: stubs could not be created"
        return 0
    fi
    JERR="$(jail "$JSTUBS" "$tools" - "$A" "$SANDBOX" persist_fixture_cleanup "$P" 2>&1 >/dev/null </dev/null)"
    JRC=$?
    assert_eq "directory PATH (find real, chmod recorded): status 0" "0" "$JRC"
    while IFS= read -r line; do
        case "$line" in
            "flag -"*R* | "flag --recursive"*) nonrec=no ;;
            "op d $(physical "$P")") sawp=yes ;;
            "op d $(physical "$P/sub")") sawsub=yes ;;
        esac
        case "$line" in
            "op d $(physical "$P")" | "op d $(physical "$P")/"*) : ;;
            "op "*) bad="${bad}[$line]" ;;
        esac
    done < "$JSTUBS/chmod.log"
    assert_eq "no recursive chmod (no -R)" "yes" "$nonrec"
    assert_eq "every chmod operand is a real directory inside PATH (no file, no symlink, nothing outside)" "" "$bad"
    assert_eq "PATH itself gets u+rwx" "yes" "$sawp"
    assert_eq "a subdirectory gets u+rwx" "yes" "$sawsub"
}
cleanup_hardlink_jailed_case

# ---------------------------------------------------------------------------
test_section "persist-fixtures safety: a symlink PATH is one rm -f and nothing else (A4, jailed)"

cleanup_symlink_cases() {
    need persist_fixture_cleanup || return 0
    local c="$SCRATCH/a4" A O p
    A="$c/area"
    O="$c/outside"
    mkdir -p "$A" "$O/odir"
    : > "$O/odir/f"
    : > "$O/ofile"
    ln -s "$O/odir" "$A/dxe-to-dir"
    ln -s "$O/ofile" "$A/dxe-to-file"
    ln -s "$A/no-such" "$A/dxe-dangling"
    for p in dxe-to-dir dxe-to-file dxe-dangling; do
        run_jailed "$DESTRUCTIVE_TOOLS" - "$A" "$SANDBOX" persist_fixture_cleanup "$A/$p"
        assert_eq "symlink PATH $p: status 0" "0" "$JRC"
        assert_eq "symlink PATH $p: exactly one rm -f -- PATH and no other destructive command" "rm -f -- $A/$p" "$JLOG"
    done
}
cleanup_symlink_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures safety: NAS fake with a relative ROOT (A3)"

nas_relative_root_cases() {
    need persist_fixture_nas_create || return 0
    local c="$SCRATCH/a3" expected tools out rc
    mkdir -p "$c/cwd/r" "$c/cdp/r" "$c/cdp2/r" "$c/cwd/-" "$c/old" "$c/elsewhere"

    expected="$(physical "$c/cwd/r")"
    tools="$(builtin cd -- "$c/cwd" && CDPATH="$c/cdp" persist_fixture_nas_create r "$c")" || exit 1
    rc=$?
    assert_eq "relative ROOT (CDPATH set at creation): status 0" "0" "$rc"
    out="$(builtin cd -- "$c/elsewhere" && CDPATH="$c/cdp2" PATH="$tools:$PATH" \
        ssh "$PERSIST_FIXTURE_NAS_HOST" 'printf "%s\n" "$DXE_FIXTURE_NAS_ROOT"; pwd -P' 2>&1)"
    assert_eq "relative ROOT: DXE_FIXTURE_NAS_ROOT and the remote cwd are its absolute physical path, from another cwd, CDPATH ignored" \
        "$expected${NL}$expected" "$out"

    expected="$(physical "$c/cwd/-")"
    tools="$(builtin cd -- "$c/cwd" && OLDPWD="$c/old" persist_fixture_nas_create - "$c")" || exit 1
    rc=$?
    assert_eq "ROOT - : status 0" "0" "$rc"
    out="$(builtin cd -- "$c/elsewhere" && OLDPWD="$c/old" PATH="$tools:$PATH" \
        ssh "$PERSIST_FIXTURE_NAS_HOST" 'printf "%s\n" "$DXE_FIXTURE_NAS_ROOT"; pwd -P' 2>&1)"
    assert_eq "ROOT - is the directory named -, not \$OLDPWD" "$expected${NL}$expected" "$out"
}
nas_relative_root_cases

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    print_summary
    exit_with_code
fi
