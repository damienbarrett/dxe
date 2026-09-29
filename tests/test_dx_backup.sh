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
# dx_runtime_exec (mid-task addition): needed only for this file's own
# direct, in-process call to dx_backup_fetch_paths (the duplicate-path
# regression test below) -- every other test here drives dx-backup as an
# external process, which sources this itself via dx-lib.sh. Safe to
# source here too: dx-runtime.sh's own header says it defines functions
# only, no I/O at import time.
# shellcheck source=../bin/lib/dx-runtime.sh
source "$BASE_DIR/bin/lib/dx-runtime.sh"
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
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST");
        elif [ "$a" = --hard-dereference ]; then :; # a real guest'"'"'s tar is always GNU tar, which supports this; this test host'"'"'s own bsdtar (standing in for it here) does not, so it is stripped before the real local exec -- any ARG log this fake keeps is written before this filtering, so it still records that dx-backup passed it.
        else args+=("$a"); fi
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

# --- WP6.1 (Astra F1): the guest LISTING command itself failing outright
# (not merely a failed archive transfer, already covered above) must also
# abort BEFORE any mirror mutation: dx_backup_fetch_listing must propagate
# the guest's exit status, and bin/dx-backup must never treat a partial/
# failed listing as "the complete at-risk set". A dedicated, isolated
# DX_BACKUP_DIR and persist tree (like missing_exclude_backup_dir above)
# keep this block from disturbing test-container's own shared manifest/
# mirror state. First, one normal successful run seeds the mirror with a
# file (keepme.txt); the SECOND run's guest listing then exits non-zero
# after printing SOME output (a different, unrelated path -- proving the
# omission of keepme.txt from that partial listing is not itself read as
# "no longer at risk"). ---
listing_fail_backup_dir="$FIXTURE/listing-fail-backups"
rm -rf "$listing_fail_backup_dir" "$FIXTURE/listing-fail-persist"
mkdir -p "$FIXTURE/listing-fail-persist/home/dx"
printf 'keep me\n' > "$FIXTURE/listing-fail-persist/home/dx/keepme.txt"
fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$FIXTURE"'/listing-fail-persist"
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
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST");
        elif [ "$a" = --hard-dereference ]; then :;
        else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'
DX_BACKUP_DIR="$listing_fail_backup_dir" "$BASE_DIR/bin/dx-backup" >/dev/null
listing_fail_manifest_before="$(cat "$listing_fail_backup_dir/$DX_CONTAINER_NAME/manifest.tsv")"

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
        *dx-persist-backup-select.sh*)
            printf "home/dx/other-file.txt\t5\t0\tabc123\n"
            exit 1
            ;;
    esac
    exit 0
fi
exit 1
'
set +e
listing_fail_out="$(DX_BACKUP_DIR="$listing_fail_backup_dir" "$BASE_DIR/bin/dx-backup" 2>&1)"
listing_fail_rc=$?
set -e
if [ "$listing_fail_rc" -ne 0 ]; then
    test_pass "WP6.1: a failed guest listing command makes dx-backup exit non-zero"
else
    test_fail "WP6.1: a failed guest listing command makes dx-backup exit non-zero (got: $listing_fail_out)"
fi
if [ -e "$listing_fail_backup_dir/$DX_CONTAINER_NAME/current/home/dx/keepme.txt" ]; then
    test_pass "WP6.1: a mirror entry the partial listing omits survives a failed guest listing"
else
    test_fail "WP6.1: a mirror entry the partial listing omits survives a failed guest listing"
fi
if [ "$(cat "$listing_fail_backup_dir/$DX_CONTAINER_NAME/manifest.tsv")" = "$listing_fail_manifest_before" ]; then
    test_pass "WP6.1: the manifest is not rewritten when the guest listing fails"
else
    test_fail "WP6.1: the manifest is not rewritten when the guest listing fails"
fi
rm -rf "$listing_fail_backup_dir" "$FIXTURE/listing-fail-persist"

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
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST");
        elif [ "$a" = --hard-dereference ]; then :; # a real guest'"'"'s tar is always GNU tar, which supports this; this test host'"'"'s own bsdtar (standing in for it here) does not, so it is stripped before the real local exec -- any ARG log this fake keeps is written before this filtering, so it still records that dx-backup passed it.
        else args+=("$a"); fi
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

# --- An explicit DX_BACKUP_EXCLUDE_FILE naming a NONEXISTENT path (Astra F6
# / Muse B3 / WP3.3 defect C): dx_backup_read_exclude_patterns correctly
# returns failure and prints an Error naming the path, but the original
# code ran it inside `done < <(...)` -- a process substitution whose exit
# status the surrounding `while` loop never inspects. Backup continued with
# an empty extra deny-list, potentially copying data the operator
# explicitly meant to exclude. Must abort BEFORE any guest round trip (no
# point spending a container exec/list/system call on a run that is about
# to fail anyway). A `container` fake that logs every single invocation
# (not just `exec`, like the Branch 17 fakes above -- this must catch
# container_exists/container_is_running's own `list` calls too) proves
# "zero guest calls", not just "the transfer never happened". ---
# A dedicated, fresh DX_BACKUP_DIR (like the shared_base/default-exclude
# blocks elsewhere in this file): this sub-test's `container` fake returns
# an empty listing unconditionally, which would otherwise corrupt
# test-container's own manifest.tsv/current mirror (built up by every test
# above and relied on by tests below) by making dx_backup_diff see
# everything as "no longer at-risk". Isolating it here means this block
# can never affect any other test's state.
missing_exclude_backup_dir="$FIXTURE/missing-exclude-backups"
rm -rf "$missing_exclude_backup_dir"
CALL_LOG="$FIXTURE/call.log"
: > "$CALL_LOG"
fake_tool_write "$FAKE_DIR" container '
printf "%s\n" "$*" >> '"'$CALL_LOG'"'
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container container-a container-b; exit 0 ;;
    exec) exit 0 ;;
esac
exit 1
'
missing_exclude="$FIXTURE/does-not-exist-exclude.txt"
rm -f "$missing_exclude"
set +e
missing_exclude_out="$(DX_BACKUP_DIR="$missing_exclude_backup_dir" DX_BACKUP_EXCLUDE_FILE="$missing_exclude" "$BASE_DIR/bin/dx-backup" 2>&1)"
missing_exclude_rc=$?
set -e
if [ "$missing_exclude_rc" -ne 0 ]; then
    test_pass "an explicit DX_BACKUP_EXCLUDE_FILE naming an absent path is a clear, nonzero error"
else
    test_fail "an explicit DX_BACKUP_EXCLUDE_FILE naming an absent path is a clear, nonzero error (rc=$missing_exclude_rc, out: $missing_exclude_out)"
fi
if printf '%s\n' "$missing_exclude_out" | stdin_matches -F "Error:" && printf '%s\n' "$missing_exclude_out" | stdin_matches -F "$missing_exclude"; then
    test_pass "the error names the missing exclude file's path"
else
    test_fail "the error names the missing exclude file's path (out: $missing_exclude_out)"
fi
if [ -s "$CALL_LOG" ]; then
    test_fail "an absent explicit exclude file aborts before any guest call (container was invoked: $(cat "$CALL_LOG"))"
else
    test_pass "an absent explicit exclude file aborts before any guest call"
fi
rm -f "$CALL_LOG"
rm -rf "$missing_exclude_backup_dir"

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
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST");
        elif [ "$a" = --hard-dereference ]; then :; # a real guest'"'"'s tar is always GNU tar, which supports this; this test host'"'"'s own bsdtar (standing in for it here) does not, so it is stripped before the real local exec -- any ARG log this fake keeps is written before this filtering, so it still records that dx-backup passed it.
        else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'

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

# --- Branch 17 (fix/dx-backup-transfer-stall): the fetch transfer is two
# UNIDIRECTIONAL execs, not one exec whose stdin (a large NUL-separated name
# list) and stdout (the archive) are both live at once -- the shape that
# deadlocked in production on a large selection (see this branch's task
# file). A `container` fake that logs every exec call's flags and full
# argument list proves the SHAPE, not just the outcome. ---
export DX_CONTAINER_NAME=test-container
EXEC_LOG="$FIXTURE/exec.log"
: > "$EXEC_LOG"
fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$FIXTURE"'/persist"
LOG="'"$EXEC_LOG"'"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container container-a container-b; exit 0 ;;
esac
if [ "${1:-}" = exec ]; then
    shift
    has_i=0
    if [ "${1:-}" = -i ]; then has_i=1; shift; fi
    if [ "${1:-}" = -u ]; then shift; shift; fi
    shift
    {
        echo "---EXEC---"
        echo "has_i=$has_i"
        for a in "$@"; do printf "ARG:%s\n" "$a"; done
    } >> "$LOG"
    args=()
    for a in "$@"; do
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST");
        elif [ "$a" = --hard-dereference ]; then :; # a real guest'"'"'s tar is always GNU tar, which supports this; this test host'"'"'s own bsdtar (standing in for it here) does not, so it is stripped before the real local exec -- any ARG log this fake keeps is written before this filtering, so it still records that dx-backup passed it.
        else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'

printf 'two-phase-check\n' > "$FIXTURE/persist/home/dx/two-phase-check.txt"
"$BASE_DIR/bin/dx-backup" >/dev/null

if grep -Fxq 'has_i=1' "$EXEC_LOG" && grep -Fq 'ARG:cat > "$1"' "$EXEC_LOG"; then
    test_pass "the fetch ships the name list into the guest via a stdin-redirected, -i exec (sh -c 'cat > ...')"
else
    test_fail "the fetch ships the name list into the guest via a stdin-redirected, -i exec (sh -c 'cat > ...') (log: $(cat "$EXEC_LOG"))"
fi

# The guest temp file path: the argument right after the ship exec's lone
# standalone "--" (an exact-line match -- a substring match would also catch
# "--exclude"/"--null").
guest_list_path="$(grep -A1 -Fx 'ARG:--' "$EXEC_LOG" | grep -F 'ARG:/tmp/' | head -n1 | sed 's/^ARG://' || true)"
if [ -n "$guest_list_path" ]; then
    test_pass "the guest temp file path is captured from the ship exec"
else
    test_fail "the guest temp file path is captured from the ship exec (log: $(cat "$EXEC_LOG"))"
fi

# The archive exec: no -i, and it reads the list from the guest temp FILE
# (-T <path>), never from stdin (-T -). ("ARG:tar" is the archive exec's
# first argument -- unique in this log, so the 2 lines before it are that
# same call's own "---EXEC---"/"has_i=" pair.)
archive_prefix="$(grep -B2 -Fx 'ARG:tar' "$EXEC_LOG" || true)"
after_dash_t="$(grep -A1 -Fx 'ARG:-T' "$EXEC_LOG" | tail -n1 || true)"
if printf '%s\n' "$archive_prefix" | grep -Fxq 'has_i=0' \
    && grep -Fxq 'ARG:--null' "$EXEC_LOG" \
    && [ "$after_dash_t" = "ARG:$guest_list_path" ]; then
    test_pass "the archive exec has no -i and reads the list from the guest temp file, not stdin"
else
    test_fail "the archive exec has no -i and reads the list from the guest temp file, not stdin (prefix: $archive_prefix; after -T: $after_dash_t)"
fi

# --- Mid-task addition: the guest-side archive create gets
# --hard-dereference, so a duplicate path (e.g. from a nested-repo
# selection edge case -- see the selector-level fix) is archived as a
# second REGULAR file, never as a hardlink record pointing at itself
# (which crashed the host's tar live on the primary guest, 2026-09-27).
# This only needs to prove the flag reaches the exec -- the fake container
# strips it before really invoking this test host's own tar (a stand-in
# for the guest's; see fake_tool_write's container definitions), because
# this is a GNU-tar-only long option this host's bsdtar does not
# recognize; the real guest's tar is always GNU tar (a NixOS Linux guest),
# so no such translation happens in production. ---
if grep -Fxq 'ARG:--hard-dereference' "$EXEC_LOG"; then
    test_pass "the archive exec passes --hard-dereference to the guest's tar"
else
    test_fail "the archive exec passes --hard-dereference to the guest's tar"
fi

# The guest temp file is really removed (not just "an rm exec ran"): its
# path, real on this test host because the fake execs for real (see this
# file's header), no longer exists once dx-backup has finished.
if [ -n "$guest_list_path" ] && [ ! -e "$guest_list_path" ]; then
    test_pass "the guest temp file is removed after a successful fetch"
else
    test_fail "the guest temp file is removed after a successful fetch"
fi

# --- Item 3 (mid-task addition): a duplicate path in the fetch list (e.g.
# from a nested-repo selection edge case, before the selector-level fix
# above) must not break the transfer, and the mirror must still end up
# with exactly one correct entry for that path. Calls dx_backup_fetch_paths
# directly with a hand-built fetch-lines file naming the same relpath
# twice: a defense-in-depth regression guard, independent of whether the
# selector itself ever produces a duplicate again.
#
# CHARACTERIZATION, not red->green: this already passes without
# --hard-dereference on this test host, because bsdtar (standing in here
# for the guest's tar -- see this file's header) only treats a repeated
# path as a hardlink when the source's real link count is already > 1;
# GNU tar (the actual guest's tar, always, since it is a NixOS Linux
# guest) tracks (device, inode) pairs regardless of link count, so it DOES
# treat the exact same regular file (nlink 1) added twice as "a second
# hardlink" and emits a self-referential record the host's tar refuses --
# reproduced live on the primary guest, 2026-09-27 (see this file's
# --hard-dereference test above). That specific crash cannot be
# reproduced under this test host's tar; this test instead pins the
# invariant this host CAN verify (no crash, correct single mirror entry)
# as a permanent guard, alongside the flag-presence test above which is
# the part that is genuinely red->green here. Live re-verification on the
# real guest is the coordinating session's, after landing. ---
printf 'dup-content\n' > "$FIXTURE/persist/home/dx/dup-me.txt"
dup_fetch="$FIXTURE/dup-fetch.tsv"
printf 'home/dx/dup-me.txt\t11\t0\tdeadbeef\nhome/dx/dup-me.txt\t11\t0\tdeadbeef\n' > "$dup_fetch"
dup_backup_dir="$FIXTURE/dup-backups/$DX_CONTAINER_NAME"
rm -rf "$FIXTURE/dup-backups"
set +e
dx_backup_fetch_paths "$DX_CONTAINER_NAME" "$dup_backup_dir" "$dup_fetch"
dup_rc=$?
set -e
if [ "$dup_rc" -eq 0 ]; then
    test_pass "a duplicate path in the fetch list does not crash the archive transfer"
else
    test_fail "a duplicate path in the fetch list does not crash the archive transfer (rc=$dup_rc)"
fi
if [ "$(cat "$dup_backup_dir/current/home/dx/dup-me.txt" 2>/dev/null)" = dup-content ]; then
    test_pass "a duplicate path in the fetch list still produces a correct single mirror entry"
else
    test_fail "a duplicate path in the fetch list still produces a correct single mirror entry"
fi
rm -f "$FIXTURE/persist/home/dx/dup-me.txt"

# --- Same shape, but the archive exec fails: the guest temp file is still
# removed (cleanup on failure, not just on success). ---
: > "$EXEC_LOG"
fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$FIXTURE"'/persist"
LOG="'"$EXEC_LOG"'"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container container-a container-b; exit 0 ;;
esac
if [ "${1:-}" = exec ]; then
    shift
    has_i=0
    if [ "${1:-}" = -i ]; then has_i=1; shift; fi
    if [ "${1:-}" = -u ]; then shift; shift; fi
    shift
    {
        echo "---EXEC---"
        echo "has_i=$has_i"
        for a in "$@"; do printf "ARG:%s\n" "$a"; done
    } >> "$LOG"
    case "$*" in
        *--null*) exit 42 ;;
    esac
    args=()
    for a in "$@"; do
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST");
        elif [ "$a" = --hard-dereference ]; then :; # a real guest'"'"'s tar is always GNU tar, which supports this; this test host'"'"'s own bsdtar (standing in for it here) does not, so it is stripped before the real local exec -- any ARG log this fake keeps is written before this filtering, so it still records that dx-backup passed it.
        else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'
printf 'two-phase-fail-check\n' > "$FIXTURE/persist/home/dx/two-phase-fail-check.txt"
set +e
fail_out="$("$BASE_DIR/bin/dx-backup" 2>&1)"
fail_rc=$?
set -e
[ "$fail_rc" -ne 0 ] && test_pass "a failed archive exec still reports a nonzero exit status" || test_fail "a failed archive exec still reports a nonzero exit status (got: $fail_out)"

fail_guest_list_path="$(grep -A1 -Fx 'ARG:--' "$EXEC_LOG" | grep -F 'ARG:/tmp/' | head -n1 | sed 's/^ARG://' || true)"
if [ -n "$fail_guest_list_path" ] && [ ! -e "$fail_guest_list_path" ]; then
    test_pass "the guest temp file is removed even when the archive exec fails"
else
    test_fail "the guest temp file is removed even when the archive exec fails (path: $fail_guest_list_path; log: $(cat "$EXEC_LOG"))"
fi

# --- The SHIP exec itself fails (phase 1, before any guest temp file
# exists): the archive exec (phase 2) must never even be attempted. ---
: > "$EXEC_LOG"
fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$FIXTURE"'/persist"
LOG="'"$EXEC_LOG"'"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container container-a container-b; exit 0 ;;
esac
if [ "${1:-}" = exec ]; then
    shift
    has_i=0
    if [ "${1:-}" = -i ]; then has_i=1; shift; fi
    if [ "${1:-}" = -u ]; then shift; shift; fi
    shift
    {
        echo "---EXEC---"
        echo "has_i=$has_i"
        for a in "$@"; do printf "ARG:%s\n" "$a"; done
    } >> "$LOG"
    if [ "${1:-}" = sh ]; then exit 42; fi
    args=()
    for a in "$@"; do
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST");
        elif [ "$a" = --hard-dereference ]; then :; # a real guest'"'"'s tar is always GNU tar, which supports this; this test host'"'"'s own bsdtar (standing in for it here) does not, so it is stripped before the real local exec -- any ARG log this fake keeps is written before this filtering, so it still records that dx-backup passed it.
        else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'
printf 'two-phase-ship-fail-check\n' > "$FIXTURE/persist/home/dx/two-phase-ship-fail-check.txt"
set +e
ship_fail_out="$("$BASE_DIR/bin/dx-backup" 2>&1)"
ship_fail_rc=$?
set -e
[ "$ship_fail_rc" -ne 0 ] && test_pass "a failed ship exec still reports a nonzero exit status" || test_fail "a failed ship exec still reports a nonzero exit status (got: $ship_fail_out)"
if grep -Fxq 'ARG:tar' "$EXEC_LOG"; then
    test_fail "the archive exec is never attempted when the ship exec fails"
else
    test_pass "the archive exec is never attempted when the ship exec fails"
fi

# Restore the well-behaved fake container (matches the rest of this file's
# convention of leaving it well-behaved after a forced-failure block).
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
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST");
        elif [ "$a" = --hard-dereference ]; then :; # a real guest'"'"'s tar is always GNU tar, which supports this; this test host'"'"'s own bsdtar (standing in for it here) does not, so it is stripped before the real local exec -- any ARG log this fake keeps is written before this filtering, so it still records that dx-backup passed it.
        else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'

# --- Branch 17: `--dry-run --summary` aggregates the at-risk selection by
# top-level directory and by reason, instead of a full per-file listing --
# added because the first real dx-backup dry-run on dx-host selected 51,262
# files / 3.2 GB of a 6.3 GB /persist, which looked too large to review file
# by file. ---

# dx_backup_summarize: direct unit test against a hand-built --with-reason
# listing (no container needed for the arithmetic itself).
summary_fixture="$FIXTURE/summary-listing.tsv"
printf '%s\n' \
    "$(printf 'home/dx/a.txt\t100\t1700000000\tdeadbeef\tmodified-untracked')" \
    "$(printf 'home/dx/b.txt\t200\t1700000000\tdeadbeef\tignored-kept')" \
    "$(printf 'etc/config\t50\t1700000000\tdeadbeef\toutside-repo')" \
    "$(printf 'git/repo/file\t300\t1700000000\tdeadbeef\twhole-repo')" \
    "$(printf 'git/repo/other\t400\t1700000000\tdeadbeef\twhole-repo')" \
    > "$summary_fixture"
summary_out="$(dx_backup_summarize "$summary_fixture")"
if printf '%s\n' "$summary_out" | stdin_matches -F 'Total at-risk under /persist: 5 files, 1050 bytes.'; then
    test_pass "dx_backup_summarize prints the grand total"
else
    test_fail "dx_backup_summarize prints the grand total (got: $summary_out)"
fi
if printf '%s\n' "$summary_out" | stdin_matches -E 'git +2 files +700 bytes'; then
    test_pass "dx_backup_summarize aggregates by top-level directory (git: 2 files, 700 bytes)"
else
    test_fail "dx_backup_summarize aggregates by top-level directory (git: 2 files, 700 bytes) (got: $summary_out)"
fi
if printf '%s\n' "$summary_out" | stdin_matches -E 'home +2 files +300 bytes'; then
    test_pass "dx_backup_summarize aggregates by top-level directory (home: 2 files, 300 bytes)"
else
    test_fail "dx_backup_summarize aggregates by top-level directory (home: 2 files, 300 bytes) (got: $summary_out)"
fi
if printf '%s\n' "$summary_out" | stdin_matches -E 'whole-repo +2 files +700 bytes'; then
    test_pass "dx_backup_summarize aggregates by reason (whole-repo: 2 files, 700 bytes)"
else
    test_fail "dx_backup_summarize aggregates by reason (whole-repo: 2 files, 700 bytes) (got: $summary_out)"
fi
if printf '%s\n' "$summary_out" | stdin_matches -E 'ignored-kept +1 files +200 bytes'; then
    test_pass "dx_backup_summarize aggregates by reason (ignored-kept: 1 file, 200 bytes)"
else
    test_fail "dx_backup_summarize aggregates by reason (ignored-kept: 1 file, 200 bytes) (got: $summary_out)"
fi

# `bin/dx-backup --dry-run --summary` end to end: no backup dir is created,
# no full per-file listing is printed, and the aggregate is present.
printf 'summary-check\n' > "$FIXTURE/persist/home/dx/summary-check.txt"
rm -rf "$FIXTURE/summary-backups"
summary_cli_out="$(DX_BACKUP_DIR="$FIXTURE/summary-backups" "$BASE_DIR/bin/dx-backup" --dry-run --summary 2>&1)" || true
if [ ! -e "$FIXTURE/summary-backups" ]; then test_pass "--dry-run --summary creates no backup directory"; else test_fail "--dry-run --summary creates no backup directory"; fi
if printf '%s\n' "$summary_cli_out" | stdin_matches -F 'summary-check.txt'; then
    test_fail "--dry-run --summary does not print the full per-file listing"
else
    test_pass "--dry-run --summary does not print the full per-file listing"
fi
if printf '%s\n' "$summary_cli_out" | stdin_matches -F 'Total at-risk under /persist:'; then
    test_pass "--dry-run --summary prints the aggregate total"
else
    test_fail "--dry-run --summary prints the aggregate total (got: $summary_cli_out)"
fi
if printf '%s\n' "$summary_cli_out" | stdin_matches -F 'By top-level directory:' && printf '%s\n' "$summary_cli_out" | stdin_matches -F 'By reason:'; then
    test_pass "--dry-run --summary prints both breakdowns"
else
    test_fail "--dry-run --summary prints both breakdowns (got: $summary_cli_out)"
fi

# --- CLI hygiene: --summary requires --dry-run. ---
if "$BASE_DIR/bin/dx-backup" --summary >/dev/null 2>&1; then test_fail "--summary without --dry-run is a usage error"; else test_pass "--summary without --dry-run is a usage error"; fi

# --- Branch 18: a default location for the user's extra exclude file. When
# DX_BACKUP_EXCLUDE_FILE is unset and
# ${XDG_CONFIG_HOME:-$HOME/.config}/dxe/dx-backup-exclude exists on the
# host, it is read the same way as an explicit DX_BACKUP_EXCLUDE_FILE (one
# pattern per line, blank lines/'#' comments skipped). An explicit
# DX_BACKUP_EXCLUDE_FILE still wins over the default. A missing default
# file is silently ignored (not an error, unlike an explicit
# DX_BACKUP_EXCLUDE_FILE naming a nonexistent file, which is already
# covered by dx_backup_read_exclude_patterns's own existing error path).
# A fresh DX_BACKUP_DIR isolates this block from every manifest state
# built up by the tests above -- everything here is "new", so what
# --dry-run reports as "would transfer" reflects only what this block's
# own deny patterns include or exclude. ---
unset DX_BACKUP_EXCLUDE_FILE 2>/dev/null || true
export XDG_CONFIG_HOME="$FIXTURE/xdg-config"
export DX_BACKUP_DIR="$FIXTURE/default-exclude-backups"
mkdir -p "$XDG_CONFIG_HOME/dxe"
printf 'default-drop-me\n' > "$FIXTURE/persist/home/dx/default-drop-me.marker"

# No default file yet: silently ignored, at-risk set unaffected.
no_default_out="$("$BASE_DIR/bin/dx-backup" --dry-run 2>&1)"
no_default_rc=$?
if [ "$no_default_rc" -eq 0 ] && printf '%s\n' "$no_default_out" | stdin_matches -F 'home/dx/default-drop-me.marker'; then
    test_pass "a missing default exclude file is silently ignored"
else
    test_fail "a missing default exclude file is silently ignored (rc=$no_default_rc, out: $no_default_out)"
fi

# The default file now exists (blank line and '#' comment included, same
# syntax as DX_BACKUP_EXCLUDE_FILE): its pattern applies with
# DX_BACKUP_EXCLUDE_FILE unset.
printf '%s\n' '# a comment line' '' 'home/dx/default-drop-me.marker' > "$XDG_CONFIG_HOME/dxe/dx-backup-exclude"
default_out="$("$BASE_DIR/bin/dx-backup" --dry-run 2>&1)"
if printf '%s\n' "$default_out" | stdin_matches -F 'home/dx/default-drop-me.marker'; then
    test_fail "the default exclude file's pattern is honoured when DX_BACKUP_EXCLUDE_FILE is unset"
else
    test_pass "the default exclude file's pattern is honoured when DX_BACKUP_EXCLUDE_FILE is unset"
fi

# An explicit DX_BACKUP_EXCLUDE_FILE still wins: its own pattern applies,
# and the default file's own (different) pattern no longer takes effect.
printf 'explicit-drop-me\n' > "$FIXTURE/persist/home/dx/explicit-drop-me.marker"
printf '%s\n' 'home/dx/explicit-drop-me.marker' > "$FIXTURE/explicit-excludes.txt"
explicit_out="$(DX_BACKUP_EXCLUDE_FILE="$FIXTURE/explicit-excludes.txt" "$BASE_DIR/bin/dx-backup" --dry-run 2>&1)"
if printf '%s\n' "$explicit_out" | stdin_matches -F 'home/dx/explicit-drop-me.marker'; then
    test_fail "an explicit DX_BACKUP_EXCLUDE_FILE's pattern is honoured"
else
    test_pass "an explicit DX_BACKUP_EXCLUDE_FILE's pattern is honoured"
fi
if printf '%s\n' "$explicit_out" | stdin_matches -F 'home/dx/default-drop-me.marker'; then
    test_pass "an explicit DX_BACKUP_EXCLUDE_FILE overrides the default location (the default's own pattern no longer applies)"
else
    test_fail "an explicit DX_BACKUP_EXCLUDE_FILE overrides the default location (the default's own pattern no longer applies)"
fi

rm -f "$FIXTURE/persist/home/dx/default-drop-me.marker" "$FIXTURE/persist/home/dx/explicit-drop-me.marker"
rm -rf "$XDG_CONFIG_HOME" "$DX_BACKUP_DIR"
unset XDG_CONFIG_HOME
export DX_BACKUP_DIR="$FIXTURE/backups"

print_summary
exit_with_code
