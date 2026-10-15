#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
set -uo pipefail

# WP6.1 implementer's unit cases for
# container/dx-nixos-26.05/scripts/lib/dx-persist-manifest.sh, next to the
# locked acceptance suite tests/test_persist_manifest.sh. These source the
# tool and call its functions in-process (so kcov sees every line, including
# the failure arms), and pin what the acceptance suite leaves open: batch
# boundaries in the record readers, locale and working-directory
# independence, the caller's shell state, temporary-file cleanup, compare's
# ordering checks, and the failure of each external tool. Tool failures are
# injected with non-destructive stand-ins for find, sha256sum and sort put
# first on PATH for one call; the real unreadable-file boundary is the
# acceptance suite's setpriv case.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
TOOL="$CONTAINER_DIR/scripts/lib/dx-persist-manifest.sh"

test_section "persist manifest (unit): toolchain"

# Same gate as the acceptance suite: Bash 5 plus GNU findutils/coreutils.
manifest_unit_toolchain_ok() {
    local v
    v="$(bash --version 2>/dev/null)" || return 1
    case "$v" in
        *"version "[5-9].*) : ;;
        *) return 1 ;;
    esac
    [ "${BASH_VERSINFO[0]}" -ge 5 ] || return 1
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

if ! manifest_unit_toolchain_ok; then
    test_skip "the manifest tool needs the guest toolchain (Bash 5, GNU findutils and coreutils); covered by run-coverage-linux.sh and CI's Linux job"
    print_summary
    exit_with_code
fi

# shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-persist-manifest.sh
source "$TOOL"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"

FIXROOT="$(persist_fixture_root_create)" || {
    test_fail "a private fixture root could be created"
    print_summary
    exit 1
}
case "$FIXROOT" in
    /*/dxe-persist-share.*) test_pass "a private fixture root exists" ;;
    *)
        test_fail "a private fixture root could be created (got [$FIXROOT])"
        print_summary
        exit_with_code
        ;;
esac
trap 'persist_fixture_cleanup "$FIXROOT"' EXIT

T=$'\t'
NL=$'\n'
REAL_SHA256SUM="$(command -v sha256sum)"
WORK="$FIXROOT/dxe-work"
STUBS="$FIXROOT/dxe-stubs"
mkdir "$WORK" "$STUBS"

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

assert_same_file() { # assert_same_file DESC A B
    if [ -s "$2" ] && cmp -s "$2" "$3"; then
        test_pass "$1"
    else
        test_fail "$1 ([$2] and [$3] differ or are empty)"
    fi
}

show() {
    perl -e 'my $s = $ARGV[0]; $s =~ s/\\/\\\\/g; $s =~ s/\t/\\t/g; $s =~ s/\n/\\n/g; $s =~ s/\0/\\0/g; print $s' "$1"
}

# paths_of MANIFEST: the PATH of each record, one per line, escaped.
paths_of() {
    perl -e 'local $/ = "\0"; while (my $r = <STDIN>) { chomp $r; my @f = split(/\t/, $r, 9); my $p = $f[8]; $p =~ s/\\/\\\\/g; $p =~ s/\t/\\t/g; $p =~ s/\n/\\n/g; print "$p\n" }' < "$1"
}

# field_of MANIFEST PATH N: field N (1-9) of PATH's record.
field_of() {
    perl -e 'my ($file, $path, $n) = @ARGV; open(my $fh, "<", $file) or exit 2; local $/ = "\0"; while (my $r = <$fh>) { chomp $r; my @f = split(/\t/, $r, 9); if ($f[8] eq $path) { print $f[$n - 1]; exit 0 } } print "<no record>"; exit 1' "$1" "$2" "$3"
}

# rec FIELD...: one record (TAB-joined, no terminator).
rec() {
    local IFS="$T"
    printf '%s' "$*"
}

# manifest FILE RECORD...: writes RECORDs, each NUL-terminated, to FILE.
manifest() {
    local file="$1"
    shift
    printf '%s\0' "$@" > "$file"
}

# --- a small tree with the shapes the record loop branches on ---------------
TREE="$WORK/tree"
mkdir -p "$TREE/m" "$TREE/z" "$TREE/._meta" "$TREE/.dxe-persist-dir/inner" "$TREE/deep"
printf 'one\n' > "$TREE/z/c"
ln "$TREE/z/c" "$TREE/m/b"
ln "$TREE/z/c" "$TREE/a"
printf 'pair\n' > "$TREE/deep/x"
ln "$TREE/deep/x" "$TREE/._meta/x-link"
printf 'marker child\n' > "$TREE/.dxe-persist-dir/inner/file"
printf 'nested marker\n' > "$TREE/deep/.dxe-persist-dir"
printf 'high\n' > "$TREE/$(printf 'caf\303\251')"
printf 'invalid\n' > "$TREE/$(printf 'bad\377byte')"
printf 'plain\n' > "$TREE/zz"
ln -s "a${T}b\\c${NL}d" "$TREE/odd-link"
mkfifo "$TREE/pipe"

# ---------------------------------------------------------------------------
test_section "persist manifest (unit): escaping"

escape_cases() {
    dx_manifest_escape "a\\b${T}c${NL}d"
    assert_eq "backslash, TAB and newline are escaped" 'a\\b\tc\nd' "$DX_MANIFEST_ESCAPED"
    dx_manifest_escape 'x&y \t'
    assert_eq "& and an already-escaped-looking text stay literal (only the backslash doubles)" 'x&y \\t' "$DX_MANIFEST_ESCAPED"
    dx_manifest_escape ''
    assert_eq "the empty string escapes to itself" '' "$DX_MANIFEST_ESCAPED"
}
escape_cases

# ---------------------------------------------------------------------------
test_section "persist manifest (unit): generate in-process"

generate_cases() {
    local m="$WORK/tree.manifest" rc state_before state_after
    state_before="$-|$PWD|$(trap -p)|${LC_ALL-unset}|$IFS"
    dx_manifest_generate "$TREE" > "$m" 2> "$WORK/tree.err"
    rc=$?
    state_after="$-|$PWD|$(trap -p)|${LC_ALL-unset}|$IFS"
    assert_eq "generate exits 0" "0" "$rc"
    assert_eq "generate writes nothing to stderr" "" "$(cat "$WORK/tree.err")"
    assert_eq "the caller's options, cwd, traps, LC_ALL and IFS are untouched" "$state_before" "$state_after"
    assert_eq "records in bytewise order; ._* subtree and the top-level marker directory with its children left out" \
        "$(printf '.|./a|./bad\377byte|./caf\303\251|./deep|./deep/.dxe-persist-dir|./deep/x|./m|./m/b|./odd-link|./pipe|./z|./z/c|./zz')" \
        "$(paths_of "$m" | paste -sd '|' -)"
    assert_eq "a three-link group is named by its bytewise-first path wherever the walk met it first" \
        "./a|./a|./a" "$(field_of "$m" ./a 7)|$(field_of "$m" ./m/b 7)|$(field_of "$m" ./z/c 7)"
    assert_eq "a file whose only other link is inside an excluded ._* directory has no group" "-" "$(field_of "$m" ./deep/x 7)"
    assert_eq "a symlink target is escaped" 'a\tb\\c\nd' "$(field_of "$m" ./odd-link 8)"
    assert_eq "a symlink records MODE - whatever lstat says" "-" "$(field_of "$m" ./odd-link 2)"
    assert_eq "a FIFO is never opened: no size, no checksum" "p|-|-" "$(field_of "$m" ./pipe 1)|$(field_of "$m" ./pipe 4)|$(field_of "$m" ./pipe 6)"
    assert_eq "a regular file gets its SHA-256" "$("$REAL_SHA256SUM" < "$TREE/zz" | cut -c1-64)" "$(field_of "$m" ./zz 6)"
    if grep -Eq '^[0-9]+\.[0-9]{9}$' <<<"$(field_of "$m" ./zz 5)"; then
        test_pass "MTIME has exactly nine fraction digits"
    else
        test_fail "MTIME has exactly nine fraction digits (got [$(field_of "$m" ./zz 5)])"
    fi
}
generate_cases

batch_cases() {
    local m="$WORK/tree.manifest" b
    for b in 1 2 3; do
        DX_MANIFEST_BATCH=$b dx_manifest_generate "$TREE" > "$WORK/tree.batch$b" 2>/dev/null
        assert_same_file "generate with a batch of $b record(s) gives the same bytes" "$m" "$WORK/tree.batch$b"
    done
}
batch_cases

locale_and_root_form_cases() {
    local m="$WORK/tree.manifest" out="$WORK/tree.locale"
    LC_ALL=C.UTF-8 dx_manifest_generate "$TREE" > "$out" 2>/dev/null
    assert_same_file "a UTF-8 LC_ALL in the caller changes nothing" "$m" "$out"
    LC_ALL='' LANG=C.UTF-8 LC_COLLATE=C.UTF-8 dx_manifest_generate "$TREE" > "$out" 2>/dev/null
    assert_same_file "a UTF-8 LANG/LC_COLLATE in the caller changes nothing" "$m" "$out"
    mkdir "$WORK/-dash-root"
    cp -a "$TREE/." "$WORK/-dash-root/"
    (cd "$WORK" && dx_manifest_generate -dash-root) > "$WORK/dash.manifest" 2>/dev/null
    if (cd "$WORK" && dx_manifest_verify tree -dash-root) > "$WORK/dash.verify" 2>&1; then
        test_pass "relative ROOTs, one starting with a dash, verify equal to each other"
    else
        test_fail "relative ROOTs, one starting with a dash, verify equal to each other ($(cat "$WORK/dash.verify"))"
    fi
    assert_same_file "a relative ROOT starting with a dash is entered as ./ROOT" "$m" "$WORK/dash.manifest"
    mkdir -p "$FIXROOT/dxe-cdpath/tree"
    printf 'decoy\n' > "$FIXROOT/dxe-cdpath/tree/decoy"
    (cd "$WORK" && CDPATH="$FIXROOT/dxe-cdpath" dx_manifest_generate tree) > "$out" 2>/dev/null
    assert_same_file "CDPATH never redirects a relative ROOT" "$m" "$out"
}
locale_and_root_form_cases

tempdir_cases() {
    local tmp="$WORK/tmp-area" rc
    mkdir "$tmp"
    TMPDIR="$tmp" dx_manifest_generate "$TREE" > /dev/null 2>&1
    TMPDIR="$tmp" dx_manifest_verify "$TREE" "$TREE" > /dev/null 2>&1
    TMPDIR="$tmp" dx_manifest_generate "$WORK/no-such-root" > /dev/null 2>&1
    TMPDIR="$tmp" dx_manifest_verify "$TREE" "$WORK/no-such-root" > /dev/null 2>&1
    assert_eq "generate and verify, failing or not, leave nothing in TMPDIR" "" "$(ls -A "$tmp")"
    mkdir "$WORK/rel-parent" "$WORK/rel-parent/rel-tmp"
    (cd "$WORK/rel-parent" && TMPDIR=rel-tmp dx_manifest_generate "$TREE") > "$WORK/rel.manifest" 2>/dev/null
    rc=$?
    assert_eq "a relative TMPDIR still works once generate has entered ROOT" "0" "$rc"
    assert_same_file "a relative TMPDIR gives the same manifest" "$WORK/tree.manifest" "$WORK/rel.manifest"
    assert_eq "and is left empty" "" "$(ls -A "$WORK/rel-parent/rel-tmp")"
    mkdir -p "$WORK/self-root/tmp"
    ln -s "$WORK/self-root/tmp" "$WORK/tmp-alias"
    TMPDIR="$WORK/tmp-alias" dx_manifest_generate "$WORK/self-root" > "$WORK/self.out" 2> "$WORK/self.err"
    rc=$?
    assert_eq "a TMPDIR inside ROOT (even through a symlink) is refused: exit 2, nothing on stdout" "2:" "$rc:$(cat "$WORK/self.out")"
    assert_contains "and says why" "is inside ROOT [$WORK/self-root]; point TMPDIR outside it" "$(cat "$WORK/self.err")"
    assert_eq "and leaves nothing behind there" "" "$(ls -A "$WORK/self-root/tmp")"
    TMPDIR="$WORK/no-such-tmp" dx_manifest_generate "$TREE" > "$WORK/notmp.out" 2> "$WORK/notmp.err"
    rc=$?
    assert_eq "generate without a usable TMPDIR: exit 2, nothing on stdout" "2:" "$rc:$(cat "$WORK/notmp.out")"
    assert_contains "generate without a usable TMPDIR: an Error: line" "Error: cannot create a temporary directory" "$(cat "$WORK/notmp.err")"
    TMPDIR="$WORK/no-such-tmp" dx_manifest_verify "$TREE" "$TREE" > "$WORK/notmp.out" 2> "$WORK/notmp.err"
    rc=$?
    assert_eq "verify without a usable TMPDIR: exit 2, nothing on stdout" "2:" "$rc:$(cat "$WORK/notmp.out")"
    assert_contains "verify without a usable TMPDIR: an Error: line" "Error: cannot create a temporary directory" "$(cat "$WORK/notmp.err")"
}
tempdir_cases

root_error_cases() {
    local rc
    dx_manifest_generate "" > "$WORK/e.out" 2> "$WORK/e.err"
    rc=$?
    assert_eq "an empty ROOT is an error, never the current directory" "2:" "$rc:$(cat "$WORK/e.out")"
    assert_contains "an empty ROOT: an Error: line" "Error: ROOT is not a directory" "$(cat "$WORK/e.err")"
    dx_manifest_verify "$WORK/no-such-a" "$WORK/no-such-b" > "$WORK/e.out" 2> "$WORK/e.err"
    rc=$?
    assert_eq "verify stops at the first ROOT that fails" "2:1" "$rc:$(grep -c '^Error:' "$WORK/e.err")"
    assert_contains "and names it" "no-such-a" "$(cat "$WORK/e.err")"
}
root_error_cases

# A ROOT the caller may not search. Root ignores mode bits, so as root the
# tool runs as uid 65534 through setpriv (the acceptance suite's pattern);
# only root without setpriv falls back to a cd that fails, a stand-in that
# exercises the same arm.
unenterable_root_cases() {
    local locked="$WORK/locked-root" rc how
    mkdir "$locked"
    printf 'x\n' > "$locked/file"
    chmod 0600 "$locked"
    if [ "$(id -u)" -ne 0 ]; then
        how="as this non-root user"
        dx_manifest_generate "$locked" > "$WORK/u.out" 2> "$WORK/u.err"
        rc=$?
    elif command -v setpriv >/dev/null 2>&1; then
        how="as uid 65534 through setpriv"
        chmod 0755 "$FIXROOT"
        setpriv --reuid=65534 --regid=65534 --clear-groups env HOME=/tmp bash "$TOOL" generate "$locked" > "$WORK/u.out" 2> "$WORK/u.err"
        rc=$?
    else
        how="as root without setpriv: a failing cd stands in"
        (cd() { return 1; }; dx_manifest_generate "$locked") > "$WORK/u.out" 2> "$WORK/u.err"
        rc=$?
    fi
    chmod 0755 "$locked"
    assert_eq "a ROOT this user cannot enter ($how): exit 2, nothing on stdout" "2:" "$rc:$(cat "$WORK/u.out")"
    assert_contains "a ROOT this user cannot enter: an Error: line naming it" "Error: ROOT is not a directory this user can enter: [$locked]" "$(cat "$WORK/u.err")"
}
unenterable_root_cases

# ---------------------------------------------------------------------------
test_section "persist manifest (unit): failing tools fail closed"

# write_stub NAME BODY: an executable NAME in $STUBS running BODY (bash).
write_stub() {
    printf '#!/bin/bash\n%s\n' "$2" > "$STUBS/$1"
    chmod 0755 "$STUBS/$1"
}

tool_failure_cases() {
    local rc
    write_stub find "echo \"find: './denied': Permission denied\" >&2; exit 1"
    (PATH="$STUBS:$PATH" dx_manifest_generate "$TREE") > "$WORK/f.out" 2> "$WORK/f.err"
    rc=$?
    rm -f "$STUBS/find"
    assert_eq "a find that fails: exit 2, nothing on stdout" "2:" "$rc:$(cat "$WORK/f.out")"
    assert_contains "find's own message is relayed as an Error: line naming the entry" "Error: find: './denied': Permission denied" "$(cat "$WORK/f.err")"
    assert_contains "and the walk is reported as failed" "Error: cannot walk ROOT" "$(cat "$WORK/f.err")"

    # A sha256sum that skips one file, as the real one does with a file it
    # cannot read (message on stderr, no line, status 1).
    printf 'secret\n' > "$WORK/tree/new${NL}line"
    write_stub sha256sum "args=(); bad=0; for a in \"\$@\"; do case \"\$a\" in *new*line) echo \"sha256sum: \$a: Permission denied\" >&2; bad=1 ;; *) args+=(\"\$a\") ;; esac; done; \"$REAL_SHA256SUM\" \"\${args[@]}\" || exit; exit \$bad"
    (PATH="$STUBS:$PATH" dx_manifest_generate "$TREE") > "$WORK/s.out" 2> "$WORK/s.err"
    rc=$?
    assert_eq "a file sha256sum skips: exit 2, nothing on stdout" "2:" "$rc:$(cat "$WORK/s.out")"
    assert_contains "the skipped file is named, escaped, on an Error: line" 'Error: cannot read ./new\nline: no checksum' "$(cat "$WORK/s.err")"
    assert_contains "sha256sum's own message is relayed" "Error: sha256sum: ./new" "$(cat "$WORK/s.err")"

    # A sha256sum that exits 0 but prints 64 characters that are not hex.
    write_stub sha256sum "for a in \"\$@\"; do case \"\$a\" in -z|--) : ;; *) printf '%s  %s\\0' \"$(printf '%064d' 0 | tr 0 g)\" \"\$a\" ;; esac; done"
    (PATH="$STUBS:$PATH" dx_manifest_generate "$TREE") > "$WORK/s.out" 2> "$WORK/s.err"
    rc=$?
    rm -f "$STUBS/sha256sum" "$WORK/tree/new${NL}line"
    assert_eq "checksum output that is not 64 hex digits is never used: exit 2, nothing on stdout" "2:" "$rc:$(cat "$WORK/s.out")"
    assert_contains "and the file is named" "Error: cannot read ./zz: no checksum" "$(cat "$WORK/s.err")"

    write_stub sort "echo 'sort: write failed' >&2; exit 2"
    (PATH="$STUBS:$PATH" dx_manifest_generate "$TREE") > "$WORK/o.out" 2> "$WORK/o.err"
    rc=$?
    rm -f "$STUBS/sort"
    assert_eq "a sort that fails: exit 2" "2" "$rc"
    assert_contains "a sort that fails: an Error: line" "Error: cannot sort the manifest" "$(cat "$WORK/o.err")"
}
tool_failure_cases

# ---------------------------------------------------------------------------
test_section "persist manifest (unit): compare"

R0="$(rec d 0755 0:0 - - - - - .)"
RA="$(rec f 0644 0:0 1 1.000000000 "$(printf '%064d' 0)" - - ./a)"
RB="$(rec f 0644 0:0 1 1.000000000 "$(printf '%064d' 0)" - - ./b)"
RZ="$(rec d 0755 0:0 - 1.000000000 - - - ./z)"
RZT="$(rec d 0755 0:0 - 1.000000000 - - - "./z${T}tab")"
RG="$(rec f 0644 0:0 1 1.000000000 "$(printf '%064d' 0)" - - './g*?[x]')"
RTT="$(rec f 0644 0:0 1 1.000000000 "$(printf '%064d' 0)" - - "./t${T}${T}t${T}")"

compare_out() { # compare_out A B: "STATUS|STDOUT" (stderr to $WORK/c.err)
    local out rc
    out="$(dx_manifest_compare "$1" "$2" 2> "$WORK/c.err")"
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

compare_cases() {
    local a="$WORK/a.m" b="$WORK/b.m" bs
    manifest "$a" "$R0" "$RA" "$RZ"
    manifest "$b" "$R0" "$RA"
    assert_eq "a record after the end of B is missing" "1|Manifests differ: differences=1 entries-a=3 entries-b=2${NL}missing ./z" "$(compare_out "$a" "$b")"
    manifest "$b" "$R0" "$RA" "$RB" "$RZ" "$RZT"
    assert_eq "records after the end of A are extra, in order" "1|Manifests differ: differences=2 entries-a=3 entries-b=5${NL}extra ./b${NL}extra ./z\\ttab" "$(compare_out "$a" "$b")"
    for bs in 1 2; do
        assert_eq "the same with a reader batch of $bs" "1|Manifests differ: differences=2 entries-a=3 entries-b=5${NL}extra ./b${NL}extra ./z\\ttab" "$(DX_MANIFEST_BATCH=$bs compare_out "$a" "$b")"
    done
    manifest "$b" "$R0" "$(rec l 0644 0:0 - 2.000000000 - - x ./a)" "$RZ"
    assert_eq "every differing field is named, in record order" "1|Manifests differ: differences=1 entries-a=3 entries-b=3${NL}changed type,size,mtime,sha256,target ./a" "$(compare_out "$a" "$b")"
    assert_eq "manifests read from pipes compare too" "0|Manifests match: entries=3" "$(compare_out <(cat "$a") <(cat "$a"))"
    manifest "$a" "$R0" "$RA" "$RG" "$RTT" "$RZ"
    manifest "$b" "$R0" "$RA" "${RG/0644/0600}" "${RTT/0644/0600}" "$RZ"
    : > "$WORK/gzzx"
    assert_eq "glob characters, doubled and trailing TABs in PATH survive the split" "1|Manifests differ: differences=2 entries-a=5 entries-b=5${NL}changed mode ./g*?[x]${NL}changed mode ./t\\t\\tt\\t" "$(cd "$WORK" && compare_out "$a" "$b")"
    # Symlink MODE (WP6.1b): never compared between two symlinks.
    local sl
    sl="$(rec l - 0:0 - 1.000000000 - - x ./a)"
    manifest "$a" "$R0" "$sl" "$RZ"
    manifest "$b" "$R0" "${sl/l${T}-/l${T}0777}" "$RZ"
    assert_eq "symlinks differing only in MODE are no difference" "0|Manifests match: entries=3" "$(compare_out "$a" "$b")"
    manifest "$b" "$R0" "${sl/l${T}-/l${T}0755}" "${RZ/0755/0700}"
    assert_eq "a symlink MODE difference is not counted beside a real one" "1|Manifests differ: differences=1 entries-a=3 entries-b=3${NL}changed mode ./z" "$(compare_out "$a" "$b")"
    manifest "$b" "$R0" "${sl/l${T}-/l${T}0777}" "$RZ"
    manifest "$a" "$R0" "$(rec l - 0:0 - 1.000000000 - - y ./a)" "$RZ"
    assert_eq "a symlink target still differs under a MODE difference" "1|Manifests differ: differences=1 entries-a=3 entries-b=3${NL}changed target ./a" "$(compare_out "$a" "$b")"
    manifest "$a" "$R0" "$sl" "$RZ"
    manifest "$b" "$R0" "$RA" "$RZ"
    assert_eq "a type change to a file still compares MODE" "1|Manifests differ: differences=1 entries-a=3 entries-b=3${NL}changed type,mode,size,sha256,target ./a" "$(compare_out "$a" "$b")"
}
compare_cases

malformed_cases() {
    local a="$WORK/a.m" b="$WORK/bad.m" result
    manifest "$a" "$R0" "$RA" "$RZ"
    manifest "$b" "$RA" "$R0" "$RZ"
    result="$(compare_out "$a" "$b")"
    assert_eq "a manifest whose first record is not ROOT's is malformed" "2|" "$result"
    assert_contains "and says so" "the first record is not the ROOT record" "$(cat "$WORK/c.err")"
    manifest "$b" "$R0" "$RZ" "$RA"
    result="$(compare_out "$a" "$b")"
    assert_eq "records out of bytewise PATH order are malformed (a merge could not trust them)" "2|" "$result"
    assert_contains "and say so" "record 3 is not in bytewise PATH order" "$(cat "$WORK/c.err")"
    manifest "$b" "$R0" "$RA" "$RA" "$RZ"
    assert_eq "a repeated PATH is malformed" "2|" "$(compare_out "$b" "$a")"
    manifest "$b" "$R0" "$RA" "$(rec f 0644 0:0 1 ./b)"
    assert_eq "a short record after valid ones is malformed even when everything before matched" "2|" "$(compare_out "$a" "$b")"
    assert_contains "and names its record number" "record 3 is not nine TAB-separated fields" "$(cat "$WORK/c.err")"
    manifest "$b" "$R0" "$(rec f "" 0:0 1 1.000000000 "$(printf '%064d' 0)" - - ./a)" "$RZ"
    assert_eq "an empty field is malformed, never merged into its neighbour" "2|" "$(compare_out "$a" "$b")"
    assert_contains "and names its record number" "record 2 is not nine TAB-separated fields" "$(cat "$WORK/c.err")"
    mkdir "$WORK/a-directory"
    assert_eq "a directory is not a readable manifest" "2|" "$(compare_out "$WORK/a-directory" "$a")"
    assert_contains "and says so" "Error: cannot read manifest" "$(cat "$WORK/c.err")"
}
malformed_cases

# ---------------------------------------------------------------------------
test_section "persist manifest (unit): entry points"

main_cases() {
    local rc probe="$WORK/probe.sh" text
    dx_manifest_main > "$WORK/m.out" 2> "$WORK/m.err"
    rc=$?
    assert_eq "main without arguments: exit 2, nothing on stdout" "2:" "$rc:$(cat "$WORK/m.out")"
    assert_contains "main without arguments: Usage: on stderr" "Usage: dx-persist-manifest generate ROOT" "$(cat "$WORK/m.err")"
    dx_manifest_main compare "$WORK/a.m" "$WORK/a.m" > "$WORK/m.out" 2>&1
    assert_eq "main dispatches compare" "0:Manifests match: entries=3" "$?:$(cat "$WORK/m.out")"
    dx_manifest_main verify "$TREE" "$TREE" > "$WORK/m.out" 2>&1
    assert_eq "main dispatches verify" "0:Manifests match: entries=14" "$?:$(cat "$WORK/m.out")"
    dx_manifest_main generate "$TREE" > "$WORK/m.out" 2>/dev/null
    assert_same_file "main dispatches generate" "$WORK/tree.manifest" "$WORK/m.out"

    printf '#!/bin/bash\nsource "$1" generate "$2"\necho "sourced:$?"\n' > "$probe"
    assert_eq "sourcing the file (even with arguments) runs nothing" "sourced:0" "$(bash "$probe" "$TOOL" "$TREE" 2>&1)"
    text="$(cat "$TOOL")"
    assert_eq "inline text under another \$0 only defines functions" "0:" "$(bash -c "$text" some-other-name generate "$TREE" 2>&1; printf '%s:' "$?")"
}
main_cases

print_summary
exit_with_code
