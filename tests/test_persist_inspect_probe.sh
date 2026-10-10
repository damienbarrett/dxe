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
#  Q-8 partial counts. A Q-8 count whose `find` exits non-zero (e.g. denied
#    to a non-root ssh user) is never reported as a number, even though a
#    `| wc -l` yields one: Q-8 status is `fail`, the affected field is `n/a`
#    (entries=n/a, hardlinks=n/a, appledouble=n/a or special=n/a), the
#    evidence contains the word `partial`, and the unaffected fields keep
#    their true values. With every find succeeding the word `partial` does
#    not appear.
#  Q-8 non-root note. When Q-9's remote uid (`id -u`) is not 0, the Q-8
#    evidence contains the word `non-root`; with uid 0 it does not. This does
#    not change either status.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "WP2.1b: inspection script hardening (probe verification, find failures)"

SUT="$BASE_DIR/tests/qnap/phase1-persist-inspect.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dxe-inspect-probe.XXXXXX")"
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
src=""; dst=""; entry=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rm) shift ;;
        --name|--label|--network|--user|-u|--workdir|-w|--cap-add|--security-opt|--pull) shift 2 ;;
        -v|--volume) src="${2%%:*}"; dst="${2#*:}"; dst="${dst%%:*}"; shift 2 ;;
        --entrypoint) entry="$2"; shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
image="${1:-}"; shift
echo "src=$src dst=$dst image=$image entry=$entry" >>"$DXE_TEST_RUN_LOG"
args=()
for a in "$@"; do args+=("${a//$dst/$DXE_TEST_SBX/mnt}"); done
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
    chmod "$DXE_TEST_MKDIR_FORCE_MODE" "$last"
fi
STUB
cat >"$FAKEBIN/find" <<'STUB'
#!/bin/bash
all="$*"
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
    *"find "*) PATH="$DXE_TEST_FAKEBIN:$PATH" exec /bin/bash -c "$last" ;;
    *"volume inspect"*) echo "$DXE_TEST_MOUNTPOINT"; exit 0 ;;
    *"$DXE_TEST_DOCKER info"*) echo "/opt/fixture-docker"; exit 0 ;;
    *"readlink -f"*) echo "$DXE_TEST_CANON"; exit 0 ;;
    *"df -P"*"$DXE_TEST_MOUNTPOINT"*)
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fixture-hdd 1000 100 900 10%% /opt/fixture-hdd\n'; exit 0 ;;
    *"df -P"*)
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fixture-ssd 1000 100 900 10%% /opt/fixture-ssd\n'; exit 0 ;;
    *"du -sk"*) printf '2048\t%s\n' "$DXE_TEST_MOUNTPOINT"; exit 0 ;;
    *"getfacl"*) echo 5; exit 0 ;;
    *"getfattr"*) echo 3; exit 0 ;;
    *"rsync --version"*)
        printf 'rsync  version 3.2.7  protocol version 31\nCapabilities:\n    64-bit files, 64-bit inums, hardlinks, symlinks, ACLs, xattrs\n'; exit 0 ;;
    *"rsync --help"*) echo "     --numeric-ids           don't map uid/gid values"; exit 0 ;;
    *"id -u"*) echo "${DXE_TEST_UID:-0}"; exit 0 ;;
    *"command -v "*) echo "/usr/bin/tool"; exit 0 ;;
    *"stat -c"*) echo "30033:30033 755"; exit 0 ;;
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
    test -z "$(grep -E '^(mkdir|chown|stat)' "$WORK/toollog" | grep -v -e '\.dxe-spike-' -e 'No such' )"

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

# 4. Q-8: the non-root note ----------------------------------------------------
DXE_TEST_UID=1000 run_inspect
E8="$(q_ev 8 "$OUT")"
check "non-root uid: statuses unchanged, exit 0" test "$RC" -eq 0 -a "$(statuses "$OUT")" = "$HAPPY"
check "non-root uid: Q-9 reports the uid" has "$(q_ev 9 "$OUT")" "uid=1000"
check "non-root uid: Q-8 evidence carries the non-root note" has "$E8" non-root
check "non-root uid: no partial marker when every find succeeds" lacks "$E8" partial

DXE_TEST_UID=1000 DXE_TEST_FIND_DENIED=entries run_inspect
E8="$(q_ev 8 "$OUT")"
check "non-root and denied: Q-8 fail with both the note and partial" \
    test "$RC" -eq 1 -a "$(q_status 8 "$OUT")" = fail
check "non-root and denied: both words are present" test "$(has "$E8" non-root && has "$E8" partial && echo y)" = y

print_summary
exit_with_code
