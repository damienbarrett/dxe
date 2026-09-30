#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
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
# Astra F5 / WP6.6: dx_lock_acquire/dx_lock_release/dx_process_start_identity,
# needed in-process below to simulate a concurrently-held backup/restore lock
# (RED 3) without spawning a second real process.
# shellcheck source=../bin/lib/dx-host-util.sh
source "$BASE_DIR/bin/lib/dx-host-util.sh"
GUEST="$BASE_DIR/container/dx-nixos-26.05"
# Captured before PATH is ever extended with FAKE_DIR below, so a fake `ln`
# installed later (Astra F5 RED 2, simulating a failed publish) can still
# `exec` the REAL `ln` for every call it does not itself intercept.
REAL_LN="$(command -v ln)"
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
assert_file_exists "$BACKUP_ROOT/current/manifest.tsv" "manifest.tsv exists after the first run"
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
manifest_before_interrupt="$(cat "$BACKUP_ROOT/current/manifest.tsv")"
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
if [ "$(cat "$BACKUP_ROOT/current/manifest.tsv")" = "$manifest_before_interrupt" ]; then test_pass "interruption leaves the previous manifest intact"; else test_fail "interruption leaves the previous manifest intact"; fi
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
listing_fail_manifest_before="$(cat "$listing_fail_backup_dir/$DX_CONTAINER_NAME/current/manifest.tsv")"

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
if [ "$(cat "$listing_fail_backup_dir/$DX_CONTAINER_NAME/current/manifest.tsv")" = "$listing_fail_manifest_before" ]; then
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
dx_backup_fetch_paths "$DX_CONTAINER_NAME" "$dup_backup_dir/current" "$dup_fetch"
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

# ---------------------------------------------------------------------------
# Astra F5 / WP6.6 (docs/reviews/2026-09-29-astra.md, "F5"): a backup is now
# published as a whole generation, atomically, never extracted straight over
# the currently-published mirror -- so a truncated transfer, a hash mismatch
# between listing and transfer, a failed publish, or lock contention with a
# concurrent backup/restore can never leave `current` (or its manifest)
# showing a partly-applied run. Each RED case below runs in its own isolated
# fixture (own DX_BACKUP_DIR/persist dir), so none of them disturb
# test-container's own long-lived shared mirror state built up above.
# ---------------------------------------------------------------------------

# --- RED 1: a truncated archive after the first changed file. Two files are
# changed on the guest; the archive exec streams back a complete, valid tar
# of only the FIRST one, then exits non-zero without ever starting the
# second -- exactly as if the guest process died right after finishing one
# file. The previously published generation (and its manifest, and its
# content) must remain byte-for-byte exactly as they were. ---
F5_1_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-f5-truncate-test.XXXXXX")"
F5_1_PERSIST="$F5_1_ROOT/persist"
F5_1_BACKUP_DIR="$F5_1_ROOT/backups"
mkdir -p "$F5_1_PERSIST/home/dx"
printf 'alpha-v1\n' > "$F5_1_PERSIST/home/dx/alpha.txt"
printf 'beta-v1\n' > "$F5_1_PERSIST/home/dx/beta.txt"

fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$F5_1_PERSIST"'"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container; exit 0 ;;
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
DX_BACKUP_DIR="$F5_1_BACKUP_DIR" "$BASE_DIR/bin/dx-backup" >/dev/null
F5_1_MIRROR="$F5_1_BACKUP_DIR/test-container"
f5_1_gen1="$(readlink "$F5_1_MIRROR/current")"
cp -R "$F5_1_MIRROR/current/" "$F5_1_ROOT/before-current/"

printf 'alpha-v2\n' > "$F5_1_PERSIST/home/dx/alpha.txt"
printf 'beta-v2\n' > "$F5_1_PERSIST/home/dx/beta.txt"

fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$F5_1_PERSIST"'"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container; exit 0 ;;
esac
if [ "${1:-}" = exec ]; then
    shift
    [ "${1:-}" != -i ] || shift
    if [ "${1:-}" = -u ]; then shift; shift; fi
    shift
    case "$*" in
        *"--hard-dereference"*)
            (cd "$FIX_PERSIST" && tar -cf - home/dx/alpha.txt)
            exit 1
            ;;
    esac
    args=()
    for a in "$@"; do
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST"); else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'
set +e
f5_1_out="$(DX_BACKUP_DIR="$F5_1_BACKUP_DIR" "$BASE_DIR/bin/dx-backup" 2>&1)"
f5_1_rc=$?
set -e
if [ "$f5_1_rc" -ne 0 ]; then
    test_pass "Astra F5 RED 1: a truncated archive after the first changed file makes dx-backup exit non-zero"
else
    test_fail "Astra F5 RED 1: a truncated archive after the first changed file makes dx-backup exit non-zero (got: $f5_1_out)"
fi
if [ "$(readlink "$F5_1_MIRROR/current")" = "$f5_1_gen1" ]; then
    test_pass "Astra F5 RED 1: current still points at the previously published generation"
else
    test_fail "Astra F5 RED 1: current still points at the previously published generation"
fi
if diff -rq "$F5_1_ROOT/before-current" "$F5_1_MIRROR/current" >/dev/null 2>&1; then
    test_pass "Astra F5 RED 1: the previous mirror content (and its manifest) is byte-identical after the truncated run"
else
    test_fail "Astra F5 RED 1: the previous mirror content (and its manifest) is byte-identical after the truncated run"
fi
rm -rf "$F5_1_ROOT"

# --- RED 2: an interrupted publication. The pointer-switch command itself
# fails (a fake `ln` that intercepts only `-sfn` calls, standing in for a
# full disk / permissions error / a process killed mid-switch -- and never
# touches the filesystem at all when it does, so there is nothing for it to
# leave half-done); the previously published generation must remain
# published and restorable. ---
F5_2_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-f5-publish-test.XXXXXX")"
F5_2_PERSIST="$F5_2_ROOT/persist"
F5_2_BACKUP_DIR="$F5_2_ROOT/backups"
mkdir -p "$F5_2_PERSIST/home/dx"
printf 'gamma-v1\n' > "$F5_2_PERSIST/home/dx/gamma.txt"

fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$F5_2_PERSIST"'"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container; exit 0 ;;
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
DX_BACKUP_DIR="$F5_2_BACKUP_DIR" "$BASE_DIR/bin/dx-backup" >/dev/null
F5_2_MIRROR="$F5_2_BACKUP_DIR/test-container"
f5_2_gen1="$(readlink "$F5_2_MIRROR/current")"

printf 'gamma-v2\n' > "$F5_2_PERSIST/home/dx/gamma.txt"

fake_tool_write "$FAKE_DIR" ln '
case " $* " in
    *" -sfn "*) exit 1 ;;
    *) exec "'"$REAL_LN"'" "$@" ;;
esac
'
set +e
f5_2_out="$(DX_BACKUP_DIR="$F5_2_BACKUP_DIR" "$BASE_DIR/bin/dx-backup" 2>&1)"
f5_2_rc=$?
set -e
rm -f "$FAKE_DIR/ln"
if [ "$f5_2_rc" -ne 0 ]; then
    test_pass "Astra F5 RED 2: a failed pointer switch makes dx-backup exit non-zero"
else
    test_fail "Astra F5 RED 2: a failed pointer switch makes dx-backup exit non-zero (got: $f5_2_out)"
fi
if [ "$(readlink "$F5_2_MIRROR/current")" = "$f5_2_gen1" ]; then
    test_pass "Astra F5 RED 2: current still points at the previously published generation after a failed publish"
else
    test_fail "Astra F5 RED 2: current still points at the previously published generation after a failed publish"
fi
if [ "$(cat "$F5_2_MIRROR/current/home/dx/gamma.txt")" = gamma-v1 ]; then
    test_pass "Astra F5 RED 2: the previous generation's content is untouched after a failed publish"
else
    test_fail "Astra F5 RED 2: the previous generation's content is untouched after a failed publish"
fi
rm -f "$F5_2_PERSIST/home/dx/gamma.txt"
DX_BACKUP_DIR="$F5_2_BACKUP_DIR" "$BASE_DIR/bin/dx-restore" >/dev/null
if [ "$(cat "$F5_2_PERSIST/home/dx/gamma.txt")" = gamma-v1 ]; then
    test_pass "Astra F5 RED 2: restore after a failed publish still restores the previous content"
else
    test_fail "Astra F5 RED 2: restore after a failed publish still restores the previous content"
fi
rm -rf "$F5_2_ROOT"

# --- RED 3: two overlapping backups. The SECOND process, started while the
# first holds the per-mirror lock, refuses rather than interleaving --
# simulated by holding the lock in THIS test script's own (still-alive)
# process, exactly like a genuinely concurrent dx-backup would hold it. A
# REAL (non---dry-run) invocation: --dry-run/--summary never take this lock
# at all (they read only the guest listing and the OLD manifest, never
# `current`, and must create nothing on disk -- see bin/dx-backup's own
# comment), so only a real run can ever observe contention on it.
# DX_SLEEP=fake-sleep keeps dx_lock_acquire's own bounded wait fast and
# deterministic (this codebase's established seam, see
# tests/test_bootstrap_publication.sh). ---
F5_3_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-f5-lock-test.XXXXXX")"
F5_3_PERSIST="$F5_3_ROOT/persist"
F5_3_BACKUP_DIR="$F5_3_ROOT/backups"
mkdir -p "$F5_3_PERSIST/home/dx" "$F5_3_BACKUP_DIR/test-container"
printf 'delta-v1\n' > "$F5_3_PERSIST/home/dx/delta.txt"
fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$F5_3_PERSIST"'"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container; exit 0 ;;
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
fake_tool_write "$FAKE_DIR" fake-sleep 'exit 0'
dx_lock_acquire "$F5_3_BACKUP_DIR/test-container/.lock" 1
set +e
f5_3_out="$(DX_BACKUP_DIR="$F5_3_BACKUP_DIR" DX_SLEEP=fake-sleep "$BASE_DIR/bin/dx-backup" 2>&1)"
f5_3_rc=$?
set -e
dx_lock_release "$F5_3_BACKUP_DIR/test-container/.lock"
if [ "$f5_3_rc" -ne 0 ]; then
    test_pass "Astra F5 RED 3: a second dx-backup started while the first holds the lock refuses rather than interleaving"
else
    test_fail "Astra F5 RED 3: a second dx-backup started while the first holds the lock refuses rather than interleaving (got: $f5_3_out)"
fi
if printf '%s\n' "$f5_3_out" | stdin_matches -F 'lock'; then
    test_pass "Astra F5 RED 3: the refusal names the lock, a clear message rather than a generic failure"
else
    test_fail "Astra F5 RED 3: the refusal names the lock, a clear message rather than a generic failure (got: $f5_3_out)"
fi
rm -rf "$F5_3_ROOT"

# --- RED 4: a file changed on the guest between the LISTING pass and the
# ARCHIVE transfer -- the classic TOCTOU this generation model exists to
# close -- is reported and the snapshot is never committed as `current`.
# Forged directly, rather than trying to win a real race: the fake
# selector-intercepting exec reports a listing whose hash does NOT match
# the file's real (transferred) bytes, decoupling "what the listing
# claimed" from "what actually arrived" deterministically. The file being
# the mirror's ONLY entry also means the previous generation's carry list is
# empty (nothing survives to carry forward -- dx_backup_generation_carry_forward's
# own "skip list covers the whole previous generation" case). ---
F5_4_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-f5-hash-test.XXXXXX")"
F5_4_PERSIST="$F5_4_ROOT/persist"
F5_4_BACKUP_DIR="$F5_4_ROOT/backups"
mkdir -p "$F5_4_PERSIST/home/dx"
printf 'race-me-v1\n' > "$F5_4_PERSIST/home/dx/race-me.txt"

fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$F5_4_PERSIST"'"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container; exit 0 ;;
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
DX_BACKUP_DIR="$F5_4_BACKUP_DIR" "$BASE_DIR/bin/dx-backup" >/dev/null
F5_4_MIRROR="$F5_4_BACKUP_DIR/test-container"
f5_4_gen1="$(readlink "$F5_4_MIRROR/current")"

printf 'race-me-v2\n' > "$F5_4_PERSIST/home/dx/race-me.txt"
f5_4_size="$(wc -c < "$F5_4_PERSIST/home/dx/race-me.txt" | tr -d '[:space:]')"

fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$F5_4_PERSIST"'"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container; exit 0 ;;
esac
if [ "${1:-}" = exec ]; then
    shift
    [ "${1:-}" != -i ] || shift
    if [ "${1:-}" = -u ]; then shift; shift; fi
    shift
    case "$*" in
        *dx-persist-backup-select.sh*)
            printf "home/dx/race-me.txt\t'"$f5_4_size"'\t0\tSTALE0STALE0STALE0STALE0STALE0STALE0STALE0STALE0\n"
            exit 0
            ;;
    esac
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
set +e
f5_4_out="$(DX_BACKUP_DIR="$F5_4_BACKUP_DIR" "$BASE_DIR/bin/dx-backup" 2>&1)"
f5_4_rc=$?
set -e
if [ "$f5_4_rc" -ne 0 ]; then
    test_pass "Astra F5 RED 4: a file whose transferred bytes do not match the listing's own hash makes dx-backup exit non-zero"
else
    test_fail "Astra F5 RED 4: a file whose transferred bytes do not match the listing's own hash makes dx-backup exit non-zero (got: $f5_4_out)"
fi
if printf '%s\n' "$f5_4_out" | stdin_matches -F 'home/dx/race-me.txt'; then
    test_pass "Astra F5 RED 4: the mismatch is reported by path"
else
    test_fail "Astra F5 RED 4: the mismatch is reported by path (got: $f5_4_out)"
fi
if [ "$(readlink "$F5_4_MIRROR/current")" = "$f5_4_gen1" ]; then
    test_pass "Astra F5 RED 4: the previously published generation stays current -- the inconsistent snapshot is never committed"
else
    test_fail "Astra F5 RED 4: the previously published generation stays current -- the inconsistent snapshot is never committed"
fi
if [ "$(cat "$F5_4_MIRROR/current/home/dx/race-me.txt")" = race-me-v1 ]; then
    test_pass "Astra F5 RED 4: the previous generation's content is untouched"
else
    test_fail "Astra F5 RED 4: the previous generation's content is untouched"
fi
f5_4_gen_count="$(find "$F5_4_MIRROR/generations" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ "$f5_4_gen_count" -eq 1 ]; then
    test_pass "Astra F5 RED 4: the unverified generation is not left behind either"
else
    test_fail "Astra F5 RED 4: the unverified generation is not left behind either (found $f5_4_gen_count generation(s))"
fi
rm -rf "$F5_4_ROOT"

# Restore the well-behaved fake container, since RED 4's isolated block above
# was the last thing in this file to install a non-default one.
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
        elif [ "$a" = --hard-dereference ]; then :;
        else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'

# --- Astra F5 / WP6.6: pruning actually deletes older generations, not just
# retains the current pair. test-container's own shared mirror (built up
# across this whole file) has had many successful real dx-backup runs by
# this point, each publishing a new generation and pruning down to the
# current one plus the one before it -- never accumulating without bound. ---
f5_prune_gen_count="$(find "$BACKUP_ROOT/generations" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ "${f5_prune_gen_count:-0}" -le 2 ]; then
    test_pass "Astra F5 / WP6.6: generations/ never accumulates more than the current generation plus the one it replaced (found $f5_prune_gen_count)"
else
    test_fail "Astra F5 / WP6.6: generations/ never accumulates more than the current generation plus the one it replaced (found $f5_prune_gen_count)"
fi

# ---------------------------------------------------------------------------
# Astra F5 / WP6.6: direct unit coverage for the generation-management
# library functions' own edge cases -- branches a full dx-backup CLI run
# does not naturally reach.
# ---------------------------------------------------------------------------

# dx_backup_generation_current: a `current` symlink whose target does NOT
# start with "generations/" (corrupt or foreign state) is treated as "no
# current generation", never silently trusted.
BADTARGET_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-badtarget-test.XXXXXX")"
ln -s /somewhere/else "$BADTARGET_FIXTURE/current"
if dx_backup_generation_current "$BADTARGET_FIXTURE" >/dev/null 2>&1; then
    test_fail "dx_backup_generation_current: a current symlink whose target is not under generations/ is refused"
else
    test_pass "dx_backup_generation_current: a current symlink whose target is not under generations/ is refused"
fi
rm -rf "$BADTARGET_FIXTURE"

# dx_backup_generation_publish: refuses a generation id that does not exist
# on disk, leaving no pointer behind at all.
PUBLISH_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-publish-test.XXXXXX")"
set +e
dx_backup_generation_publish "$PUBLISH_FIXTURE" no-such-generation 2>/dev/null
publish_missing_rc=$?
set -e
if [ "$publish_missing_rc" -ne 0 ] && [ ! -e "$PUBLISH_FIXTURE/current" ]; then
    test_pass "dx_backup_generation_publish: refuses to publish a generation that does not exist, leaving no pointer behind"
else
    test_fail "dx_backup_generation_publish: refuses to publish a generation that does not exist, leaving no pointer behind (rc=$publish_missing_rc)"
fi

# dx_backup_generation_publish: a `current` that exists but is NOT a symlink
# (the shape every mirror created before this generation model existed has)
# must never be silently mishandled -- this host's own `ln -sfn` was
# confirmed, while designing this function, to place the new symlink INSIDE
# such a real directory instead of replacing it (successfully, with no
# error); publish must refuse loudly instead, leaving that directory's
# content completely untouched.
mkdir -p "$PUBLISH_FIXTURE/current/home/dx" "$PUBLISH_FIXTURE/generations/realgen"
printf 'legacy content\n' > "$PUBLISH_FIXTURE/current/home/dx/legacy.txt"
printf 'new gen content\n' > "$PUBLISH_FIXTURE/generations/realgen/new.txt"
set +e
dx_backup_generation_publish "$PUBLISH_FIXTURE" realgen 2>/dev/null
publish_legacy_rc=$?
set -e
if [ "$publish_legacy_rc" -ne 0 ]; then
    test_pass "dx_backup_generation_publish: refuses to publish over a pre-existing non-symlink current/"
else
    test_fail "dx_backup_generation_publish: refuses to publish over a pre-existing non-symlink current/"
fi
if [ ! -L "$PUBLISH_FIXTURE/current" ] && [ "$(cat "$PUBLISH_FIXTURE/current/home/dx/legacy.txt")" = "legacy content" ] && [ ! -e "$PUBLISH_FIXTURE/current/realgen" ]; then
    test_pass "dx_backup_generation_publish: a refused publish leaves the pre-existing current/ directory completely untouched"
else
    test_fail "dx_backup_generation_publish: a refused publish leaves the pre-existing current/ directory completely untouched"
fi
rm -rf "$PUBLISH_FIXTURE"

# dx_backup_generation_prune: a backup dir with no generations/ at all, or
# an empty existing generations/, is a harmless no-op; otherwise it deletes
# every generation not named to keep.
PRUNE_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-prune-test.XXXXXX")"
if dx_backup_generation_prune "$PRUNE_FIXTURE" keep-me; then
    test_pass "dx_backup_generation_prune: a backup dir with no generations/ at all is a harmless no-op"
else
    test_fail "dx_backup_generation_prune: a backup dir with no generations/ at all is a harmless no-op"
fi
mkdir -p "$PRUNE_FIXTURE/generations"
if dx_backup_generation_prune "$PRUNE_FIXTURE" keep-me; then
    test_pass "dx_backup_generation_prune: an empty existing generations/ is a harmless no-op"
else
    test_fail "dx_backup_generation_prune: an empty existing generations/ is a harmless no-op"
fi
mkdir -p "$PRUNE_FIXTURE/generations/keep-me" "$PRUNE_FIXTURE/generations/drop-me"
dx_backup_generation_prune "$PRUNE_FIXTURE" keep-me
if [ -d "$PRUNE_FIXTURE/generations/keep-me" ] && [ ! -e "$PRUNE_FIXTURE/generations/drop-me" ]; then
    test_pass "dx_backup_generation_prune: deletes every generation not named to keep, retaining the rest"
else
    test_fail "dx_backup_generation_prune: deletes every generation not named to keep, retaining the rest"
fi
rm -rf "$PRUNE_FIXTURE"

# dx_backup_generation_carry_forward: a previous generation directory that
# does not exist at all (defensive: a `current` symlink whose STRING target
# looks valid but whose generation directory is itself somehow missing) is a
# harmless no-op.
CARRY_FIXTURE1="$(mktemp -d "${TMPDIR:-/tmp}/dxe-carry1-test.XXXXXX")"
: > "$CARRY_FIXTURE1/empty-skip.txt"
if dx_backup_generation_carry_forward "$CARRY_FIXTURE1/no-such-prev" "$CARRY_FIXTURE1/new1" "$CARRY_FIXTURE1/empty-skip.txt" 2>/dev/null; then
    test_pass "dx_backup_generation_carry_forward: a nonexistent previous generation directory is a harmless no-op"
else
    test_fail "dx_backup_generation_carry_forward: a nonexistent previous generation directory is a harmless no-op"
fi
rm -rf "$CARRY_FIXTURE1"

# dx_backup_generation_carry_forward: a directory-precreation failure (the
# destination's own parent is not a directory at all) is reported, not
# silently ignored. Deliberately a REGULAR FILE standing where a directory
# is needed, not a read-only mode bit: root (as this suite also runs under,
# in the coverage container) ignores mode bits entirely, so a mode-based
# fixture never fails for root -- ENOTDIR from mkdir-under-a-file is a real
# filesystem constraint no uid can bypass.
CARRY_FIXTURE2="$(mktemp -d "${TMPDIR:-/tmp}/dxe-carry2-test.XXXXXX")"
mkdir -p "$CARRY_FIXTURE2/prev/sub"
printf 'x\n' > "$CARRY_FIXTURE2/prev/sub/f.txt"
: > "$CARRY_FIXTURE2/new2"
: > "$CARRY_FIXTURE2/empty-skip.txt"
set +e
dx_backup_generation_carry_forward "$CARRY_FIXTURE2/prev" "$CARRY_FIXTURE2/new2/nested" "$CARRY_FIXTURE2/empty-skip.txt" 2>/dev/null
carry_mkdir_fail_rc=$?
set -e
if [ "$carry_mkdir_fail_rc" -ne 0 ]; then
    test_pass "dx_backup_generation_carry_forward: a directory precreation failure is reported, not silently ignored"
else
    test_fail "dx_backup_generation_carry_forward: a directory precreation failure is reported, not silently ignored"
fi
rm -rf "$CARRY_FIXTURE2"

# dx_backup_generation_carry_forward: a hard-link failure (something already
# occupies the destination path) is reported, not silently ignored.
CARRY_FIXTURE3="$(mktemp -d "${TMPDIR:-/tmp}/dxe-carry3-test.XXXXXX")"
mkdir -p "$CARRY_FIXTURE3/prev" "$CARRY_FIXTURE3/new3"
printf 'x\n' > "$CARRY_FIXTURE3/prev/f.txt"
printf 'already here\n' > "$CARRY_FIXTURE3/new3/f.txt"
: > "$CARRY_FIXTURE3/empty-skip.txt"
set +e
dx_backup_generation_carry_forward "$CARRY_FIXTURE3/prev" "$CARRY_FIXTURE3/new3" "$CARRY_FIXTURE3/empty-skip.txt" 2>/dev/null
carry_ln_fail_rc=$?
set -e
if [ "$carry_ln_fail_rc" -ne 0 ]; then
    test_pass "dx_backup_generation_carry_forward: a hard-link failure (destination already occupied) is reported, not silently ignored"
else
    test_fail "dx_backup_generation_carry_forward: a hard-link failure (destination already occupied) is reported, not silently ignored"
fi
rm -rf "$CARRY_FIXTURE3"

# dx_backup_generation_commit: refuses when the freshly minted generation id
# already exists on disk (an id collision, stubbing dx_backup_generation_new_id
# to force one deterministically -- this codebase's established pattern for
# a direct unit test of an otherwise environment-driven id, see
# test_dx_restore.sh's own dx_runtime_exec/dx_pbs_hash_entry stubs).
COMMIT_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-commit-collide-test.XXXXXX")"
mkdir -p "$COMMIT_FIXTURE/generations/collide-id"
dx_backup_generation_new_id() { printf '%s\n' collide-id; }
: > "$COMMIT_FIXTURE/empty-listing.tsv"
: > "$COMMIT_FIXTURE/empty-fetch.tsv"
: > "$COMMIT_FIXTURE/empty-remove.txt"
set +e
dx_backup_generation_commit test-container "$COMMIT_FIXTURE" "$COMMIT_FIXTURE/empty-listing.tsv" "$COMMIT_FIXTURE/empty-fetch.tsv" "$COMMIT_FIXTURE/empty-remove.txt" 2>/dev/null
collide_rc=$?
set -e
unset -f dx_backup_generation_new_id
if [ "$collide_rc" -ne 0 ]; then
    test_pass "dx_backup_generation_commit: refuses when the freshly minted generation id already exists on disk"
else
    test_fail "dx_backup_generation_commit: refuses when the freshly minted generation id already exists on disk"
fi
rm -rf "$COMMIT_FIXTURE"

# ---------------------------------------------------------------------------
# Astra F5 / WP6.9 follow-up: the legacy-mirror refusal cannot ship as-is --
# a mirror created before this generation model existed (current/ a real
# directory, manifest.tsv sitting directly beside it, no generations/ at
# all -- dx-host's own real mirror has exactly this shape) must be adopted
# in place, not refused, and a hand migration is not acceptable.
# ---------------------------------------------------------------------------

# dx_backup_generation_migrate_legacy: direct unit coverage.
LEGACY_UNIT_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-legacy-unit-test.XXXXXX")"
mkdir -p "$LEGACY_UNIT_FIXTURE/current/home/dx"
printf 'legacy-content\n' > "$LEGACY_UNIT_FIXTURE/current/home/dx/f.txt"
printf 'home/dx/f.txt\t14\t0\tdeadbeef\n' > "$LEGACY_UNIT_FIXTURE/manifest.tsv"
touch -t 202401021200 "$LEGACY_UNIT_FIXTURE/manifest.tsv"
# Reuse dx_pbs_stat_mtime (sourced transitively via bin/lib/dx-backup.sh,
# which is what dx_backup_generation_legacy_id itself calls) rather than a
# second, independently-ordered GNU/BSD `stat` fallback: a bare `stat -f
# '%m' ... || stat -c '%Y' ...` tries BSD's custom-format `-f` first, but on
# GNU coreutils `-f` means "report on the FILESYSTEM", not "use this
# format" -- it still exits nonzero (the stray "%m" is parsed as a second,
# nonexistent file operand), but only after printing multi-line filesystem
# info to STDOUT (never suppressed by `2>/dev/null`), which the `||`
# fallback's real epoch then gets appended after inside the same command
# substitution. One shared helper, in the same order the library uses,
# avoids that trap entirely.
legacy_unit_expected_epoch="$(dx_pbs_stat_mtime "$LEGACY_UNIT_FIXTURE/manifest.tsv")"
# The snapshot includes manifest.tsv too (copied alongside, matching where
# migration will place it inside the new generation): the "byte-identical"
# comparison below is over the WHOLE generation directory as migration
# leaves it, not just the pre-existing file tree.
cp -R "$LEGACY_UNIT_FIXTURE/current/" "$LEGACY_UNIT_FIXTURE/before-current/"
cp "$LEGACY_UNIT_FIXTURE/manifest.tsv" "$LEGACY_UNIT_FIXTURE/before-current/manifest.tsv"

if dx_backup_generation_migrate_legacy "$LEGACY_UNIT_FIXTURE"; then
    test_pass "dx_backup_generation_migrate_legacy: succeeds against a legacy-shaped mirror"
else
    test_fail "dx_backup_generation_migrate_legacy: succeeds against a legacy-shaped mirror"
fi
if [ "$(readlink "$LEGACY_UNIT_FIXTURE/current" 2>/dev/null)" = "generations/legacy-$legacy_unit_expected_epoch" ]; then
    test_pass "dx_backup_generation_migrate_legacy: current becomes a symlink to generations/legacy-<manifest mtime>"
else
    test_fail "dx_backup_generation_migrate_legacy: current becomes a symlink to generations/legacy-<manifest mtime> (got: $(readlink "$LEGACY_UNIT_FIXTURE/current" 2>/dev/null))"
fi
if diff -rq "$LEGACY_UNIT_FIXTURE/before-current" "$LEGACY_UNIT_FIXTURE/current" >/dev/null 2>&1; then
    test_pass "dx_backup_generation_migrate_legacy: the old content is carried byte-identical into the new generation"
else
    test_fail "dx_backup_generation_migrate_legacy: the old content is carried byte-identical into the new generation"
fi
if [ -f "$LEGACY_UNIT_FIXTURE/current/manifest.tsv" ] && [ "$(cat "$LEGACY_UNIT_FIXTURE/current/manifest.tsv")" = "$(printf 'home/dx/f.txt\t14\t0\tdeadbeef')" ]; then
    test_pass "dx_backup_generation_migrate_legacy: the old manifest moves inside the new generation"
else
    test_fail "dx_backup_generation_migrate_legacy: the old manifest moves inside the new generation"
fi
if [ ! -e "$LEGACY_UNIT_FIXTURE/manifest.tsv" ]; then
    test_pass "dx_backup_generation_migrate_legacy: the old top-level manifest.tsv no longer exists (moved, not copied)"
else
    test_fail "dx_backup_generation_migrate_legacy: the old top-level manifest.tsv no longer exists (moved, not copied)"
fi

# Idempotent: a second call against the now-migrated mirror is a no-op.
if dx_backup_generation_migrate_legacy "$LEGACY_UNIT_FIXTURE"; then
    test_pass "dx_backup_generation_migrate_legacy: a second call against an already-migrated mirror is a no-op"
else
    test_fail "dx_backup_generation_migrate_legacy: a second call against an already-migrated mirror is a no-op"
fi
if [ "$(readlink "$LEGACY_UNIT_FIXTURE/current" 2>/dev/null)" = "generations/legacy-$legacy_unit_expected_epoch" ]; then
    test_pass "dx_backup_generation_migrate_legacy: the second call does not re-migrate or change the pointer"
else
    test_fail "dx_backup_generation_migrate_legacy: the second call does not re-migrate or change the pointer"
fi
rm -rf "$LEGACY_UNIT_FIXTURE"

# A mirror with no current/ at all (the very first backup ever) is a no-op.
NOCURRENT_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-legacy-nocurrent-test.XXXXXX")"
if dx_backup_generation_migrate_legacy "$NOCURRENT_FIXTURE"; then
    test_pass "dx_backup_generation_migrate_legacy: a mirror with no current/ at all is a no-op"
else
    test_fail "dx_backup_generation_migrate_legacy: a mirror with no current/ at all is a no-op"
fi
rm -rf "$NOCURRENT_FIXTURE"

# A `current` that is neither a symlink nor a directory (some other,
# unrecognised shape) is refused loudly, exactly like
# dx_backup_generation_publish's own guard -- never silently mishandled.
WEIRDCURRENT_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-legacy-weird-test.XXXXXX")"
printf 'not a directory\n' > "$WEIRDCURRENT_FIXTURE/current"
set +e
dx_backup_generation_migrate_legacy "$WEIRDCURRENT_FIXTURE" 2>/dev/null
weird_rc=$?
set -e
if [ "$weird_rc" -ne 0 ] && [ -f "$WEIRDCURRENT_FIXTURE/current" ] && [ "$(cat "$WEIRDCURRENT_FIXTURE/current")" = "not a directory" ]; then
    test_pass "dx_backup_generation_migrate_legacy: refuses a current that is neither a symlink nor a directory, leaving it untouched"
else
    test_fail "dx_backup_generation_migrate_legacy: refuses a current that is neither a symlink nor a directory, leaving it untouched"
fi
rm -rf "$WEIRDCURRENT_FIXTURE"

# A legacy mirror with NO manifest.tsv at all (created but never completed a
# successful run) still migrates, falling back to legacy-<current time>.
NOMANIFEST_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-legacy-nomanifest-test.XXXXXX")"
mkdir -p "$NOMANIFEST_FIXTURE/current/home/dx"
printf 'x\n' > "$NOMANIFEST_FIXTURE/current/home/dx/f.txt"
if dx_backup_generation_migrate_legacy "$NOMANIFEST_FIXTURE"; then
    test_pass "dx_backup_generation_migrate_legacy: a legacy mirror with no manifest.tsv still migrates"
else
    test_fail "dx_backup_generation_migrate_legacy: a legacy mirror with no manifest.tsv still migrates"
fi
if readlink "$NOMANIFEST_FIXTURE/current" 2>/dev/null | grep -qE '^generations/legacy-[0-9]+$'; then
    test_pass "dx_backup_generation_migrate_legacy: falls back to legacy-<current time> with no manifest to read a timestamp from"
else
    test_fail "dx_backup_generation_migrate_legacy: falls back to legacy-<current time> with no manifest to read a timestamp from (got: $(readlink "$NOMANIFEST_FIXTURE/current" 2>/dev/null))"
fi
rm -rf "$NOMANIFEST_FIXTURE"

# Generation-id collision: a generation already exists at the exact id this
# legacy manifest's own timestamp would produce.
COLLIDE_LEGACY_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-legacy-collide-test.XXXXXX")"
mkdir -p "$COLLIDE_LEGACY_FIXTURE/current"
printf 'x\n' > "$COLLIDE_LEGACY_FIXTURE/current/f.txt"
: > "$COLLIDE_LEGACY_FIXTURE/manifest.tsv"
touch -t 202401031200 "$COLLIDE_LEGACY_FIXTURE/manifest.tsv"
# Same dx_pbs_stat_mtime reuse as the direct-unit-coverage case above.
collide_epoch="$(dx_pbs_stat_mtime "$COLLIDE_LEGACY_FIXTURE/manifest.tsv")"
mkdir -p "$COLLIDE_LEGACY_FIXTURE/generations/legacy-$collide_epoch"
set +e
dx_backup_generation_migrate_legacy "$COLLIDE_LEGACY_FIXTURE" 2>/dev/null
collide_rc=$?
set -e
if [ "$collide_rc" -ne 0 ] && [ ! -L "$COLLIDE_LEGACY_FIXTURE/current" ]; then
    test_pass "dx_backup_generation_migrate_legacy: refuses when the derived legacy generation id already exists"
else
    test_fail "dx_backup_generation_migrate_legacy: refuses when the derived legacy generation id already exists"
fi
rm -rf "$COLLIDE_LEGACY_FIXTURE"

# --- Migration runs under the backup lock: a legacy-shaped mirror
# contended by another process (lock pre-held, exactly like the earlier
# RED 3 lock-contention case) is left in its legacy shape entirely
# untouched -- migration never gets a chance to run without the lock. ---
LEGACY_LOCK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-legacy-lock-test.XXXXXX")"
LEGACY_LOCK_BACKUP_DIR="$LEGACY_LOCK_ROOT/backups"
LEGACY_LOCK_MIRROR="$LEGACY_LOCK_BACKUP_DIR/test-container"
mkdir -p "$LEGACY_LOCK_MIRROR/current/home/dx"
printf 'legacy-lock-content\n' > "$LEGACY_LOCK_MIRROR/current/home/dx/f.txt"
printf 'home/dx/f.txt\t20\t0\tdeadbeef\n' > "$LEGACY_LOCK_MIRROR/manifest.tsv"
fake_tool_write "$FAKE_DIR" fake-sleep 'exit 0'
dx_lock_acquire "$LEGACY_LOCK_MIRROR/.lock" 1
set +e
legacy_lock_out="$(DX_BACKUP_DIR="$LEGACY_LOCK_BACKUP_DIR" DX_SLEEP=fake-sleep "$BASE_DIR/bin/dx-backup" 2>&1)"
legacy_lock_rc=$?
set -e
dx_lock_release "$LEGACY_LOCK_MIRROR/.lock"
if [ "$legacy_lock_rc" -ne 0 ]; then
    test_pass "Astra F5 / WP6.9: dx-backup against a legacy mirror refuses when the lock is contended"
else
    test_fail "Astra F5 / WP6.9: dx-backup against a legacy mirror refuses when the lock is contended (got: $legacy_lock_out)"
fi
if [ -d "$LEGACY_LOCK_MIRROR/current" ] && [ ! -L "$LEGACY_LOCK_MIRROR/current" ] && [ ! -d "$LEGACY_LOCK_MIRROR/generations" ]; then
    test_pass "Astra F5 / WP6.9: a contended legacy mirror is left in its legacy shape -- migration never ran without the lock"
else
    test_fail "Astra F5 / WP6.9: a contended legacy mirror is left in its legacy shape -- migration never ran without the lock"
fi
rm -rf "$LEGACY_LOCK_ROOT"

# --- End-to-end: a legacy-shaped mirror, run through the real dx-backup
# entrypoint once. The guest has ONE additional change beyond what the
# legacy manifest recorded, so this single real run both migrates the
# legacy content in place AND publishes a fresh generation on top of it,
# retaining the legacy generation as the one before -- exactly the sequence
# dx-host's own real mirror needs on its first post-upgrade backup. The old
# manifest is captured by really running the selector against the
# fixture (dx_backup_fetch_listing, already sourced/exported above) rather
# than hand-computing a hash, so the unchanged file's recorded line is
# guaranteed byte-identical to what a fresh listing produces for it --
# otherwise it would misclassify as "changed" and never exercise carrying a
# file forward from the newly-adopted legacy generation. ---
E2E_LEGACY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-f5-legacy-e2e-test.XXXXXX")"
E2E_LEGACY_PERSIST="$E2E_LEGACY_ROOT/persist"
E2E_LEGACY_BACKUP_DIR="$E2E_LEGACY_ROOT/backups"
E2E_LEGACY_MIRROR="$E2E_LEGACY_BACKUP_DIR/test-container"
mkdir -p "$E2E_LEGACY_PERSIST/home/dx" "$E2E_LEGACY_MIRROR/current/home/dx"
printf 'legacy-unchanged\n' > "$E2E_LEGACY_PERSIST/home/dx/unchanged.txt"
printf 'legacy-old-content\n' > "$E2E_LEGACY_PERSIST/home/dx/changed.txt"

fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$E2E_LEGACY_PERSIST"'"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container; exit 0 ;;
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
export DX_CONTAINER_NAME=test-container
dx_backup_fetch_listing "$DX_CONTAINER_NAME" > "$E2E_LEGACY_ROOT/real-listing.tsv"
LC_ALL=C sort "$E2E_LEGACY_ROOT/real-listing.tsv" > "$E2E_LEGACY_MIRROR/manifest.tsv"
cp "$E2E_LEGACY_PERSIST/home/dx/unchanged.txt" "$E2E_LEGACY_MIRROR/current/home/dx/unchanged.txt"
cp "$E2E_LEGACY_PERSIST/home/dx/changed.txt" "$E2E_LEGACY_MIRROR/current/home/dx/changed.txt"
# The snapshot includes manifest.tsv too (copied alongside, matching where
# migration will place it inside the legacy generation): the
# "byte-identical" comparison below is over the WHOLE generation directory
# as migration leaves it, not just the pre-existing file tree.
cp -R "$E2E_LEGACY_MIRROR/current/" "$E2E_LEGACY_ROOT/before-legacy-current/"
cp "$E2E_LEGACY_MIRROR/manifest.tsv" "$E2E_LEGACY_ROOT/before-legacy-current/manifest.tsv"
e2e_legacy_manifest_before="$(cat "$E2E_LEGACY_MIRROR/manifest.tsv")"

printf 'legacy-new-content\n' > "$E2E_LEGACY_PERSIST/home/dx/changed.txt"

set +e
e2e_legacy_out="$(DX_BACKUP_DIR="$E2E_LEGACY_BACKUP_DIR" "$BASE_DIR/bin/dx-backup" 2>&1)"
e2e_legacy_rc=$?
set -e
if [ "$e2e_legacy_rc" -eq 0 ]; then
    test_pass "Astra F5 / WP6.9: dx-backup succeeds against a pre-existing legacy-shaped mirror"
else
    test_fail "Astra F5 / WP6.9: dx-backup succeeds against a pre-existing legacy-shaped mirror (got: $e2e_legacy_out)"
fi

e2e_current_target="$(readlink "$E2E_LEGACY_MIRROR/current" 2>/dev/null || true)"
e2e_gen_names="$(find "$E2E_LEGACY_MIRROR/generations" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's#.*/##' | LC_ALL=C sort)"
e2e_gen_count="$(printf '%s\n' "$e2e_gen_names" | grep -c . || true)"
if [ "$e2e_gen_count" -eq 2 ]; then
    test_pass "Astra F5 / WP6.9: exactly two generations are retained (the legacy one plus the new one)"
else
    test_fail "Astra F5 / WP6.9: exactly two generations are retained (the legacy one plus the new one) (found: $e2e_gen_names)"
fi
e2e_legacy_gen_name="$(printf '%s\n' "$e2e_gen_names" | grep '^legacy-' || true)"
if [ -n "$e2e_legacy_gen_name" ]; then
    test_pass "Astra F5 / WP6.9: the legacy generation is retained under its legacy-<id> name"
else
    test_fail "Astra F5 / WP6.9: the legacy generation is retained under its legacy-<id> name (found: $e2e_gen_names)"
fi
if [ -n "$e2e_current_target" ] && [ "$e2e_current_target" != "generations/$e2e_legacy_gen_name" ]; then
    test_pass "Astra F5 / WP6.9: current ends up on the NEW generation, not the legacy one, after a run with a real change"
else
    test_fail "Astra F5 / WP6.9: current ends up on the NEW generation, not the legacy one, after a run with a real change (current -> $e2e_current_target)"
fi
if [ -n "$e2e_legacy_gen_name" ] && diff -rq "$E2E_LEGACY_ROOT/before-legacy-current" "$E2E_LEGACY_MIRROR/generations/$e2e_legacy_gen_name" >/dev/null 2>&1; then
    test_pass "Astra F5 / WP6.9: the legacy generation's own content is byte-identical to the pre-migration mirror"
else
    test_fail "Astra F5 / WP6.9: the legacy generation's own content is byte-identical to the pre-migration mirror"
fi
if [ -n "$e2e_legacy_gen_name" ] && [ "$(cat "$E2E_LEGACY_MIRROR/generations/$e2e_legacy_gen_name/manifest.tsv" 2>/dev/null)" = "$e2e_legacy_manifest_before" ]; then
    test_pass "Astra F5 / WP6.9: the legacy generation holds the exact old manifest"
else
    test_fail "Astra F5 / WP6.9: the legacy generation holds the exact old manifest"
fi
if [ "$(cat "$E2E_LEGACY_MIRROR/current/home/dx/changed.txt" 2>/dev/null)" = legacy-new-content ]; then
    test_pass "Astra F5 / WP6.9: the changed file is correctly fetched into the new generation"
else
    test_fail "Astra F5 / WP6.9: the changed file is correctly fetched into the new generation"
fi
if [ "$(cat "$E2E_LEGACY_MIRROR/current/home/dx/unchanged.txt" 2>/dev/null)" = legacy-unchanged ]; then
    test_pass "Astra F5 / WP6.9: the unchanged file is correctly carried forward from the legacy generation into the new one"
else
    test_fail "Astra F5 / WP6.9: the unchanged file is correctly carried forward from the legacy generation into the new one"
fi
rm -rf "$E2E_LEGACY_ROOT"

print_summary
exit_with_code
