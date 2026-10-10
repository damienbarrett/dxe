#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP4.2 acceptance: NAS directory operations (plans/do D-6; spec R15-R17).
#
# Interface contract (pinned by this file; the implementation must match):
#
#   Declared in bin/lib/dx-runtime.sh (dispatching through dx_runtime_dispatch)
#   and implemented by BOTH adapters as dx_runtime_{apple,docker}_host_dir_<op>:
#     dx_runtime_host_dir_probe ROOT GUEST
#     dx_runtime_host_dir_create ROOT GUEST MARKER_TEXT
#     dx_runtime_host_dir_marker_write PATH MARKER_TEXT
#     dx_runtime_host_dir_usage PATH
#   The directory an operation works on is <ROOT>/dxe/<GUEST>/persist; the
#   marker is <that dir>/.dxe-persist-dir. ROOT and PATH may be relative: the
#   NAS shell resolves them from its own cwd (the NAS fake's cwd is the
#   fixture root). Newlines in ROOT, GUEST or PATH are unsupported.
#
#   Apple (DX_RUNTIME=apple): each op prints nothing on stdout, a line
#   containing "unsupported" on stderr, returns non-zero and makes NO call
#   (no container, ssh, ...).
#
#   Docker (DX_RUNTIME=docker-ssh): each op is exactly ONE ssh invocation
#   made through dx_runtime_docker_ssh_exec, i.e. the remote command string
#   is dx_runtime_docker_quote_argv of an argv whose first words are
#       sh -c <SCRIPT> sh <data words...>
#   where SCRIPT is a constant, SINGLE-LINE POSIX sh program that reads its
#   data from "$@" (ROOT, GUEST, PATH and the mount sentinel are separate
#   data words, never interpolated into SCRIPT). No remote command contains a
#   newline or a bash-only "$'...'" quote, and each passes `sh -n` (and
#   `dash -n` when dash exists). The marker TEXT is never an argv word: it is
#   sent on the ssh command's STDIN. The host validates TEXT first (it must
#   satisfy dx_persist_marker_parse); an invalid TEXT returns non-zero
#   without any ssh call.
#   Only POSIX/busybox-safe tools; the dir-state test does not follow links.
#
#   probe ROOT GUEST   stdout, exactly, then exit 0:
#       root=<canonical ROOT: cd -P -- ROOT && pwd -P in the NAS shell>
#       mounted=yes|no|unknown
#       state=absent|symlink|empty|nonempty
#       marker=absent|present
#       <the marker file's bytes verbatim, only when marker=present>
#     mounted is a FAIL-CLOSED signal (spec R15: the share root must be proven
#     mounted/unlocked before anything is created; an unmounted QTS volume can
#     leave an empty mount point). The sentinel is the controller variable
#     DX_PERSIST_HOST_MOUNT_SENTINEL, a config registry field (kind optname:
#     one file name, no "/", no ".."; default empty; set per private profile
#     like DX_PERSIST_HOST_ROOT; a name must not start with "." or "-").
#     Unset or empty: mounted=unknown (never yes). Configured: mounted=yes
#     iff <canonical ROOT>/<sentinel> exists as a REGULAR FILE (lstat; a
#     directory or a symlink, even to a file, gives no), else mounted=no.
#     The probe only reports facts; the POLICY (an existing marked directory
#     proves itself through its marker; creating a new directory requires
#     mounted=yes) belongs to WP4.3 and is not tested here.
#     state: symlink = the persist path is a symbolic link (even dangling; never
#     followed, so then marker=absent); empty = a directory with no entries
#     at all (dotfiles count as entries); nonempty = a directory with any
#     entry (the marker alone makes it nonempty); absent = nothing there.
#     An unusable ROOT (not a directory): non-zero, empty stdout, stderr
#     containing "not a directory".
#   MARKER_TEXT handling (create and marker_write): the file gets TEXT followed
#   by exactly one newline unless TEXT already ends with one (command
#   substitution strips it, so callers usually pass it without), and the same
#   bytes are what is sent on stdin.
#   create ROOT GUEST MARKER_TEXT   makes dxe, dxe/<GUEST>, dxe/<GUEST>/persist
#     under the existing ROOT (never ROOT itself) and the marker (temp file
#     in the same directory + mv, text from stdin), nothing else. Prints
#     nothing on stdout. Refuses (non-zero, stderr containing "exists",
#     existing content untouched) when <ROOT>/dxe/<GUEST>/persist already
#     exists in any form; refuses a missing ROOT (stderr "not a directory",
#     nothing created).
#   marker_write PATH MARKER_TEXT   PATH is the persist directory. Replaces
#     PATH/.dxe-persist-dir atomically: temp file in PATH, then `mv` (found
#     through PATH) onto the marker; if mv fails the old marker is intact,
#     no temp file is left and the status is non-zero. A PATH that is not a
#     directory: non-zero, nothing created.
#   usage PATH   stdout is byte-for-byte what `du -sk -- PATH` prints in the
#     NAS shell (KiB, tab, PATH as given); a missing PATH: non-zero, empty
#     stdout.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-persist-dir.sh"

test_section "WP4.2: NAS directory operations"

SCRATCH="$(persist_fixture_root_create)"
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac

unset DX_PERSIST_HOST_MOUNT_SENTINEL
NL='
'
MARKER_NAME=".dxe-persist-dir"
GUEST="dx-fix"
MARKER_TEXT="$(dx_persist_marker_format "$GUEST" ready "" 2026-10-11T08:00:00Z)"
MARKER_TEXT_B="$(dx_persist_marker_format "$GUEST" retired "" 2026-10-11T08:00:00Z "" 2026-10-12T09:30:00Z)"

check() { # LABEL CMD...
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then test_pass "$label"; else test_fail "$label"; fi
}
check_not() { # LABEL CMD...
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then test_fail "$label"; else test_pass "$label"; fi
}
eq() { # LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (expected [$2], got [$3])"; fi
}
has() { # LABEL FILE FIXED-STRING  (single-line needle)
    if grep -Fq -- "$3" "$2" 2>/dev/null; then test_pass "$1"; else test_fail "$1 (no [$3] in $2)"; fi
}
file_eq() { # LABEL FILE EXPECTED-TEXT
    local want="$SCRATCH/.want"
    printf '%s' "$3" >"$want"
    if cmp -s "$want" "$2"; then test_pass "$1"; else test_fail "$1 (got: $(cat "$2" 2>/dev/null))"; fi
}
physical() { (cd -P -- "$1" && pwd -P); }
file_eq_out() { file_eq "$1" "$3" "$2"; }

# --- NAS fake with a recording ssh in front --------------------------------
ROOT0="$(persist_fixture_root_create "$SCRATCH")"
TOOLS="$(persist_fixture_nas_create "$ROOT0" "$SCRATCH")"
REC="$SCRATCH/rec-bin"
RECLOG="$SCRATCH/rec-log"
mkdir -p "$REC" "$RECLOG"
fake_tool_write "$REC" ssh 'd="${DXE_REC_DIR:?}"
n=1
while [ -e "$d/$n.cmd" ]; do n=$((n+1)); done
last=""
for a in "$@"; do last="$a"; done
printf "%s" "$last" > "$d/$n.cmd"
/bin/cat > "$d/$n.stdin.tmp"
/bin/mv "$d/$n.stdin.tmp" "$d/$n.stdin"
exec "${DXE_REC_REAL_SSH:?}" "$@" < "$d/$n.stdin"'
STUBS="$SCRATCH/stub-bin"
mkdir -p "$STUBS"

# nas CMD...: run a runtime op against the docker-ssh adapter + the NAS fake.
nas() {
    (
        export DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$PERSIST_FIXTURE_NAS_HOST"
        export DXE_REC_DIR="$RECLOG" DXE_REC_REAL_SSH="$TOOLS/ssh"
        PATH="$REC:$TOOLS:$PATH"
        export PATH
        "$@" </dev/null
    )
}
reclog_reset() { rm -f "$RECLOG"/*.cmd "$RECLOG"/*.stdin 2>/dev/null; }
rec_count() { find "$RECLOG" -name '*.cmd' | wc -l | tr -d ' '; }

# A fresh share root with its own NAS fake (so tree assertions are exact).
new_root() { # prints root
    persist_fixture_root_create "$SCRATCH"
}
use_root() { # ROOT: re-point TOOLS (the fake's cwd) at ROOT
    TOOLS="$(persist_fixture_nas_create "$1" "$SCRATCH")"
    reclog_reset
}
tree_of() { (cd "$1" && find . | LC_ALL=C sort); }


# --- recorded-command hygiene ----------------------------------------------
WORDS_STUB="$SCRATCH/words-bin"
mkdir -p "$WORDS_STUB"
fake_tool_write "$WORDS_STUB" sh 'printf "%s\n" "$@" > "${DXE_WORDS_OUT:?}"'
EMPTY_CWD="$SCRATCH/empty-cwd"
mkdir -p "$EMPTY_CWD"
HAVE_DASH=0
command -v dash >/dev/null 2>&1 && HAVE_DASH=1

# cmd_check LABEL N: assert the Nth recorded remote command is a single-line,
# fully backslash-quoted `sh -c SCRIPT sh DATA...` whose script is POSIX.
# On success leaves the words (one per line) in $SCRATCH/words.N.
cmd_check() {
    local label="$1" n="$2" f="$RECLOG/$2.cmd" rest
    if [ ! -f "$f" ]; then
        test_fail "$label: command $n was recorded"
        return 1
    fi
    if [ "$(wc -l <"$f" | tr -d ' ')" != 0 ]; then
        test_fail "$label: the remote command is a single line"
    else
        test_pass "$label: the remote command is a single line"
    fi
    if grep -Fq -- "\$'" "$f"; then
        test_fail "$label: no bash-only \$'...' quoting reaches the NAS shell"
    else
        test_pass "$label: no bash-only \$'...' quoting reaches the NAS shell"
    fi
    if sh -n "$f" 2>/dev/null; then test_pass "$label: remote command passes sh -n"; else test_fail "$label: remote command passes sh -n"; fi
    if [ "$HAVE_DASH" = 1 ]; then
        if dash -n "$f" 2>/dev/null; then test_pass "$label: remote command passes dash -n"; else test_fail "$label: remote command passes dash -n"; fi
    fi
    case "$(cat "$f")" in
        "sh -c "*) test_pass "$label: the command is sh -c <script> ..." ;;
        *) test_fail "$label: the command is sh -c <script> ..."; return 1 ;;
    esac
    # Only a command made of backslash-quoted words is safe to unquote by
    # evaluating it against a stub `sh` (anything else could execute).
    rest="$(sed -e 's/\\.//g' -e "s/''//g" "$f" | tr -d "A-Za-z0-9 _./=:,@%+-")"
    if [ -n "$rest" ]; then
        test_fail "$label: every word is backslash-quoted (stray [$rest])"
        return 1
    fi
    test_pass "$label: every word is backslash-quoted"
    (
        cd "$EMPTY_CWD" || exit 1
        PATH="$WORDS_STUB:$PATH" DXE_WORDS_OUT="$SCRATCH/words.$n"
        export PATH DXE_WORDS_OUT
        eval "$(cat "$f")"
    )
    if [ "$(sed -n 1p "$SCRATCH/words.$n")" = "-c" ] && [ "$(sed -n 3p "$SCRATCH/words.$n")" = "sh" ]; then
        test_pass "$label: argv is -c SCRIPT sh DATA..."
    else
        test_fail "$label: argv is -c SCRIPT sh DATA..."
        return 1
    fi
    sed -n 2p "$SCRATCH/words.$n" >"$SCRATCH/script.$n"
    if sh -n "$SCRATCH/script.$n" 2>/dev/null; then test_pass "$label: SCRIPT passes sh -n"; else test_fail "$label: SCRIPT passes sh -n"; fi
    if [ "$HAVE_DASH" = 1 ]; then
        if dash -n "$SCRATCH/script.$n" 2>/dev/null; then test_pass "$label: SCRIPT passes dash -n"; else test_fail "$label: SCRIPT passes dash -n"; fi
    fi
    return 0
}
word_is() { # LABEL N WORD: WORD is a whole data word; SCRIPT does not embed it
    local label="$1" n="$2" word="$3"
    if tail -n +4 "$SCRATCH/words.$n" 2>/dev/null | grep -Fqx -- "$word"; then
        test_pass "$label: data word [$word] passed as its own argv word"
    else
        test_fail "$label: data word [$word] passed as its own argv word"
    fi
    if grep -Fq -- "$word" "$SCRATCH/script.$n" 2>/dev/null; then
        test_fail "$label: SCRIPT does not embed [$word]"
    else
        test_pass "$label: SCRIPT does not embed [$word]"
    fi
}

have() { type "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
test_section "WP4.2: operations are declared and implemented in both adapters"
for op in probe create marker_write usage; do
    check "dx_runtime_host_dir_$op is declared (dx-runtime.sh)" have "dx_runtime_host_dir_$op"
    check "dx_runtime_apple_host_dir_$op is implemented" have "dx_runtime_apple_host_dir_$op"
    check "dx_runtime_docker_host_dir_$op is implemented" have "dx_runtime_docker_host_dir_$op"
done

# ---------------------------------------------------------------------------
test_section "WP4.2: Apple answers unsupported and makes no call"
apple_cases() {
    local calls="$SCRATCH/apple-calls" tools root="$ROOT0"
    tools="$(fake_tool_dir_create "$SCRATCH")"
    : >"$calls"
    local t
    for t in container ssh docker; do
        fake_tool_write "$tools" "$t" "echo $t >> '$calls'; exit 99"
    done
    apple_run() {
        local op="$1" out err rc
        shift
        out="$(DX_RUNTIME=apple PATH="$tools:$PATH" "dx_runtime_host_dir_$op" "$@" 2>"$SCRATCH/apple.err")"
        rc=$?
        err="$(cat "$SCRATCH/apple.err")"
        if [ "$rc" != 0 ] && [ "$rc" != 99 ]; then test_pass "apple $op: non-zero status"; else test_fail "apple $op: non-zero status (rc=$rc)"; fi
        eq "apple $op: nothing on stdout" "" "$out"
        if grep -Fq "unsupported" <<<"$err"; then test_pass "apple $op: stderr says unsupported"; else test_fail "apple $op: stderr says unsupported (got: $err)"; fi
    }
    apple_run probe "$root" "$GUEST"
    apple_run create "$root" "$GUEST" "$MARKER_TEXT"
    apple_run marker_write "$root/x" "$MARKER_TEXT"
    apple_run usage "$root"
    eq "apple: no runtime tool was called" "0" "$(wc -l <"$calls" | tr -d ' ')"
    eq "apple: nothing was created on the share" "." "$(tree_of "$root")"
}
apple_cases

# ---------------------------------------------------------------------------
test_section "WP4.2: probe reports directory state, marker and canonical root"
probe_cases() {
    local root out rc canon g="$GUEST" d
    root="$(new_root)"
    use_root "$root"
    canon="$(physical "$root")"

    nas dx_runtime_host_dir_probe "$root" "$g" >"$SCRATCH/probe.out" 2>"$SCRATCH/probe.err"
    rc=$?
    eq "absent: status 0" "0" "$rc"
    file_eq_out "absent: exact report" "root=$canon${NL}mounted=unknown${NL}state=absent${NL}marker=absent${NL}" "$SCRATCH/probe.out"
    eq "probe is exactly one ssh call" "1" "$(rec_count)"
    cmd_check "probe" 1 && {
        word_is "probe" 1 "$root"
        word_is "probe" 1 "$g"
    }
    eq "probe creates nothing" "." "$(tree_of "$root")"

    d="$root/dxe/$g/persist"
    mkdir -p "$d"
    nas dx_runtime_host_dir_probe "$root" "$g" >"$SCRATCH/probe.out" 2>/dev/null
    file_eq_out "empty: exact report" "root=$canon${NL}mounted=unknown${NL}state=empty${NL}marker=absent${NL}" "$SCRATCH/probe.out"

    : >"$d/.hidden"
    nas dx_runtime_host_dir_probe "$root" "$g" >"$SCRATCH/probe.out" 2>/dev/null
    file_eq_out "a dotfile makes it nonempty" "root=$canon${NL}mounted=unknown${NL}state=nonempty${NL}marker=absent${NL}" "$SCRATCH/probe.out"
    rm -f "$d/.hidden"

    printf 'data\n' >"$d/file"
    nas dx_runtime_host_dir_probe "$root" "$g" >"$SCRATCH/probe.out" 2>/dev/null
    file_eq_out "nonempty: exact report" "root=$canon${NL}mounted=unknown${NL}state=nonempty${NL}marker=absent${NL}" "$SCRATCH/probe.out"

    printf '%s\n' "$MARKER_TEXT" >"$d/$MARKER_NAME"
    nas dx_runtime_host_dir_probe "$root" "$g" >"$SCRATCH/probe.out" 2>/dev/null
    file_eq_out "marker present: text follows the marker=present line verbatim" \
        "root=$canon${NL}mounted=unknown${NL}state=nonempty${NL}marker=present${NL}$MARKER_TEXT${NL}" "$SCRATCH/probe.out"

    rm -f "$d/file"
    nas dx_runtime_host_dir_probe "$root" "$g" >"$SCRATCH/probe.out" 2>/dev/null
    file_eq_out "the marker alone is nonempty" \
        "root=$canon${NL}mounted=unknown${NL}state=nonempty${NL}marker=present${NL}$MARKER_TEXT${NL}" "$SCRATCH/probe.out"

    # A symlink is reported as such, never followed (its target holds a marker).
    local other="$root/elsewhere"
    mkdir -p "$other"
    printf '%s\n' "$MARKER_TEXT" >"$other/$MARKER_NAME"
    rm -rf "${d:?}"
    ln -s "$other" "$d"
    nas dx_runtime_host_dir_probe "$root" "$g" >"$SCRATCH/probe.out" 2>/dev/null
    file_eq_out "symlink to a populated dir: state=symlink, marker not followed" \
        "root=$canon${NL}mounted=unknown${NL}state=symlink${NL}marker=absent${NL}" "$SCRATCH/probe.out"
    rm -f "$d"
    ln -s "$root/no-such-target" "$d"
    nas dx_runtime_host_dir_probe "$root" "$g" >"$SCRATCH/probe.out" 2>/dev/null
    file_eq_out "dangling symlink: state=symlink" \
        "root=$canon${NL}mounted=unknown${NL}state=symlink${NL}marker=absent${NL}" "$SCRATCH/probe.out"

    # A symlinked root resolves canonically.
    local link="$SCRATCH/dxe-root-link"
    ln -s "$root" "$link"
    nas dx_runtime_host_dir_probe "$link" "$g" >"$SCRATCH/probe.out" 2>/dev/null
    file_eq_out "symlinked root: canonical root reported" \
        "root=$canon${NL}mounted=unknown${NL}state=symlink${NL}marker=absent${NL}" "$SCRATCH/probe.out"
    rm -f "$link"

    # Not a directory.
    out="$(nas dx_runtime_host_dir_probe "$root/no-such-root" "$g" 2>"$SCRATCH/probe.err")"
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "missing root: non-zero"; else test_fail "missing root: non-zero"; fi
    eq "missing root: empty stdout" "" "$out"
    has "missing root: stderr says not a directory" "$SCRATCH/probe.err" "not a directory"
}
probe_cases

test_section "WP4.2: probe's mounted flag fails closed on a sentinel file"
mount_cases() {
    local root canon n=".share-mounted" S="share-mounted" rc link
    root="$(new_root)"
    use_root "$root"
    canon="$(physical "$root")"
    nas dx_runtime_host_dir_probe "$root" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    has "sentinel unset: mounted=unknown" "$SCRATCH/probe.out" "mounted=unknown"
    DX_PERSIST_HOST_MOUNT_SENTINEL="" nas dx_runtime_host_dir_probe "$root" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    has "sentinel empty: mounted=unknown" "$SCRATCH/probe.out" "mounted=unknown"
    : >"$root/$n"
    DX_PERSIST_HOST_MOUNT_SENTINEL="" nas dx_runtime_host_dir_probe "$root" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    if grep -Fq "mounted=yes" "$SCRATCH/probe.out"; then test_fail "no sentinel configured is never mounted=yes"; else test_pass "no sentinel configured is never mounted=yes"; fi
    rm -f "$root/$n"
    reclog_reset
    DX_PERSIST_HOST_MOUNT_SENTINEL="$S" nas dx_runtime_host_dir_probe "$root" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    file_eq_out "sentinel configured but absent: mounted=no, rest still reported" \
        "root=$canon${NL}mounted=no${NL}state=absent${NL}marker=absent${NL}" "$SCRATCH/probe.out"
    eq "the sentinel check is part of the same single ssh call" "1" "$(rec_count)"
    cmd_check "probe (sentinel)" 1 && word_is "probe (sentinel)" 1 "$S"
    reclog_reset
    : >"$root/$S"
    DX_PERSIST_HOST_MOUNT_SENTINEL="$S" nas dx_runtime_host_dir_probe "$root" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    rc=$?
    eq "sentinel present: status 0" "0" "$rc"
    file_eq_out "sentinel present (regular file): mounted=yes" \
        "root=$canon${NL}mounted=yes${NL}state=absent${NL}marker=absent${NL}" "$SCRATCH/probe.out"
    DX_PERSIST_HOST_MOUNT_SENTINEL="other-sentinel" nas dx_runtime_host_dir_probe "$root" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    has "a different sentinel name is honoured" "$SCRATCH/probe.out" "mounted=no"
    rm -f "$root/$S"
    mkdir "$root/$S"
    DX_PERSIST_HOST_MOUNT_SENTINEL="$S" nas dx_runtime_host_dir_probe "$root" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    has "sentinel that is a directory: mounted=no" "$SCRATCH/probe.out" "mounted=no"
    rmdir "$root/$S"
    : >"$root/real-file"
    ln -s real-file "$root/$S"
    DX_PERSIST_HOST_MOUNT_SENTINEL="$S" nas dx_runtime_host_dir_probe "$root" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    has "sentinel that is a symlink to a file: mounted=no" "$SCRATCH/probe.out" "mounted=no"
    rm -f "$root/$S"
    ln -s no-such-target "$root/$S"
    DX_PERSIST_HOST_MOUNT_SENTINEL="$S" nas dx_runtime_host_dir_probe "$root" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    has "sentinel that is a dangling symlink: mounted=no" "$SCRATCH/probe.out" "mounted=no"
    # The sentinel is looked up under the canonical root, via a symlinked root.
    rm -f "$root/$S"
    : >"$root/$S"
    link="$SCRATCH/dxe-sentinel-root-link"
    ln -s "$root" "$link"
    DX_PERSIST_HOST_MOUNT_SENTINEL="$S" nas dx_runtime_host_dir_probe "$link" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    has "sentinel found through a symlinked root: mounted=yes" "$SCRATCH/probe.out" "mounted=yes"
    rm -f "$link"
}
mount_cases

test_section "WP4.2: the sentinel is a validated profile field"
sentinel_field_cases() {
    local f=DX_PERSIST_HOST_MOUNT_SENTINEL v
    check "$f is a registry field (dx_config_is_field)" dx_config_is_field "$f"
    eq "$f kind is optname" "optname" "$(dx_config_kind "$f" 2>/dev/null)"
    eq "$f default is empty" "" "$(dx_config_default "$f" 2>/dev/null)"
    check "$f default is registered (default lookup succeeds)" dx_config_default "$f"
    check "$f: empty is accepted" dx_config_validate_value "$f" ""
    check "$f: a plain file name is accepted" dx_config_validate_value "$f" "share-mounted"
    for v in "a/b" "/abs" "../x" ".." "dir/" "a b" ".hidden" "-dash"; do
        check_not "$f: [$v] is rejected" dx_config_validate_value "$f" "$v"
    done
}
sentinel_field_cases

# ---------------------------------------------------------------------------
test_section "WP4.2: create makes the directory and a valid marker, nothing else"
create_cases() {
    local root canon d out rc
    root="$(new_root)"
    use_root "$root"
    canon="$(physical "$root")"
    d="$root/dxe/$GUEST/persist"

    out="$(nas dx_runtime_host_dir_create "$root" "$GUEST" "$MARKER_TEXT" 2>"$SCRATCH/create.err")"
    rc=$?
    eq "create: status 0" "0" "$rc"
    eq "create: nothing on stdout" "" "$out"
    eq "create: exactly the three levels and the marker" \
        ".${NL}./dxe${NL}./dxe/$GUEST${NL}./dxe/$GUEST/persist${NL}./dxe/$GUEST/persist/$MARKER_NAME" "$(tree_of "$root")"
    file_eq "create: marker content is the text plus one newline" "$d/$MARKER_NAME" "$MARKER_TEXT$NL"
    if [ -f "$d/$MARKER_NAME" ] && dx_persist_marker_parse <"$d/$MARKER_NAME" 2>/dev/null \
        && [ "$DX_PERSIST_MARKER_GUEST" = "$GUEST" ] && [ "$DX_PERSIST_MARKER_STATE" = ready ]; then
        test_pass "create: the marker parses with the marker library"
    else
        test_fail "create: the marker parses with the marker library"
    fi
    eq "create is exactly one ssh call" "1" "$(rec_count)"
    cmd_check "create" 1 && {
        word_is "create" 1 "$root"
        word_is "create" 1 "$GUEST"
    }
    if grep -Fq "guest=$GUEST" "$RECLOG/1.cmd"; then test_fail "create: the marker text is not in the remote argv"; else test_pass "create: the marker text is not in the remote argv"; fi
    file_eq "create: the marker text travels on stdin" "$RECLOG/1.stdin" "$MARKER_TEXT$NL"

    # Existing path: refuse, leave it alone.
    printf 'precious\n' >"$d/keep"
    reclog_reset
    out="$(nas dx_runtime_host_dir_create "$root" "$GUEST" "$MARKER_TEXT_B" 2>"$SCRATCH/create.err")"
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "create over an existing directory: non-zero"; else test_fail "create over an existing directory: non-zero"; fi
    has "create over an existing directory: stderr says exists" "$SCRATCH/create.err" "exists"
    file_eq "create over an existing directory: marker untouched" "$d/$MARKER_NAME" "$MARKER_TEXT$NL"
    file_eq "create over an existing directory: content untouched" "$d/keep" "precious${NL}"

    # Existing symlink at the path is also refused, and not followed.
    local root2 target
    root2="$(new_root)"
    use_root "$root2"
    target="$root2/elsewhere"
    mkdir -p "$target" "$root2/dxe/$GUEST"
    ln -s "$target" "$root2/dxe/$GUEST/persist"
    nas dx_runtime_host_dir_create "$root2" "$GUEST" "$MARKER_TEXT" >/dev/null 2>"$SCRATCH/create.err"
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "create over a symlink: non-zero"; else test_fail "create over a symlink: non-zero"; fi
    eq "create over a symlink: nothing written through it" "" "$(find "$target" -mindepth 1 | head -n1)"

    # Invalid marker text: refused on the host, no ssh call, nothing created.
    local root3
    root3="$(new_root)"
    use_root "$root3"
    nas dx_runtime_host_dir_create "$root3" "$GUEST" "schema=1${NL}guest=$GUEST${NL}state=bogus" >/dev/null 2>"$SCRATCH/create.err"
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "create with an invalid marker: non-zero"; else test_fail "create with an invalid marker: non-zero"; fi
    eq "create with an invalid marker: no ssh call" "0" "$(rec_count)"
    eq "create with an invalid marker: nothing created" "." "$(tree_of "$root3")"

    # Missing root: never creates the root.
    nas dx_runtime_host_dir_create "$root3/no-such-root" "$GUEST" "$MARKER_TEXT" >/dev/null 2>"$SCRATCH/create.err"
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "create under a missing root: non-zero"; else test_fail "create under a missing root: non-zero"; fi
    has "create under a missing root: stderr says not a directory" "$SCRATCH/create.err" "not a directory"
    eq "create under a missing root: nothing created" "." "$(tree_of "$root3")"
}
create_cases

# ---------------------------------------------------------------------------
test_section "WP4.2: spaces and a leading dash survive quoting"
quoting_cases() {
    local root rel="-dash root" canon d out rc
    root="$(new_root)"
    mkdir -p "$root/$rel"
    use_root "$root"
    canon="$(physical "$root/$rel")"
    d="$root/$rel/dxe/$GUEST/persist"

    nas dx_runtime_host_dir_create "$rel" "$GUEST" "$MARKER_TEXT" >/dev/null 2>"$SCRATCH/q.err"
    rc=$?
    eq "create with a relative '-dash root' ROOT: status 0" "0" "$rc"
    file_eq "create: marker landed under the dashed, spaced root" "$d/$MARKER_NAME" "$MARKER_TEXT$NL"
    eq "create: nothing leaked outside the dashed root" ".${NL}./-dash root" "$(cd "$root" && find . -maxdepth 1 | LC_ALL=C sort)"
    cmd_check "create (dash+space)" 1 && word_is "create (dash+space)" 1 "$rel"

    reclog_reset
    nas dx_runtime_host_dir_probe "$rel" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    file_eq_out "probe with a dashed, spaced ROOT" \
        "root=$canon${NL}mounted=unknown${NL}state=nonempty${NL}marker=present${NL}$MARKER_TEXT${NL}" "$SCRATCH/probe.out"
    cmd_check "probe (dash+space)" 1 && word_is "probe (dash+space)" 1 "$rel"

    reclog_reset
    nas dx_runtime_host_dir_marker_write "$rel/dxe/$GUEST/persist" "$MARKER_TEXT_B" >/dev/null 2>&1
    rc=$?
    eq "marker_write with a dashed, spaced PATH: status 0" "0" "$rc"
    file_eq "marker_write: replaced under the dashed root" "$d/$MARKER_NAME" "$MARKER_TEXT_B$NL"
    cmd_check "marker_write (dash+space)" 1 && word_is "marker_write (dash+space)" 1 "$rel/dxe/$GUEST/persist"

    reclog_reset
    out="$(nas dx_runtime_host_dir_usage "$rel/dxe/$GUEST/persist" 2>/dev/null)"
    rc=$?
    eq "usage with a dashed, spaced PATH: status 0" "0" "$rc"
    eq "usage: same as du -sk" "$(cd "$root" && du -sk -- "$rel/dxe/$GUEST/persist")" "$out"
    cmd_check "usage (dash+space)" 1 && word_is "usage (dash+space)" 1 "$rel/dxe/$GUEST/persist"
}
quoting_cases

# ---------------------------------------------------------------------------
test_section "WP4.2: marker_write replaces the marker atomically"
marker_write_cases() {
    local root d rc before
    root="$(new_root)"
    use_root "$root"
    d="$root/dxe/$GUEST/persist"
    mkdir -p "$d"
    printf '%s\n' "$MARKER_TEXT" >"$d/$MARKER_NAME"
    : >"$d/payload"

    nas dx_runtime_host_dir_marker_write "$d" "$MARKER_TEXT_B" >"$SCRATCH/mw.out" 2>"$SCRATCH/mw.err"
    rc=$?
    eq "marker_write: status 0" "0" "$rc"
    eq "marker_write: nothing on stdout" "0" "$(wc -c <"$SCRATCH/mw.out" | tr -d ' ')"
    file_eq "marker_write: new content (text plus one newline)" "$d/$MARKER_NAME" "$MARKER_TEXT_B$NL"
    eq "marker_write: only the marker and the payload remain" "./$MARKER_NAME${NL}./payload" "$(cd "$d" && find . -type f | LC_ALL=C sort)"
    eq "marker_write is exactly one ssh call" "1" "$(rec_count)"
    cmd_check "marker_write" 1 && word_is "marker_write" 1 "$d"
    file_eq "marker_write: the text travels on stdin" "$RECLOG/1.stdin" "$MARKER_TEXT_B$NL"

    # TEXT that already ends in a newline is not given a second one.
    nas dx_runtime_host_dir_marker_write "$d" "$MARKER_TEXT$NL" >/dev/null 2>&1
    file_eq "marker_write: a trailing newline is not doubled" "$d/$MARKER_NAME" "$MARKER_TEXT$NL"
    printf "%s\n" "$MARKER_TEXT" >"$d/$MARKER_NAME"

    # mv fails: old content intact, no temp file left, non-zero.
    cat >"$STUBS/mv" <<'STUB'
#!/bin/bash
{ pwd -P; printf '%s\n' "$@"; echo --; } >> "${DXE_MV_LOG:?}"
exit 1
STUB
    chmod 0755 "$STUBS/mv"
    : >"$SCRATCH/mv.log"
    before="$(cat "$d/$MARKER_NAME")"
    reclog_reset
    DXE_MV_LOG="$SCRATCH/mv.log" PATH="$STUBS:$PATH" nas dx_runtime_host_dir_marker_write "$d" "$MARKER_TEXT" >/dev/null 2>"$SCRATCH/mw.err"
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "failing mv: non-zero status"; else test_fail "failing mv: non-zero status"; fi
    eq "failing mv: old marker intact" "$before" "$(cat "$d/$MARKER_NAME")"
    eq "failing mv: no temp file left behind" "./$MARKER_NAME${NL}./payload" "$(cd "$d" && find . -type f | LC_ALL=C sort)"
    # mv was asked to move a temp file in the SAME directory onto the marker.
    local pwd_line src dst
    pwd_line="$(sed -n 1p "$SCRATCH/mv.log")"
    src="$(grep -v '^-' "$SCRATCH/mv.log" | sed -n 2p)"
    dst="$(grep -v '^-' "$SCRATCH/mv.log" | sed -n 3p)"
    case "$src" in /*) : ;; *) src="$pwd_line/$src" ;; esac
    case "$dst" in /*) : ;; *) dst="$pwd_line/$dst" ;; esac
    dst="$(physical "$(dirname "$dst")")/$(basename "$dst")"
    src="$(physical "$(dirname "$src")")/$(basename "$src")"
    eq "mv destination is the marker file" "$(physical "$d")/$MARKER_NAME" "$dst"
    eq "mv source is a temp file in the same directory" "$(physical "$d")" "$(dirname "$src")"
    if [ "$(basename "$src")" != "$MARKER_NAME" ]; then test_pass "mv source has a different name than the marker"; else test_fail "mv source has a different name than the marker"; fi

    # Invalid text: no ssh, nothing changes.
    reclog_reset
    nas dx_runtime_host_dir_marker_write "$d" "not a marker" >/dev/null 2>&1
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "marker_write with invalid text: non-zero"; else test_fail "marker_write with invalid text: non-zero"; fi
    eq "marker_write with invalid text: no ssh call" "0" "$(rec_count)"
    eq "marker_write with invalid text: marker unchanged" "$before" "$(cat "$d/$MARKER_NAME")"

    # PATH is not a directory: non-zero, nothing created.
    nas dx_runtime_host_dir_marker_write "$root/no-such-dir" "$MARKER_TEXT" >/dev/null 2>&1
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "marker_write into a missing directory: non-zero"; else test_fail "marker_write into a missing directory: non-zero"; fi
    check_not "marker_write into a missing directory creates nothing" test -e "$root/no-such-dir"
}
marker_write_cases

# ---------------------------------------------------------------------------
test_section "WP4.2: usage prints du -sk style output"
usage_cases() {
    local root d out rc
    root="$(new_root)"
    use_root "$root"
    d="$root/dxe/$GUEST/persist"
    mkdir -p "$d"
    perl -e 'print "x" x 300000' >"$d/blob"
    out="$(nas dx_runtime_host_dir_usage "$d" 2>"$SCRATCH/u.err")"
    rc=$?
    eq "usage: status 0" "0" "$rc"
    eq "usage: byte-for-byte du -sk" "$(du -sk -- "$d")" "$out"
    case "$out" in
        [0-9]*"	$d") test_pass "usage: <KiB><TAB><path>" ;;
        *) test_fail "usage: <KiB><TAB><path> (got [$out])" ;;
    esac
    if [ "${out%%	*}" -ge 290 ] 2>/dev/null; then test_pass "usage: the number reflects the 300000 byte file"; else test_fail "usage: the number reflects the 300000 byte file (got [$out])"; fi
    eq "usage is exactly one ssh call" "1" "$(rec_count)"
    cmd_check "usage" 1 && word_is "usage" 1 "$d"
    out="$(nas dx_runtime_host_dir_usage "$root/no-such-dir" 2>/dev/null)"
    rc=$?
    if [ "$rc" != 0 ]; then test_pass "usage of a missing path: non-zero"; else test_fail "usage of a missing path: non-zero"; fi
    eq "usage of a missing path: empty stdout" "" "$out"
}
usage_cases

# ---------------------------------------------------------------------------
test_section "WP4.2: the runtime boundary audit still passes"
audit_cases() {
    local out rc
    out="$(bash "$SCRIPT_DIR/test_runtime_boundary_audit.sh" 2>&1)"
    rc=$?
    eq "boundary audit exits 0 (no new exception needed)" "0" "$rc"
    if grep -Fq "FAIL" <<<"$out"; then test_fail "boundary audit reports no failures"; else test_pass "boundary audit reports no failures"; fi
}
audit_cases

print_summary
exit_with_code
