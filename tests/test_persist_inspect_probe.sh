#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP2.1b: hardening of tests/qnap/phase1-persist-inspect.sh before it runs
# against the real NAS (spec section 9 Q-8, Q-9, Q-10; plan Gate A).
# Companion to tests/test_persist_inspect_script.sh (WP2.1), which keeps
# pinning everything not listed here.
#
# Unlike the WP2.1 suite, this suite EXECUTES the remote commands the script
# sends: the ssh stub runs `docker run` probes and `find` pipelines locally
# under bash (the remote shell is assumed to be bash), with a fake `docker`
# (maps the bind-mount target onto a sandbox directory and runs the
# entrypoint there) and fake chown/stat/mkdir/find on PATH. So the cases
# assert on what the probe really does and on what a failing find really
# yields, not on source text.
#
# Interface contract (the implementer builds exactly this):
#
#  Probe location (Q-10, --write-probe). The probe's only directory is
#    <bind target>/.dxe-spike-<random> directly in the share root (the bind
#    target is the container-side path of DXE_QNAP_SHARE_ROOT). It never
#    depends on, and never creates, <root>/dxe. Everything it writes is
#    under that .dxe-spike-* path; it is removed at the end, also when a step
#    fails; the share root is left exactly as found.
#  Probe verification. The probe VERIFIES with the read-back command
#    `stat -c '%u:%g %a' <path>` (exactly that format; the stub rejects any
#    other):
#      chown:     `chown 30033:30033 <probe dir>`, then read back the probe
#                 dir; owner must be 30033:30033.
#      mkdir0700: `mkdir -m 0700 <probe dir>/.dxe-spike-0700` run as root
#                 (the container user), then read back; owner must be 0:0
#                 and mode 700.
#    The probe's stdout lines (one each):
#      chown=ok                      | chown=fail(observed=<uid:gid>)
#      mkdir0700=ok                  | mkdir0700=fail(observed=<uid:gid>/<mode>)
#    observed values are the read-back values (n/a if the read-back or the
#    creation itself failed). A chown command that exits 0 but changed
#    nothing, a root-squashed create (owner not 0:0) and a mode other than
#    700 are all `fail`. The Q-10 evidence copies the tokens verbatim, e.g.
#    `write-probe=fail chown=fail(observed=0:0) mkdir0700=ok`; all ok gives
#    `write-probe=ok chown=ok mkdir0700=ok`; Q-10 is `fail` on any fail.
#  Q-8 partial counts (WP2.1c: the finds run INSIDE the read-only inspection
#    container, see tests/test_persist_inspect_script.sh for its argv and its
#    tagged stdout lines). A Q-8 count whose `find` exits non-zero (e.g. denied) is never reported as a number, even though a
#    `| wc -l` yields one: Q-8 status is `fail`, the affected field is `n/a`
#    (entries=n/a, hardlinks=n/a, appledouble=n/a or special=n/a), the
#    evidence contains the word `partial`, and the unaffected fields keep
#    their true values. With every find succeeding the word `partial` does
#    not appear.
#  Q-8 non-root note (WP2.1c): the counts come from a root container, so the
#    Q-8 evidence NEVER contains `non-root` when the container read succeeded,
#    whatever Q-9's remote uid is.
#  Inspection container (WP2.1c), executed here for real: this suite runs the
#    `docker run --rm --network none -v <volume>:/v:ro --entrypoint sh <image>
#    -c <script>` command locally, with /v mapped to a sandbox directory and
#    fake df, du, find, stat, getfacl, getfattr on PATH (every one rejects a
#    path that is not /v). The script must print the tagged lines pinned in
#    test_persist_inspect_script.sh (fs=, mount=, df-error=, size_kb=, entries=,
#    hardlinks=, appledouble=, special=, acl=, xattr=, apple=, owner=, mode=)
#    and must not write: the write-verb stubs log, and the sandbox is compared
#    before and after. A df that fails or prints only a header gives Q-2 fail,
#    `df failed: <reason>`, never `fs=Filesystem`. du failing gives
#    size_kb=n/a and Q-8 fail (no `partial`). stat failing gives owner=n/a
#    mode=n/a and Q-10 fail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "WP2.1b: inspection script hardening (probe verification, find failures)"

SUT="$BASE_DIR/tests/qnap/phase1-persist-inspect.sh"

dxe_test_mktemp_dir WORK "${TMPDIR:-/tmp}/dxe-inspect-probe.XXXXXX"
trap 'rm -rf "$WORK"' EXIT

SHARE="/opt/fixture-share/dxe-persist"
CANON="/opt/fixture-pool-ssd/shares/dxe-persist"
MOUNTPOINT="/opt/fixture-docker/volumes/dx-qnap-persist/_data"
HOST="dxe-fixture-nas.invalid"
FAKEBIN="$WORK/fakebin"
DOCKERBIN="$WORK/dockerbin"
FAKE_DOCKER="$DOCKERBIN/docker"
SBX="$WORK/sbx"
mkdir -p "$FAKEBIN" "$DOCKERBIN" "$WORK/stubs"

# --- fake docker: only `run` is executed; it maps the -v target to the sandbox
cat >"$FAKE_DOCKER" <<'STUB'
#!/bin/bash
[ "${1:-}" = run ] || { echo "fake docker: unexpected subcommand: $*" >&2; exit 98; }
shift
src=""; dst=""; opts=""; entry=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rm) shift ;;
        --name|--label|--network|--user|-u|--workdir|-w|--cap-add|--security-opt|--pull) shift 2 ;;
        -v|--volume) src="${2%%:*}"; rest="${2#*:}"; dst="${rest%%:*}"; case "$rest" in *:*) opts="${rest#*:}" ;; esac; shift 2 ;;
        --entrypoint) entry="$2"; shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
image="${1:-}"; shift
echo "src=$src dst=$dst opts=$opts image=$image entry=$entry" >>"$DXE_TEST_RUN_LOG"
args=()
for a in "$@"; do args+=("$(printf '%s' "$a" | DST="$dst" REPL="$DXE_TEST_SBX/mnt" perl -0777 -pe 's{(?<![\w./-])\Q$ENV{DST}\E(?![\w-])}{$ENV{REPL}}g')"); done
PATH="$DXE_TEST_FAKEBIN:$PATH" exec "$entry" "${args[@]}"
STUB
chmod +x "$FAKE_DOCKER"

# --- fake chown / stat / mkdir (the "container" tools) and find (the NAS's)
cat >"$FAKEBIN/chown" <<'STUB'
#!/bin/bash
echo "chown $*" >>"$DXE_TEST_TOOL_LOG"
case "${DXE_TEST_CHOWN:-apply}" in
    fail) echo "chown: Operation not permitted" >&2; exit 1 ;;
    ignore) exit 0 ;;
esac
/bin/mkdir -p "$DXE_TEST_SBX/meta"
printf '%s\n' "$1" >"$DXE_TEST_SBX/meta/$(printf '%s' "$2" | tr / _)"
STUB
cat >"$FAKEBIN/stat" <<'STUB'
#!/bin/bash
echo "stat $*" >>"$DXE_TEST_TOOL_LOG"
if [ "${1:-}" != -c ] || [ "${2:-}" != '%u:%g %a' ] || [ "$#" -ne 3 ]; then
    echo "fake stat: unsupported invocation: $*" >&2
    exit 64
fi
[ -e "$3" ] || { echo "stat: cannot statx '$3'" >&2; exit 1; }
meta="$DXE_TEST_SBX/meta/$(printf '%s' "$3" | tr / _)"
if [ "${3%/}" = "$DXE_TEST_SBX/mnt" ]; then
    [ "${DXE_TEST_STAT_ROOT:-ok}" = fail ] && { echo "stat: cannot statx: Permission denied" >&2; exit 1; }
    printf "%s %s\n" "${DXE_TEST_ROOT_OWNER:-30033:30033}" "${DXE_TEST_ROOT_MODE:-755}"
    exit 0
fi
if [ -f "$meta" ]; then owner="$(cat "$meta")"; else owner="${DXE_TEST_CREATED_OWNER:-0:0}"; fi
mode="$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$3")"
printf '%s %s\n' "$owner" "$mode"
STUB
cat >"$FAKEBIN/mkdir" <<'STUB'
#!/bin/bash
echo "mkdir $*" >>"$DXE_TEST_TOOL_LOG"
/bin/mkdir "$@" || exit $?
if [ -n "${DXE_TEST_MKDIR_FORCE_MODE:-}" ]; then
    for last in "$@"; do :; done
    /bin/chmod "$DXE_TEST_MKDIR_FORCE_MODE" "$last"
fi
STUB
cat >"$FAKEBIN/find" <<'STUB'
#!/bin/bash
all="$*"
echo "find $*" >>"$DXE_TEST_TOOL_LOG"
if [ "${1%/}" != "$DXE_TEST_SBX/mnt" ]; then echo "find: wrong root: $*" >&2; exit 2; fi
case "$all" in
    *-links*) kind=hardlinks; full=7; partial=3 ;;
    *-name*) kind=appledouble; full=2; partial=1 ;;
    *"-type s"*) kind=special; full=1; partial=0 ;;
    *) kind=entries; full=4242; partial=10 ;;
esac
denied=0
case " ${DXE_TEST_FIND_DENIED:-} " in *" $kind "*|*" all "*) denied=1 ;; esac
n=$full
[ "$denied" -eq 1 ] && n=$partial
i=0
while [ "$i" -lt "$n" ]; do
    if [ "$kind" = appledouble ]; then echo "./dxe/._fixture$((i + 1))"; else echo "./f$i"; fi
    i=$((i + 1))
done
if [ "$denied" -eq 1 ]; then echo "find: './secret': Permission denied" >&2; exit 1; fi
exit 0
STUB
chmod +x "$FAKEBIN/chown" "$FAKEBIN/stat" "$FAKEBIN/mkdir" "$FAKEBIN/find"

# --- the inspection container's read tools: each accepts only the root /v
# (mapped to the sandbox) and fails otherwise; df/du/stat/find/getfacl/getfattr
# have knobs. Write verbs other than the probe's own are logged and refused.
cat >"$FAKEBIN/df" <<'STUB'
#!/bin/bash
echo "df $*" >>"$DXE_TEST_TOOL_LOG"
ok=0
for a in "$@"; do [ "${a%/}" = "$DXE_TEST_SBX/mnt" ] && ok=1; done
if [ "$ok" -ne 1 ]; then echo "df: wrong operand: $*" >&2; exit 2; fi
case "${DXE_TEST_DF:-ok}" in
    fail) echo "df: $DXE_TEST_SBX/mnt: Permission denied" >&2; exit 1 ;;
    header) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'; exit 0 ;;
esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fixture-hdd 1000 100 900 10%% /opt/fixture-hdd\n'
STUB
cat >"$FAKEBIN/du" <<'STUB'
#!/bin/bash
echo "du $*" >>"$DXE_TEST_TOOL_LOG"
ok=0
for a in "$@"; do [ "${a%/}" = "$DXE_TEST_SBX/mnt" ] && ok=1; done
if [ "$ok" -ne 1 ]; then echo "du: wrong operand: $*" >&2; exit 2; fi
if [ "${DXE_TEST_DU:-ok}" = fail ]; then echo "du: cannot read: Permission denied" >&2; exit 1; fi
printf '2048\t%s\n' "$DXE_TEST_SBX/mnt"
STUB
cat >"$FAKEBIN/getfacl" <<'STUB'
#!/bin/bash
echo "getfacl $*" >>"$DXE_TEST_TOOL_LOG"
i=0; while [ "$i" -lt 5 ]; do echo "# file: f$i"; echo "user::rw-"; echo; i=$((i + 1)); done
STUB
cat >"$FAKEBIN/getfattr" <<'STUB'
#!/bin/bash
echo "getfattr $*" >>"$DXE_TEST_TOOL_LOG"
i=0; while [ "$i" -lt 3 ]; do echo "# file: f$i"; echo "user.k=\"v\""; echo; i=$((i + 1)); done
STUB
for verb in chmod mv cp touch ln rmdir; do
    cat >"$FAKEBIN/$verb" <<'STUB'
#!/bin/bash
echo "$(basename "$0") $*" >>"$DXE_TEST_TOOL_LOG"
STUB
done
# rm only ever removes a probe directory inside the sandbox share root.
cat >"$FAKEBIN/rm" <<'STUB'
#!/bin/bash
echo "rm $*" >>"$DXE_TEST_TOOL_LOG"
[ -n "${DXE_TEST_SBX:-}" ] || exit 1
for a in "$@"; do
    case "$a" in
        -*) ;;
        "$DXE_TEST_SBX"/mnt/.dxe-spike-*) case "$a" in *..*) echo "fake rm: refused $a" >&2; exit 1 ;; esac ;;
        *) echo "fake rm: refused $a" >&2; exit 1 ;;
    esac
done
exec /bin/rm "$@"
STUB
chmod +x "$FAKEBIN/df" "$FAKEBIN/du" "$FAKEBIN/getfacl" "$FAKEBIN/getfattr" \
    "$FAKEBIN/chmod" "$FAKEBIN/mv" "$FAKEBIN/cp" "$FAKEBIN/touch" "$FAKEBIN/ln" "$FAKEBIN/rmdir" "$FAKEBIN/rm"

# --- ssh stub: docker run and find pipelines run locally, the rest is canned
cat >"$WORK/stubs/ssh" <<'STUB'
#!/bin/bash
n=$(ls "$DXE_TEST_CALLS" | wc -l | tr -d ' ')
printf '%s\n' "$@" >"$DXE_TEST_CALLS/$(printf '%04d' "$n").txt"
last=""
for a in "$@"; do last="$a"; done
[ "$last" = true ] && exit 0
case "$last" in
    "$DXE_TEST_DOCKER run"*) PATH="$DXE_TEST_FAKEBIN:$PATH" exec /bin/bash -c "$last" ;;
    *"volume inspect"*) echo "$DXE_TEST_MOUNTPOINT"; exit 0 ;;
    *"$DXE_TEST_DOCKER info"*) echo "/opt/fixture-docker"; exit 0 ;;
    *"readlink -f"*) echo "$DXE_TEST_CANON"; exit 0 ;;
    *"df -P"*)
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fixture-ssd 1000 100 900 10%% /opt/fixture-ssd\n'; exit 0 ;;
    *"rsync --version"*)
        printf 'rsync  version 3.2.7  protocol version 31\nCapabilities:\n    64-bit files, 64-bit inums, hardlinks, symlinks, ACLs, xattrs\n'; exit 0 ;;
    *"rsync --help"*) echo "     --numeric-ids           don't map uid/gid values"; exit 0 ;;
    *"id -u"*) echo "${DXE_TEST_UID:-0}"; exit 0 ;;
    *"command -v "*) echo "/usr/bin/tool"; exit 0 ;;
esac
echo "stub: unexpected remote command: $*" >&2
exit 97
STUB
chmod +x "$WORK/stubs/ssh"

# run_inspect <args...>: fresh sandbox share (with some pre-existing content),
# sets RC OUT ERR CALLS. Knobs are exported DXE_TEST_* variables.
RUN_N=0
run_inspect() {
    RUN_N=$((RUN_N + 1))
    local home="$WORK/home$RUN_N"
    CALLS="$WORK/calls$RUN_N"
    rm -rf "$SBX"
    mkdir -p "$home" "$CALLS" "$SBX/mnt/keep-dir"
    echo data >"$SBX/mnt/keep.txt"
    : >"$WORK/toollog"
    : >"$WORK/runlog"
    set +e
    OUT="$(cd "$WORK" && env HOME="$home" PATH="$WORK/stubs:$PATH" \
        DXE_QNAP_HOST="$HOST" DXE_QNAP_DOCKER="$FAKE_DOCKER" \
        DXE_QNAP_SHARE_ROOT="$SHARE" DXE_QNAP_PROBE_IMAGE="dxe-fixture-image:test" \
        DXE_TEST_CALLS="$CALLS" DXE_TEST_DOCKER="$FAKE_DOCKER" \
        DXE_TEST_MOUNTPOINT="$MOUNTPOINT" DXE_TEST_CANON="$CANON" \
        DXE_TEST_FAKEBIN="$FAKEBIN" DXE_TEST_SBX="$SBX" \
        DXE_TEST_TOOL_LOG="$WORK/toollog" DXE_TEST_RUN_LOG="$WORK/runlog" \
        DXE_TEST_UID="${DXE_TEST_UID:-0}" \
        DXE_TEST_CHOWN="${DXE_TEST_CHOWN:-apply}" \
        DXE_TEST_CREATED_OWNER="${DXE_TEST_CREATED_OWNER:-0:0}" \
        DXE_TEST_MKDIR_FORCE_MODE="${DXE_TEST_MKDIR_FORCE_MODE:-}" \
        DXE_TEST_FIND_DENIED="${DXE_TEST_FIND_DENIED:-}" \
        DXE_TEST_DF="${DXE_TEST_DF:-ok}" DXE_TEST_DU="${DXE_TEST_DU:-ok}" \
        DXE_TEST_STAT_ROOT="${DXE_TEST_STAT_ROOT:-ok}" \
        DXE_TEST_ROOT_OWNER="${DXE_TEST_ROOT_OWNER:-30033:30033}" DXE_TEST_ROOT_MODE="${DXE_TEST_ROOT_MODE:-755}" \
        /bin/bash "$SUT" "$@" 2>"$WORK/stderr")"
    RC=$?
    ERR="$(cat "$WORK/stderr")"
}

q_lines() { grep -E "^Q-$1 \| " <<<"$2"; }
q_status() { q_lines "$1" "$2" | head -n1 | awk -F' [|] ' '{print $2}'; }
q_ev() { q_lines "$1" "$2" | head -n1 | awk -F' [|] ' '{print $3}'; }
statuses() {
    local n out=""
    for n in 1 2 3 4 5 6 7 8 9 10; do out="$out$n=$(q_status "$n" "$1") "; done
    printf '%s' "$out"
}
check() { local d="$1"; shift; if "$@"; then test_pass "$d"; else test_fail "$d"; fi; }
has() { grep -Fq -- "$2" <<<"$1"; }
lacks() { ! grep -Fq -- "$2" <<<"$1"; }
no_crash() { test -z "$(grep -E 'unbound variable|command not found|syntax error' <<<"$ERR")"; }
# Names left in the sandbox share root, sorted, one line.
share_listing() { (cd "$SBX/mnt" 2>/dev/null && ls -A | sort | tr '\n' ' '); }
# The paths the fake tools were handed, joined.
tool_paths() { cat "$WORK/toollog"; }

HAPPY="1=ok 2=ok 3=manual 4=ok 5=manual 6=manual 7=manual 8=ok 9=ok 10=ok "

check "the script exists" test -f "$SUT"

# 1. Probe location and verification: the happy path -----------------------
run_inspect --write-probe
check "probe happy: exits 0 with the contract statuses" test "$RC" -eq 0 -a "$(statuses "$OUT")" = "$HAPPY"
check "probe happy: no crash output" no_crash
E10="$(q_ev 10 "$OUT")"
check "probe happy: evidence is write-probe=ok chown=ok mkdir0700=ok" has "$E10" "write-probe=ok chown=ok mkdir0700=ok"
check "probe happy: the container bound the share root" has "$(cat "$WORK/runlog")" "src=$SHARE "
check "probe happy: the share root is left exactly as found" test "$(share_listing)" = "keep-dir keep.txt "
check "probe happy: <root>/dxe was never created" test ! -e "$SBX/mnt/dxe"
check "probe happy: the probe dir is directly under the share root" \
    has "$(tool_paths)" "mkdir $SBX/mnt/.dxe-spike-"
check "probe happy: nothing is created under <root>/dxe" lacks "$(tool_paths)" "$SBX/mnt/dxe"
check "probe happy: chown 30033:30033 targets the probe dir" \
    has "$(tool_paths)" "chown 30033:30033 $SBX/mnt/.dxe-spike-"
check "probe happy: the 0700 directory is made with mkdir -m 0700" has "$(tool_paths)" "mkdir -m 0700 $SBX/mnt/.dxe-spike-"
check "probe happy: ownership is read back with stat -c '%u:%g %a' (twice)" \
    test "$(grep -c "^stat -c %u:%g %a $SBX/mnt/.dxe-spike-" "$WORK/toollog")" -ge 2
check "probe happy: every path the tools touched is a .dxe-spike- path" \
    test -z "$(grep -E '^(mkdir|chown|stat)' "$WORK/toollog" | grep -v -x -e "stat -c %u:%g %a $SBX/mnt" | grep -v -e "\.dxe-spike-" -e "No such")"

# 2. The probe verifies: it must not trust the exit status ------------------
DXE_TEST_CHOWN=ignore run_inspect --write-probe
E10="$(q_ev 10 "$OUT")"
check "silent chown: exit 1, Q-10 fail" test "$RC" -eq 1 -a "$(q_status 10 "$OUT")" = fail
check "silent chown: only Q-10 fails" test "$(statuses "$OUT")" = "1=ok 2=ok 3=manual 4=ok 5=manual 6=manual 7=manual 8=ok 9=ok 10=fail "
check "silent chown: evidence reports the observed owner" has "$E10" "chown=fail(observed=0:0)"
check "silent chown: the 0700 check still reports ok" has "$E10" "mkdir0700=ok"
check "silent chown: write-probe=fail" has "$E10" "write-probe=fail"
check "silent chown: the probe is still removed" test "$(share_listing)" = "keep-dir keep.txt "

DXE_TEST_CHOWN=fail run_inspect --write-probe
E10="$(q_ev 10 "$OUT")"
check "failing chown: Q-10 fail with the observed owner" test "$RC" -eq 1 -a "$(q_status 10 "$OUT")" = fail
check "failing chown: evidence chown=fail(observed=0:0)" has "$E10" "chown=fail(observed=0:0)"
check "failing chown: the probe is still removed" test "$(share_listing)" = "keep-dir keep.txt "

DXE_TEST_CREATED_OWNER=65534:65534 run_inspect --write-probe
E10="$(q_ev 10 "$OUT")"
check "root squash: exit 1, Q-10 fail" test "$RC" -eq 1 -a "$(q_status 10 "$OUT")" = fail
check "root squash: mkdir0700 reports the squashed owner and the mode" has "$E10" "mkdir0700=fail(observed=65534:65534/700)"
check "root squash: the probe is still removed" test "$(share_listing)" = "keep-dir keep.txt "

DXE_TEST_MKDIR_FORCE_MODE=755 run_inspect --write-probe
E10="$(q_ev 10 "$OUT")"
check "mode not honoured: Q-10 fail" test "$RC" -eq 1 -a "$(q_status 10 "$OUT")" = fail
check "mode not honoured: mkdir0700 reports the observed mode" has "$E10" "mkdir0700=fail(observed=0:0/755)"
check "mode not honoured: chown is unaffected" has "$E10" "chown=ok"
check "mode not honoured: the probe is still removed" test "$(share_listing)" = "keep-dir keep.txt "

# 3. Q-8: a failing find is not a clean count ----------------------------------
run_inspect
E8="$(q_ev 8 "$OUT")"
check "clean finds: Q-8 ok with true counts" test "$(q_status 8 "$OUT")" = ok
check "clean finds: counts are the real ones" has "$E8" "entries=4242 hardlinks=7 appledouble=2 special=1"
check "clean finds: the word partial does not appear" lacks "$E8" partial
check "clean finds: root, so no non-root note" lacks "$E8" non-root

partial_case() { # partial_case <kind> <field=bad> <description>
    DXE_TEST_FIND_DENIED="$1" run_inspect
    local ev; ev="$(q_ev 8 "$OUT")"
    check "$3: exit 1" test "$RC" -eq 1
    check "$3: only Q-8 fails, all ten still reported" \
        test "$(statuses "$OUT")" = "1=ok 2=ok 3=manual 4=ok 5=manual 6=manual 7=manual 8=fail 9=ok 10=ok "
    check "$3: the failed count is n/a ($2)" has "$ev" "$2"
    check "$3: evidence is marked partial" has "$ev" partial
    check "$3: no crash output" no_crash
    DXE_TEST_FIND_DENIED=""
}
partial_case entries entries=n/a "entries find denied"
partial_case hardlinks hardlinks=n/a "hardlinks find denied"
partial_case appledouble appledouble=n/a "._* find denied"
partial_case special special=n/a "special-file find denied"

DXE_TEST_FIND_DENIED=entries run_inspect
E8="$(q_ev 8 "$OUT")"
check "one denied find: the partial under-count is not reported" lacks "$E8" "entries=10"
check "one denied find: the other counts keep their true values" has "$E8" "hardlinks=7 appledouble=2 special=1"
check "one denied find: size is still reported" has "$E8" "size_kb=2048"
DXE_TEST_FIND_DENIED=""

DXE_TEST_FIND_DENIED=all run_inspect
E8="$(q_ev 8 "$OUT")"
check "every find denied: Q-8 fail, exit 1, partial" test "$RC" -eq 1 -a "$(q_status 8 "$OUT")" = fail
check "every find denied: all four counts are n/a" \
    has "$E8" "entries=n/a hardlinks=n/a appledouble=n/a special=n/a"
DXE_TEST_FIND_DENIED=""


# 4. Q-8: no non-root note when the container read the volume -------------------
DXE_TEST_UID=1000 run_inspect
E8="$(q_ev 8 "$OUT")"
check "non-root ssh uid: statuses unchanged, exit 0" test "$RC" -eq 0 -a "$(statuses "$OUT")" = "$HAPPY"
check "non-root ssh uid: Q-9 still reports the uid" has "$(q_ev 9 "$OUT")" "uid=1000"
check "non-root ssh uid: the container read the volume, so no non-root note" lacks "$E8" non-root
check "non-root ssh uid: true counts from the container" has "$E8" "size_kb=2048 entries=4242 hardlinks=7 appledouble=2 special=1 acl=5 xattr=3"
check "non-root ssh uid: no partial marker" lacks "$E8" partial

DXE_TEST_UID=1000 DXE_TEST_FIND_DENIED=entries run_inspect
E8="$(q_ev 8 "$OUT")"
check "non-root and denied: Q-8 fail, partial, still no non-root note" \
    test "$RC" -eq 1 -a "$(q_status 8 "$OUT")" = fail -a "$(has "$E8" partial && lacks "$E8" non-root && echo y)" = y

# 5. WP2.1c: the inspection container really runs, read-only, on /v -----------------
run_inspect
E2="$(q_ev 2 "$OUT")"
E8="$(q_ev 8 "$OUT")"
E10="$(q_ev 10 "$OUT")"
check "container: the volume is bound by name, on /v, read-only" \
    has "$(cat "$WORK/runlog")" "src=dx-qnap-persist dst=/v opts=ro image=dxe-fixture-image:test entry=sh"
check "container: exactly one container run without --write-probe" test "$(grep -c . "$WORK/runlog")" = 1
check "container: Q-2 filesystem and mount come from the container's df" has "$E2" "fs=/dev/fixture-hdd mount=/opt/fixture-hdd"
check "container: Q-2 keeps mountpoint and volume" has "$E2" "mountpoint=$MOUNTPOINT"
check "container: Q-2 is ok and never shows the df header" test "$(q_status 2 "$OUT")" = ok -a "$(lacks "$E2" Filesystem && echo y)" = y
check "container: Q-8 counts" has "$E8" "size_kb=2048 entries=4242 hardlinks=7 appledouble=2 special=1 acl=5 xattr=3"
check "container: Q-8 lists the ._ files" test "$(has "$E8" ._fixture1 && has "$E8" ._fixture2 && echo y)" = y
check "container: Q-10 owner and mode are the volume root's" has "$E10" "owner=30033:30033 mode=755 write-probe=skipped"
check "container: every read tool was handed the sandbox root, once per tool at least" \
    test "$(for t in df du find stat getfacl getfattr; do grep -Fq "$t " "$WORK/toollog" && echo y; done | wc -l | tr -d ' ')" = 6
check "container: no write verb ran" test -z "$(grep -E '^(mkdir|chown|chmod|rm|rmdir|mv|cp|touch|ln) ' "$WORK/toollog")"
check "container: the sandbox is exactly as found" test "$(share_listing)" = "keep-dir keep.txt " -a "$(cat "$SBX/mnt/keep.txt")" = data
check "container: nothing but the share was created in the sandbox" test "$(cd "$SBX" && ls -A | tr '\n' ' ')" = "mnt "
check "container: the host never reads the mountpoint (every other ssh call lacks it)" \
    test -z "$(for f in "$CALLS"/*.txt; do grep -Fl ':/v:ro' "$f" >/dev/null || grep -F "$MOUNTPOINT" "$f"; done)"
check "container: no host-side df of the mountpoint" \
    test -z "$(for f in "$CALLS"/*.txt; do tr '\n' ' ' <"$f" | grep -F "df -P $MOUNTPOINT"; done)"

# 6. WP2.1c: df is never parsed blindly ------------------------------------------------
DXE_TEST_DF=fail run_inspect
E2="$(q_ev 2 "$OUT")"
check "df fails in the container: Q-2 fail, exit 1" test "$RC" -eq 1 -a "$(q_status 2 "$OUT")" = fail
check "df fails: evidence is df failed: <the first stderr line>" has "$E2" "df failed: df: $SBX/mnt: Permission denied"
check "df fails: the header is never data" test "$(lacks "$E2" fs=Filesystem && lacks "$E2" "mount=on" && echo y)" = y
check "df fails: Q-8 and Q-10 are unaffected" \
    test "$(statuses "$OUT")" = "1=ok 2=fail 3=manual 4=ok 5=manual 6=manual 7=manual 8=ok 9=ok 10=ok "
check "df fails: no crash output" no_crash
DXE_TEST_DF=header run_inspect
E2="$(q_ev 2 "$OUT")"
check "df prints only a header: Q-2 fail, exit 1" test "$RC" -eq 1 -a "$(q_status 2 "$OUT")" = fail
check "df prints only a header: df failed, never fs=Filesystem" test "$(has "$E2" "df failed" && lacks "$E2" fs=Filesystem && echo y)" = y
DXE_TEST_DF=ok

# 7. WP2.1c: du and stat failing inside the container ----------------------------------
DXE_TEST_DU=fail run_inspect
E8="$(q_ev 8 "$OUT")"
check "du fails: only Q-8 fails" test "$RC" -eq 1 -a "$(statuses "$OUT")" = "1=ok 2=ok 3=manual 4=ok 5=manual 6=manual 7=manual 8=fail 9=ok 10=ok "
check "du fails: size_kb=n/a, other counts true, not partial" test "$(has "$E8" "size_kb=n/a entries=4242" && lacks "$E8" partial && echo y)" = y
DXE_TEST_DU=ok
DXE_TEST_STAT_ROOT=fail run_inspect
E10="$(q_ev 10 "$OUT")"
check "stat fails: only Q-10 fails" test "$RC" -eq 1 -a "$(statuses "$OUT")" = "1=ok 2=ok 3=manual 4=ok 5=manual 6=manual 7=manual 8=ok 9=ok 10=fail "
check "stat fails: owner=n/a mode=n/a" has "$E10" "owner=n/a mode=n/a"
DXE_TEST_STAT_ROOT=ok
DXE_TEST_ROOT_OWNER=0:0 DXE_TEST_ROOT_MODE=700 run_inspect
check "owner and mode are read, not hard-coded" has "$(q_ev 10 "$OUT")" "owner=0:0 mode=700"
check "root-owned 0700 volume root is still Q-10 ok" test "$(q_status 10 "$OUT")" = ok

# 8. WP2.1c: with --write-probe the inspection container stays read-only ----------------
run_inspect --write-probe
check "probe + inspection: two container runs, the first read-only on the volume" \
    test "$(grep -c . "$WORK/runlog")" = 2 -a "$(grep -c 'opts=ro ' "$WORK/runlog")" = 1
check "probe + inspection: only the probe container binds the share root" \
    test "$(grep -F "src=$SHARE " "$WORK/runlog" | grep -c .)" = 1 -a "$(grep -F "src=$SHARE " "$WORK/runlog" | grep -c 'opts=ro')" = 0
check "probe + inspection: statuses all ok" test "$(statuses "$OUT")" = "$HAPPY"
check "probe + inspection: Q-10 has the volume root's owner and the probe result" \
    has "$(q_ev 10 "$OUT")" "owner=30033:30033 mode=755 write-probe=ok chown=ok mkdir0700=ok"

print_summary
exit_with_code
