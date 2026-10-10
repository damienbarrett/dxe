#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP2.1: tests/qnap/phase1-persist-inspect.sh (spec section 9 "QNAP
# inspection", checks Q-1 .. Q-10).
#
# Interface contract (the implementer builds exactly this):
#
#  Invocation:  tests/qnap/phase1-persist-inspect.sh [--write-probe]
#                   [--report FILE] [--help]
#    unknown argument -> exit 2 + usage on stderr. --help -> usage, exit 0.
#  Environment:
#    DXE_QNAP_HOST            ssh_config alias (default: the phase-0 alias), as phase0.
#    DXE_QNAP_DOCKER          absolute docker path ON THE NAS. When set, no
#                             discovery call is made (tests set it).
#    DXE_QNAP_SHARE_ROOT      REQUIRED: candidate share path on the NAS.
#                             Unset/empty -> exit 2, message names the
#                             variable, no ssh call, no report.
#    DXE_QNAP_PERSIST_VOLUME  volume to inspect (default dx-qnap-persist).
#    DXE_QNAP_PROBE_IMAGE     image for the write probe (default: the script's
#                             choice; tests set it and expect it in the argv).
#  Transport: everything runs as `ssh <phase0 ssh opts> <host> <remote
#    command...>` (tests/qnap/lib/phase0-common.sh). Never the local docker
#    CLI. The first call is the reachability preflight `... <host> true`;
#    if it fails: exit 1, stderr contains "cannot reach", no report file, no
#    Q-lines. Every docker call is `<DXE_QNAP_DOCKER> <subcommand> ...`.
#  One ssh invocation per probe, with these literal fragments in its remote
#  command (the stub dispatches on them; an unrecognised command makes the
#  stub exit 97, so stray commands fail the run):
#    Q-1  `readlink -f <share-root>`        -> canonical path
#         `df -P <share-root>`              -> header + one row; the row's
#                                              filesystem + mount are evidence
#    Q-2  `<docker> volume inspect --format '{{.Mountpoint}}' <volume>`
#                                           -> mountpoint (plain path)
#         `df -P <mountpoint>`
#    Q-4  `<docker> info`                   -> prints DockerRootDir; evidence
#                                              carries that path
#    Q-8  `du -sk <mountpoint>`             -> "<kb>\t<path>"
#         `find <mp> ... | wc -l`           -> entry count (no -links/-name/
#                                              special -type fragments)
#         `find <mp> -type f -links +1 ... | wc -l`     -> hard-link count
#         `find <mp> -name '._*'`           -> one path per line
#         ONE find with `-type s`, `-type p`, `-type b`, `-type c` joined by
#         -o, piped to `wc -l`              -> special-file count
#         `getfacl ...` / `getfattr ...`    -> a count each (already counted
#                                              remotely, a bare integer)
#    Q-9  `rsync --version`, `rsync --help` (the latter must contain
#         --numeric-ids), `id -u`, and one `command -v <tool>` per tool for
#         readlink mv du mktemp (tools are detected ONLY via `command -v`).
#    Q-10 `stat -c '%u:%g %a' <mountpoint>` -> "<uid>:<gid> <octal mode>"
#  Report: one line per check, exactly ten, shape
#         Q-<n> | <status> | <one-line evidence>
#    status is ok|fail|manual|unknown. The same ten lines go to stdout and
#    to the report file (other report/stdout lines never start with "Q-").
#    Q-3, Q-5, Q-6, Q-7 are always `manual`. Q-1, 2, 4, 8, 9, 10 are `ok`
#    when their commands succeed and `fail` when one fails (the script goes
#    on to the remaining checks). `Report: <path>` is printed on stdout.
#    Overall exit: 0 when no check is `fail`, else 1.
#    Evidence tokens (fixed strings; other text is free):
#      Q-1  canonical=<readlink output> fs=<df filesystem> mount=<df mount>
#      Q-2  mountpoint=<path> fs=<df filesystem> mount=<df mount>
#      Q-4  DockerRootDir=<path>
#      Q-8  size_kb=<n> entries=<n> hardlinks=<n> appledouble=<n>
#           special=<n> acl=<n> xattr=<n> and the `._*` paths themselves
#      Q-9  rsync=<version> hardlinks=yes|no acls=yes|no xattrs=yes|no
#           numeric-ids=yes|no uid=<id -u> tools=ok  (tools=missing:<name>
#           and status fail when a `command -v` fails)
#      Q-10 owner=<uid:gid> mode=<octal> write-probe=skipped|ok|fail
#           (with the probe also: chown=ok|fail mkdir0700=ok|fail, copied
#           from the probe container's stdout lines of the same names)
#  Report file: default $HOME/dxe-recovery/qnap/phase1-persist-inspect-
#    <UTC date>.md, overwritten (not appended) by a re-run; --report FILE
#    overrides. Nothing is ever written inside the repository.
#  --write-probe (Q-10 only): exactly one ssh call whose remote command is
#    `<docker> run` with `--name dxe-spike-<suffix>`,
#    `--label dxe.role=spike`, DXE_QNAP_PROBE_IMAGE, and a bind whose source
#    is DXE_QNAP_SHARE_ROOT. Inside it: mkdir of
#    <root>/dxe/.dxe-spike-<random>, `chown`, a root-owned 0700 mkdir, then
#    removal of that one directory (no globs, no `..`). The only write verbs
#    anywhere are mkdir, chown, rm, rmdir, and every operand contains
#    `.dxe-spike-` (or is a variable assigned from such a path in the same
#    command). Docker subcommands used overall: info, volume inspect, run.
#    The probe's stdout is `chown=ok|fail` and `mkdir0700=ok|fail` lines;
#    any `=fail` makes Q-10 `fail`, and the removal still happens.
#  Without --write-probe: no write verb at all (mkdir chown chmod rm rmdir
#    mv cp touch ln), no `docker run|create|rm|volume create|volume rm`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "WP2.1: QNAP persist inspection script"

SUT="$BASE_DIR/tests/qnap/phase1-persist-inspect.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dxe-inspect-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAKE_DOCKER="/opt/fake/docker"
SHARE="/opt/fixture-share/dxe-persist"
CANON="/opt/fixture-pool-ssd/shares/dxe-persist"
MOUNTPOINT="/opt/fixture-docker/volumes/dx-qnap-persist/_data"
VOLUME="dx-qnap-persist"
HOST="dxe-fixture-nas.invalid"

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# Recording ssh: one file per invocation, one argument per line, so a
# multi-line remote script stays a single record.
cat >"$STUBS/ssh" <<'STUB'
#!/bin/bash
n=$(ls "$DXE_TEST_CALLS" | wc -l | tr -d ' ')
f="$DXE_TEST_CALLS/$(printf '%04d' "$n").txt"
printf '%s\n' "$@" >"$f"
all="$*"
last=""
for a in "$@"; do last="$a"; done
if [ "$last" = true ]; then
    [ -n "${DXE_TEST_UNREACHABLE:-}" ] && exit 255
    exit 0
fi
if [ -n "${DXE_TEST_FAIL_MATCH:-}" ]; then
    case "$all" in *"$DXE_TEST_FAIL_MATCH"*) echo "stub: injected failure" >&2; exit 1 ;; esac
fi
case "$all" in
    *"$DXE_TEST_DOCKER run"*)
        echo "chown=${DXE_TEST_PROBE_CHOWN:-ok}"
        echo "mkdir0700=${DXE_TEST_PROBE_MKDIR:-ok}"
        exit 0 ;;
    *"volume inspect"*) echo "$DXE_TEST_MOUNTPOINT"; exit 0 ;;
    *"$DXE_TEST_DOCKER info"*) echo "DockerRootDir=/opt/fixture-docker"; echo "/opt/fixture-docker"; exit 0 ;;
    *"readlink -f"*) echo "$DXE_TEST_CANON"; exit 0 ;;
    *"df -P"*"$DXE_TEST_MOUNTPOINT"*)
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fixture-hdd 1000 100 900 10%% /opt/fixture-hdd\n'; exit 0 ;;
    *"df -P"*)
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fixture-ssd 1000 100 900 10%% /opt/fixture-ssd\n'; exit 0 ;;
    *"du -sk"*) printf '2048\t%s\n' "$DXE_TEST_MOUNTPOINT"; exit 0 ;;
    *"-links +1"*) echo 7; exit 0 ;;
    *"-type s"*) echo 1; exit 0 ;;
    *"._"*) printf './dxe/._fixture1\n./home/._fixture2\n'; exit 0 ;;
    *"find "*) echo 4242; exit 0 ;;
    *"getfacl"*) echo 5; exit 0 ;;
    *"getfattr"*) echo 3; exit 0 ;;
    *"rsync --version"*)
        printf 'rsync  version 3.2.7  protocol version 31\nCapabilities:\n    64-bit files, 64-bit inums, hardlinks, symlinks, ACLs, xattrs\n'; exit 0 ;;
    *"rsync --help"*) echo "     --numeric-ids           don't map uid/gid values by user/group name"; exit 0 ;;
    *"id -u"*) echo 0; exit 0 ;;
    *"command -v "*) echo "/usr/bin/tool"; exit 0 ;;
    *"stat -c"*) echo "30033:30033 755"; exit 0 ;;
esac
echo "stub: unexpected remote command: $all" >&2
exit 97
STUB
chmod +x "$STUBS/ssh"

# The local docker CLI must never be used: it records and fails.
cat >"$STUBS/docker" <<'STUB'
#!/bin/bash
echo "local docker called: $*" >>"$DXE_TEST_LOCAL_DOCKER"
exit 99
STUB
chmod +x "$STUBS/docker"

# run_inspect <args...>: sets RC OUT ERR HOME_DIR CALLS. Extra env goes in
# via exported DXE_TEST_* variables set by the caller beforehand.
RUN_N=0
run_inspect() {
    RUN_N=$((RUN_N + 1))
    HOME_DIR="$WORK/home$RUN_N"
    CALLS="$WORK/calls$RUN_N"
    mkdir -p "$HOME_DIR" "$CALLS"
    : >"$WORK/localdocker$RUN_N"
    LOCAL_DOCKER_LOG="$WORK/localdocker$RUN_N"
    run_inspect_in "$HOME_DIR" "$CALLS" "$@"
}

run_inspect_in() {
    local home="$1" calls="$2"
    shift 2
    set +e
    OUT="$(cd "$WORK" && env HOME="$home" PATH="$STUBS:$PATH" \
        DXE_QNAP_HOST="$HOST" DXE_QNAP_DOCKER="$FAKE_DOCKER" \
        DXE_QNAP_SHARE_ROOT="${DXE_TEST_SHARE_ROOT-$SHARE}" \
        DXE_QNAP_PROBE_IMAGE="dxe-fixture-image:test" \
        DXE_TEST_CALLS="$calls" DXE_TEST_DOCKER="$FAKE_DOCKER" \
        DXE_TEST_MOUNTPOINT="$MOUNTPOINT" DXE_TEST_CANON="$CANON" \
        DXE_TEST_LOCAL_DOCKER="$LOCAL_DOCKER_LOG" \
        DXE_TEST_FAIL_MATCH="${DXE_TEST_FAIL_MATCH:-}" \
        DXE_TEST_UNREACHABLE="${DXE_TEST_UNREACHABLE:-}" \
        DXE_TEST_PROBE_CHOWN="${DXE_TEST_PROBE_CHOWN:-ok}" \
        DXE_TEST_PROBE_MKDIR="${DXE_TEST_PROBE_MKDIR:-ok}" \
        /bin/bash "$SUT" "$@" 2>"$WORK/stderr")"
    RC=$?
    ERR="$(cat "$WORK/stderr")"
}

# --- helpers over the recorded transcript -------------------------------

call_files() { ls "$CALLS"/*.txt 2>/dev/null; }
all_calls_text() { local f; for f in $(call_files); do cat "$f"; done; }

# Normalised text of one call: args joined by spaces, `command -v <tool>`
# presence checks removed, shell separators made into " ; " tokens.
norm_call() {
    tr '\n' ' ' <"$1" | sed -E -e 's/command -v [A-Za-z0-9_.-]+/ /g' \
        -e 's/[;&|()]/ ; /g' -e "s/[\"']/ /g" | tr -s ' '
}

# scan_writes <call-file>: prints VERB:<verb> for each write verb and
# BADOPERAND:<token> for each write operand that is not a .dxe-spike- path.
scan_writes() {
    local text tok mode="" assigned=0
    text="$(norm_call "$1")"
    if grep -Eq '[A-Za-z_]+=[^ ]*\.dxe-spike-' <<<"$text"; then assigned=1; fi
    set -f
    for tok in $text; do
        if [ "$tok" = ";" ]; then mode=""; continue; fi
        if [ -z "$mode" ]; then
            case "$tok" in
                mkdir|chown|chmod|rm|rmdir|mv|cp|touch|ln)
                    mode="$tok"; echo "VERB:$tok" ;;
                -delete) echo "VERB:-delete" ;;
            esac
            continue
        fi
        case "$tok" in
            -*) continue ;;
        esac
        if grep -Eq '^[0-9]+(:[0-9]+)?$' <<<"$tok"; then continue; fi
        case "$tok" in
            *\**|*..*) echo "BADOPERAND:$tok"; continue ;;
            *.dxe-spike-*) continue ;;
            \$*) [ "$assigned" -eq 1 ] && continue ;;
        esac
        echo "BADOPERAND:$tok"
    done
    set +f
}

all_writes() {
    local f
    for f in $(call_files); do scan_writes "$f"; done
}

docker_subs() {
    local f
    for f in $(call_files); do
        norm_call "$f" | grep -oE "$FAKE_DOCKER [a-z]+( [a-z]+)?" | sed -E "s#^$FAKE_DOCKER ##"
    done
}

# q_line <n> <text>: the report/stdout lines for check n.
q_lines() { grep -E "^Q-$1 \| " <<<"$2"; }
q_count() { q_lines "$1" "$2" | grep -c . ; }
q_status() { q_lines "$1" "$2" | head -n1 | awk -F' [|] ' '{print $2}'; }
q_ev() { q_lines "$1" "$2" | head -n1 | awk -F' [|] ' '{print $3}'; }

statuses() {
    local n out=""
    for n in 1 2 3 4 5 6 7 8 9 10; do out="$out$n=$(q_status "$n" "$1") "; done
    printf '%s' "$out"
}

check() { # check <description> <command...>
    local d="$1"
    shift
    if "$@"; then test_pass "$d"; else test_fail "$d"; fi
}

has() { grep -Fq -- "$2" <<<"$1"; }

report_file() { ls "$HOME_DIR"/dxe-recovery/qnap/phase1-persist-inspect-*.md 2>/dev/null | head -n1; }

HAPPY="1=ok 2=ok 3=manual 4=ok 5=manual 6=manual 7=manual 8=ok 9=ok 10=ok "

# ------------------------------------------------------------------------
check "the script exists" test -f "$SUT"
if [ ! -f "$SUT" ]; then
    test_fail "(remaining cases cannot run without the script)"
fi

# 1. Happy path: ten lines, statuses, evidence ----------------------------
REPO_BEFORE="$(git -C "$BASE_DIR" status --porcelain 2>/dev/null)"
run_inspect
check "happy run exits 0 with no crash output" test "$RC" -eq 0 -a -z "$(grep -E 'unbound variable|command not found|syntax error' <<<"$ERR")"
n=1
while [ "$n" -le 10 ]; do
    check "stdout has exactly one Q-$n line" test "$(q_count "$n" "$OUT")" = 1
    n=$((n + 1))
done
check "statuses match the contract (manual: Q-3,5,6,7)" test "$(statuses "$OUT")" = "$HAPPY"
RF="$(report_file)"
check "report file lands under HOME/dxe-recovery/qnap" test -n "$RF" -a -f "${RF:-/nonexistent}"
REPORT_TEXT="$(cat "${RF:-/nonexistent}" 2>/dev/null)"
check "report file carries the same statuses" test "$(statuses "$REPORT_TEXT")" = "$HAPPY"
n=1
while [ "$n" -le 10 ]; do
    check "report file has exactly one Q-$n line" test "$(q_count "$n" "$REPORT_TEXT")" = 1
    n=$((n + 1))
done
check "stdout names the report path" has "$OUT" "Report: $RF"
check "nothing written inside the repository" test "$(git -C "$BASE_DIR" status --porcelain 2>/dev/null)" = "$REPO_BEFORE"
check "local docker CLI never used" test -n "$(call_files)" -a ! -s "$LOCAL_DOCKER_LOG"

E1="$(q_ev 1 "$OUT")"
check "Q-1 evidence: canonical path" has "$E1" "canonical=$CANON"
check "Q-1 evidence: filesystem and mount" has "$E1" "fs=/dev/fixture-ssd"
check "Q-1 evidence: mount point" has "$E1" "mount=/opt/fixture-ssd"
E2="$(q_ev 2 "$OUT")"
check "Q-2 evidence: volume mountpoint" has "$E2" "mountpoint=$MOUNTPOINT"
check "Q-2 evidence: the volume's pool differs from the share's" has "$E2" "fs=/dev/fixture-hdd"
check "Q-4 evidence: DockerRootDir" has "$(q_ev 4 "$OUT")" "DockerRootDir=/opt/fixture-docker"
E8="$(q_ev 8 "$OUT")"
for kv in size_kb=2048 entries=4242 hardlinks=7 appledouble=2 special=1 acl=5 xattr=3 ._fixture1 ._fixture2; do
    check "Q-8 evidence has $kv" has "$E8" "$kv"
done
E9="$(q_ev 9 "$OUT")"
for kv in rsync=3.2.7 hardlinks=yes acls=yes xattrs=yes numeric-ids=yes uid=0 tools=ok; do
    check "Q-9 evidence has $kv" has "$E9" "$kv"
done
E10="$(q_ev 10 "$OUT")"
for kv in owner=30033:30033 mode=755 write-probe=skipped; do
    check "Q-10 evidence has $kv" has "$E10" "$kv"
done

# 2. Transport and no-write contract --------------------------------------
FIRST="$(call_files | head -n1)"
check "first ssh call is the reachability preflight" test "$(tail -n1 "$FIRST")" = true
check "every ssh call is non-interactive and targets the alias" \
    test "$(for f in $(call_files); do grep -Fxq 'BatchMode=yes' "$f" && grep -Fxq "$HOST" "$f" && echo y; done | wc -l | tr -d ' ')" = "$(call_files | wc -l | tr -d ' ')"
check "docker is reached as <DXE_QNAP_DOCKER> over ssh" has "$(all_calls_text)" "$FAKE_DOCKER volume inspect"
check "volume inspect names the configured volume" has "$(all_calls_text)" "$VOLUME"
check "no write verb reaches the NAS without --write-probe (and calls were made)" test -n "$(call_files)" -a -z "$(all_writes)"
check "docker subcommands are only info and volume inspect without the probe" \
    test "$(docker_subs | sort -u | tr '\n' ',')" = "info,volume inspect,"
for t in readlink mv du mktemp; do
    check "Q-9 checks tool $t with command -v" has "$(all_calls_text)" "command -v $t"
done
FILES_BEFORE="$(find "$HOME_DIR" -type f | wc -l | tr -d ' ')"

# 3. Idempotent re-run overwrites ------------------------------------------
mkdir -p "$WORK/calls_again2"
CALLS="$WORK/calls_again2"
run_inspect_in "$HOME_DIR" "$CALLS"
check "re-run exits 0" test "$RC" -eq 0
check "re-run keeps a single report file" test "$(find "$HOME_DIR" -type f | wc -l | tr -d ' ')" = "$FILES_BEFORE"
check "re-run does not append to the report" test "$(q_count 1 "$(cat "$(report_file)")")" = 1

# 4. --report FILE ----------------------------------------------------------
run_inspect --report "$WORK/custom-report.md"
check "--report FILE writes there" test -f "$WORK/custom-report.md"
check "--report FILE has ten Q lines" test "$(grep -cE '^Q-[0-9]+ \| ' "$WORK/custom-report.md")" = 10

# 5. Argument and environment errors -----------------------------------------
run_inspect --bogus
check "unknown argument exits 2" test "$RC" -eq 2
check "unknown argument sends no ssh call" test -z "$(call_files)"
DXE_TEST_SHARE_ROOT="" run_inspect
check "missing DXE_QNAP_SHARE_ROOT exits 2" test "$RC" -eq 2
check "missing DXE_QNAP_SHARE_ROOT names the variable" has "$ERR" "DXE_QNAP_SHARE_ROOT"
check "missing DXE_QNAP_SHARE_ROOT makes no ssh call" test -z "$(call_files)"
check "missing DXE_QNAP_SHARE_ROOT writes no report" test -z "$(report_file)"
run_inspect --help
check "--help exits 0" test "$RC" -eq 0
check "--help makes no ssh call" test -z "$(call_files)"

# 6. Unreachable host --------------------------------------------------------
DXE_TEST_UNREACHABLE=1 run_inspect
check "unreachable host exits 1" test "$RC" -eq 1
check "unreachable host says cannot reach" has "$ERR" "cannot reach"
check "unreachable host writes no report" test -z "$(report_file)"
check "unreachable host prints no Q lines" test "$(q_count 1 "$OUT")" = 0
check "unreachable host stops after the preflight" test "$(call_files | wc -l | tr -d ' ')" = 1
unset DXE_TEST_UNREACHABLE

# 7. A failing remote command is reported, the rest still runs --------------
fail_case() { # fail_case <fragment> <Q> <description>
    DXE_TEST_FAIL_MATCH="$1" run_inspect
    local want
    want="$(sed -E "s/(^| )$2=[a-z]+/\\1$2=fail/" <<<"$HAPPY")"
    check "$3: exit 1" test "$RC" -eq 1
    check "$3: only Q-$2 turns to fail, all ten still reported" test "$(statuses "$OUT")" = "$want"
    check "$3: no crash output" test -z "$(grep -E 'unbound variable|command not found|syntax error' <<<"$ERR")"
    check "$3: report file is complete" test "$(grep -cE '^Q-[0-9]+ \| ' "$(report_file)")" = 10
    check "$3: evidence is not empty" test -n "$(q_ev "$2" "$OUT")"
    DXE_TEST_FAIL_MATCH=""
}
fail_case "readlink -f" 1 "failing readlink"
fail_case "info" 4 "failing docker info"
fail_case "du -sk" 8 "failing du"
fail_case "rsync --version" 9 "failing rsync --version"
fail_case "command -v mktemp" 9 "missing mktemp"
fail_case "stat -c" 10 "failing stat"

DXE_TEST_FAIL_MATCH="volume inspect" run_inspect
check "failing volume inspect: exit 1" test "$RC" -eq 1
check "failing volume inspect: Q-2, Q-8, Q-10 fail" \
    test "$(statuses "$OUT")" = "1=ok 2=fail 3=manual 4=ok 5=manual 6=manual 7=manual 8=fail 9=ok 10=fail "
check "failing volume inspect: no crash" test -z "$(grep -E 'unbound variable|command not found|syntax error' <<<"$ERR")"
DXE_TEST_FAIL_MATCH=""
DXE_TEST_FAIL_MATCH="mktemp" run_inspect
check "missing tool is named in Q-9 evidence" has "$(q_ev 9 "$OUT")" "tools=missing:mktemp"
DXE_TEST_FAIL_MATCH=""

# 8. --write-probe -------------------------------------------------------------
run_inspect --write-probe
check "probe run exits 0" test "$RC" -eq 0
check "probe run keeps the status contract" test "$(statuses "$OUT")" = "$HAPPY"
E10="$(q_ev 10 "$OUT")"
for kv in write-probe=ok chown=ok mkdir0700=ok owner=30033:30033 mode=755; do
    check "probe Q-10 evidence has $kv" has "$E10" "$kv"
done
RUN_CALLS="$(for f in $(call_files); do norm_call "$f" | grep -Fq "$FAKE_DOCKER run" && echo "$f"; done)"
check "exactly one docker run call" test "$(printf '%s\n' "$RUN_CALLS" | grep -c .)" = 1
RUN_TEXT="$(norm_call "${RUN_CALLS:-/nonexistent}" 2>/dev/null)"
check "probe container is named dxe-spike-*" has "$RUN_TEXT" "--name dxe-spike-"
check "probe container carries the spike label" has "$RUN_TEXT" "--label dxe.role=spike"
check "probe uses the configured image" has "$RUN_TEXT" "dxe-fixture-image:test"
check "probe binds only the share root" has "$RUN_TEXT" "$SHARE"
check "probe never binds the docker socket or other host paths" test -z "$(grep -Eo -- '(-v|--volume)[= ][^ ]+' <<<"$RUN_TEXT" | grep -Fv -- "$SHARE")"
check "probe writes only .dxe-spike-* operands" test -n "$(all_writes)" -a -z "$(all_writes | grep BADOPERAND)"
check "probe uses only mkdir, chown, rm, rmdir" test -n "$(all_writes)" -a -z "$(all_writes | grep VERB | grep -Ev 'VERB:(mkdir|chown|rm|rmdir)$')"
check "probe creates a .dxe-spike- directory under dxe/" has "$RUN_TEXT" "/dxe/.dxe-spike-"
check "probe runs a chown" has "$(all_writes)" "VERB:chown"
check "probe makes a directory" has "$(all_writes)" "VERB:mkdir"
check "probe removes its own directory" has "$(all_writes)" "VERB:rm"
VERB_ORDER="$(norm_call "${RUN_CALLS:-/nonexistent}" 2>/dev/null | tr ' ' '\n' | grep -E '^(mkdir|rm|rmdir)$' | tr '\n' ' ')"
check "the probe's last write is its removal, after the mkdir" \
    test "${VERB_ORDER%% *}" = mkdir -a "$(awk '{print $NF}' <<<"$VERB_ORDER")" != mkdir
check "docker subcommands are only info, volume inspect, run" \
    test "$(docker_subs | sort -u | tr '\n' ',')" = "info,run,volume inspect,"
check "no docker rm, create or volume create/rm anywhere" test -n "$(call_files)" -a -z "$(all_calls_text | tr '\n' ' ' | grep -E "$FAKE_DOCKER (rm|create|rmi|volume (create|rm|prune))")"
check "probe run is not a bare write outside the container" \
    test "$(for f in $(call_files); do [ "$f" = "$RUN_CALLS" ] || scan_writes "$f"; done | wc -l | tr -d ' ')" = 0

# probe failure --------------------------------------------------------------
DXE_TEST_PROBE_CHOWN=fail run_inspect --write-probe
check "chown failure: exit 1" test "$RC" -eq 1
check "chown failure: Q-10 fail" test "$(q_status 10 "$OUT")" = fail
check "chown failure: evidence says chown=fail" has "$(q_ev 10 "$OUT")" "chown=fail"
check "chown failure: other checks unchanged" \
    test "$(statuses "$OUT")" = "1=ok 2=ok 3=manual 4=ok 5=manual 6=manual 7=manual 8=ok 9=ok 10=fail "
check "chown failure: the removal still runs" has "$(all_writes)" "VERB:rm"
check "chown failure: still only .dxe-spike- operands" test -z "$(all_writes | grep BADOPERAND)"
DXE_TEST_PROBE_CHOWN=ok
DXE_TEST_PROBE_MKDIR=fail run_inspect --write-probe
check "0700 mkdir failure: Q-10 fail with mkdir0700=fail" test "$(q_status 10 "$OUT")" = fail -a "$RC" -eq 1
check "0700 mkdir failure evidence" has "$(q_ev 10 "$OUT")" "mkdir0700=fail"
DXE_TEST_PROBE_MKDIR=ok
DXE_TEST_FAIL_MATCH="$FAKE_DOCKER run" run_inspect --write-probe
check "probe container failing to run: Q-10 fail, exit 1, nine others reported" \
    test "$(q_status 10 "$OUT")" = fail -a "$RC" -eq 1 -a "$(grep -cE '^Q-[0-9]+ \| ' <<<"$OUT")" = 10
check "probe container failing to run: no crash" test -z "$(grep -E 'unbound variable|command not found|syntax error' <<<"$ERR")"
DXE_TEST_FAIL_MATCH=""

print_summary
exit_with_code
