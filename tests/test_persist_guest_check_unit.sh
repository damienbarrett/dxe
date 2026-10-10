#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
set -euo pipefail

# WP4.5 (implementer unit cases): the guest /persist check
# (container/dx-nixos-26.05/bootstrap/persistence.sh's
# dx_persist_storage_check, which setup_persist runs before any change) beyond what the
# acceptance suite (tests/test_persist_guest_check.sh) pins:
#   - a marker path that is not a regular file (directory, symlink, dangling
#     symlink, FIFO) is refused as malformed and never read through or
#     blocked on;
#   - a mount-point tool's own stderr never adds a second line;
#   - the host-path success line;
#   - constitution rule 3: the `mountpoint` stub is validated against the
#     real tool where one exists (Linux CI and the kcov image), and a host
#     without the tool fails closed.
# Every mutating command is a recording stub in each run; all file activity
# stays inside $TMP_ROOT.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/fake-tools.sh
source "$SCRIPT_DIR/lib/fake-tools.sh"
test_section "WP4.5: guest /persist check (unit)"

BOOTSTRAP_DIR="$CONTAINER_DIR/bootstrap"

TMP_RAW="$(mktemp -d "${TMPDIR:-/tmp}/dxe-persist-guest-unit.XXXXXX")" || exit 1
TMP_ROOT="$(cd "$TMP_RAW" && pwd -P)" || exit 1
gu_cleanup() {
    case "$TMP_ROOT" in
        */dxe-persist-guest-unit.??????)
            if [ -d "$TMP_ROOT" ] && [ ! -L "$TMP_ROOT" ]; then
                rm -rf -- "$TMP_ROOT"
            fi
            ;;
    esac
}
trap gu_cleanup EXIT

# shellcheck source=../container/dx-nixos-26.05/bootstrap/common.sh
source "$BOOTSTRAP_DIR/common.sh"
# shellcheck source=../container/dx-nixos-26.05/bootstrap/persistence.sh
source "$BOOTSTRAP_DIR/persistence.sh"

GUEST=dx-unit
GU_STUB_BIN="$TMP_ROOT/stub-bin"
for gu_name in chown chmod chgrp install mkdir mv rm ln touch cp find; do
    fake_tool_write "$GU_STUB_BIN" "$gu_name" 'printf "%s %s\n" "${0##*/}" "$*" >>"$GU_CALLS"
exit 0'
done

# Called inside a subshell only: every mutating command records instead of
# acting, and there is no dx account.
gu_define_recorders() {
    chown() { printf 'chown %s\n' "$*" >>"$GU_CALLS"; }
    chmod() { printf 'chmod %s\n' "$*" >>"$GU_CALLS"; }
    chgrp() { printf 'chgrp %s\n' "$*" >>"$GU_CALLS"; }
    install() { printf 'install %s\n' "$*" >>"$GU_CALLS"; }
    mkdir() { printf 'mkdir %s\n' "$*" >>"$GU_CALLS"; }
    mv() { printf 'mv %s\n' "$*" >>"$GU_CALLS"; }
    rm() { printf 'rm %s\n' "$*" >>"$GU_CALLS"; }
    ln() { printf 'ln %s\n' "$*" >>"$GU_CALLS"; }
    touch() { printf 'touch %s\n' "$*" >>"$GU_CALLS"; }
    cp() { printf 'cp %s\n' "$*" >>"$GU_CALLS"; }
    find() { printf 'find %s\n' "$*" >>"$GU_CALLS"; }
    id() {
        case " $* " in
            *" dx "*) return 1 ;;
        esac
        command id "$@"
    }
    PATH="$GU_STUB_BIN:$PATH"
}

gu_new_case() { # NAME -> GU_DIR, GU_ROOT, GU_MARKER (a fresh, real directory)
    GU_DIR="$TMP_ROOT/cases/$1"
    GU_ROOT="$GU_DIR/persist"
    GU_MARKER="$GU_ROOT/.dxe-persist-dir"
    command mkdir -p "$GU_ROOT" "$GU_DIR/log"
    : >"$GU_DIR/log/calls"
}

# gu_run DIR FUNCTION ROOT MOUNTPOINT_MODE
#   MOUNTPOINT_MODE: "mounted" (a stub that says ROOT is a mount point),
#   "noisy" (a stub that fails and writes its own stderr line), or "real"
#   (no stub: whatever `mountpoint` this host has, if any).
gu_run() {
    local dir="$1" fn="$2" root="$3" probe="$4"
    (
        set +e
        export DX_PERSIST_STORAGE=host-path DX_PERSIST_DIR_GUEST="$GUEST"
        export GU_CALLS="$dir/log/calls"
        gu_define_recorders
        case "$probe" in
            mounted) mountpoint() { return 0; } ;;
            noisy) mountpoint() { echo "mountpoint: $*: unexpected failure" >&2; return 1; } ;;
            real) : ;;
        esac
        "$fn" "$root" </dev/null >"$dir/log/out" 2>"$dir/log/err"
        printf '%s\n' "$?" >"$dir/log/rc"
    ) || true
}

# gu_expect_refusal LABEL DIR PHRASE: non-zero, nothing on stdout, exactly one
# stderr line starting "Error: " and containing PHRASE, no mutating call.
gu_expect_refusal() {
    local label="$1" dir="$2" phrase="$3" problems="" line
    [ "$(cat "$dir/log/rc" 2>/dev/null)" != 0 ] || problems="$problems returned 0;"
    [ -f "$dir/log/rc" ] || problems="$problems did not return;"
    [ ! -s "$dir/log/out" ] || problems="$problems stdout not empty;"
    [ "$(awk 'END { print NR }' "$dir/log/err")" = 1 ] || problems="$problems stderr is not exactly one line;"
    line="$(head -n 1 "$dir/log/err")"
    case "$line" in
        "Error: "*"$phrase"*) : ;;
        *) problems="$problems the Error line lacks '$phrase';" ;;
    esac
    [ ! -s "$dir/log/calls" ] || problems="$problems a mutating command ran;"
    if [ -z "$problems" ]; then
        test_pass "$label"
    else
        test_fail "$label [$problems] (stderr: $(cat "$dir/log/err"); calls: $(tr '\n' ';' <"$dir/log/calls"))"
    fi
}

gu_ready_marker() { printf 'schema=1\nguest=%s\nstate=ready\n' "$GUEST"; }

# --- A marker that is not a regular file is malformed, never followed ------

gu_new_case marker-directory
command mkdir -p "$GU_MARKER"
gu_run "$GU_DIR" setup_persist "$GU_ROOT" mounted
gu_expect_refusal "a .dxe-persist-dir directory is refused as malformed, nothing changed" \
    "$GU_DIR" "$GU_MARKER is malformed"

gu_new_case marker-symlink
gu_ready_marker >"$GU_DIR/elsewhere"
command ln -s "$GU_DIR/elsewhere" "$GU_MARKER"
gu_run "$GU_DIR" setup_persist "$GU_ROOT" mounted
gu_expect_refusal "a symlinked marker is refused as malformed even when its target is a ready marker for this guest" \
    "$GU_DIR" "$GU_MARKER is malformed"

gu_new_case marker-dangling
command ln -s "$GU_DIR/nowhere" "$GU_MARKER"
gu_run "$GU_DIR" setup_persist "$GU_ROOT" mounted
gu_expect_refusal "a dangling marker symlink is malformed, not missing" \
    "$GU_DIR" "$GU_MARKER is malformed"

# A FIFO would block the boot forever if it were read. A background writer
# completes only if the check opens it for reading; the writer is killed
# afterwards either way, so this case cannot hang.
gu_new_case marker-fifo
mkfifo "$GU_MARKER"
(gu_ready_marker >"$GU_MARKER") &
gu_writer=$!
gu_run "$GU_DIR" setup_persist "$GU_ROOT" mounted
kill "$gu_writer" 2>/dev/null || true
wait "$gu_writer" 2>/dev/null || true
gu_expect_refusal "a FIFO marker is refused as malformed without being read" \
    "$GU_DIR" "$GU_MARKER is malformed"

# --- The mount-point tool's own output never adds a line -----------------

gu_new_case noisy-probe
gu_ready_marker >"$GU_MARKER"
gu_run "$GU_DIR" setup_persist "$GU_ROOT" noisy
gu_expect_refusal "a mount-point tool that fails noisily still yields exactly one Error line" \
    "$GU_DIR" "$GU_ROOT is not a mount point"

# --- Host-path success line -----------------------------------------------

gu_new_case success-line
gu_ready_marker >"$GU_MARKER"
gu_run "$GU_DIR" dx_persist_storage_check "$GU_ROOT" mounted
if [ "$(cat "$GU_DIR/log/rc")" = 0 ] && [ ! -s "$GU_DIR/log/err" ] && [ ! -s "$GU_DIR/log/calls" ] \
    && [ "$(awk 'END { print NR }' "$GU_DIR/log/out")" = 1 ] \
    && grep -Fq "$GU_ROOT" "$GU_DIR/log/out" && grep -Fqw "$GUEST" "$GU_DIR/log/out"; then
    test_pass "host-path success prints one stdout line naming the root and the guest, and changes nothing"
else
    test_fail "host-path success prints one stdout line naming the root and the guest, and changes nothing (rc $(cat "$GU_DIR/log/rc"); out: $(cat "$GU_DIR/log/out"); err: $(cat "$GU_DIR/log/err"))"
fi

# --- Constitution rule 3: the real mount-point tool -----------------------
# Only the read-only check runs here (never setup_persist), with recorders
# for every mutating command in place.

gu_new_case real-unmounted
gu_ready_marker >"$GU_MARKER"
gu_run "$GU_DIR" dx_persist_storage_check "$GU_ROOT" real
gu_expect_refusal "real probe: a fresh temporary directory is not a mount point (or, with no mountpoint tool, the probe fails closed)" \
    "$GU_DIR" "$GU_ROOT is not a mount point"

# /proc is a mount point on every Linux host and container and has no
# marker, so getting past the real probe shows up as the "missing" refusal.
gu_new_case real-mounted
gu_run "$GU_DIR" dx_persist_storage_check /proc real
if command -v mountpoint >/dev/null 2>&1 && [ -d /proc ]; then
    gu_expect_refusal "real probe: the real mountpoint reports /proc as a mount point, so the check reaches the marker" \
        "$GU_DIR" "/proc/.dxe-persist-dir is missing"
else
    gu_expect_refusal "real probe: with no mountpoint tool on this host even /proc fails closed at the probe" \
        "$GU_DIR" "/proc is not a mount point"
fi

print_summary
exit_with_code
