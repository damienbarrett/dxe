#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP0.2: acceptance tests for the shared /persist host-access fixtures,
# tests/lib/persist-fixtures.sh (NOT YET WRITTEN when this file was authored;
# the implementer builds it to satisfy exactly this contract). Later WPs (NAS
# directory operations, rsync, manifest, migration) build on it.
#
# Interface contract (all names and behaviours below are pinned by this file):
#
#  Import: `source tests/lib/persist-fixtures.sh` sources the sibling
#  fake-tools.sh itself (fake_tool_dir_create, fake_qnap_ssh_write). It is
#  "safe to source": it defines functions and constants only -- no output, no
#  shell options, no cd, no I/O at import time. Bash 3.2 compatible. Needs
#  only perl (also used to create the Unix socket) beyond coreutils.
#
#  Constant: PERSIST_FIXTURE_NAS_HOST=dxe-fixture-nas.invalid
#
#  persist_fixture_root_create [PARENT]
#      Creates a new empty directory PARENT/dxe-persist-share.XXXXXX
#      (PARENT defaults to ${TMPDIR:-/tmp}) and prints its path. Mode 0700
#      is not pinned. Each call yields a distinct directory.
#
#  persist_fixture_cleanup PATH...
#      Removes each PATH recursively, including trees holding mode-0700/0500
#      directories, sockets, FIFOs and dangling symlinks. A path that does not
#      exist is not an error (status 0). It REFUSES (status 1, message on
#      stderr containing "refusing", nothing removed) an empty argument, "/",
#      "." and any path whose basename does not start with "dxe-". Intended
#      use: trap 'persist_fixture_cleanup "$ROOT" "$TOOLS"' EXIT
#
#  persist_fixture_nas_create ROOT [PARENT]
#      ROOT must be an existing directory (else status 1, message containing
#      "does not exist" on stderr, nothing created). Creates, via
#      fake_tool_dir_create (so scp/sftp/docker/tailscale/container/nix/curl
#      stay fail-closed, exit 99), a tool directory PARENT/dxe-fake-tools.* and
#      prints its path. Its `ssh` is fake_qnap_ssh_write's fake (argv appended
#      to $DXE_FAKE_SSH_ARGV_LOG when set, DXE_FAKE_SSH_REMOTE_PATH restricts
#      PATH, last argv word is eval'ed locally), additionally run with
#      cwd = ROOT and DXE_FIXTURE_NAS_ROOT=ROOT exported. The caller puts the
#      printed directory first on PATH and sends commands to
#      $PERSIST_FIXTURE_NAS_HOST. The eval'ed command's exit status is the
#      fake ssh's exit status.
#
#  persist_fixture_euid
#      Prints the effective uid (default: `id -u`). The tree builder asks THIS
#      FUNCTION (never `id -u` directly) so tests can override it.
#
#  persist_fixture_tree_build DIR
#      DIR must exist (else status 1, "does not exist" on stderr). Populates
#      it (relative to DIR; contents in parentheses; modes set explicitly, so
#      umask does not matter; exit 0, no stdout):
#        plain.txt (plain\n, 0644)         empty-file (0 bytes)
#        secret-0600.txt (secret\n, 0600)  private-0700/ (dir 0700)
#        private-0700/inner.txt (inner\n)  ._root-meta (dot-underscore, root)
#        nested/a/b/c/deep.txt (deep\n)    nested/a/._deep-meta (depth 3)
#        hard-link group A, 3 links, content "group-a\n":
#            links/a-one  links/a-two  nested/a/a-three
#        hard-link group B, 2 links, content "group-b\n":
#            links/b-one  nested/b-two
#        links/to-plain -> ../plain.txt (symlink to a file)
#        links/dangling -> no-such-target (dangling symlink)
#        special/sock (Unix socket, created via perl IO::Socket::UNIX bound to
#            a RELATIVE name, so DIR may exceed the ~104 byte sun_path limit)
#        special/fifo (named pipe)
#        names/<newline-name>: "line", a real newline, "break.txt"
#        names/-dash.txt   names/with space.txt
#      Every other directory is mode 0755. When persist_fixture_euid prints 0
#      it ADDITIONALLY creates, in this order, and runs exactly these three
#      chown commands (found on PATH, exactly two args: owner spec then path
#      as "$DIR/..."):
#        owners/ (0755), owners/uid30033 -> chown 30033:30033 "$DIR/owners/uid30033"
#        owners/uid0                     -> chown 0:0         "$DIR/owners/uid0"
#        owners/dir30033/ (dir)          -> chown 30033:30033 "$DIR/owners/dir30033"
#      When it prints anything else there is no owners/ and chown is NEVER run.
#
#  persist_fixture_tree_list DIR
#      Prints one record per entry under DIR (DIR itself excluded; symlinks not
#      followed; every type): the path relative to DIR with no "./" prefix,
#      each record terminated by NUL (so newline names are exact), sorted
#      bytewise (C locale, perl `sort`) by that path.
#
#  Portability: the test reads link counts, inodes, modes and owners with a
#  perl lstat one-liner, because BSD and GNU `stat` take different flags.
#
#  Coverage-container case: when DXE_COVERAGE_ISOLATED=1 (the kcov container
#  sets it; tests/coverage/Dockerfile must install rsync) `command -v rsync`
#  must succeed. Outside that environment the case records nothing at all
#  (no pass, no skip).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
LIB="$SCRIPT_DIR/lib/persist-fixtures.sh"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pfx-test.XXXXXX")"
trap 'chmod -R u+rwx "$SCRATCH" 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

# --- local helpers ----------------------------------------------------------
lstat_field() { # lstat_field FIELD PATH: nlink | mode | owner | inode
    perl -e '
        my @s = lstat($ARGV[1]) or exit 1;
        my $f = $ARGV[0];
        if    ($f eq "nlink") { print $s[3] }
        elsif ($f eq "mode")  { printf "%04o", $s[2] & 07777 }
        elsif ($f eq "owner") { print "$s[4]:$s[5]" }
        elsif ($f eq "inode") { print "$s[0]:$s[1]" }
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

NL=$'\n'
# Every path persist_fixture_tree_build creates when not root, relative to DIR.
EXPECTED_ENTRIES=(
    plain.txt empty-file secret-0600.txt private-0700 private-0700/inner.txt
    ._root-meta nested nested/a nested/a/b nested/a/b/c nested/a/b/c/deep.txt
    nested/a/._deep-meta nested/a/a-three nested/b-two
    links links/a-one links/a-two links/b-one links/to-plain links/dangling
    special special/sock special/fifo
    names "names/line${NL}break.txt" names/-dash.txt "names/with space.txt"
)
OWNER_ENTRIES=(owners owners/uid30033 owners/uid0 owners/dir30033)

# Sorted NUL-separated expected list from the arguments.
expected_list_file() { # expected_list_file OUT PATH...
    local out="$1"; shift
    printf '%s\0' "$@" | perl -e '
        local $/ = "\0"; my @l = <STDIN>; chomp @l;
        print map { "$_\0" } sort @l;' > "$out"
}

# A recording chown ahead of the real one: logs argv (one arg per line, a
# "--" line per call) and changes nothing.
recording_chown_dir() { # prints dir; log is $dir/chown.log
    local d
    d="$(mktemp -d "$SCRATCH/chown.XXXXXX")"
    fake_tool_write "$d" chown "printf '%s\n' \"\$@\" >> \"$d/chown.log\"; echo -- >> \"$d/chown.log\""
    printf '%s\n' "$d"
}

# ---------------------------------------------------------------------------
test_section "persist-fixtures: library presence and import purity"

if [ -f "$LIB" ]; then
    test_pass "tests/lib/persist-fixtures.sh exists"
    # shellcheck source=lib/persist-fixtures.sh
    source "$LIB"
else
    test_fail "tests/lib/persist-fixtures.sh exists"
fi

purity_probe() {
    local out rc
    out="$(cd "$SCRATCH" && env -i PATH="$PATH" HOME="$HOME" bash -c '
        before_opts="$-"; before_pwd="$PWD"
        source "$1" || exit 3
        [ "$before_opts" = "$-" ] || exit 4
        [ "$before_pwd" = "$PWD" ] || exit 5
        [ "$(type -t persist_fixture_tree_build)" = function ] || exit 6
        [ "$PERSIST_FIXTURE_NAS_HOST" = dxe-fixture-nas.invalid ] || exit 7
        [ "$(type -t fake_qnap_ssh_write)" = function ] || exit 8' _ "$LIB" 2>&1)"
    rc=$?
    assert_eq "sourcing prints nothing, keeps options/cwd, defines functions and host constant, pulls in fake-tools" "0:" "$rc:$out"
}
purity_probe

# ---------------------------------------------------------------------------
test_section "persist-fixtures: temporary share root and cleanup"

root_cases() {
    need persist_fixture_root_create || return 0
    need persist_fixture_cleanup || return 0
    local parent a b
    parent="$SCRATCH/parent"; mkdir -p "$parent"
    a="$(persist_fixture_root_create "$parent")"
    b="$(persist_fixture_root_create "$parent")"
    assert_true "root is an existing directory" test -d "$a"
    assert_eq "root is created directly under PARENT with the dxe-persist-share. prefix" "$parent" "$(dirname "$a")"
    case "$(basename "$a")" in
        dxe-persist-share.*) test_pass "root basename has the dxe-persist-share. prefix" ;;
        *) test_fail "root basename has the dxe-persist-share. prefix ($a)" ;;
    esac
    assert_eq "new root is empty" "0" "$(find "$a" -mindepth 1 | wc -l | tr -d ' ')"
    assert_true "two calls give distinct roots" test "$a" != "$b"

    local default_root
    default_root="$(TMPDIR="$SCRATCH" persist_fixture_root_create)"
    assert_eq "PARENT defaults to \${TMPDIR:-/tmp}" "$SCRATCH" "$(dirname "$default_root")"

    # Cleanup removes a nasty tree.
    persist_fixture_tree_build "$a" 2>/dev/null
    persist_fixture_cleanup "$a" "$b" "$default_root"
    assert_eq "cleanup removed a full tree (0700 dirs, socket, fifo, dangling link) and the empty roots" "no:no:no" \
        "$(test -e "$a" -o -L "$a" && echo yes || echo no):$(test -e "$b" && echo yes || echo no):$(test -e "$default_root" && echo yes || echo no)"
    persist_fixture_cleanup "$a" 2>/dev/null
    assert_eq "cleanup of a missing path is not an error" "0" "$?"

    # Refusals.
    local victim="$SCRATCH/not-prefixed" err rc
    mkdir -p "$victim"
    err="$(persist_fixture_cleanup "$victim" 2>&1)"; rc=$?
    assert_eq "cleanup refuses a path whose basename lacks the dxe- prefix (status 1)" "1" "$rc"
    assert_true "refusal message says refusing" grep -Fq "refusing" <<<"$err"
    assert_true "refused directory is untouched" test -d "$victim"
    for bad in "" "/" "."; do
        err="$(persist_fixture_cleanup "$bad" 2>&1)"; rc=$?
        assert_eq "cleanup refuses [$bad] (status 1)" "1" "$rc"
        assert_true "cleanup refusing [$bad] says refusing" grep -Fq "refusing" <<<"$err"
    done
    assert_true "cwd still exists after refusing '.'" test -d .
}
root_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures: NAS fake runs commands locally against the root"

nas_cases() {
    need persist_fixture_nas_create || return 0
    need persist_fixture_root_create || return 0
    local root tools log rc out
    root="$(persist_fixture_root_create "$SCRATCH")"
    tools="$(persist_fixture_nas_create "$root" "$SCRATCH")"
    log="$SCRATCH/nas-argv.log"
    : > "$log"
    assert_true "tool dir is a directory under PARENT" test -d "$tools"
    assert_eq "tool dir sits directly under PARENT" "$SCRATCH" "$(dirname "$tools")"
    assert_true "tool dir holds an executable ssh" test -x "$tools/ssh"

    out="$(PATH="$tools:$PATH" DXE_FAKE_SSH_ARGV_LOG="$log" \
        ssh -o BatchMode=yes "$PERSIST_FIXTURE_NAS_HOST" \
        'printf "cwd=%s\nroot=%s\n" "$(pwd -P)" "$DXE_FIXTURE_NAS_ROOT"; mkdir -p dxe/guest && : > dxe/guest/marker')"
    rc=$?
    assert_eq "fake ssh exits 0 for a successful remote command" "0" "$rc"
    assert_eq "remote command ran locally with cwd = ROOT and DXE_FIXTURE_NAS_ROOT = ROOT" \
        "cwd=$(cd "$root" && pwd -P)${NL}root=$root" "$out"
    assert_true "the remote command's effect landed inside the temporary root" test -f "$root/dxe/guest/marker"
    assert_eq "ssh argv recorded exactly, one word per line, command last" \
        "-o${NL}BatchMode=yes${NL}dxe-fixture-nas.invalid${NL}printf \"cwd=%s\nroot=%s\n\" \"\$(pwd -P)\" \"\$DXE_FIXTURE_NAS_ROOT\"; mkdir -p dxe/guest && : > dxe/guest/marker" \
        "$(cat "$log")"

    PATH="$tools:$PATH" ssh "$PERSIST_FIXTURE_NAS_HOST" 'exit 7'
    assert_eq "remote exit status propagates" "7" "$?"

    # A path with spaces and a leading dash survives intact when quoted.
    PATH="$tools:$PATH" ssh "$PERSIST_FIXTURE_NAS_HOST" "mkdir -p -- 'sp ace/-dash' && : > 'sp ace/-dash/f'"
    assert_true "quoted path with a space and a leading dash survives" test -f "$root/sp ace/-dash/f"

    # DXE_FAKE_SSH_REMOTE_PATH still restricts the remote PATH.
    local only
    only="$(mktemp -d "$SCRATCH/remote-path.XXXXXX")"
    fake_tool_write "$only" nas-only-tool 'echo nas-only-tool-ran'
    out="$(PATH="$tools:$PATH" DXE_FAKE_SSH_REMOTE_PATH="$only" ssh "$PERSIST_FIXTURE_NAS_HOST" 'nas-only-tool' 2>&1)"
    assert_eq "restricted remote PATH finds only its own tools" "nas-only-tool-ran" "$out"
    PATH="$tools:$PATH" DXE_FAKE_SSH_REMOTE_PATH="$only" ssh "$PERSIST_FIXTURE_NAS_HOST" 'touch should-not-exist' >/dev/null 2>&1
    assert_false "an external tool outside the restricted remote PATH is not available" test -e "$root/should-not-exist"

    # Fail-closed neighbours stay fail-closed.
    out="$(PATH="$tools:$PATH" scp a b 2>&1)"; rc=$?
    assert_eq "scp in the tool dir is fail-closed (exit 99)" "99" "$rc"
    assert_true "fail-closed message explains itself" grep -Fq "refusing to reach a real host" <<<"$out"

    # Missing root.
    local missing="$SCRATCH/no-such-root" err before after
    before="$(find "$SCRATCH" -maxdepth 1 -name 'dxe-fake-tools.*' | wc -l | tr -d ' ')"
    err="$(persist_fixture_nas_create "$missing" "$SCRATCH" 2>&1)"; rc=$?
    assert_eq "missing ROOT: status 1" "1" "$rc"
    assert_true "missing ROOT: message says does not exist" grep -Fq "does not exist" <<<"$err"
    after="$(find "$SCRATCH" -maxdepth 1 -name 'dxe-fake-tools.*' | wc -l | tr -d ' ')"
    assert_eq "missing ROOT: no tool dir created" "$before" "$after"
}
nas_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures: tree builder (non-root path)"

tree_nonroot_cases() {
    need persist_fixture_tree_build || return 0
    local d="$SCRATCH/tree1" chowns rc out
    mkdir -p "$d"
    chowns="$(recording_chown_dir)"
    persist_fixture_euid() { echo 1000; }
    out="$(PATH="$chowns:$PATH" persist_fixture_tree_build "$d" 2>&1)"; rc=$?
    unset -f persist_fixture_euid
    # shellcheck source=lib/persist-fixtures.sh
    source "$LIB"
    assert_eq "builder exits 0 and prints nothing" "0:" "$rc:$out"
    assert_false "not root: chown is never run" test -e "$chowns/chown.log"
    assert_false "not root: no owners/ directory" test -e "$d/owners"

    # Entry set, exactly.
    expected_list_file "$SCRATCH/exp1" "${EXPECTED_ENTRIES[@]}"
    if need persist_fixture_tree_list; then
        persist_fixture_tree_list "$d" > "$SCRATCH/got1"
        assert_true "tree has exactly the pinned entries (nothing more, nothing less)" cmp -s "$SCRATCH/exp1" "$SCRATCH/got1"
    fi

    # Regular files and contents.
    assert_eq "plain.txt content" "plain" "$(cat "$d/plain.txt")"
    assert_eq "secret-0600.txt content" "secret" "$(cat "$d/secret-0600.txt")"
    assert_eq "private-0700/inner.txt content" "inner" "$(cat "$d/private-0700/inner.txt")"
    assert_eq "nested/a/b/c/deep.txt content" "deep" "$(cat "$d/nested/a/b/c/deep.txt")"
    assert_true "empty-file is a regular file" test -f "$d/empty-file"
    assert_false "empty-file is empty" test -s "$d/empty-file"

    # Modes.
    assert_eq "secret-0600.txt mode" "0600" "$(lstat_field mode "$d/secret-0600.txt")"
    assert_eq "private-0700 mode" "0700" "$(lstat_field mode "$d/private-0700")"
    assert_eq "plain.txt mode" "0644" "$(lstat_field mode "$d/plain.txt")"
    assert_eq "nested/a/b mode" "0755" "$(lstat_field mode "$d/nested/a/b")"
    assert_eq "links mode" "0755" "$(lstat_field mode "$d/links")"

    # Hard-link group A (3 links) and B (2 links).
    local p
    for p in links/a-one links/a-two nested/a/a-three; do
        assert_eq "group A member $p has link count 3" "3" "$(lstat_field nlink "$d/$p")"
        assert_eq "group A member $p content" "group-a" "$(cat "$d/$p")"
    done
    assert_eq "group A shares one inode (one/two)" "$(lstat_field inode "$d/links/a-one")" "$(lstat_field inode "$d/links/a-two")"
    assert_eq "group A shares one inode (one/three)" "$(lstat_field inode "$d/links/a-one")" "$(lstat_field inode "$d/nested/a/a-three")"
    for p in links/b-one nested/b-two; do
        assert_eq "group B member $p has link count 2" "2" "$(lstat_field nlink "$d/$p")"
        assert_eq "group B member $p content" "group-b" "$(cat "$d/$p")"
    done
    assert_eq "group B shares one inode" "$(lstat_field inode "$d/links/b-one")" "$(lstat_field inode "$d/nested/b-two")"
    assert_true "groups A and B are different inodes" test "$(lstat_field inode "$d/links/a-one")" != "$(lstat_field inode "$d/links/b-one")"
    assert_eq "plain.txt has link count 1" "1" "$(lstat_field nlink "$d/plain.txt")"
    assert_eq "empty-file has link count 1" "1" "$(lstat_field nlink "$d/empty-file")"

    # Symlinks.
    assert_true "links/to-plain is a symlink (test -L)" test -L "$d/links/to-plain"
    assert_true "links/to-plain is a symlink (test -h)" test -h "$d/links/to-plain"
    assert_eq "links/to-plain target" "../plain.txt" "$(readlink "$d/links/to-plain")"
    assert_eq "links/to-plain resolves to the file" "plain" "$(cat "$d/links/to-plain")"
    assert_true "links/dangling is a symlink" test -L "$d/links/dangling"
    assert_eq "links/dangling target" "no-such-target" "$(readlink "$d/links/dangling")"
    assert_false "links/dangling really dangles (test -e false)" test -e "$d/links/dangling"
    assert_false "plain.txt is not a symlink" test -L "$d/plain.txt"

    # Special files.
    assert_true "special/sock is a Unix socket (test -S)" test -S "$d/special/sock"
    assert_false "special/sock is not a regular file" test -f "$d/special/sock"
    assert_true "special/fifo is a FIFO (test -p)" test -p "$d/special/fifo"
    assert_false "special/fifo is not a regular file" test -f "$d/special/fifo"

    # Awkward names, exactly.
    assert_true "newline name exists as a regular file" test -f "$d/names/line${NL}break.txt"
    assert_true "leading-dash name exists as a regular file" test -f "$d/names/-dash.txt"
    assert_true "name with a space exists as a regular file" test -f "$d/names/with space.txt"
    assert_eq "names/ holds exactly the 3 awkward names (perl readdir, bytewise)" \
        "-dash.txt|line${NL}break.txt|with space.txt" \
        "$(perl -e 'opendir(D,$ARGV[0]) or exit 1; @n = sort grep { $_ ne "." && $_ ne ".." } readdir(D); print join("|",@n)' "$d/names")"

    # Apple-double style files at the root and at depth >= 2.
    assert_true "._root-meta at the root is a regular file" test -f "$d/._root-meta"
    assert_true "nested/a/._deep-meta at depth 3 is a regular file" test -f "$d/nested/a/._deep-meta"
    assert_eq "root has exactly one ._ entry" "1" "$(find "$d" -maxdepth 1 -name '._*' | wc -l | tr -d ' ')"
    assert_eq "tree has exactly two ._ entries" "2" "$(find "$d" -name '._*' | wc -l | tr -d ' ')"

    # Nested directories.
    assert_true "nested/a/b/c is a directory" test -d "$d/nested/a/b/c"

    # Deterministic: a second tree lists identically.
    local d2="$SCRATCH/tree2"
    mkdir -p "$d2"
    persist_fixture_euid() { echo 1000; }
    persist_fixture_tree_build "$d2" >/dev/null 2>&1
    unset -f persist_fixture_euid
    # shellcheck source=lib/persist-fixtures.sh
    source "$LIB"
    if need persist_fixture_tree_list; then
        persist_fixture_tree_list "$d2" > "$SCRATCH/got2"
        assert_true "two trees list byte-identically" cmp -s "$SCRATCH/got1" "$SCRATCH/got2"
    fi

    # Missing directory.
    local err
    err="$(persist_fixture_tree_build "$SCRATCH/nope" 2>&1)"; rc=$?
    assert_eq "missing DIR: status 1" "1" "$rc"
    assert_true "missing DIR: message says does not exist" grep -Fq "does not exist" <<<"$err"
    assert_false "missing DIR: nothing created" test -e "$SCRATCH/nope"
}
tree_nonroot_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures: tree builder (root path, chown stubbed by recording)"

tree_root_stub_cases() {
    need persist_fixture_tree_build || return 0
    local d="$SCRATCH/tree-rootstub" chowns out rc
    mkdir -p "$d"
    chowns="$(recording_chown_dir)"
    persist_fixture_euid() { echo 0; }
    out="$(PATH="$chowns:$PATH" persist_fixture_tree_build "$d" 2>&1)"; rc=$?
    unset -f persist_fixture_euid
    # shellcheck source=lib/persist-fixtures.sh
    source "$LIB"
    assert_eq "root path: exits 0 and prints nothing" "0:" "$rc:$out"
    assert_eq "root path: exactly three chown calls with exact argv, in order" \
        "30033:30033${NL}$d/owners/uid30033${NL}--${NL}0:0${NL}$d/owners/uid0${NL}--${NL}30033:30033${NL}$d/owners/dir30033${NL}--" \
        "$(cat "$chowns/chown.log" 2>/dev/null)"
    assert_true "owners/ is a directory" test -d "$d/owners"
    assert_true "owners/uid30033 is a regular file" test -f "$d/owners/uid30033"
    assert_true "owners/uid0 is a regular file" test -f "$d/owners/uid0"
    assert_true "owners/dir30033 is a directory" test -d "$d/owners/dir30033"
    if need persist_fixture_tree_list; then
        expected_list_file "$SCRATCH/exp3" "${EXPECTED_ENTRIES[@]}" "${OWNER_ENTRIES[@]}"
        persist_fixture_tree_list "$d" > "$SCRATCH/got3"
        assert_true "root path: entries are the pinned set plus the owners entries" cmp -s "$SCRATCH/exp3" "$SCRATCH/got3"
    fi
}
tree_root_stub_cases

# The recording stub above stands in for a privilege boundary: validate it
# against the real one whenever this suite genuinely runs as root.
tree_real_root_cases() {
    [ "$(id -u)" = 0 ] || return 0
    need persist_fixture_tree_build || return 0
    local d="$SCRATCH/tree-realroot"
    mkdir -p "$d"
    persist_fixture_tree_build "$d" >/dev/null 2>&1
    assert_eq "real root: owners/uid30033 owned by 30033:30033" "30033:30033" "$(lstat_field owner "$d/owners/uid30033")"
    assert_eq "real root: owners/dir30033 owned by 30033:30033" "30033:30033" "$(lstat_field owner "$d/owners/dir30033")"
    assert_eq "real root: owners/uid0 owned by 0:0" "0:0" "$(lstat_field owner "$d/owners/uid0")"
    assert_eq "real root: the default persist_fixture_euid is 0" "0" "$(persist_fixture_euid)"
}
tree_real_root_cases

default_euid_case() {
    need persist_fixture_euid || return 0
    assert_eq "persist_fixture_euid defaults to id -u" "$(id -u)" "$(persist_fixture_euid)"
}
default_euid_case

# ---------------------------------------------------------------------------
test_section "persist-fixtures: socket path longer than sun_path"

long_path_cases() {
    need persist_fixture_tree_build || return 0
    local long="$SCRATCH/long" i
    for i in 1 2 3 4 5 6; do long="$long/segment-number-$i-padding-padding"; done
    mkdir -p "$long"
    persist_fixture_euid() { echo 1000; }
    persist_fixture_tree_build "$long" >/dev/null 2>&1
    unset -f persist_fixture_euid
    # shellcheck source=lib/persist-fixtures.sh
    source "$LIB"
    assert_true "DIR path is longer than 104 bytes" test "${#long}" -gt 104
    assert_true "socket still created under a very long DIR" test -S "$long/special/sock"
}
long_path_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures: tree list (NUL-safe, sorted)"

list_cases() {
    need persist_fixture_tree_list || return 0
    local d="$SCRATCH/list" rc
    mkdir -p "$d/b" "$d/a"
    : > "$d/b/z"; : > "$d/a/y"; : > "$d/a-x"; : > "$d/b/line${NL}two"
    ln -s dangling "$d/c-link"
    persist_fixture_tree_list "$d" > "$SCRATCH/list.out"; rc=$?
    expected_list_file "$SCRATCH/list.exp" a a/y a-x b b/z "b/line${NL}two" c-link
    assert_eq "list exits 0" "0" "$rc"
    assert_true "list is NUL-terminated, relative, bytewise sorted, DIR excluded, symlink not followed, newline name exact" \
        cmp -s "$SCRATCH/list.exp" "$SCRATCH/list.out"
    # Real NUL termination, not newline.
    assert_eq "record count by NUL" "7" "$(perl -e 'local $/="\0"; my @r=<STDIN>; print scalar @r' < "$SCRATCH/list.out")"
    mkdir -p "$SCRATCH/list-empty"
    assert_eq "empty directory lists nothing" "0" "$(persist_fixture_tree_list "$SCRATCH/list-empty" | wc -c | tr -d ' ')"
}
list_cases

# ---------------------------------------------------------------------------
test_section "persist-fixtures: coverage container provides rsync"

# Only recorded inside the kcov container (DXE_COVERAGE_ISOLATED=1); anywhere
# else this block records nothing (no pass, no skip).
if [ "${DXE_COVERAGE_ISOLATED:-}" = 1 ]; then
    assert_true "rsync is installed in the coverage container (tests/coverage/Dockerfile)" command -v rsync
fi

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    print_summary
    exit_with_code
fi
