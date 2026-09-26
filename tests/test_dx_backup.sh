#!/bin/bash
set -uo pipefail
# Increment 2 (Branch 10, feat/persist-backup): dx-backup capture, driven
# through the fake-container boundary (tests/lib/fake-tools.sh's approach,
# extended here with a `container` fake tailored to this feature -- see
# test_bootstrap_publication.sh for the same "exec passes through for real"
# style this follows). The fake `container exec` remaps a literal `/persist`
# argument to a fixture directory and then runs the REAL command (the real
# guest selector, real tar) against it, so these tests exercise the actual
# production selector and dx-backup/bin/lib/dx-backup.sh code, not a copy.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=../bin/lib/dx-backup.sh
source "$BASE_DIR/bin/lib/dx-backup.sh"
GUEST="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-26.05"
test_section "Persist backup: dx-backup capture (fake-container boundary)"

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-dx-backup-test.XXXXXX")"
trap 'chmod -R u+w "$FIXTURE" 2>/dev/null || true; rm -rf "$FIXTURE"' EXIT

FAKE_DIR="$(fake_tool_dir_create "$FIXTURE")"
mkdir -p "$FIXTURE/persist" "$FIXTURE/bootstrap"
ln -sfn "$GUEST" "$FIXTURE/bootstrap/current"

# `container`: system/list succeed; `exec [-i] [-u USER] NAME CMD...` strips
# the flags and NAME, remaps a bare `/persist` argument to the fixture's
# persist directory, and execs the rest for real.
fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$FIXTURE"'/persist"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container container-a container-b; exit 0 ;;
esac
if [ "${1:-}" = exec ]; then
    shift
    [ "${1:-}" != -i ] || shift
    if [ "${1:-}" = -u ]; then shift; shift; fi
    shift
    args=()
    for a in "$@"; do
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST"); else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'
fake_tool_write "$FAKE_DIR" chown 'exit 0'

export PATH="$FAKE_DIR:$PATH"
export DX_CONTAINER_NAME=test-container
export DX_BOOTSTRAP_PATH="$FIXTURE/bootstrap"
# DX_BACKUP_DIR (a registered bin/lib/dx-config.sh field) names only the BASE
# directory; dx-backup always appends /$DX_CONTAINER_NAME itself. BACKUP_ROOT
# is that actual per-container mirror path, used throughout this file.
export DX_BACKUP_DIR="$FIXTURE/backups"
BACKUP_ROOT="$DX_BACKUP_DIR/$DX_CONTAINER_NAME"
unset DX_BACKUP_EXCLUDE_FILE 2>/dev/null || true

mkdir -p "$FIXTURE/persist/home/dx"
printf 'hello\n' > "$FIXTURE/persist/home/dx/loose.txt"

# --- dry-run on a completely fresh destination writes NOTHING. ---
dry_out="$("$BASE_DIR/bin/dx-backup" --dry-run 2>&1)"
if [ ! -e "$DX_BACKUP_DIR" ] && [ ! -e "$BACKUP_ROOT" ]; then test_pass "dry-run creates no backup directory at all"; else test_fail "dry-run creates no backup directory at all"; fi
if printf '%s\n' "$dry_out" | stdin_matches -F 'home/dx/loose.txt'; then test_pass "dry-run prints the at-risk selection"; else test_fail "dry-run prints the at-risk selection"; fi
if printf '%s\n' "$dry_out" | stdin_matches -F '1 files, 6 bytes would be transferred.'; then test_pass "dry-run prints the would-be transfer counts"; else test_fail "dry-run prints the would-be transfer counts"; fi

# --- First real run: transfers the set, writes manifest.tsv atomically. ---
first_out="$("$BASE_DIR/bin/dx-backup" 2>&1)"
if printf '%s\n' "$first_out" | stdin_matches -F '1 files, 6 bytes transferred.'; then test_pass "first run transfers the full at-risk set"; else test_fail "first run transfers the full at-risk set (got: $first_out)"; fi
assert_file_exists "$BACKUP_ROOT/manifest.tsv" "manifest.tsv exists after the first run"
assert_file_exists "$BACKUP_ROOT/current/home/dx/loose.txt" "the mirrored file exists under current/"
if [ "$(cat "$BACKUP_ROOT/current/home/dx/loose.txt")" = hello ]; then test_pass "the mirrored file has the right content"; else test_fail "the mirrored file has the right content"; fi
assert_file_exists "$BACKUP_ROOT/last-run.log" "last-run.log exists after a real run"

# --- Second run, no guest-side change: transfers zero bytes. ---
second_out="$("$BASE_DIR/bin/dx-backup" 2>&1)"
if printf '%s\n' "$second_out" | stdin_matches -F '0 files, 0 bytes transferred.'; then test_pass "a second run with no guest change transfers zero bytes"; else test_fail "a second run with no guest change transfers zero bytes (got: $second_out)"; fi

# --- A changed file transfers only that file. ---
printf 'hello\nworld\n' > "$FIXTURE/persist/home/dx/loose.txt"
mkdir -p "$FIXTURE/persist/home/dx/other"
printf 'unrelated\n' > "$FIXTURE/persist/home/dx/other/unrelated.txt"
"$BASE_DIR/bin/dx-backup" >/dev/null
changed_out="$("$BASE_DIR/bin/dx-backup" 2>&1)"
if printf '%s\n' "$changed_out" | stdin_matches -F '0 files, 0 bytes transferred.'; then test_pass "settles back to zero transfer after catching up"; else test_fail "settles back to zero transfer after catching up"; fi
if [ "$(cat "$BACKUP_ROOT/current/home/dx/loose.txt")" = "$(printf 'hello\nworld\n')" ]; then test_pass "a changed file's mirrored content is updated"; else test_fail "a changed file's mirrored content is updated"; fi
assert_file_exists "$BACKUP_ROOT/current/home/dx/other/unrelated.txt" "an unrelated new file is captured too"

# --- A file removed from the at-risk set leaves the mirror (mirror
# semantics), and current/ itself survives even when it ends up empty. ---
rm "$FIXTURE/persist/home/dx/other/unrelated.txt"
"$BASE_DIR/bin/dx-backup" >/dev/null
if [ ! -e "$BACKUP_ROOT/current/home/dx/other/unrelated.txt" ] && [ ! -e "$BACKUP_ROOT/current/home/dx/other" ]; then
    test_pass "a file no longer at-risk is removed from the mirror (and its now-empty directory pruned)"
else
    test_fail "a file no longer at-risk is removed from the mirror (and its now-empty directory pruned)"
fi
[ -d "$BACKUP_ROOT/current" ] && test_pass "current/ itself always survives mirror pruning" || test_fail "current/ itself always survives mirror pruning"

# --- Interruption (a failed fetch) leaves the previous manifest intact. ---
manifest_before_interrupt="$(cat "$BACKUP_ROOT/manifest.tsv")"
printf 'brand new content that will never arrive\n' > "$FIXTURE/persist/home/dx/interrupt-me.txt"
fake_tool_write "$FAKE_DIR" container '
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container container-a container-b; exit 0 ;;
esac
if [ "${1:-}" = exec ]; then
    shift
    [ "${1:-}" != -i ] || shift
    if [ "${1:-}" = -u ]; then shift; shift; fi
    shift
    case "$*" in
        *tar*) exit 42 ;;
    esac
    exec "$@"
fi
exit 1
'
set +e
interrupted_out="$("$BASE_DIR/bin/dx-backup" 2>&1)"
interrupted_rc=$?
set -e
[ "$interrupted_rc" -ne 0 ] && test_pass "a failed fetch reports a nonzero exit status" || test_fail "a failed fetch reports a nonzero exit status (got: $interrupted_out)"
if [ "$(cat "$BACKUP_ROOT/manifest.tsv")" = "$manifest_before_interrupt" ]; then test_pass "interruption leaves the previous manifest intact"; else test_fail "interruption leaves the previous manifest intact"; fi
if [ ! -e "$BACKUP_ROOT/current/home/dx/interrupt-me.txt" ]; then test_pass "interruption does not leave a partial file behind"; else test_fail "interruption does not leave a partial file behind"; fi
rm -f "$FIXTURE/persist/home/dx/interrupt-me.txt"

# Restore the well-behaved fake container for the remaining checks.
fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$FIXTURE"'/persist"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container container-a container-b; exit 0 ;;
esac
if [ "${1:-}" = exec ]; then
    shift
    [ "${1:-}" != -i ] || shift
    if [ "${1:-}" = -u ]; then shift; shift; fi
    shift
    args=()
    for a in "$@"; do
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST"); else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'

# --- DX_BACKUP_EXCLUDE_FILE is honoured end to end. Blank lines and '#'
# comments in the exclude file are skipped, not treated as patterns. ---
printf 'drop-me\n' > "$FIXTURE/persist/home/dx/drop-me.tmp"
printf '%s\n' '# a comment line' '' 'home/dx/drop-me.tmp' > "$FIXTURE/excludes.txt"
DX_BACKUP_EXCLUDE_FILE="$FIXTURE/excludes.txt" "$BASE_DIR/bin/dx-backup" >/dev/null
if [ ! -e "$BACKUP_ROOT/current/home/dx/drop-me.tmp" ]; then test_pass "DX_BACKUP_EXCLUDE_FILE is honoured end to end"; else test_fail "DX_BACKUP_EXCLUDE_FILE is honoured end to end"; fi
rm -f "$FIXTURE/persist/home/dx/drop-me.tmp"

# --- CLI hygiene. ---
if "$BASE_DIR/bin/dx-backup" --not-a-real-flag >/dev/null 2>&1; then test_fail "an unrecognized flag is a usage error"; else test_pass "an unrecognized flag is a usage error"; fi
if DX_CONTAINER_NAME=no-such-container "$BASE_DIR/bin/dx-backup" >/dev/null 2>&1; then test_fail "a nonexistent container is a clear error"; else test_pass "a nonexistent container is a clear error"; fi

# --- DX_BACKUP_DIR names only the BASE directory: dx-backup always appends
# /$DX_CONTAINER_NAME itself, even for an explicitly overridden base, so two
# differently-named containers sharing one DX_BACKUP_DIR base never collide.
# (DX_BACKUP_DIR's own default value, $HOME/Backups/dxe-persist, is a plain
# bin/lib/dx-config.sh registry field -- tested directly in
# tests/test_refactor_state_machines.sh, not here.) ---
shared_base="$FIXTURE/shared-base"
DX_CONTAINER_NAME=container-a DX_BACKUP_DIR="$shared_base" "$BASE_DIR/bin/dx-backup" >/dev/null
DX_CONTAINER_NAME=container-b DX_BACKUP_DIR="$shared_base" "$BASE_DIR/bin/dx-backup" >/dev/null
if [ "$(cat "$shared_base/container-a/current/home/dx/loose.txt")" = "$(printf 'hello\nworld\n')" ] && [ "$(cat "$shared_base/container-b/current/home/dx/loose.txt")" = "$(printf 'hello\nworld\n')" ]; then
    test_pass "DX_BACKUP_DIR always gets /\$DX_CONTAINER_NAME appended, even when overridden"
else
    test_fail "DX_BACKUP_DIR always gets /\$DX_CONTAINER_NAME appended, even when overridden"
fi
if [ ! -e "$shared_base/current" ]; then test_pass "two containers sharing one DX_BACKUP_DIR base never share a mirror"; else test_fail "two containers sharing one DX_BACKUP_DIR base never share a mirror"; fi

print_summary
exit_with_code
