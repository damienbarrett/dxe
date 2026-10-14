#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail
# WP-TAR: every tar extractor that reads a pipe must drain it.
#
# The defect: bsdtar (macOS, libarchive 3.7.4) stops extracting at the
# end-of-archive marker and exits without reading the trailing padding its
# creator writes to fill the last record. The creator's final write then
# fails with EPIPE ("tar: Write error"), and under `set -o pipefail` a
# complete, correct transfer is reported as a failure. The established fix is
# in bin/lib/dx-bootstrap-sync.sh: after a SUCCESSFUL extract, `cat
# >/dev/null` consumes what the extractor left behind.
#
# Sites covered (behaviour only; nothing here reads production source):
#   1. dx_backup_fetch_paths   guest tar -cf -  |  HOST  tar -xf -
#   2. dx_backup_restore_push  host  tar -cf -  |  GUEST tar -xf -
#   3. bin/dx-get (both directory forms)  guest tar -cf - | HOST tar -xf -
#   4. bin/dx-put (both directory forms)  host tar -cf -   | GUEST tar -xf -
# Left out on purpose: container/.../base-and-storage.sh's import tar pipe.
# Both ends there run inside the guest and are GNU tar, which reads whole
# 10240-byte records, and the creator pads to exactly such a record, so
# nothing can be left unread; and it is not fed by curl. (dx-get has no curl
# either: it is a guest tar pipe.)
#
# Fakes. A `container` fake runs `exec [-i] [-u U] NAME CMD...` for real in a
# fixture directory standing in for the guest ($DX_FAKE_GUEST_ROOT; any
# `/persist` inside an argument is remapped to $DX_FAKE_GUEST_ROOT/persist).
# A `tar` wrapper on PATH (host and "guest" are the same machine here) calls
# the real tar and is steered by environment:
#   DX_FAKE_TAR_PAD_BYTES=N  a creator (-cf) writes N extra zero bytes after
#                            its valid archive; N is far above any pipe
#                            buffer, so a creator whose reader exits at the
#                            end-of-archive marker CANNOT finish: it prints
#                            "tar: Write error" and exits 1, like bsdtar.
#   DX_FAKE_TAR_XFAIL=1      an extractor prints "tar: Unexpected EOF in
#                            archive" and exits 2 WITHOUT reading stdin.
#   DX_FAKE_TAR_GARBAGE=1    a creator emits 1024 bytes of "x" (not a tar
#                            archive) so the REAL extractor must fail.
#
# Interface contract (behaviour; function names are unchanged):
#   - dx_backup_fetch_paths CONTAINER DEST LIST: the HOST extractor drains
#     after a successful extract. Returns 0 on a padded valid stream. When the
#     extract fails the function returns the extractor's status (2 in the
#     XFAIL case), never 0, and the extractor's stderr still reaches the
#     caller's stderr.
#   - dx_backup_restore_push CONTAINER BACKUPDIR TARGETS: the GUEST command
#     becomes a small `sh -c` program that extracts then drains, and it must
#     receive the guest root as a separate positional argument (e.g.
#     `sh -c 'tar -xf - -C "$1" && cat >/dev/null' -- "$DX_BACKUP_GUEST_ROOT"`)
#     so that the existing fakes' exact-argument `/persist` remap keeps
#     working. The program text must contain the words "tar -xf" (the
#     ship-failure fake in tests/test_dx_restore.sh lets exactly such an sh
#     program through and refuses every other `sh`). The exec keeps `-i -u dx`. A failed extract makes the function
#     return the extractor's status (2), unmasked by the drain.
#   - bin/dx-get DIR forms: the host extractor drains after a successful
#     extract; a failed extract exits non-zero (2 here).
#   - bin/dx-put DIR forms: the guest extractor drains like restore push; a
#     failed extract exits non-zero (2 here). dx-put is included because it
#     is the same class as restore push (not named in the WP text).
#   - The drain runs ONLY after a successful extract (use `&&`, not `;`).
#   - No stderr text "Write error" / "Broken pipe" on a successful transfer.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=../bin/lib/dx-backup.sh
source "$BASE_DIR/bin/lib/dx-backup.sh"
# shellcheck source=../bin/lib/dx-runtime.sh
source "$BASE_DIR/bin/lib/dx-runtime.sh"
test_section "WP-TAR: tar extractors drain their pipes"

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-tar-drain-test.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

REAL_TAR="$(command -v tar)"
FAKE_DIR="$(fake_tool_dir_create "$FIXTURE")"
GUEST_ROOT="$FIXTURE/guest"
mkdir -p "$GUEST_ROOT/persist" "$FIXTURE/home"
PAD=2097152

fake_tool_write "$FAKE_DIR" container '
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container; exit 0 ;;
esac
if [ "${1:-}" = exec ]; then
    shift
    [ "${1:-}" != -i ] || shift
    if [ "${1:-}" = -u ]; then shift; shift; fi
    shift
    cd "$DX_FAKE_GUEST_ROOT" || exit 1
    args=()
    for a in "$@"; do args+=("${a//\/persist/$DX_FAKE_GUEST_ROOT/persist}"); done
    exec "${args[@]}"
fi
exit 1
'
fake_tool_write "$FAKE_DIR" chown 'exit 0'
fake_tool_write "$FAKE_DIR" tar '
real_tar="'"$REAL_TAR"'"
creator=0
args=()
for a in "$@"; do
    case "$a" in
        -cf) creator=1 ;;
        --hard-dereference) continue ;;
    esac
    args+=("$a")
done
if [ "$creator" -eq 1 ]; then
    if [ "${DX_FAKE_TAR_GARBAGE:-0}" = 1 ]; then
        head -c 1024 /dev/zero | tr "\0" x
        exit 0
    fi
    "$real_tar" "${args[@]}" || exit $?
    if [ "${DX_FAKE_TAR_PAD_BYTES:-0}" -gt 0 ]; then
        head -c "$DX_FAKE_TAR_PAD_BYTES" /dev/zero || { echo "tar: Write error" >&2; exit 1; }
    fi
    exit 0
fi
if [ "${DX_FAKE_TAR_XFAIL:-0}" = 1 ]; then
    echo "tar: Unexpected EOF in archive" >&2
    exit 2
fi
exec "$real_tar" "${args[@]}"
'

export PATH="$FAKE_DIR:$PATH"
export HOME="$FIXTURE/home"
export DX_CONTAINER_NAME=test-container
export DX_FAKE_GUEST_ROOT="$GUEST_ROOT"
unset DX_FAKE_TAR_PAD_BYTES DX_FAKE_TAR_XFAIL DX_FAKE_TAR_GARBAGE

# Succeeded cleanly: rc 0, no pipe-failure text on stderr.
clean_stderr() {
    ! grep -Eq 'Write error|Broken pipe|Error exit delayed' "$1"
}

# --- Site 1: dx_backup_fetch_paths (host extractor) -------------------------
mkdir -p "$GUEST_ROOT/persist/home/dx"
printf 'alpha content\n' > "$GUEST_ROOT/persist/home/dx/alpha.txt"
FETCH_LIST="$FIXTURE/fetch.tsv"
printf 'home/dx/alpha.txt\t14\n' > "$FETCH_LIST"

fetch_run() { # dest stderr-file; remaining env is set by the caller
    (set -o pipefail; dx_backup_fetch_paths test-container "$1" "$FETCH_LIST" 2>"$2")
}

dest="$FIXTURE/fetch-ok"; err="$FIXTURE/fetch-ok.err"
DX_FAKE_TAR_PAD_BYTES=$PAD fetch_run "$dest" "$err"; rc=$?
if [ "$rc" -eq 0 ]; then test_pass "fetch_paths: a valid archive followed by 2 MiB of padding succeeds"; else test_fail "fetch_paths: a valid archive followed by 2 MiB of padding succeeds (rc=$rc err=$(cat "$err"))"; fi
if [ "$(cat "$dest/home/dx/alpha.txt" 2>/dev/null)" = "alpha content" ]; then test_pass "fetch_paths: the padded transfer extracted the file with the right content"; else test_fail "fetch_paths: the padded transfer extracted the file with the right content"; fi
if clean_stderr "$err"; then test_pass "fetch_paths: the padded transfer prints no Write error / Broken pipe"; else test_fail "fetch_paths: the padded transfer prints no Write error / Broken pipe (err=$(cat "$err"))"; fi

dest="$FIXTURE/fetch-xfail"; err="$FIXTURE/fetch-xfail.err"
DX_FAKE_TAR_XFAIL=1 fetch_run "$dest" "$err"; rc=$?
if [ "$rc" -eq 2 ]; then test_pass "fetch_paths: a failed extract returns the extractor's status (the drain does not mask it)"; else test_fail "fetch_paths: a failed extract returns the extractor's status 2 (rc=$rc)"; fi
if grep -Fq 'Unexpected EOF in archive' "$err"; then test_pass "fetch_paths: the extractor's error still reaches stderr"; else test_fail "fetch_paths: the extractor's error still reaches stderr (err=$(cat "$err"))"; fi
if [ ! -e "$dest/home/dx/alpha.txt" ]; then test_pass "fetch_paths: a failed extract leaves no file behind"; else test_fail "fetch_paths: a failed extract leaves no file behind"; fi

dest="$FIXTURE/fetch-garbage"; err="$FIXTURE/fetch-garbage.err"
DX_FAKE_TAR_GARBAGE=1 fetch_run "$dest" "$err"; rc=$?
if [ "$rc" -ne 0 ]; then test_pass "fetch_paths: a stream that is not a tar archive fails the transfer"; else test_fail "fetch_paths: a stream that is not a tar archive fails the transfer"; fi
if [ ! -e "$dest/home/dx/alpha.txt" ]; then test_pass "fetch_paths: a garbage stream extracts nothing"; else test_fail "fetch_paths: a garbage stream extracts nothing"; fi

# --- Site 2: dx_backup_restore_push (guest extractor) -----------------------
BACKUP="$FIXTURE/backups/test-container"
mkdir -p "$BACKUP/current/a/b"
printf 'one\n' > "$BACKUP/current/a/b/one.txt"
TARGETS="$FIXTURE/targets.txt"
printf 'a/b/one.txt\n' > "$TARGETS"

push_run() { # stderr-file
    (set -o pipefail; dx_backup_restore_push test-container "$BACKUP" "$TARGETS" 2>"$1")
}

rm -rf "${GUEST_ROOT:?}/persist/a"
err="$FIXTURE/push-ok.err"
DX_FAKE_TAR_PAD_BYTES=$PAD push_run "$err"; rc=$?
if [ "$rc" -eq 0 ]; then test_pass "restore_push: a valid archive followed by 2 MiB of padding succeeds"; else test_fail "restore_push: a valid archive followed by 2 MiB of padding succeeds (rc=$rc err=$(cat "$err"))"; fi
if [ "$(cat "$GUEST_ROOT/persist/a/b/one.txt" 2>/dev/null)" = one ]; then test_pass "restore_push: the padded transfer extracted the file with the right content"; else test_fail "restore_push: the padded transfer extracted the file with the right content"; fi
if clean_stderr "$err"; then test_pass "restore_push: the padded transfer prints no Write error / Broken pipe"; else test_fail "restore_push: the padded transfer prints no Write error / Broken pipe (err=$(cat "$err"))"; fi

rm -rf "${GUEST_ROOT:?}/persist/a"
err="$FIXTURE/push-xfail.err"
DX_FAKE_TAR_XFAIL=1 push_run "$err"; rc=$?
if [ "$rc" -eq 2 ]; then test_pass "restore_push: a failed extract returns the extractor's status (the drain does not mask it)"; else test_fail "restore_push: a failed extract returns the extractor's status 2 (rc=$rc)"; fi
if grep -Fq 'Unexpected EOF in archive' "$err"; then test_pass "restore_push: the extractor's error still reaches stderr"; else test_fail "restore_push: the extractor's error still reaches stderr (err=$(cat "$err"))"; fi
if [ ! -e "$GUEST_ROOT/persist/a/b/one.txt" ]; then test_pass "restore_push: a failed extract leaves no file behind"; else test_fail "restore_push: a failed extract leaves no file behind"; fi

# --- Sites 3 and 4: bin/dx-get and bin/dx-put -------------------------------
mkdir -p "$GUEST_ROOT/adir/sub"
printf 'file content' > "$GUEST_ROOT/adir/sub/leaf.txt"

# --- dx-get: into an existing/trailing-slash destination, and "copy as" ---
for form in into as; do
    if [ "$form" = into ]; then dest="$FIXTURE/get-$form/"; leaf="$FIXTURE/get-$form/adir/sub/leaf.txt"; else dest="$FIXTURE/get-$form"; leaf="$FIXTURE/get-$form/sub/leaf.txt"; fi
    err="$FIXTURE/get-$form.err"
    DX_FAKE_TAR_PAD_BYTES=$PAD "$BASE_DIR/bin/dx-get" adir "$dest" >/dev/null 2>"$err"; rc=$?
    if [ "$rc" -eq 0 ]; then test_pass "dx-get ($form): a valid archive followed by 2 MiB of padding succeeds"; else test_fail "dx-get ($form): a valid archive followed by 2 MiB of padding succeeds (rc=$rc err=$(cat "$err"))"; fi
    if [ "$(cat "$leaf" 2>/dev/null)" = "file content" ]; then test_pass "dx-get ($form): the padded transfer extracted the right content"; else test_fail "dx-get ($form): the padded transfer extracted the right content"; fi
    if clean_stderr "$err"; then test_pass "dx-get ($form): the padded transfer prints no Write error / Broken pipe"; else test_fail "dx-get ($form): the padded transfer prints no Write error / Broken pipe (err=$(cat "$err"))"; fi

    if [ "$form" = into ]; then dest="$FIXTURE/getx-$form/"; leaf="$FIXTURE/getx-$form/adir/sub/leaf.txt"; else dest="$FIXTURE/getx-$form"; leaf="$FIXTURE/getx-$form/sub/leaf.txt"; fi
    err="$FIXTURE/getx-$form.err"
    DX_FAKE_TAR_XFAIL=1 "$BASE_DIR/bin/dx-get" adir "$dest" >/dev/null 2>"$err"; rc=$?
    if [ "$rc" -eq 2 ]; then test_pass "dx-get ($form): a failed extract exits with the extractor's status"; else test_fail "dx-get ($form): a failed extract exits with the extractor's status 2 (rc=$rc)"; fi
    if grep -Fq 'Unexpected EOF in archive' "$err"; then test_pass "dx-get ($form): the extractor's error still reaches stderr"; else test_fail "dx-get ($form): the extractor's error still reaches stderr (err=$(cat "$err"))"; fi
    if [ ! -e "$leaf" ]; then test_pass "dx-get ($form): a failed extract leaves no file behind"; else test_fail "dx-get ($form): a failed extract leaves no file behind"; fi
done

# --- dx-put: into a trailing-slash destination, and "copy as" ---
SRC="$FIXTURE/put-src"
mkdir -p "$SRC/sub"
printf 'alpha' > "$SRC/sub/one.txt"
for form in into as; do
    if [ "$form" = into ]; then dest="put-$form/"; leaf="$GUEST_ROOT/put-$form/put-src/sub/one.txt"; else dest="put-$form"; leaf="$GUEST_ROOT/put-$form/sub/one.txt"; fi
    err="$FIXTURE/put-$form.err"
    DX_FAKE_TAR_PAD_BYTES=$PAD "$BASE_DIR/bin/dx-put" "$SRC" "$dest" >/dev/null 2>"$err"; rc=$?
    if [ "$rc" -eq 0 ]; then test_pass "dx-put ($form): a valid archive followed by 2 MiB of padding succeeds"; else test_fail "dx-put ($form): a valid archive followed by 2 MiB of padding succeeds (rc=$rc err=$(cat "$err"))"; fi
    if [ "$(cat "$leaf" 2>/dev/null)" = alpha ]; then test_pass "dx-put ($form): the padded transfer extracted the right content"; else test_fail "dx-put ($form): the padded transfer extracted the right content"; fi
    if clean_stderr "$err"; then test_pass "dx-put ($form): the padded transfer prints no Write error / Broken pipe"; else test_fail "dx-put ($form): the padded transfer prints no Write error / Broken pipe (err=$(cat "$err"))"; fi

    if [ "$form" = into ]; then dest="putx-$form/"; leaf="$GUEST_ROOT/putx-$form/put-src/sub/one.txt"; else dest="putx-$form"; leaf="$GUEST_ROOT/putx-$form/sub/one.txt"; fi
    err="$FIXTURE/putx-$form.err"
    DX_FAKE_TAR_XFAIL=1 "$BASE_DIR/bin/dx-put" "$SRC" "$dest" >/dev/null 2>"$err"; rc=$?
    if [ "$rc" -eq 2 ]; then test_pass "dx-put ($form): a failed extract exits with the extractor's status"; else test_fail "dx-put ($form): a failed extract exits with the extractor's status 2 (rc=$rc)"; fi
    if grep -Fq 'Unexpected EOF in archive' "$err"; then test_pass "dx-put ($form): the extractor's error still reaches stderr"; else test_fail "dx-put ($form): the extractor's error still reaches stderr (err=$(cat "$err"))"; fi
    if [ ! -e "$leaf" ]; then test_pass "dx-put ($form): a failed extract leaves no file behind"; else test_fail "dx-put ($form): a failed extract leaves no file behind"; fi
done

print_summary
exit_with_code
