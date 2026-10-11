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
#   Host-side refusal of degenerate locations (every op, Docker side): a ROOT
#   (probe, create) or PATH (marker_write, usage) that is EMPTY or exactly
#   "-" returns non-zero, prints nothing on stdout and a reason on stderr,
#   and makes NO ssh call (in the NAS shell an empty operand is the cwd and
#   `cd -- -` is $OLDPWD). No rm/chmod/chown/mv/find runs on the host either.
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
#     followed, so then marker=absent), and ALSO when the dxe level or the
#     dxe/<GUEST> level is a symbolic link (even dangling): such a level is
#     never followed and nothing below it is read, so then marker=absent and
#     no marker text is printed; empty = a directory with no entries
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
#     exists in any form (directory, symlink even dangling, regular file,
#     FIFO, ...); refuses a missing ROOT (stderr "not a directory", nothing
#     created); refuses a symlinked dxe or dxe/<GUEST> level (non-zero,
#     nothing created or written through it).
#     The sequence is fixed: after those checks, make dxe and dxe/<GUEST>
#     when missing, then create the leaf with a plain
#         mkdir -- <ROOT>/dxe/<GUEST>/persist
#     (`mkdir` found through PATH, as `mv` is; its operand names the leaf,
#     absolute or relative to the NAS shell's cwd; no -p and never the
#     rename of a prepared temp DIRECTORY), so that if anything appeared at
#     the leaf meanwhile, that mkdir fails, create returns non-zero and what
#     appeared is left untouched (nothing written into or through it). Then
#     write the marker inside the new leaf exactly as marker_write does: the
#     same slot check, a temp FILE in the leaf, ONE `mv` onto the marker --
#     the only mv create ever runs. If anything fails after the mkdir,
#     create removes only its own temp FILE (never the leaf: no rmdir, no
#     rm -r), so an EMPTY, UNMARKED leaf remains (probe: state=empty,
#     marker=absent; WP4.4 adopts it with marker_write on the next run) and
#     create returns non-zero.
#   marker_write PATH MARKER_TEXT   PATH is the persist directory. Replaces
#     PATH/.dxe-persist-dir atomically: temp file in PATH, then `mv` (found
#     through PATH) onto the marker; if mv fails the old marker is intact,
#     no temp file is left and the status is non-zero. A PATH that is not a
#     directory: non-zero, nothing created.
#     The marker SLOT PATH/.dxe-persist-dir may be replaced only when it is
#     missing or a regular file. A slot that is a symlink (to a directory, to
#     a file, or dangling) or any other non-regular file (a directory, a
#     FIFO, ...) is refused: non-zero, a reason on stderr, nothing on stdout,
#     nothing written anywhere (not through the link, not into the slot, no
#     temp file left) and the slot itself left exactly as it was.
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
# Safety additions (F1-F4). Every case works on its own fixture root. A
# symlink a case plants points only into an "outside" directory: inside this
# run's scratch, outside every fixture root; each case asserts nothing
# landed there. The remote-shell cases run once with the host's `sh` and,
# when dash exists, once more with dash as the NAS shell.
nonzero() { # LABEL STATUS
    if [ "$2" != 0 ]; then test_pass "$1"; else test_fail "$1 (status 0)"; fi
}
nonempty_file() { # LABEL FILE
    if [ -s "$2" ]; then test_pass "$1"; else test_fail "$1 (empty)"; fi
}
outside_new() { mktemp -d "$SCRATCH/dxe-outside.XXXXXX"; }
same_link() { # LABEL PATH TARGET: PATH is still a symlink to exactly TARGET
    if [ -L "$2" ] && [ "$(readlink "$2")" = "$3" ]; then test_pass "$1"; else test_fail "$1"; fi
}
real_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }
real_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
real_fifo() { [ -p "$1" ] && [ ! -L "$1" ]; }

SHELL_MODES="sh"
DASH_SHIM="$SCRATCH/dash-shim-bin"
DASH_LOG="$SCRATCH/dash-shim.log"
if [ "$HAVE_DASH" = 1 ]; then
    SHELL_MODES="sh dash"
    fake_tool_write "$DASH_SHIM" sh "$(printf 'printf "dash\\n" >> %q\nexec %q "$@"' "$DASH_LOG" "$(command -v dash)")"
fi
# in_shell MODE CMD...: run CMD with the NAS shell's `sh` being the host's
# own sh, or dash (a shim first on PATH that logs each use).
in_shell() {
    local mode="$1"
    shift
    : >"$DASH_LOG"
    if [ "$mode" = dash ]; then PATH="$DASH_SHIM:$PATH" "$@"; else "$@"; fi
}
ran_under() { # LABEL MODE: in dash mode, the remote script really ran under dash
    if [ "$2" = dash ]; then nonempty_file "$1: the NAS shell was dash" "$DASH_LOG"; fi
}

# mv stubs for the remote shell (found through PATH like the real one). Both
# log one block per call: @@call, the physical cwd, each argv word, @@end.
# MVREC then runs the next mv on PATH; MVFAIL fails without moving anything.
MVREC="$SCRATCH/mvrec-bin"
MVFAIL="$SCRATCH/mvfail-bin"
fake_tool_write "$MVREC" mv '{ echo @@call; pwd -P; printf "%s\n" "$@"; echo @@end; } >> "${DXE_MV_LOG:?}"
self="$(cd -P "$(dirname "$0")" && pwd -P)"
IFS=:
for p in $PATH; do
    [ -n "$p" ] || continue
    [ "$(cd -P "$p" 2>/dev/null && pwd -P)" = "$self" ] && continue
    if [ -x "$p/mv" ]; then exec "$p/mv" "$@"; fi
done
echo "mvrec: no real mv on PATH" >&2
exit 127'
fake_tool_write "$MVFAIL" mv '{ echo @@call; pwd -P; printf "%s\n" "$@"; echo @@end; } >> "${DXE_MV_LOG:?}"
exit 1'
mv_calls() { # LOG: number of recorded mv calls
    grep -c '^@@call$' "$1" 2>/dev/null || true
}
# mv_first_check LABEL LOG PERSIST_DIR: the first recorded mv moved a temp
# FILE that sits in PERSIST_DIR itself onto PERSIST_DIR/.dxe-persist-dir.
mv_first_check() {
    local label="$1" log="$2" pd cwd src dst
    pd="$(physical "$3")"
    awk '/^@@call$/ { n++; next } /^@@end$/ { next } n == 1' "$log" >"$SCRATCH/mv.first"
    cwd="$(sed -n 1p "$SCRATCH/mv.first")"
    sed 1d "$SCRATCH/mv.first" | grep -v '^-' >"$SCRATCH/mv.ops"
    eq "$label: mv got exactly two operands" "2" "$(wc -l <"$SCRATCH/mv.ops" | tr -d ' ')"
    src="$(sed -n 1p "$SCRATCH/mv.ops")"
    dst="$(sed -n 2p "$SCRATCH/mv.ops")"
    case "$src" in /*) : ;; *) src="$cwd/$src" ;; esac
    case "$dst" in /*) : ;; *) dst="$cwd/$dst" ;; esac
    eq "$label: mv destination is the marker in the persist directory" \
        "$pd/$MARKER_NAME" "$(physical "$(dirname "$dst")")/$(basename "$dst")"
    eq "$label: mv source sits in the persist directory itself" "$pd" "$(physical "$(dirname "$src")")"
    if [ "$(basename "$src")" != "$MARKER_NAME" ]; then
        test_pass "$label: mv source is not the marker name"
    else
        test_fail "$label: mv source is not the marker name"
    fi
}

# A `mkdir` for the remote shell that races create. When an operand is the
# leaf (last component "persist", physical parent $DXE_RACE_PARENT), it
# fires once ($DXE_RACE_FLAG records that it did):
#   pre-symlink  plants a symlink to $DXE_RACE_OUTSIDE at the leaf first;
#   pre-dir      plants a real directory holding "keep" at the leaf first;
#   post-slot    after the real mkdir succeeds, plants a symlink to
#                $DXE_RACE_OUTSIDE at the leaf's marker slot.
# Then (or otherwise) it runs the next mkdir on PATH with the same argv.
RACE="$SCRATCH/race-bin"
fake_tool_write "$RACE" mkdir 'mode="${DXE_RACE_MODE:?}"; parent="${DXE_RACE_PARENT:?}"
out="${DXE_RACE_OUTSIDE:?}"; flag="${DXE_RACE_FLAG:?}"
self="$(cd -P "$(dirname "$0")" && pwd -P)"
real=""
oldifs="$IFS"
IFS=:
for p in $PATH; do
    [ -n "$p" ] || continue
    [ "$(cd -P "$p" 2>/dev/null && pwd -P)" = "$self" ] && continue
    if [ -x "$p/mkdir" ]; then real="$p/mkdir"; break; fi
done
IFS="$oldifs"
[ -n "$real" ] || { echo "race-mkdir: no real mkdir on PATH" >&2; exit 127; }
post=""
for a in "$@"; do
    case "$a" in -*) continue ;; esac
    b="${a%/}"
    [ "${b##*/}" = persist ] || continue
    case "$b" in */*) par="${b%/*}" ;; *) par=. ;; esac
    [ "$(cd -P "$par" 2>/dev/null && pwd -P)" = "$parent" ] || continue
    [ ! -e "$flag" ] || continue
    : > "$flag"
    case "$mode" in
        pre-symlink) ln -s "$out" "$b" ;;
        pre-dir) "$real" "$b" && printf "precious\n" > "$b/keep" ;;
        post-slot) post="$b" ;;
    esac
done
"$real" "$@"
rc=$?
if [ -n "$post" ] && [ "$rc" = 0 ]; then ln -s "$out" "$post/.dxe-persist-dir"; fi
exit "$rc"'

# ---------------------------------------------------------------------------
test_section "WP4.2: marker_write replaces only a missing or regular-file marker slot (F1)"
# slot_refused MODE KIND: the slot is KIND; marker_write must refuse it.
slot_refused() {
    local mode="$1" kind="$2" root d out link="" rc before_root before_out label
    label="[$mode] marker slot is $kind"
    root="$(new_root)"
    use_root "$root"
    d="$root/dxe/$GUEST/persist"
    mkdir -p "$d"
    printf 'payload\n' >"$d/payload"
    out="$(outside_new)"
    case "$kind" in
        "a symlink to a directory") link="$out"; ln -s "$link" "$d/$MARKER_NAME" ;;
        "a symlink to a file") printf 'victim\n' >"$out/victim"; link="$out/victim"; ln -s "$link" "$d/$MARKER_NAME" ;;
        "a dangling symlink") link="$out/ghost"; ln -s "$link" "$d/$MARKER_NAME" ;;
        "a directory") mkdir "$d/$MARKER_NAME" ;;
        "a FIFO") mkfifo "$d/$MARKER_NAME" ;;
    esac
    before_root="$(tree_of "$root")"
    before_out="$(tree_of "$out")"
    in_shell "$mode" nas dx_runtime_host_dir_marker_write "$d" "$MARKER_TEXT_B" >"$SCRATCH/slot.out" 2>"$SCRATCH/slot.err"
    rc=$?
    ran_under "$label" "$mode"
    nonzero "$label: marker_write refuses (non-zero)" "$rc"
    eq "$label: nothing on stdout" "0" "$(wc -c <"$SCRATCH/slot.out" | tr -d ' ')"
    nonempty_file "$label: a reason on stderr" "$SCRATCH/slot.err"
    eq "$label: the share tree is unchanged (no temp file, nothing renamed)" "$before_root" "$(tree_of "$root")"
    eq "$label: nothing landed in the outside directory" "$before_out" "$(tree_of "$out")"
    case "$kind" in
        *symlink*) same_link "$label: the slot is still the same symlink" "$d/$MARKER_NAME" "$link" ;;
        "a directory") check "$label: the slot is still a directory" real_dir "$d/$MARKER_NAME" ;;
        "a FIFO") check "$label: the slot is still a FIFO" real_fifo "$d/$MARKER_NAME" ;;
    esac
    if [ "$kind" = "a symlink to a file" ]; then
        file_eq "$label: the link's target file is unchanged" "$out/victim" "victim$NL"
    fi
    if [ "$kind" = "a dangling symlink" ]; then
        check_not "$label: the dangling link's target was not created" test -e "$out/ghost"
    fi
    file_eq "$label: the payload is untouched" "$d/payload" "payload$NL"
}
# slot_replaced MODE KIND: a missing or regular-file slot is (re)written.
slot_replaced() {
    local mode="$1" kind="$2" root d rc label
    label="[$mode] marker slot is $kind"
    root="$(new_root)"
    use_root "$root"
    d="$root/dxe/$GUEST/persist"
    mkdir -p "$d"
    printf 'payload\n' >"$d/payload"
    if [ "$kind" = "a regular file" ]; then printf '%s\n' "$MARKER_TEXT" >"$d/$MARKER_NAME"; fi
    in_shell "$mode" nas dx_runtime_host_dir_marker_write "$d" "$MARKER_TEXT_B" >/dev/null 2>&1
    rc=$?
    ran_under "$label" "$mode"
    eq "$label: marker_write succeeds" "0" "$rc"
    check "$label: the marker is a regular file" real_file "$d/$MARKER_NAME"
    file_eq "$label: the marker holds the new text" "$d/$MARKER_NAME" "$MARKER_TEXT_B$NL"
    eq "$label: only the marker and the payload are there" "./$MARKER_NAME${NL}./payload" \
        "$(cd "$d" && find . -mindepth 1 | LC_ALL=C sort)"
}
for mode in $SHELL_MODES; do
    for kind in "a symlink to a directory" "a symlink to a file" "a dangling symlink" "a directory" "a FIFO"; do
        slot_refused "$mode" "$kind"
    done
    slot_replaced "$mode" "missing"
    slot_replaced "$mode" "a regular file"
done

# ---------------------------------------------------------------------------
test_section "WP4.2: create makes the leaf with mkdir, then marks it (F2)"
# create_marks MODE: the one mv is the marker's; no directory is renamed.
create_marks() {
    local mode="$1" root d rc label
    label="[$mode] create"
    root="$(new_root)"
    use_root "$root"
    d="$root/dxe/$GUEST/persist"
    : >"$SCRATCH/mvrec.log"
    DXE_MV_LOG="$SCRATCH/mvrec.log" PATH="$MVREC:$PATH" in_shell "$mode" nas dx_runtime_host_dir_create "$root" "$GUEST" "$MARKER_TEXT" >/dev/null 2>&1
    rc=$?
    ran_under "$label" "$mode"
    eq "$label: status 0" "0" "$rc"
    eq "$label: exactly the three levels and the marker" \
        ".${NL}./dxe${NL}./dxe/$GUEST${NL}./dxe/$GUEST/persist${NL}./dxe/$GUEST/persist/$MARKER_NAME" "$(tree_of "$root")"
    eq "$label: exactly one mv (the marker's; no directory is renamed)" "1" "$(mv_calls "$SCRATCH/mvrec.log")"
    mv_first_check "$label" "$SCRATCH/mvrec.log" "$d"
}
# create_mark_fails MODE: the marker mv fails after the mkdir.
create_mark_fails() {
    local mode="$1" root d rc label
    label="[$mode] create whose marker mv fails"
    root="$(new_root)"
    use_root "$root"
    d="$root/dxe/$GUEST/persist"
    : >"$SCRATCH/mvfail.log"
    DXE_MV_LOG="$SCRATCH/mvfail.log" PATH="$MVFAIL:$PATH" in_shell "$mode" nas dx_runtime_host_dir_create "$root" "$GUEST" "$MARKER_TEXT" >"$SCRATCH/cf.out" 2>/dev/null
    rc=$?
    ran_under "$label" "$mode"
    nonzero "$label: non-zero" "$rc"
    eq "$label: nothing on stdout" "0" "$(wc -c <"$SCRATCH/cf.out" | tr -d ' ')"
    eq "$label: an EMPTY, UNMARKED leaf remains (no temp file, no marker)" \
        ".${NL}./dxe${NL}./dxe/$GUEST${NL}./dxe/$GUEST/persist" "$(tree_of "$root")"
    check "$label: the leaf is a real directory" real_dir "$d"
    eq "$label: exactly one mv was attempted" "1" "$(mv_calls "$SCRATCH/mvfail.log")"
    mv_first_check "$label" "$SCRATCH/mvfail.log" "$d"
    nas dx_runtime_host_dir_probe "$root" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    file_eq_out "$label: probe then sees state=empty, marker=absent" \
        "root=$(physical "$root")${NL}mounted=unknown${NL}state=empty${NL}marker=absent${NL}" "$SCRATCH/probe.out"
    nas dx_runtime_host_dir_create "$root" "$GUEST" "$MARKER_TEXT" >/dev/null 2>"$SCRATCH/cf.err"
    rc=$?
    nonzero "$label: a second create refuses the leftover leaf" "$rc"
    has "$label: ... saying it exists" "$SCRATCH/cf.err" "exists"
    nas dx_runtime_host_dir_marker_write "$d" "$MARKER_TEXT" >/dev/null 2>&1
    rc=$?
    eq "$label: marker_write adopts the leftover leaf" "0" "$rc"
    file_eq "$label: ... which then holds the marker" "$d/$MARKER_NAME" "$MARKER_TEXT$NL"
}
# create_race MODE RACE_MODE: something appears at the leaf (or its slot).
create_race() {
    local mode="$1" race="$2" root d out rc label parent flag
    label="[$mode] create racing $race"
    root="$(new_root)"
    use_root "$root"
    d="$root/dxe/$GUEST/persist"
    mkdir -p "$root/dxe/$GUEST"
    parent="$(physical "$root/dxe/$GUEST")"
    out="$(outside_new)"
    flag="$SCRATCH/race.$race.$mode.fired"
    rm -f "$flag"
    DXE_RACE_MODE="$race" DXE_RACE_PARENT="$parent" DXE_RACE_OUTSIDE="$out" DXE_RACE_FLAG="$flag" \
        PATH="$RACE:$PATH" in_shell "$mode" nas dx_runtime_host_dir_create "$root" "$GUEST" "$MARKER_TEXT" >/dev/null 2>&1
    rc=$?
    ran_under "$label" "$mode"
    check "$label: the leaf was made by a mkdir naming <ROOT>/dxe/<GUEST>/persist" test -e "$flag"
    nonzero "$label: create fails" "$rc"
    eq "$label: nothing landed in the outside directory" "." "$(tree_of "$out")"
    case "$race" in
        pre-symlink)
            eq "$label: the share tree is exactly what was there" \
                ".${NL}./dxe${NL}./dxe/$GUEST${NL}./dxe/$GUEST/persist" "$(tree_of "$root")"
            same_link "$label: the planted symlink is untouched" "$d" "$out"
            ;;
        pre-dir)
            eq "$label: nothing was written into the planted directory" \
                ".${NL}./dxe${NL}./dxe/$GUEST${NL}./dxe/$GUEST/persist${NL}./dxe/$GUEST/persist/keep" "$(tree_of "$root")"
            file_eq "$label: its content is untouched" "$d/keep" "precious$NL"
            ;;
        post-slot)
            eq "$label: the leaf stays, holding only the planted slot (no temp file)" \
                ".${NL}./dxe${NL}./dxe/$GUEST${NL}./dxe/$GUEST/persist${NL}./dxe/$GUEST/persist/$MARKER_NAME" "$(tree_of "$root")"
            same_link "$label: the planted slot symlink is untouched" "$d/$MARKER_NAME" "$out"
            ;;
    esac
}
# create_existing MODE KIND: an existing leaf of KIND is refused untouched.
create_existing() {
    local mode="$1" kind="$2" root d out rc before label
    label="[$mode] create over a leaf that is $kind"
    root="$(new_root)"
    use_root "$root"
    d="$root/dxe/$GUEST/persist"
    mkdir -p "$root/dxe/$GUEST"
    out="$(outside_new)"
    case "$kind" in
        "a regular file") printf 'precious\n' >"$d" ;;
        "a FIFO") mkfifo "$d" ;;
        "a dangling symlink") ln -s "$out/ghost" "$d" ;;
    esac
    before="$(tree_of "$root")"
    in_shell "$mode" nas dx_runtime_host_dir_create "$root" "$GUEST" "$MARKER_TEXT" >/dev/null 2>"$SCRATCH/ce.err"
    rc=$?
    ran_under "$label" "$mode"
    nonzero "$label: non-zero" "$rc"
    has "$label: stderr says exists" "$SCRATCH/ce.err" "exists"
    eq "$label: the share tree is unchanged" "$before" "$(tree_of "$root")"
    eq "$label: nothing landed in the outside directory" "." "$(tree_of "$out")"
    case "$kind" in
        "a regular file") check "$label: still a regular file" real_file "$d"; file_eq "$label: content untouched" "$d" "precious$NL" ;;
        "a FIFO") check "$label: still a FIFO" real_fifo "$d" ;;
        "a dangling symlink") same_link "$label: still the same symlink" "$d" "$out/ghost" ;;
    esac
}
# create_level_link MODE LEVEL: a symlinked dxe or dxe/<GUEST> level.
create_level_link() {
    local mode="$1" level="$2" root out rc before label
    label="[$mode] create under a symlinked $level level"
    root="$(new_root)"
    use_root "$root"
    out="$(outside_new)"
    if [ "$level" = dxe ]; then
        ln -s "$out" "$root/dxe"
    else
        mkdir "$root/dxe"
        ln -s "$out" "$root/dxe/$GUEST"
    fi
    before="$(tree_of "$root")"
    in_shell "$mode" nas dx_runtime_host_dir_create "$root" "$GUEST" "$MARKER_TEXT" >/dev/null 2>/dev/null
    rc=$?
    ran_under "$label" "$mode"
    nonzero "$label: non-zero" "$rc"
    eq "$label: nothing was written through the link" "." "$(tree_of "$out")"
    eq "$label: the share tree is unchanged" "$before" "$(tree_of "$root")"
}
for mode in $SHELL_MODES; do
    create_marks "$mode"
    create_mark_fails "$mode"
    for race in pre-symlink pre-dir post-slot; do
        create_race "$mode" "$race"
    done
    for kind in "a regular file" "a FIFO" "a dangling symlink"; do
        create_existing "$mode" "$kind"
    done
    create_level_link "$mode" dxe
    create_level_link "$mode" "dxe/<GUEST>"
done

# ---------------------------------------------------------------------------
test_section "WP4.2: probe never reads through a symlinked dxe or dxe/<GUEST> level (F3)"
# level_probe MODE LABEL ROOT: the exact report for a symlinked level.
level_probe() {
    local mode="$1" label="$2" root="$3" rc
    in_shell "$mode" nas dx_runtime_host_dir_probe "$root" "$GUEST" >"$SCRATCH/probe.out" 2>/dev/null
    rc=$?
    ran_under "$label" "$mode"
    eq "$label: status 0" "0" "$rc"
    file_eq_out "$label: state=symlink, marker=absent, nothing read through it" \
        "root=$(physical "$root")${NL}mounted=unknown${NL}state=symlink${NL}marker=absent${NL}" "$SCRATCH/probe.out"
}
level_cases() {
    local mode="$1" root out1 out2 before1 before2
    root="$(new_root)"
    use_root "$root"
    # The link targets hold a marked, populated persist directory for GUEST.
    out1="$(outside_new)"
    mkdir -p "$out1/$GUEST/persist"
    printf '%s\n' "$MARKER_TEXT" >"$out1/$GUEST/persist/$MARKER_NAME"
    printf 'data\n' >"$out1/$GUEST/persist/file"
    out2="$(outside_new)"
    mkdir -p "$out2/persist"
    printf '%s\n' "$MARKER_TEXT" >"$out2/persist/$MARKER_NAME"
    printf 'data\n' >"$out2/persist/file"
    before1="$(tree_of "$out1")"
    before2="$(tree_of "$out2")"

    ln -s "$out1" "$root/dxe"
    level_probe "$mode" "[$mode] probe, dxe is a symlink to a marked tree" "$root"
    rm -f "$root/dxe"
    ln -s "$out1/no-such-dxe" "$root/dxe"
    level_probe "$mode" "[$mode] probe, dxe is a dangling symlink" "$root"
    rm -f "$root/dxe"
    mkdir "$root/dxe"
    ln -s "$out2" "$root/dxe/$GUEST"
    level_probe "$mode" "[$mode] probe, dxe/<GUEST> is a symlink to a marked tree" "$root"
    rm -f "$root/dxe/$GUEST"
    ln -s "$out2/no-such-guest" "$root/dxe/$GUEST"
    level_probe "$mode" "[$mode] probe, dxe/<GUEST> is a dangling symlink" "$root"
    rm -f "$root/dxe/$GUEST"

    eq "[$mode] probe through symlinked levels: the first outside tree is unchanged" "$before1" "$(tree_of "$out1")"
    eq "[$mode] probe through symlinked levels: the second outside tree is unchanged" "$before2" "$(tree_of "$out2")"
}
for mode in $SHELL_MODES; do
    level_cases "$mode"
done

# ---------------------------------------------------------------------------
test_section "WP4.2: an empty or \"-\" ROOT/PATH is refused on the host, with no ssh call (F4)"
# These calls must never reach a shell: ssh only records (exit 99), and
# recording no-op rm/chmod/chown/mv/find stand first on PATH; the cwd and
# OLDPWD are empty scratch directories that must stay empty.
NORUN_TOOLS="$(fake_tool_dir_create "$SCRATCH")"
NORUN_SSH_LOG="$SCRATCH/norun-ssh.log"
NORUN_TOOL_LOG="$SCRATCH/norun-tools.log"
fake_tool_write "$NORUN_TOOLS" ssh "$(printf 'printf "%%s\\n" "$*" >> %q\nexit 99' "$NORUN_SSH_LOG")"
for t in rm chmod chown mv find; do
    fake_tool_write "$NORUN_TOOLS" "$t" "$(printf 'printf "%%s %%s\\n" %q "$*" >> %q\nexit 0' "$t" "$NORUN_TOOL_LOG")"
done
F4_CWD="$(mktemp -d "$SCRATCH/dxe-f4-cwd.XXXXXX")"
F4_OLD="$(mktemp -d "$SCRATCH/dxe-f4-oldpwd.XXXXXX")"
nas_norun() {
    (
        cd "$F4_OLD" && cd "$F4_CWD" || exit 1
        export DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$PERSIST_FIXTURE_NAS_HOST"
        PATH="$NORUN_TOOLS:$PATH"
        export PATH
        "$@" </dev/null
    )
}
degenerate_case() { # LABEL OP ARGS...
    local label="$1" op="$2" out rc
    shift 2
    : >"$NORUN_SSH_LOG"
    : >"$NORUN_TOOL_LOG"
    out="$(nas_norun "dx_runtime_host_dir_$op" "$@" 2>"$SCRATCH/f4.err")"
    rc=$?
    nonzero "$label: non-zero" "$rc"
    eq "$label: nothing on stdout" "" "$out"
    nonempty_file "$label: a reason on stderr" "$SCRATCH/f4.err"
    eq "$label: no ssh call" "0" "$(wc -l <"$NORUN_SSH_LOG" | tr -d ' ')"
    eq "$label: no rm/chmod/chown/mv/find ran" "" "$(cat "$NORUN_TOOL_LOG")"
}
for v in "" "-"; do
    degenerate_case "probe ROOT=[$v]" probe "$v" "$GUEST"
    degenerate_case "create ROOT=[$v]" create "$v" "$GUEST" "$MARKER_TEXT"
    degenerate_case "marker_write PATH=[$v]" marker_write "$v" "$MARKER_TEXT"
    degenerate_case "usage PATH=[$v]" usage "$v"
done
eq "degenerate locations: the cwd stayed empty" "." "$(tree_of "$F4_CWD")"
eq "degenerate locations: OLDPWD stayed empty" "." "$(tree_of "$F4_OLD")"

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
