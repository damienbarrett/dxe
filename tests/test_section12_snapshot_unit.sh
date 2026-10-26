#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
# WP-TESTS-A (A2): the repository snapshot that tests/test_section12_validate_linux.sh
# ships into the guest is built from an archive FILE, never a `writer | tar -x`
# pipe. On the 2026-10-16 live run `git archive HEAD | tar -x` died with rc 141:
# macOS bsdtar closed early, the writer got EPIPE, pipefail reported it.
# These cases drive tests/lib/section12-snapshot.sh against a tiny fixture repo
# with a recording `tar` on PATH that refuses any stdin/stdout stream form.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/fake-tools.sh
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=lib/section12-snapshot.sh
source "$SCRIPT_DIR/lib/section12-snapshot.sh"
test_section "Section 12 snapshot: archive through a file, no tar pipe"

fixture="" # assigned by dxe_test_mktemp_dir; declared for ShellCheck (SC2154)
dxe_test_mktemp_dir fixture "${TMPDIR:-/tmp}/dxe-s12-snap.XXXXXX"
trap 'rm -rf "$fixture"' EXIT

real_tar="$(command -v tar)"
tools="$(fake_tool_dir_create "$fixture")" || exit 1
cat > "$fixture/fake-tar.body" <<'FAKE'
printf '%s\n' "$*" >> "$FAKE_TAR_LOG"
# Refuse the stream forms: -f - / a bare - / no -f at all (stdin or stdout).
prev=""
has_f=0
for a in "$@"; do
    case "$a" in
        -) echo "fake tar: refusing a stdin/stdout stream ($*)" >&2; exit 97 ;;
        -*f | --file=* | -f*) has_f=1 ;;
    esac
    [ "$prev" = -f ] && has_f=1
    prev="$a"
done
[ "$has_f" = 1 ] || { echo "fake tar: refusing a form without -f ($*)" >&2; exit 97; }
exec "$FAKE_TAR_REAL" "$@"
FAKE
fake_tool_write "$tools" tar "$(cat "$fixture/fake-tar.body")"
export FAKE_TAR_LOG="$fixture/tar.argv" FAKE_TAR_REAL="$real_tar"

mkdir -p "$fixture/repo/bin" "$fixture/repo/tests"
printf 'one\n' > "$fixture/repo/README"
printf 'two\n' > "$fixture/repo/bin/tool"
printf 'three\n' > "$fixture/repo/tests/t.sh"
printf 'untracked\n' > "$fixture/repo/untracked-file"
git -C "$fixture/repo" init -q
git -C "$fixture/repo" add README bin/tool tests/t.sh
git -C "$fixture/repo" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
expected="$(git -C "$fixture/repo" ls-files | LC_ALL=C sort)"

listing() { (cd "$1" && find . -type f | sed 's|^\./||' | LC_ALL=C sort); }

# --- git checkout: files = git ls-files, committed content only -------------
mkdir -p "$fixture/snap1" "$fixture/work1"
: > "$fixture/tar.argv"
rc=0
PATH="$tools:$PATH" section12_snapshot_build "$fixture/repo" "$fixture/snap1" "$fixture/work1" 2> "$fixture/err1" || rc=$?
if [ "$rc" = 0 ] && [ "$(listing "$fixture/snap1")" = "$expected" ] && [ "$(cat "$fixture/snap1/bin/tool")" = two ]; then
    test_pass "git checkout: the snapshot holds exactly the tracked files with their content"
else
    test_fail "git checkout: rc=$rc, snapshot=[$(listing "$fixture/snap1" | tr '\n' ' ')] expected=[$(printf '%s' "$expected" | tr '\n' ' ')] err=[$(cat "$fixture/err1")]"
fi
if [ -z "$(listing "$fixture/work1")" ] && [ ! -e "$fixture/snap1/section12-snapshot.tar" ]; then
    test_pass "git checkout: the archive file is removed afterwards and never lands in the snapshot"
else
    test_fail "git checkout: leftover archive: work=[$(listing "$fixture/work1")]"
fi
if grep -Fq -- '-xf ' "$fixture/tar.argv" && ! grep -Fq -- ' -x -C' "$fixture/tar.argv" && [ "$(wc -l < "$fixture/tar.argv" | tr -d ' ')" = 1 ]; then
    test_pass "git checkout: tar runs once, extracting from a file (-xf FILE -C DIR)"
else
    test_fail "git checkout: tar argv was [$(tr '\n' '|' < "$fixture/tar.argv")]"
fi

# --- plain export: no .git, AppleDouble sidecars excluded --------------------
mkdir -p "$fixture/plain/sub" "$fixture/plain/.git" "$fixture/snap2" "$fixture/work2"
printf 'a\n' > "$fixture/plain/a"
printf 'b\n' > "$fixture/plain/sub/b"
printf 'x\n' > "$fixture/plain/._a"
printf 'x\n' > "$fixture/plain/.git/config"
: > "$fixture/tar.argv"
rc=0
PATH="$tools:$PATH" section12_snapshot_build "$fixture/plain" "$fixture/snap2" "$fixture/work2" 2> "$fixture/err2" || rc=$?
if [ "$rc" = 0 ] && [ "$(listing "$fixture/snap2")" = "$(printf 'a\nsub/b')" ]; then
    test_pass "plain export: files copied, .git and ._* excluded"
else
    test_fail "plain export: rc=$rc snapshot=[$(listing "$fixture/snap2" | tr '\n' ' ')] err=[$(cat "$fixture/err2")]"
fi
if [ -z "$(listing "$fixture/work2")" ] && ! grep -Eq -- '-cf -|-xf -|-x -C| -f -' "$fixture/tar.argv" && [ "$(wc -l < "$fixture/tar.argv" | tr -d ' ')" = 2 ]; then
    test_pass "plain export: two tar runs, both through a file, archive removed"
else
    test_fail "plain export: tar argv was [$(tr '\n' '|' < "$fixture/tar.argv")]"
fi

# --- an early-closing extractor no longer matters; a failing one is reported --
fake_tool_write "$tools" tar 'echo "fake tar: extract failed" >&2; exit 5'
mkdir -p "$fixture/snap3" "$fixture/work3"
rc=0
PATH="$tools:$PATH" section12_snapshot_build "$fixture/repo" "$fixture/snap3" "$fixture/work3" 2> /dev/null || rc=$?
if [ "$rc" != 0 ]; then
    test_pass "a failing tar extraction makes the build fail (rc $rc)"
else
    test_fail "a failing tar extraction was swallowed"
fi

print_summary
exit_with_code
