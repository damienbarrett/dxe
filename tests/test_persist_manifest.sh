#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
set -uo pipefail

# WP6.1 (plans/do plan.md D-8; spec R33): acceptance tests for the /persist
# migration manifest tool. Written before the tool exists; the implementer
# builds it to satisfy exactly this contract.
#
# Interface contract (every name, format and status below is pinned):
#
#  File: container/dx-nixos-26.05/scripts/lib/dx-persist-manifest.sh. Bash 5
#  with GNU coreutils and findutils (the guest image). Like every
#  scripts/lib/*.sh it is safe to source -- functions and constants only, no
#  output, shell options or I/O at import (tests/test_refactor_contracts.sh's
#  import-purity loop already applies to it). Two ways to run it, identical
#  in stdout, stderr and exit status:
#      bash dx-persist-manifest.sh SUBCOMMAND ARG...
#      bash -c "$(cat dx-persist-manifest.sh)" dx-persist-manifest SUBCOMMAND ARG...
#  The second is the inline-script form the host uses for a one-off container
#  from $DX_IMAGE (D-8; bin/dx-migrate-persist passes `sh -lc SCRIPT` the
#  same way): there $0 is "dx-persist-manifest" and no file backs the text,
#  so a main guard of the plain `[ "${BASH_SOURCE[0]}" = "$0" ]` shape must
#  be extended to run there too. Output never depends on the caller's
#  locale (it behaves as under LC_ALL=C).
#
#  Subcommands and exit status (the cmp/diff convention):
#      generate ROOT                 manifest of ROOT on stdout; 0, or 2 on error
#      compare MANIFEST_A MANIFEST_B 0 equal, 1 different, 2 error
#      verify ROOT_A ROOT_B          generate both (no output of its own),
#                                    then exactly what compare prints and
#                                    returns; 2 if either generate fails
#  Any other argument list (none, an unknown subcommand, a wrong argument
#  count) is a usage error: exit 2, a line containing "Usage:" on stderr,
#  nothing on stdout. Every other error: exit 2 and a line starting
#  "Error:" on stderr. On exit 2, compare and verify print nothing on stdout,
#  and generate prints nothing on stdout when ROOT is not a directory. On
#  success nothing is written to stderr.
#
#  generate ROOT. ROOT must be a directory; a symlink to one is followed and
#  a trailing "/" changes nothing (same bytes out). It walks ROOT without
#  following symlinks and prints one record per entry, ROOT itself
#  included. Each record is TERMINATED by a NUL byte and consists of nine
#  fields separated by single TABs, in this order:
#      TYPE MODE OWNER SIZE MTIME SHA256 LINK TARGET PATH
#    TYPE    f regular file, d directory, l symlink, p FIFO, s socket,
#            c character device, b block device
#    MODE    permission bits incl. setuid/setgid/sticky, four octal digits:
#            0644, 0700, 1777; "-" for a symlink (l), always (WP6.1b, below)
#    OWNER   numeric uid:gid of the entry itself (lstat): 0:0, 30033:30033
#    SIZE    byte size for f; "-" for every other type (directory sizes are
#            filesystem-dependent; a symlink's is its target's length)
#    MTIME   modification time of the entry itself (lstat) as
#            SECONDS.NANOSECONDS with exactly nine fraction digits
#            (1700000001.000000000, 1700000002.000123456); "-" for ROOT
#            itself (see below)
#    SHA256  64 lowercase hex digits of the content for f; "-" otherwise
#    LINK    hard-link group id: for a non-directory whose inode is shared
#            by two or more INCLUDED entries, the bytewise-smallest PATH of
#            those entries, escaped (below); otherwise "-". Links from
#            excluded names or from outside ROOT do not count, so a file
#            whose only other name is an excluded ._* file (or lies outside
#            ROOT) has "-". Never an inode number: it is stable across trees.
#    TARGET  symlink target for l, escaped; "-" otherwise
#    PATH    "." for ROOT, otherwise "./" + the path relative to ROOT,
#            RAW (any byte but NUL: newlines, TABs, backslashes, a leading
#            dash). It is the last field, so a TAB in it is unambiguous.
#  Escaped (LINK, TARGET, and every path that compare prints): "\" becomes
#  "\\", TAB becomes "\t", newline becomes "\n"; every other byte as is.
#  Records are in bytewise (C locale) order of PATH, so "." comes first and
#  two trees with equal content give byte-identical manifests.
#  Excluded, with everything below them: every entry whose name (basename)
#  starts with "._", at any depth; and the marker ".dxe-persist-dir" at the
#  top of ROOT only ("./nested/.dxe-persist-dir" and "./.dxe-persist-dir.bak"
#  are ordinary entries). The rsync side excludes the same names (D-10).
#  ROOT's MTIME is "-": ROOT holds the marker, whose atomic rewrite (a
#  temporary file renamed over it, D-3) changes ROOT's mtime; the marker is
#  outside the comparison and so is that side effect. ROOT's TYPE, MODE and
#  OWNER are compared.
#  MTIME precision is the nanosecond: GNU cp -a and rsync >= 3.1 (both ends
#  are the one local rsync binary on the NAS) preserve it, the plan's
#  mutation probe requires a same-second change to be caught, and a
#  migration that silently truncated timestamps is a difference to report.
#  Any read error (an entry that cannot be listed, a file that cannot be
#  hashed) is exit 2 with an Error: line naming the entry: a manifest is
#  never produced with a guessed or empty checksum.
#
#  compare MANIFEST_A MANIFEST_B. Reads two generate outputs (A is the
#  source, B the destination). A manifest that cannot be read, has no
#  records, does not start with the ROOT record ".", or holds a record
#  with fewer than nine fields is malformed: exit 2. Otherwise records are
#  matched by PATH and stdout is:
#      equal:      exactly one line   Manifests match: entries=N
#      different:  first line         Manifests differ: differences=D entries-a=NA entries-b=NB
#                  then min(D, 20) difference lines, one per PATH, in
#                  bytewise order of the raw PATH:
#                      missing PATH        (in A only)
#                      extra PATH          (in B only)
#                      changed FIELDS PATH (in both; FIELDS is every field
#                                           whose value differs, in record
#                                           order, comma-separated, from:
#                                           type mode owner size mtime
#                                           sha256 link target)
#                  PATH escaped. N, NA, NB count records (ROOT included); D
#                  counts difference lines before truncation. No other line.
#  Examples: "changed sha256 ./plain.txt", "changed type,size,sha256
#  ./special/fifo", "changed mode ./names/line\nbreak.txt".
#
#  Symlink permission bits (WP6.1b; the WP7.2 live trial, 2026-10-13). A
#  symlink's mode is not part of the tree: Linux never consults it, cannot
#  set it (lchmod is unsupported, so rsync cannot carry it), and filesystems
#  disagree about it -- the same links read 0777 on the ext4 Docker volume
#  and 0755 on the NAS's ZFS share, so every volume<->share migration or
#  rollback of a tree holding symlinks failed verification on "changed
#  mode". Therefore:
#    - generate writes MODE "-" for every TYPE l record, whatever lstat says.
#      A symlink's record is exactly
#          l - UID:GID - MTIME - LINK TARGET PATH
#      (LINK as for any non-directory; "-" unless the link itself is
#      hard-linked). The format stays nine fields, so two trees that differ
#      only in symlink modes give byte-identical manifests.
#    - compare never compares MODE between two TYPE l records, whatever
#      either holds ("-", 0777, 0755 -- a manifest from an older tool, or
#      edited): such a pair whose other seven fields are equal is no
#      difference at all, and "mode" never appears in FIELDS for it.
#    - everything else about a symlink is still compared: TYPE, TARGET (exact
#      bytes), OWNER (numeric, lstat) and MTIME (lstat, nanoseconds; rsync -a
#      sets it with lutimes) -- and LINK.
#    - MODE stays compared for every other pair, including a type change
#      where only one side is a symlink ("-" against 0644 is a difference:
#      "changed type,mode,size,sha256,target PATH"), and for f, d, p and s
#      records exactly as before.
#  Linux cannot give a symlink any mode but 0777, so this suite cannot build
#  two real trees whose symlink modes differ (the NAS could). It pins the
#  generate side through the exact records, and the compare side by editing
#  the MODE field of generated records in the manifest text.
#
#  Platform: needs GNU find/stat/coreutils and a Bash >= 5 `bash` on PATH.
#  Where they are missing (a stock macOS host: BSD tools, Bash 3.2) the
#  suite records one skip after the tool-presence check and stops -- the
#  repo's established pattern for guest-toolchain suites
#  (tests/test_herdr_config_persistence.sh:36-48; the GNU-tool probe shape
#  of tests/test_nix_store_import.sh:14-21). It runs in full in the Linux
#  coverage container (tests/run-coverage-linux.sh: root, kcov) and in CI's
#  ubuntu-24.04 job. The owner cases need root (skipped otherwise, as in
#  tests/test_persist_backup_select.sh's root-only cases); the unreadable-
#  file case drops to uid 65534 with setpriv when run as root, as
#  tests/test_persist_backup_select.sh:553-567 does.
#
#  Fixtures: WP0.2's tests/lib/persist-fixtures.sh tree (hard-link groups,
#  dangling symlink, socket, FIFO, newline/leading-dash/space names, ._*
#  files, 0600/0700 modes, numeric owners as root) plus the extras below,
#  all inside one persist_fixture_root_create root that
#  persist_fixture_cleanup removes. Each destination is `cp -a` of the
#  source inside that root; every mutation below targets a path inside a
#  destination this run created (fx_copy refuses anything else), and puts
#  back the parent directory's mtime with `touch -r` so that exactly the
#  intended difference remains.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
TOOL="$CONTAINER_DIR/scripts/lib/dx-persist-manifest.sh"

test_section "persist manifest: tool presence"

assert_file_exists "$TOOL" "the manifest tool exists at scripts/lib/dx-persist-manifest.sh (plan D-8)"

# --- toolchain gate ----------------------------------------------------------
# Probed from captured output, never `cmd | grep -q` (pipefail; see
# stdin_matches in tests/test_helpers.sh).
manifest_toolchain_ok() {
    local v
    v="$(bash --version 2>/dev/null)" || return 1
    case "$v" in
        *"version "[5-9].*) : ;;
        *) return 1 ;;
    esac
    v="$(find --version 2>/dev/null)" || return 1
    case "$v" in
        *"GNU findutils"*) : ;;
        *) return 1 ;;
    esac
    v="$(stat --version 2>/dev/null)" || return 1
    case "$v" in
        *"GNU coreutils"*) : ;;
        *) return 1 ;;
    esac
    command -v sha256sum >/dev/null 2>&1
}

if ! manifest_toolchain_ok; then
    test_skip "the manifest tool needs the guest toolchain (Bash 5, GNU findutils and coreutils); covered by run-coverage-linux.sh and CI's Linux job"
    print_summary
    exit_with_code
fi

# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"

FIXROOT="$(persist_fixture_root_create)" || {
    test_fail "a fixture root could be created under \${TMPDIR:-/tmp}"
    print_summary
    exit 1
}
case "$FIXROOT" in
    /*/dxe-persist-share.*) : ;;
    *)
        test_fail "a fixture root could be created under \${TMPDIR:-/tmp} (got [$FIXROOT])"
        print_summary
        exit_with_code
        ;;
esac
if [ ! -d "$FIXROOT" ] || [ -L "$FIXROOT" ]; then
    test_fail "the fixture root is a real directory"
    print_summary
    exit_with_code
fi
trap 'persist_fixture_cleanup "$FIXROOT"' EXIT

NL=$'\n'
TAB=$'\t'
BS='\'
SRC="$FIXROOT/dxe-src"
MAN="$FIXROOT/dxe-manifests"
mkdir "$SRC" "$MAN"
chmod 0755 "$SRC"

NAME_NL="names/line${NL}break.txt"
NAME_TAB="names/tab${TAB}inside.txt"
NAME_TTAB="names/trailing-tab${TAB}"
NAME_BS="names/back${BS}slash.txt"

# --- local helpers ------------------------------------------------------------
assert_eq() { # assert_eq DESC EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then
        test_pass "$1"
    else
        test_fail "$1 (expected [$(show "$2")], got [$(show "$3")])"
    fi
}

assert_contains() { # assert_contains DESC NEEDLE HAYSTACK
    if grep -Fq -- "$2" <<<"$3"; then
        test_pass "$1"
    else
        test_fail "$1 (no [$2] in [$(show "$3")])"
    fi
}

# show TEXT: TEXT with backslash, TAB and newline made visible, for messages.
show() {
    perl -e 'my $s = $ARGV[0]; $s =~ s/\\/\\\\/g; $s =~ s/\t/\\t/g; $s =~ s/\n/\\n/g; print $s' "$1"
}

# tool OUT ERR ARG...: runs the tool as a file; returns its status.
tool() {
    local out="$1" err="$2"
    shift 2
    bash "$TOOL" "$@" > "$out" 2> "$err"
}

# rec FIELD...: one expected record (without its NUL terminator).
rec() {
    local IFS="$TAB"
    printf '%s' "$*"
}

sha_of() { sha256sum < "$1" | cut -c1-64; }

# pin_mtime REL SECONDS.NANOS: set an entry's own mtime in the source tree.
pin_mtime() { touch -h -m -d "@$2" -- "$SRC/$1"; }

# Perl manifest reader. MODE: has RECORD | show PATH | paths | count | ok.
MANIFEST_READER='
    my ($mode, $file, $arg) = @ARGV;
    open(my $fh, "<", $file) or exit 2;
    local $/; my $d = <$fh>; close $fh;
    $d = "" unless defined $d;
    if ($mode eq "ok") { exit((length($d) && substr($d, -1) eq "\0") ? 0 : 1) }
    $d =~ s/\0\z//;
    my @r = length($d) ? split(/\0/, $d, -1) : ();
    sub esc { my $s = shift; $s =~ s/\\/\\\\/g; $s =~ s/\t/\\t/g; $s =~ s/\n/\\n/g; $s }
    sub path_of { my @f = split(/\t/, $_[0], 9); @f == 9 ? $f[8] : undef }
    if ($mode eq "count") { print scalar(@r); exit 0 }
    if ($mode eq "has") { for (@r) { exit 0 if $_ eq $arg } exit 1 }
    if ($mode eq "show") {
        for (@r) { my $p = path_of($_); if (defined $p && $p eq $arg) { print esc($_); exit 0 } }
        print "<no record>"; exit 1;
    }
    if ($mode eq "paths") {
        for (@r) { my $p = path_of($_); print defined $p ? "$p\0" : "<malformed>\0" }
        exit 0;
    }
    exit 3;'
manifest_read() { perl -e "$MANIFEST_READER" "$@"; }

# assert_record DESC MANIFEST RECORD: the manifest holds exactly this record.
assert_record() {
    local desc="$1" manifest="$2" want="$3" path
    if manifest_read has "$manifest" "$want"; then
        test_pass "$desc"
    else
        path="$(perl -e 'my @f = split(/\t/, $ARGV[0], 9); print $f[8]' "$want")"
        test_fail "$desc (expected [$(show "$want")], manifest has [$(manifest_read show "$manifest" "$path")])"
    fi
}

# fx_copy NAME: cp -a of the source tree to $FIXROOT/dxe-b-NAME; prints it.
# Refuses (status 1, nothing copied) unless the destination is a new path
# directly inside this run's fixture root: every mutation below is applied
# only to a directory this function returned.
fx_copy() {
    local dest="$FIXROOT/dxe-b-$1"
    case "$1" in
        '' | */* | *..*) return 1 ;;
    esac
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        return 1
    fi
    cp -a -- "$SRC" "$dest" || return 1
    printf '%s\n' "$dest"
}

# restore_mtime B REL...: give each B/REL the source's own mtime back.
restore_mtime() {
    local b="$1" rel
    shift
    for rel in "$@"; do
        touch -h -r "$SRC/$rel" -- "$b/$rel"
    done
}

# differ_out D NB LINE...: the expected compare stdout for a difference
# against the source manifest (entries-a is always $N).
differ_out() {
    local d="$1" nb="$2" line out
    shift 2
    out="Manifests differ: differences=$d entries-a=$N entries-b=$nb"
    for line in "$@"; do
        out="$out$NL$line"
    done
    printf '%s' "$out"
}

# expect_compare DESC B STATUS STDOUT: generate B, compare the source
# manifest with it, and check the exact status and stdout.
expect_compare() {
    local desc="$1" b="$2" want_rc="$3" want_out="$4" mb out rc
    mb="$MAN/$(basename "$b").manifest"
    tool "$mb" "$mb.err" generate "$b"
    out="$(bash "$TOOL" compare "$MA" "$mb" 2>"$mb.cmp.err")"
    rc=$?
    assert_eq "$desc: compare exits $want_rc" "$want_rc" "$rc"
    assert_eq "$desc: compare output" "$want_out" "$out"
}

# --- the source tree ---------------------------------------------------------
persist_fixture_tree_build "$SRC" || test_fail "the WP0.2 fixture tree builds in the source directory"
printf 'tab\n' > "$SRC/$NAME_TAB"
printf 'trailing\n' > "$SRC/$NAME_TTAB"
printf 'back\n' > "$SRC/$NAME_BS"
printf 'not meta\n' > "$SRC/names/not._meta"
ln "$SRC/$NAME_NL" "$SRC/names/z-link"
ln -s "odd${TAB}target${NL}x" "$SRC/links/odd-target"
# WP6.1b: the live seed's other symlink shapes -- one to a directory, and an
# absolute one (dangling here, as it would be outside the guest).
ln -s ../nested "$SRC/links/to-dir"
ln -s /dxe-fixture-absolute/no-such-target "$SRC/links/absolute"
mkdir "$SRC/sticky"
mkdir "$SRC/nested/._meta-dir"
printf 'meta child\n' > "$SRC/nested/._meta-dir/child"
ln "$SRC/plain.txt" "$SRC/._plain-link"
ln "$SRC/empty-file" "$FIXROOT/dxe-outside-link"
printf 'schema=1\nguest=dxe-fixture\nstate=ready\n' > "$SRC/.dxe-persist-dir"
printf 'not the marker\n' > "$SRC/.dxe-persist-dir.bak"
chmod 0644 "$SRC/$NAME_TAB" "$SRC/$NAME_TTAB" "$SRC/$NAME_BS" "$SRC/names/not._meta" \
    "$SRC/nested/._meta-dir/child" "$SRC/.dxe-persist-dir" "$SRC/.dxe-persist-dir.bak"
chmod 0755 "$SRC/nested/._meta-dir"
chmod 1777 "$SRC/sticky"
chmod 0640 "$SRC/special/fifo"
chmod 0600 "$SRC/special/sock"
# Distinct, fixed mtimes (after every entry exists: creating an entry moves
# its directory's mtime). Zero and leading-zero fractions pin the format.
pin_mtime plain.txt 1700000001.000000000
pin_mtime empty-file 1700000002.000123456
pin_mtime secret-0600.txt 1700000003.300000003
pin_mtime private-0700 1700000004.400000004
pin_mtime links/a-one 1700000005.500000005
pin_mtime links/b-one 1700000006.600000006
pin_mtime links/to-plain 1700000007.700000007
pin_mtime links/dangling 1700000008.800000008
pin_mtime links/odd-target 1700000009.900000009
pin_mtime special/fifo 1700000010.010000010
pin_mtime special/sock 1700000011.011000011
pin_mtime "$NAME_NL" 1700000012.012000012
pin_mtime names/-dash.txt 1700000013.013000013
pin_mtime "names/with space.txt" 1700000014.014000014
pin_mtime "$NAME_TAB" 1700000015.015000015
pin_mtime "$NAME_TTAB" 1700000016.016000016
pin_mtime "$NAME_BS" 1700000017.017000017
pin_mtime names/not._meta 1700000018.018000018
pin_mtime sticky 1700000019.019000019
pin_mtime .dxe-persist-dir.bak 1700000022.022000022
pin_mtime links/to-dir 1700000023.023000023
pin_mtime links/absolute 1700000024.024000024
IS_ROOT=no
if [ "$(id -u)" -eq 0 ]; then
    IS_ROOT=yes
    pin_mtime owners/uid30033 1700000020.020000020
    pin_mtime owners/dir30033 1700000021.021000021
fi

O="$(stat -c %u:%g -- "$SRC/plain.txt")"
EMPTY_SHA="$(sha_of "$SRC/empty-file")"

# The expected PATH sequence: every fixture entry except ._* subtrees and the
# top-level marker, "./"-prefixed, plus ".", in bytewise order.
EXPECTED_PATHS="$MAN/expected-paths"
persist_fixture_tree_list "$SRC" | perl -e '
    local $/ = "\0"; my @o = (".");
    while (my $p = <STDIN>) {
        chomp $p;
        next if grep { /^\._/ } split m{/}, $p;
        next if $p eq ".dxe-persist-dir";
        push @o, "./$p";
    }
    print map { "$_\0" } sort @o;' > "$EXPECTED_PATHS"
N="$(perl -e 'local $/; my $d = <STDIN>; print scalar(() = $d =~ /\0/g)' < "$EXPECTED_PATHS")"

MA="$MAN/src.manifest"

# ---------------------------------------------------------------------------
test_section "persist manifest: generate (record layout)"

generate_cases() {
    local rc paths
    tool "$MA" "$MA.err" generate "$SRC"
    rc=$?
    assert_eq "generate exits 0 on a readable tree" "0" "$rc"
    assert_eq "generate writes nothing to stderr on success" "" "$(cat "$MA.err")"
    if manifest_read ok "$MA"; then
        test_pass "the manifest is non-empty and its last record ends with NUL"
    else
        test_fail "the manifest is non-empty and its last record ends with NUL"
    fi
    paths="$MAN/actual-paths"
    manifest_read paths "$MA" > "$paths"
    if cmp -s "$EXPECTED_PATHS" "$paths"; then
        test_pass "one record per included entry, ROOT first as \".\", ./-prefixed raw paths in bytewise order"
    else
        test_fail "one record per included entry, ROOT first as \".\", ./-prefixed raw paths in bytewise order (expected [$(show "$(tr '\0' '|' < "$EXPECTED_PATHS")")], got [$(show "$(tr '\0' '|' < "$paths")")])"
    fi
    assert_eq "no record for a ._* name at any depth, or below a ._* directory" "0" \
        "$(perl -e 'local $/ = "\0"; my ($n, $seen) = (0, 0); while (<STDIN>) { $seen++; chomp; $n++ if grep { /^\._/ } split m{/}; } print $seen ? $n : "no records"' < "$paths")"
    assert_eq "no record for the top-level marker .dxe-persist-dir" "0" \
        "$(perl -e 'local $/ = "\0"; my ($n, $seen) = (0, 0); while (<STDIN>) { $seen++; chomp; $n++ if $_ eq "./.dxe-persist-dir"; } print $seen ? $n : "no records"' < "$paths")"

    assert_record "ROOT record: type, mode, owner; size, mtime, checksum, link and target are -" "$MA" \
        "$(rec d 0755 "$O" - - - - - .)"
    assert_record "regular file: size, nanosecond mtime with a zero fraction, SHA-256; its only other link is an excluded ._* name, so no group" "$MA" \
        "$(rec f 0644 "$O" 6 1700000001.000000000 "$(sha_of "$SRC/plain.txt")" - - ./plain.txt)"
    assert_record "a file hard-linked from outside ROOT has no group; leading-zero nanoseconds are kept" "$MA" \
        "$(rec f 0644 "$O" 0 1700000002.000123456 "$EMPTY_SHA" - - ./empty-file)"
    assert_record "a 0600 file" "$MA" \
        "$(rec f 0600 "$O" 7 1700000003.300000003 "$(sha_of "$SRC/secret-0600.txt")" - - ./secret-0600.txt)"
    assert_record "a 0700 directory: size and checksum are -" "$MA" \
        "$(rec d 0700 "$O" - 1700000004.400000004 - - - ./private-0700)"
    assert_record "a sticky 1777 directory keeps its special bit in MODE" "$MA" \
        "$(rec d 1777 "$O" - 1700000019.019000019 - - - ./sticky)"
    local a_sha b_sha
    a_sha="$(sha_of "$SRC/links/a-one")"
    b_sha="$(sha_of "$SRC/links/b-one")"
    assert_record "hard-link group A: links/a-one carries the group's first path" "$MA" \
        "$(rec f 0644 "$O" 8 1700000005.500000005 "$a_sha" ./links/a-one - ./links/a-one)"
    assert_record "hard-link group A: links/a-two carries the same group id" "$MA" \
        "$(rec f 0644 "$O" 8 1700000005.500000005 "$a_sha" ./links/a-one - ./links/a-two)"
    assert_record "hard-link group A: nested/a/a-three carries the same group id" "$MA" \
        "$(rec f 0644 "$O" 8 1700000005.500000005 "$a_sha" ./links/a-one - ./nested/a/a-three)"
    assert_record "hard-link group B: links/b-one" "$MA" \
        "$(rec f 0644 "$O" 8 1700000006.600000006 "$b_sha" ./links/b-one - ./links/b-one)"
    assert_record "hard-link group B: nested/b-two" "$MA" \
        "$(rec f 0644 "$O" 8 1700000006.600000006 "$b_sha" ./links/b-one - ./nested/b-two)"
    assert_record "symlink: MODE - (WP6.1b), its own owner and mtime, size -, target as written" "$MA" \
        "$(rec l - "$O" - 1700000007.700000007 - - ../plain.txt ./links/to-plain)"
    assert_record "dangling symlink: MODE -" "$MA" \
        "$(rec l - "$O" - 1700000008.800000008 - - no-such-target ./links/dangling)"
    assert_record "a symlink target with a TAB and a newline is escaped; MODE -" "$MA" \
        "$(rec l - "$O" - 1700000009.900000009 - - 'odd\ttarget\nx' ./links/odd-target)"
    assert_record "a symlink to a directory is a symlink record (never followed); MODE -" "$MA" \
        "$(rec l - "$O" - 1700000023.023000023 - - ../nested ./links/to-dir)"
    assert_record "an absolute (dangling) symlink keeps its target byte for byte; MODE -" "$MA" \
        "$(rec l - "$O" - 1700000024.024000024 - - /dxe-fixture-absolute/no-such-target ./links/absolute)"
    assert_record "FIFO" "$MA" \
        "$(rec p 0640 "$O" - 1700000010.010000010 - - - ./special/fifo)"
    assert_record "socket" "$MA" \
        "$(rec s 0600 "$O" - 1700000011.011000011 - - - ./special/sock)"
    local x_sha
    x_sha="$(sha_of "$SRC/$NAME_NL")"
    assert_record "a path with a newline is raw in PATH and escaped as its own group id" "$MA" \
        "$(rec f 0644 "$O" 1 1700000012.012000012 "$x_sha" './names/line\nbreak.txt' - "./$NAME_NL")"
    assert_record "a later link to the newline name carries the escaped group id" "$MA" \
        "$(rec f 0644 "$O" 1 1700000012.012000012 "$x_sha" './names/line\nbreak.txt' - ./names/z-link)"
    assert_record "a leading-dash name is hashed" "$MA" \
        "$(rec f 0644 "$O" 0 1700000013.013000013 "$EMPTY_SHA" - - ./names/-dash.txt)"
    assert_record "a name with spaces" "$MA" \
        "$(rec f 0644 "$O" 0 1700000014.014000014 "$EMPTY_SHA" - - "./names/with space.txt")"
    assert_record "a name with an inner TAB stays raw in PATH" "$MA" \
        "$(rec f 0644 "$O" 4 1700000015.015000015 "$(sha_of "$SRC/$NAME_TAB")" - - "./$NAME_TAB")"
    assert_record "a name ending in a TAB keeps that TAB" "$MA" \
        "$(rec f 0644 "$O" 9 1700000016.016000016 "$(sha_of "$SRC/$NAME_TTAB")" - - "./$NAME_TTAB")"
    assert_record "a name with a backslash stays raw in PATH" "$MA" \
        "$(rec f 0644 "$O" 5 1700000017.017000017 "$(sha_of "$SRC/$NAME_BS")" - - "./$NAME_BS")"
    assert_record "._ inside a name (not at its start) is an ordinary entry" "$MA" \
        "$(rec f 0644 "$O" 9 1700000018.018000018 "$(sha_of "$SRC/names/not._meta")" - - ./names/not._meta)"
    assert_record "only the exact top-level marker name is excluded" "$MA" \
        "$(rec f 0644 "$O" 15 1700000022.022000022 "$(sha_of "$SRC/.dxe-persist-dir.bak")" - - ./.dxe-persist-dir.bak)"
    if [ "$IS_ROOT" = yes ]; then
        assert_record "numeric owner of a 30033-owned file" "$MA" \
            "$(rec f 0644 30033:30033 0 1700000020.020000020 "$EMPTY_SHA" - - ./owners/uid30033)"
        assert_record "numeric owner of a 30033-owned directory" "$MA" \
            "$(rec d 0755 30033:30033 - 1700000021.021000021 - - - ./owners/dir30033)"
    else
        test_skip "numeric owners other than the caller's need root (the Linux coverage container runs as root)"
    fi
}
generate_cases

generate_root_forms() {
    local link="$FIXROOT/dxe-src-link" m1="$MAN/slash.manifest" m2="$MAN/link.manifest"
    ln -s "$SRC" "$link"
    tool "$m1" "$m1.err" generate "$SRC/"
    tool "$m2" "$m2.err" generate "$link"
    if manifest_read ok "$MA" && cmp -s "$MA" "$m1" && cmp -s "$MA" "$m2"; then
        test_pass "ROOT given with a trailing / or through a symlink yields the same bytes"
    else
        test_fail "ROOT given with a trailing / or through a symlink yields the same bytes"
    fi
}
generate_root_forms

# ---------------------------------------------------------------------------
test_section "persist manifest: compare and verify on equal trees"

equal_cases() {
    local b mb out rc
    b="$(fx_copy equal)" || { test_fail "equal: fixture copy"; return 0; }
    mb="$MAN/equal.manifest"
    tool "$mb" "$mb.err" generate "$b"
    if manifest_read ok "$MA" && cmp -s "$MA" "$mb"; then
        test_pass "a cp -a copy (new inodes, same content) yields a byte-identical manifest"
    else
        test_fail "a cp -a copy (new inodes, same content) yields a byte-identical manifest"
    fi
    out="$(bash "$TOOL" compare "$MA" "$mb" 2>"$MAN/equal.err")"
    rc=$?
    assert_eq "compare of equal trees exits 0" "0" "$rc"
    assert_eq "compare of equal trees prints exactly the match line" "Manifests match: entries=$N" "$out"
    assert_eq "compare of equal trees writes nothing to stderr" "" "$(cat "$MAN/equal.err")"
    out="$(bash "$TOOL" compare "$MA" "$MA" 2>/dev/null)"
    rc=$?
    assert_eq "a manifest compared with itself matches" "0:Manifests match: entries=$N" "$rc:$out"
    out="$(bash "$TOOL" verify "$SRC" "$b" 2>/dev/null)"
    rc=$?
    assert_eq "verify of equal trees exits 0 with the match line" "0:Manifests match: entries=$N" "$rc:$out"
}
equal_cases

# ---------------------------------------------------------------------------
test_section "persist manifest: each single change is reported"

change_cases() {
    local b

    b="$(fx_copy content)" || { test_fail "content: fixture copy"; return 0; }
    printf 'PLAIN\n' > "$b/plain.txt"
    restore_mtime "$b" plain.txt
    expect_compare "content change, same size and mtime" "$b" 1 \
        "$(differ_out 1 "$N" 'changed sha256 ./plain.txt')"

    b="$(fx_copy mode)" || { test_fail "mode: fixture copy"; return 0; }
    chmod 0640 "$b/plain.txt"
    expect_compare "mode change" "$b" 1 "$(differ_out 1 "$N" 'changed mode ./plain.txt')"

    b="$(fx_copy sticky)" || { test_fail "sticky: fixture copy"; return 0; }
    chmod 0777 "$b/sticky"
    expect_compare "lost sticky bit on a directory" "$b" 1 "$(differ_out 1 "$N" 'changed mode ./sticky')"

    b="$(fx_copy mtime-seconds)" || { test_fail "mtime-seconds: fixture copy"; return 0; }
    touch -h -m -d @1700000033.300000003 -- "$b/secret-0600.txt"
    expect_compare "mtime off by whole seconds" "$b" 1 "$(differ_out 1 "$N" 'changed mtime ./secret-0600.txt')"

    b="$(fx_copy mtime-nanos)" || { test_fail "mtime-nanos: fixture copy"; return 0; }
    touch -h -m -d @1700000002.000123457 -- "$b/empty-file"
    expect_compare "mtime off by one nanosecond in the same second" "$b" 1 \
        "$(differ_out 1 "$N" 'changed mtime ./empty-file')"

    b="$(fx_copy target)" || { test_fail "target: fixture copy"; return 0; }
    ln -sfn ../empty-file "$b/links/to-plain"
    restore_mtime "$b" links/to-plain links
    expect_compare "symlink target change (SIZE stays -)" "$b" 1 \
        "$(differ_out 1 "$N" 'changed target ./links/to-plain')"

    b="$(fx_copy broken-link)" || { test_fail "broken-link: fixture copy"; return 0; }
    cp -p -- "$b/links/a-two" "$b/links/a-two.copy"
    mv -f -- "$b/links/a-two.copy" "$b/links/a-two"
    restore_mtime "$b" links
    expect_compare "a hard-link group broken by replacing one link with a copy" "$b" 1 \
        "$(differ_out 1 "$N" 'changed link ./links/a-two')"

    b="$(fx_copy broken-first)" || { test_fail "broken-first: fixture copy"; return 0; }
    cp -p -- "$b/links/a-one" "$b/links/a-one.copy"
    mv -f -- "$b/links/a-one.copy" "$b/links/a-one"
    restore_mtime "$b" links
    expect_compare "replacing the group's first path re-ids the rest of the group" "$b" 1 \
        "$(differ_out 3 "$N" 'changed link ./links/a-one' 'changed link ./links/a-two' 'changed link ./nested/a/a-three')"

    b="$(fx_copy extra)" || { test_fail "extra: fixture copy"; return 0; }
    printf 'extra\n' > "$b/nested/extra.txt"
    restore_mtime "$b" nested
    expect_compare "an extra file in the destination" "$b" 1 \
        "$(differ_out 1 "$((N + 1))" 'extra ./nested/extra.txt')"

    b="$(fx_copy missing)" || { test_fail "missing: fixture copy"; return 0; }
    rm -f -- "$b/names/with space.txt"
    restore_mtime "$b" names
    expect_compare "a file missing from the destination (name with a space)" "$b" 1 \
        "$(differ_out 1 "$((N - 1))" 'missing ./names/with space.txt')"

    b="$(fx_copy type)" || { test_fail "type: fixture copy"; return 0; }
    rm -f -- "$b/special/fifo"
    : > "$b/special/fifo"
    chmod 0640 "$b/special/fifo"
    restore_mtime "$b" special/fifo special
    expect_compare "a FIFO replaced by an empty regular file" "$b" 1 \
        "$(differ_out 1 "$N" 'changed type,size,sha256 ./special/fifo')"

    b="$(fx_copy marker-nested)" || { test_fail "marker-nested: fixture copy"; return 0; }
    printf 'not the root marker\n' > "$b/nested/.dxe-persist-dir"
    restore_mtime "$b" nested
    expect_compare "a .dxe-persist-dir below the top is an ordinary entry" "$b" 1 \
        "$(differ_out 1 "$((N + 1))" 'extra ./nested/.dxe-persist-dir')"
}
change_cases

owner_cases() {
    local b
    if [ "$IS_ROOT" != yes ]; then
        test_skip "owner changes need root to chown (the Linux coverage container runs as root)"
        return 0
    fi
    b="$(fx_copy owner-uid)" || { test_fail "owner-uid: fixture copy"; return 0; }
    chown 30033 "$b/plain.txt"
    expect_compare "owner (uid) change" "$b" 1 "$(differ_out 1 "$N" 'changed owner ./plain.txt')"
    b="$(fx_copy owner-gid)" || { test_fail "owner-gid: fixture copy"; return 0; }
    chown :30033 "$b/plain.txt"
    expect_compare "group (gid) change" "$b" 1 "$(differ_out 1 "$N" 'changed owner ./plain.txt')"
}
owner_cases

# ---------------------------------------------------------------------------
test_section "persist manifest: symlink permission bits are not compared (WP6.1b)"

# The WP7.2 live trial (2026-10-13) verified a resumed volume -> share copy
# and got "changed mode" on exactly the seed's four symlinks: 0777 on the
# ext4 volume, 0755 on the ZFS share, everything else about them equal.
# Linux cannot make that difference here, so the compare side is pinned on
# manifest text: generated records with their MODE field edited.

# MANIFEST_EDITOR IN OUT SELECTOR N=VALUE...: writes manifest IN to OUT with
# field N (1-8) of every selected record set to VALUE. SELECTOR is "type:T"
# (every record of TYPE T) or "path:P" (the record whose raw PATH is P).
# Prints how many records it edited; status 3, OUT not written, for none.
MANIFEST_EDITOR='
    my ($in, $out, $sel, @sets) = @ARGV;
    open(my $fh, "<", $in) or exit 2;
    local $/; my $d = <$fh>; close $fh;
    exit 2 unless defined $d && length($d) && substr($d, -1) eq "\0";
    chop $d;
    my @r = split(/\0/, $d, -1);
    my ($kind, $want) = split(/:/, $sel, 2);
    my $n = 0;
    for my $rec (@r) {
        my @f = split(/\t/, $rec, 9);
        next unless @f == 9;
        next unless ($kind eq "type" && $f[0] eq $want) || ($kind eq "path" && $f[8] eq $want);
        for my $s (@sets) { my ($i, $v) = split(/=/, $s, 2); $f[$i - 1] = $v; }
        $rec = join("\t", @f);
        $n++;
    }
    exit 3 unless $n;
    open(my $oh, ">", $out) or exit 2;
    print $oh map { "$_\0" } @r;
    close $oh or exit 2;
    print $n;'
manifest_edit() { perl -e "$MANIFEST_EDITOR" "$@"; }

# expect_text DESC MANIFEST_A MANIFEST_B STATUS STDOUT: compare two manifest
# files as they are (no generate); checks the exact status and stdout.
expect_text() {
    local out rc
    out="$(bash "$TOOL" compare "$2" "$3" 2>"$MAN/text.err")"
    rc=$?
    assert_eq "$1: compare exits $4" "$4" "$rc"
    assert_eq "$1: compare output" "$5" "$out"
}

symlink_mode_text_cases() {
    local n m755="$MAN/l-0755.manifest" m777="$MAN/l-0777.manifest" e="$MAN/l-edit"
    if ! manifest_read ok "$MA"; then
        test_fail "WP6.1b text cases: the source manifest was generated"
        return 0
    fi
    n="$(manifest_edit "$MA" "$m755" type:l 2=0755)" || n="none"
    assert_eq "the source manifest holds five symlink records (relative, dangling, odd target, to a directory, absolute)" "5" "$n"
    manifest_edit "$MA" "$m777" type:l 2=0777 >/dev/null || : > "$m777"

    expect_text "every symlink's MODE 0755 in B (as on the ZFS share), A as generated" "$MA" "$m755" 0 \
        "Manifests match: entries=$N"
    expect_text "the same with the sides swapped (a rollback reads the share as A)" "$m755" "$MA" 0 \
        "Manifests match: entries=$N"
    expect_text "0777 (ext4) against 0755 (ZFS) on every symlink, as the trial's two trees held them" "$m777" "$m755" 0 \
        "Manifests match: entries=$N"

    # Each other field of a symlink still counts, and "mode" is never named
    # beside it, though B's symlink modes all differ from A's.
    manifest_edit "$m755" "$e.target" path:./links/absolute 8=/dxe-fixture-absolute/other-target >/dev/null || : > "$e.target"
    expect_text "a symlink's TARGET still counts (mode never named)" "$MA" "$e.target" 1 \
        "$(differ_out 1 "$N" 'changed target ./links/absolute')"
    manifest_edit "$m755" "$e.owner" path:./links/dangling 3=30033:30033 >/dev/null || : > "$e.owner"
    expect_text "a symlink's OWNER still counts (mode never named)" "$MA" "$e.owner" 1 \
        "$(differ_out 1 "$N" 'changed owner ./links/dangling')"
    manifest_edit "$m755" "$e.mtime" path:./links/to-dir 5=1700000023.023000024 >/dev/null || : > "$e.mtime"
    expect_text "a symlink's MTIME still counts, to the nanosecond (mode never named)" "$MA" "$e.mtime" 1 \
        "$(differ_out 1 "$N" 'changed mtime ./links/to-dir')"
    manifest_edit "$m755" "$e.all" path:./links/to-plain 3=30033:30033 5=1700000007.700000008 8=../empty-file >/dev/null || : > "$e.all"
    expect_text "owner, mtime and target of one symlink: exactly those three fields, in record order" "$MA" "$e.all" 1 \
        "$(differ_out 1 "$N" 'changed owner,mtime,target ./links/to-plain')"

    # MODE still counts for every other type, ROOT included, alongside
    # symlink-mode noise that must not be counted (D stays 5).
    manifest_edit "$m755" "$e.1" path:. 2=0700 >/dev/null || : > "$e.1"
    manifest_edit "$e.1" "$e.2" path:./plain.txt 2=0755 >/dev/null || : > "$e.2"
    manifest_edit "$e.2" "$e.3" path:./private-0700 2=0755 >/dev/null || : > "$e.3"
    manifest_edit "$e.3" "$e.4" path:./special/fifo 2=0755 >/dev/null || : > "$e.4"
    manifest_edit "$e.4" "$e.5" path:./special/sock 2=0755 >/dev/null || : > "$e.5"
    expect_text "MODE still counts for ROOT, a file, a directory, a FIFO and a socket; the symlink modes add nothing" "$MA" "$e.5" 1 \
        "$(differ_out 5 "$N" 'changed mode .' 'changed mode ./plain.txt' 'changed mode ./private-0700' \
            'changed mode ./special/fifo' 'changed mode ./special/sock')"
}
symlink_mode_text_cases

# On real trees: the symlink fields that are still compared, through
# generate and compare (and the type change that makes MODE count again).
symlink_tree_cases() {
    local b
    b="$(fx_copy l-absolute)" || { test_fail "l-absolute: fixture copy"; return 0; }
    ln -sfn /dxe-fixture-absolute/other-target "$b/links/absolute"
    restore_mtime "$b" links/absolute links
    expect_compare "an absolute symlink pointed elsewhere" "$b" 1 \
        "$(differ_out 1 "$N" 'changed target ./links/absolute')"

    b="$(fx_copy l-dangling)" || { test_fail "l-dangling: fixture copy"; return 0; }
    ln -sfn no-such-target-2 "$b/links/dangling"
    restore_mtime "$b" links/dangling links
    expect_compare "a dangling symlink pointed at another missing name" "$b" 1 \
        "$(differ_out 1 "$N" 'changed target ./links/dangling')"

    b="$(fx_copy l-to-dir)" || { test_fail "l-to-dir: fixture copy"; return 0; }
    ln -sfn ../nested/a "$b/links/to-dir"
    restore_mtime "$b" links/to-dir links
    expect_compare "a symlink to a directory pointed at another directory" "$b" 1 \
        "$(differ_out 1 "$N" 'changed target ./links/to-dir')"

    b="$(fx_copy l-mtime)" || { test_fail "l-mtime: fixture copy"; return 0; }
    touch -h -m -d @1700000023.023000024 -- "$b/links/to-dir"
    expect_compare "a symlink's own mtime off by one nanosecond" "$b" 1 \
        "$(differ_out 1 "$N" 'changed mtime ./links/to-dir')"

    b="$(fx_copy l-type)" || { test_fail "l-type: fixture copy"; return 0; }
    rm -f -- "$b/links/to-dir"
    printf 'now a file\n' > "$b/links/to-dir"
    chmod 0644 "$b/links/to-dir"
    restore_mtime "$b" links/to-dir links
    expect_compare "a symlink replaced by a regular file: MODE counts when only one side is a symlink" "$b" 1 \
        "$(differ_out 1 "$N" 'changed type,mode,size,sha256,target ./links/to-dir')"
}
symlink_tree_cases

symlink_owner_cases() {
    local b
    if [ "$IS_ROOT" != yes ]; then
        test_skip "symlink owner changes need root to chown -h (the Linux coverage container runs as root)"
        return 0
    fi
    b="$(fx_copy l-owner-uid)" || { test_fail "l-owner-uid: fixture copy"; return 0; }
    chown -h 30033 "$b/links/absolute"
    expect_compare "a symlink's own owner (uid, lstat) still counts" "$b" 1 \
        "$(differ_out 1 "$N" 'changed owner ./links/absolute')"
    b="$(fx_copy l-owner-gid)" || { test_fail "l-owner-gid: fixture copy"; return 0; }
    chown -h :30033 "$b/links/dangling"
    expect_compare "a symlink's own group (gid, lstat) still counts" "$b" 1 \
        "$(differ_out 1 "$N" 'changed owner ./links/dangling')"
}
symlink_owner_cases

# ---------------------------------------------------------------------------
test_section "persist manifest: awkward names"

odd_name_cases() {
    local b
    b="$(fx_copy odd-names)" || { test_fail "odd-names: fixture copy"; return 0; }
    chmod 0600 "$b/names/-dash.txt" "$b/$NAME_BS" "$b/$NAME_NL" "$b/$NAME_TAB" "$b/$NAME_TTAB"
    # names/z-link shares the newline name's inode, so its mode changes too.
    expect_compare "newline, TAB, trailing TAB, backslash and leading-dash names: one escaped line each, raw-path order" "$b" 1 \
        "$(differ_out 6 "$N" \
            'changed mode ./names/-dash.txt' \
            'changed mode ./names/back\\slash.txt' \
            'changed mode ./names/line\nbreak.txt' \
            'changed mode ./names/tab\tinside.txt' \
            'changed mode ./names/trailing-tab\t' \
            'changed mode ./names/z-link')"
}
odd_name_cases

# ---------------------------------------------------------------------------
test_section "persist manifest: exclusions"

exclusion_cases() {
    local b
    b="$(fx_copy excluded)" || { test_fail "excluded: fixture copy"; return 0; }
    rm -f -- "$b/._root-meta" "$b/nested/a/._deep-meta" "$b/._plain-link" "$b/nested/._meta-dir/child" "$b/.dxe-persist-dir"
    rmdir -- "$b/nested/._meta-dir"
    printf 'finder\n' > "$b/links/._new-meta"
    mkdir "$b/special/._meta-dir2"
    printf 'child\n' > "$b/special/._meta-dir2/child"
    ln "$b/links/b-one" "$b/links/._b-link"
    restore_mtime "$b" nested nested/a links special
    expect_compare "._* entries (files, directories with children, an extra hard link) and the top-level marker are ignored on both sides" "$b" 0 \
        "Manifests match: entries=$N"

    b="$(fx_copy marker-rewrite)" || { test_fail "marker-rewrite: fixture copy"; return 0; }
    printf 'schema=1\nguest=dxe-other\nstate=copying\n' > "$b/.dxe-persist-dir.tmp"
    mv -f -- "$b/.dxe-persist-dir.tmp" "$b/.dxe-persist-dir"
    touch -h -m -d @1500000000.5 -- "$b"
    expect_compare "a rewritten marker (and the ROOT mtime it moves) is not a difference" "$b" 0 \
        "Manifests match: entries=$N"
}
exclusion_cases

# ---------------------------------------------------------------------------
test_section "persist manifest: output size and the verify / inline forms"

truncation_cases() {
    local b i out rc text
    b="$(fx_copy bulk)" || { test_fail "bulk: fixture copy"; return 0; }
    mkdir "$b/bulk"
    for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
        : > "$b/bulk/f$i"
    done
    expect_compare "25 differences: the summary counts all, then only the first 20 lines" "$b" 1 \
        "$(differ_out 25 "$((N + 25))" 'extra ./bulk' \
            'extra ./bulk/f01' 'extra ./bulk/f02' 'extra ./bulk/f03' 'extra ./bulk/f04' 'extra ./bulk/f05' \
            'extra ./bulk/f06' 'extra ./bulk/f07' 'extra ./bulk/f08' 'extra ./bulk/f09' 'extra ./bulk/f10' \
            'extra ./bulk/f11' 'extra ./bulk/f12' 'extra ./bulk/f13' 'extra ./bulk/f14' 'extra ./bulk/f15' \
            'extra ./bulk/f16' 'extra ./bulk/f17' 'extra ./bulk/f18' 'extra ./bulk/f19')"
    out="$(bash "$TOOL" verify "$SRC" "$b" 2>/dev/null)"
    rc=$?
    assert_eq "verify ROOT_A ROOT_B prints and returns what compare does" \
        "1:$(bash "$TOOL" compare "$MA" "$MAN/dxe-b-bulk.manifest" 2>/dev/null)" "$rc:$out"

    text="$(cat "$TOOL" 2>/dev/null)"
    out="$(bash -c "$text" dx-persist-manifest verify "$SRC" "$FIXROOT/dxe-b-content" 2>/dev/null)"
    rc=$?
    assert_eq "inline form (bash -c TEXT dx-persist-manifest verify ...) reports the difference" \
        "1:$(differ_out 1 "$N" 'changed sha256 ./plain.txt')" "$rc:$out"
    bash -c "$text" dx-persist-manifest generate "$SRC" > "$MAN/inline.manifest" 2>/dev/null
    if manifest_read ok "$MA" && cmp -s "$MA" "$MAN/inline.manifest"; then
        test_pass "inline form generate yields the same bytes as the file form"
    else
        test_fail "inline form generate yields the same bytes as the file form"
    fi
}
truncation_cases

# ---------------------------------------------------------------------------
test_section "persist manifest: errors fail closed"

error_cases() {
    local out err rc missing="$FIXROOT/dxe-no-such-root" f="$MAN/garbage.manifest" e="$MAN/empty.manifest"
    err="$MAN/err.txt"

    tool "$MAN/out.txt" "$err" generate "$missing"
    rc=$?
    assert_eq "generate of a missing ROOT exits 2 with nothing on stdout" "2:" "$rc:$(cat "$MAN/out.txt")"
    assert_contains "generate of a missing ROOT prints an Error: line" "Error:" "$(cat "$err")"
    tool "$MAN/out.txt" "$err" generate "$SRC/plain.txt"
    rc=$?
    assert_eq "generate of a regular file exits 2 with nothing on stdout" "2:" "$rc:$(cat "$MAN/out.txt")"
    assert_contains "generate of a regular file prints an Error: line" "Error:" "$(cat "$err")"

    tool "$MAN/out.txt" "$err" compare "$MA" "$MAN/no-such.manifest"
    rc=$?
    assert_eq "compare with a missing manifest exits 2 with nothing on stdout" "2:" "$rc:$(cat "$MAN/out.txt")"
    assert_contains "compare with a missing manifest prints an Error: line" "Error:" "$(cat "$err")"
    : > "$e"
    tool "$MAN/out.txt" "$err" compare "$e" "$e"
    rc=$?
    assert_eq "two empty manifests are malformed, not a match (exit 2, nothing on stdout)" "2:" "$rc:$(cat "$MAN/out.txt")"
    printf 'garbage\0' > "$f"
    tool "$MAN/out.txt" "$err" compare "$MA" "$f"
    rc=$?
    assert_eq "a record with too few fields is malformed (exit 2, nothing on stdout)" "2:" "$rc:$(cat "$MAN/out.txt")"
    assert_contains "a malformed manifest prints an Error: line" "Error:" "$(cat "$err")"

    tool "$MAN/out.txt" "$err" verify "$SRC" "$missing"
    rc=$?
    assert_eq "verify against a missing destination exits 2 with nothing on stdout" "2:" "$rc:$(cat "$MAN/out.txt")"
    tool "$MAN/out.txt" "$err" verify "$missing" "$missing"
    rc=$?
    assert_eq "verify of two missing roots is an error, never a match (exit 2, nothing on stdout)" "2:" "$rc:$(cat "$MAN/out.txt")"
    assert_contains "verify of a missing root prints an Error: line" "Error:" "$(cat "$err")"
}
error_cases

usage_cases() {
    local rc
    tool "$MAN/out.txt" "$MAN/err.txt"
    rc=$?
    assert_eq "no arguments: exit 2, nothing on stdout" "2:" "$rc:$(cat "$MAN/out.txt")"
    assert_contains "no arguments: Usage: on stderr" "Usage:" "$(cat "$MAN/err.txt")"
    tool "$MAN/out.txt" "$MAN/err.txt" frobnicate "$SRC"
    rc=$?
    assert_eq "unknown subcommand: exit 2, nothing on stdout" "2:" "$rc:$(cat "$MAN/out.txt")"
    assert_contains "unknown subcommand: Usage: on stderr" "Usage:" "$(cat "$MAN/err.txt")"
    tool "$MAN/out.txt" "$MAN/err.txt" generate
    assert_eq "generate without ROOT is a usage error" "2" "$?"
    tool "$MAN/out.txt" "$MAN/err.txt" generate "$SRC" "$SRC"
    assert_eq "generate with two roots is a usage error" "2:" "$?:$(cat "$MAN/out.txt")"
    tool "$MAN/out.txt" "$MAN/err.txt" compare "$MA"
    assert_eq "compare with one manifest is a usage error" "2" "$?"
    tool "$MAN/out.txt" "$MAN/err.txt" verify "$SRC" "$SRC" "$SRC"
    assert_eq "verify with three roots is a usage error" "2:" "$?:$(cat "$MAN/out.txt")"
}
usage_cases

# A file that cannot be read must stop the manifest, never become an empty or
# guessed checksum that two sides could share. Root ignores mode bits, so as
# root the tool runs as uid 65534 through setpriv (the
# tests/test_persist_backup_select.sh pattern).
unreadable_cases() {
    local u="$FIXROOT/dxe-unreadable" rc out vrc errlines
    mkdir "$u"
    printf 'ok\n' > "$u/ok.txt"
    printf 'locked\n' > "$u/locked.txt"
    chmod 0755 "$u"
    chmod 0644 "$u/ok.txt"
    chmod 0000 "$u/locked.txt"
    if [ "$IS_ROOT" = yes ]; then
        if ! command -v setpriv >/dev/null 2>&1; then
            test_skip "an unreadable file makes generate exit 2 (running as root without setpriv: mode bits do not deny root)"
            test_skip "an unreadable file makes verify exit 2 (running as root without setpriv)"
            return 0
        fi
        chmod 0755 "$FIXROOT"
        setpriv --reuid=65534 --regid=65534 --clear-groups env HOME=/tmp bash "$TOOL" generate "$u" > "$MAN/unread.out" 2> "$MAN/unread.err"
        rc=$?
        out="$(setpriv --reuid=65534 --regid=65534 --clear-groups env HOME=/tmp bash "$TOOL" verify "$u" "$u" 2>/dev/null)"
        vrc=$?
    else
        bash "$TOOL" generate "$u" > "$MAN/unread.out" 2> "$MAN/unread.err"
        rc=$?
        out="$(bash "$TOOL" verify "$u" "$u" 2>/dev/null)"
        vrc=$?
    fi
    assert_eq "an unreadable file makes generate exit 2" "2" "$rc"
    errlines="$(grep '^Error:' "$MAN/unread.err")"
    if grep -Fq 'locked.txt' <<<"$errlines"; then
        test_pass "the unreadable file is named on an Error: line"
    else
        test_fail "the unreadable file is named on an Error: line (stderr: $(show "$(cat "$MAN/unread.err")"))"
    fi
    assert_eq "verify of a tree with an unreadable file is exit 2 with nothing on stdout, never a match" "2:" "$vrc:$out"
    chmod 0644 "$u/locked.txt"
}
unreadable_cases

print_summary
exit_with_code
