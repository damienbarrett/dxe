#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP6.4c acceptance: an interrupted copy is resumable, and copies are
# mutually exclusive (plans/do plan.md D-10 with both 2026-10-11 paragraphs;
# spec R33, R35, R36; the 2026-10-12 findings: a SIGKILLed rsync leaves its
# temp file `.<name>.XXXXXX` in the destination, so a resume without --delete
# fails the verification; directory mtimes changed within the same second are
# left alone under rsync's default --modify-window=0, so the nanosecond
# manifest reports them). Written before the change; the implementer builds
# exactly this contract. It amends, for exactly these words, the argv pinned by
# tests/test_persist_rsync_ops.sh (WP6.2/6.2b), tests/test_persist_migrate.sh
# (WP6.4) and tests/test_persist_rollback.sh (WP6.5), and the in-process
# runtime recorders of tests/test_persist_migrate_hardening.sh (WP6.4b) and
# tests/test_persist_rollback_hardening.sh (WP6.5b).
#
# Interface contract (pinned by this file and those amendments):
#
# A. The rsync words (D-10) of BOTH directions of dx_runtime_host_rsync gain
#    `--inplace --modify-window=-1`, right after `--numeric-ids`:
#        -aH --numeric-ids --inplace --modify-window=-1 [-A] [-X]
#        --exclude=/.dxe-persist-dir --exclude=._* /src/ /dst/
#    --inplace: an interrupted copy leaves no rsync temp file, only a
#    possibly partial file under its final name, which the rerun rewrites.
#    --modify-window=-1: rsync compares modification times to the nanosecond,
#    as the manifest does, so a same-second change is copied again.
#    (rsync_check is unchanged: its `--version` run gets neither word.)
#
# B. Named, labelled copy and verify containers. PID below is the DQ6 profile
#    id, dx_runtime_docker_profile_id (<DX_REMOTE_HOST>__<DX_CONTAINER_NAME>);
#    LABELS(ROLE) is exactly what dx_runtime_docker_label_flags ROLE puts in
#    DXE_RUNTIME_DOCKER_LABEL_ARGV:
#        --label io.dxe.managed=true --label io.dxe.schema=1
#        --label io.dxe.profile=PID --label io.dxe.role=ROLE
#        --label io.dxe.system=<DX_GUEST_SYSTEM>
#    - The ONE rsync copy run of dx_runtime_host_rsync (forward and reverse)
#      carries `--name dxe-persist-copy-PID` then LABELS(persist-copy),
#      immediately before `--entrypoint`:
#        run --rm --network none --user 0:0 --pull never -v NIX:/nix:ro
#            <the direction's two mounts, as WP6.2>
#            --name dxe-persist-copy-PID LABELS(persist-copy)
#            --entrypoint RSYNC $DX_IMAGE <the words of A>
#    - The ONE manifest run of dx_runtime_host_manifest_verify (forward and
#      reverse) carries `--name dxe-persist-verify-PID` then
#      LABELS(persist-verify), immediately before `--entrypoint`:
#        run --rm --network none --user 0:0 --pull never
#            <the direction's two mounts, as WP6.4 J3>
#            --name dxe-persist-verify-PID LABELS(persist-verify)
#            --entrypoint bash $DX_IMAGE -c MANIFEST dx-persist-manifest verify /src /dst
#    No other run gets a name (rsync_check, inventory, establish, marker-set
#    are unchanged).
#
# C. A new neutral runtime operation, declared in bin/lib/dx-runtime.sh as
#        dx_runtime_host_copy_containers() { dx_runtime_dispatch host_copy_containers "$@"; }
#    and implemented as dx_runtime_docker_host_copy_containers and
#    dx_runtime_apple_host_copy_containers (Apple: non-zero, "unsupported" on
#    stderr, nothing on stdout, no tool call).
#    docker-ssh, no arguments (any argument: non-zero, a reason on stderr,
#    nothing on stdout, no call). Exactly two docker calls, in this order,
#    argv exactly:
#        ps -a --filter name=^/dxe-persist-copy-PID$ --format {{.State}}
#        ps -a --filter name=^/dxe-persist-verify-PID$ --format {{.State}}
#    A call that prints a non-empty last line means that container exists,
#    in that state (Docker's own words: running, created, exited, ...).
#    Output: one line "<container name> <state>" per existing container, the
#    copy container's first; nothing when neither exists. Status 0.
#    A failing ps call (non-zero): status non-zero, NOTHING on stdout,
#    docker's message passed on on stderr (no line starting "Error:"; the
#    caller's refusal is the one Error line).
#    It only reads: it never stops, kills or removes a container.
#
# D. dx-persist-migrate and dx-persist-rollback (dx_persist_migrate_main and
#    dx_persist_rollback_main): after the lock and the guest-stopped check
#    (WP6.4/WP6.5 E1: a running guest is still refused first, with no
#    copy-container check), and BEFORE any other runtime call (the DQ6
#    checks and the probe come after it), each runs
#    dx_runtime_host_copy_containers once. The FIRST line of its output
#    decides (the copy container before the verify container):
#      - no line: on, unchanged;
#      - "<name> running": refused, exit 1, exactly one stderr line starting
#        "Error:", holding <name>, "running", "wait" (wait for it to finish),
#        "docker stop <name>" (or stop it yourself) and the command's own
#        name (dx-persist-migrate / dx-persist-rollback, to run again); it
#        does NOT say "docker rm" (never remove a running copy);
#      - "<name> <any other state>" (created, exited, dead, ...): refused,
#        exit 1, exactly one Error line holding <name>, <state>, "inspect"
#        and "docker rm <name>" (the user inspects and removes it) and the
#        command's name;
#      - the operation fails: refused, exit 1, exactly one Error line holding
#        "cannot tell" and the command's name.
#    Every refusal writes nothing and makes no further runtime call: no DQ6
#    inspect, no NAS-shell call, no run, no volume create, and never a
#    `docker rm`/`stop`/`kill` of the container (only the user removes it);
#    the lock is released last.
#
# E. Fidelity (real rsync, Linux; skipped with a reason where the toolchain
#    is missing, like WP6.2's fidelity section). The rsync words are taken
#    from what dx_runtime_host_rsync forward actually asks docker to run
#    (everything after the image word; /src/ and /dst/ swapped for local
#    directories):
#    - interrupted: a tree holding a 64 MiB file; rsync with those words
#      runs in its own process group and the whole group is SIGKILLed at
#      once (as `docker kill` ends a copy container) once the bulk file has
#      started to arrive. With --inplace that leaves the partial file under
#      its final name and no temp file. Running the same words again
#      completes the copy and the WP6.1 manifest verify passes: no stray
#      `.<name>.XXXXXX`, no partial file.
#    - same-second: after a first copy that verifies, a directory's mtime and
#      a same-size file's content change within the same second as their
#      current mtimes; the same words again bring both over and the verify
#      passes.
#
# F. The runbook (docs/qnap-runbook.md 11.4) is pinned by the amendment to
#    tests/test_persist_runbook_docs.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
# shellcheck source=../bin/lib/dx-config.sh
source "$BASE_DIR/bin/lib/dx-config.sh"

test_section "WP6.4c: resumable, mutually exclusive copies"

SCRATCH="$(persist_fixture_root_create)" || exit 1
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac
mkdir -p "$SCRATCH/home" "$SCRATCH/tmp"

GUEST=dx-fix
NAS="$PERSIST_FIXTURE_NAS_HOST"
PID="${NAS}__$GUEST"
COPY_NAME="dxe-persist-copy-$PID"
VERIFY_NAME="dxe-persist-verify-$PID"
IMAGE=dx-fix-image:4
RSYNC_EP=/nix/var/nix/profiles/per-user/root/profile/bin/rsync
MANIFEST="$CONTAINER_DIR/scripts/lib/dx-persist-manifest.sh"

# --- the fakes ----------------------------------------------------------------
# ssh: a docker call (the configured absolute docker path) is evaluated here;
# any other remote command (a NAS-shell call) is logged as "nas" and fails
# like an unreachable host, so nothing runs on this machine's filesystem.
# docker: records every call (argv NUL-separated, one file per call) and one
# event line, answers the DQ6 label inspects, the guest's state, the remote
# lock, `ps -a` (from ps.<name> / ps.fail.<name>) and `run` (run.out /
# run.rc). Anything else is "other" and exits 99.
TOOLS="$(fake_tool_dir_create "$SCRATCH")" || exit 1
fake_tool_write "$TOOLS" ssh 'last=""
for a in "$@"; do last="$a"; done
eval "set -- $last"
case "${1:-}" in
    */docker) exec "$@" ;;
esac
printf "nas %s\n" "${1:-}" >>"${FAKE_DOCKER_DIR:?}/events"
echo "ssh: connect to host dxe-fixture-nas.invalid port 22: Connection refused" >&2
exit 255'
fake_tool_write "$TOOLS" docker 'd="${FAKE_DOCKER_DIR:?}"
n=1
while [ -e "$d/call.$n" ]; do n=$((n + 1)); done
printf "%s\0" "$@" >"$d/call.$n"
ev() { printf "%s\n" "$*" >>"$d/events"; }
last=""
for a in "$@"; do last="$a"; done
case "${1:-} ${2:-}" in
    "volume inspect")
        ev "dq6 $last"
        if [ -f "$d/labels/$last" ]; then cat "$d/labels/$last"; exit 0; fi
        echo "Error: No such volume: $last" >&2
        exit 1 ;;
    "container inspect")
        case "$last" in
            dxe-lock-*)
                ev lock-inspect
                [ -f "$d/lock.held" ] || { echo "Error: No such container: $last" >&2; exit 1; }
                case "$*" in
                    *io.dxe.managed*) printf "true|%s__%s|lock|%s\n" "$DX_REMOTE_HOST" "$DX_CONTAINER_NAME" "$(cat "$d/lock.held")" ;;
                    *) printf "%s|2026-10-12T00:00:00Z\n" "$(cat "$d/lock.held")" ;;
                esac
                exit 0 ;;
        esac
        ev "guest-state $last"
        if [ "$(cat "$d/guest" 2>/dev/null)" = running ]; then echo true; else echo false; fi
        exit 0 ;;
    "create --name")
        ev lock
        if [ -e "$d/lock.held" ]; then echo "docker: Error response from daemon: Conflict." >&2; exit 125; fi
        owner=""
        for a in "$@"; do case "$a" in io.dxe.owner=*) owner="${a#io.dxe.owner=}" ;; esac; done
        printf "%s\n" "$owner" >"$d/lock.held"
        echo 0123456789ab
        exit 0 ;;
    "rm dxe-lock-"*)
        ev unlock
        /bin/rm -f "$d/lock.held"
        exit 0 ;;
    "ps -a")
        f=""
        prev=""
        for a in "$@"; do
            if [ "$prev" = --filter ]; then f="$a"; fi
            prev="$a"
        done
        nm="${f#name=^/}"
        nm="${nm%\$}"
        ev "ps $nm"
        if [ -f "$d/ps.fail.$nm" ]; then
            echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
            exit 1
        fi
        if [ -f "$d/ps.$nm" ]; then cat "$d/ps.$nm"; fi
        exit 0 ;;
    "run --rm")
        ev run
        if [ -f "$d/run.out" ]; then cat "$d/run.out"; fi
        rc=0
        if [ -f "$d/run.rc" ]; then rc="$(cat "$d/run.rc")"; fi
        exit "$rc" ;;
esac
ev "other $*"
echo "fake docker: unexpected call: $*" >&2
exit 99'
# Apple's runtime tool: recorded, never succeeds.
fake_tool_write "$TOOLS" container 'printf "container %s\n" "$*" >>"${FAKE_DOCKER_DIR:?}/events"
exit 99'

# A fresh recording area, with this profile's persist and nix volumes labelled.
new_fake() {
    dxe_test_mktemp_dir FAKE_DOCKER_DIR "$SCRATCH/dxe-fake-docker.XXXXXX"
    mkdir "$FAKE_DOCKER_DIR/labels"
    : >"$FAKE_DOCKER_DIR/events"
    set_labels dx-fix-persist persist
    set_labels dx-fix-nix nix
    STATE="$FAKE_DOCKER_DIR/state"
    mkdir -p "$STATE"
}
set_labels() { printf 'true|1|%s|%s|x86_64-linux\n' "$PID" "$2" >"$FAKE_DOCKER_DIR/labels/$1"; }
ps_answer() { printf '%s\n' "$2" >"$FAKE_DOCKER_DIR/ps.$1"; } # NAME STATE
ps_fail() { : >"$FAKE_DOCKER_DIR/ps.fail.$1"; }

# cil [VAR=VALUE...] -- FN [ARGS...]: FN in a subshell that sourced
# bin/dx-lib.sh with this suite's configuration (VAR=VALUE exported first).
# Sets RC OUT ERR EVENTS.
cil() {
    local pre=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        pre+=("$1")
        shift
    done
    shift
    (
        for _n in $DXE_CONFIG_FIELDS; do unset "$_n"; done
        unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PERSIST_FRESH_START DXE_RUNTIME_DOCKER_DAEMON_ID \
            DX_LEGACY_WORKSPACE_VOLUME DXE_LIFECYCLE_LOCK_OWNER DXE_LIFECYCLE_LOCK_HELD DX_PROFILES_DIR DXE_FAKE_SSH_REMOTE_PATH
        HOME="$SCRATCH/home" XDG_STATE_HOME="$STATE" TMPDIR="$SCRATCH/tmp" PATH="$TOOLS:/usr/bin:/bin"
        export HOME XDG_STATE_HOME TMPDIR PATH FAKE_DOCKER_DIR
        export DXE_RUNTIME_DOCKER_BIN="$TOOLS/docker"
        export DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$NAS" DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume
        export DX_CONTAINER_NAME="$GUEST" DX_IMAGE="$IMAGE"
        export DX_NIX_VOLUME=dx-fix-nix DX_PERSIST_VOLUME=dx-fix-persist DX_BOOTSTRAP_VOLUME=dx-fix-bootstrap
        export DX_PERSIST_STORAGE=volume DX_PERSIST_HOST_ROOT="$SCRATCH/dxe-no-share" DX_PERSIST_HOST_MOUNT_SENTINEL=dxe-share-mounted
        for _kv in "${pre[@]+"${pre[@]}"}"; do export "${_kv?}"; done
        # shellcheck source=../bin/dx-lib.sh
        source "$BASE_DIR/bin/dx-lib.sh" || exit 96
        if ! type "$1" >/dev/null 2>&1; then
            echo "$1 is not defined" >&2
            exit 97
        fi
        "$@"
    ) >"$SCRATCH/cil.out" 2>"$SCRATCH/cil.err" </dev/null
    RC=$?
    OUT="$(cat "$SCRATCH/cil.out")"
    ERR="$(cat "$SCRATCH/cil.err")"
    EVENTS="$(cat "$FAKE_DOCKER_DIR/events")"
}

# --- reading what happened ----------------------------------------------------
n_calls() { local n=0; while [ -e "$FAKE_DOCKER_DIR/call.$((n + 1))" ]; do n=$((n + 1)); done; echo "$n"; }
words_of() { # N: the argv of docker call N, one word per line; the word after -c as <SCRIPT>
    local w prev=""
    [ -f "$FAKE_DOCKER_DIR/call.$1" ] || { echo "<no call $1>"; return 0; }
    while IFS= read -r -d '' w; do
        if [ "$prev" = -c ]; then printf '<SCRIPT>\n'; else printf '%s\n' "$w"; fi
        prev="$w"
    done <"$FAKE_DOCKER_DIR/call.$1"
}
run_call() { # the number of the first `run` call ("" when none)
    local n=1
    while [ -e "$FAKE_DOCKER_DIR/call.$n" ]; do
        if [ "$(words_of "$n" | sed -n 1p)" = run ]; then echo "$n"; return 0; fi
        n=$((n + 1))
    done
}
events_flat() { grep -v '^lock-inspect$' <<<"$EVENTS" | tr '\n' '|' | sed 's/|$//'; }
error_lines() { grep -c '^Error:' <<<"$1" || true; }
eq() { # LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (expected [$2], got [$3])"; fi
}
flat() { awk '{ printf "<%s>", $0 } END { print "" }'; } # one word per line -> <w><w>...
argv_eq() { # LABEL EXPECTED ACTUAL (one word per line each), compared and shown flat
    eq "$1" "$(flat <<<"$2")" "$(flat <<<"$3")"
}
has() { # LABEL TEXT NEEDLE (fixed string)
    if grep -Fq -- "$3" <<<"$2"; then test_pass "$1"; else test_fail "$1 (no [$3] in [$2])"; fi
}
lacks() { # LABEL TEXT NEEDLE
    if grep -Fq -- "$3" <<<"$2"; then test_fail "$1 (found [$3] in [$2])"; else test_pass "$1"; fi
}
labels_of() { # ROLE: LABELS(ROLE), one word per line
    printf '%s\n' --label io.dxe.managed=true --label io.dxe.schema=1 --label "io.dxe.profile=$PID" \
        --label "io.dxe.role=$1" --label io.dxe.system=x86_64-linux
}
ps_argv() { # NAME
    printf '%s\n' ps -a --filter "name=^/$1\$" --format '{{.State}}'
}

# =============================================================================
test_section "WP6.4c C: dx_runtime_host_copy_containers is declared and implemented"
new_fake
for fn in dx_runtime_host_copy_containers dx_runtime_docker_host_copy_containers dx_runtime_apple_host_copy_containers; do
    cil -- type "$fn"
    if [ "$RC" -eq 0 ]; then test_pass "$fn is defined"; else test_fail "$fn is defined"; fi
done

# =============================================================================
test_section "WP6.4c C: the two ps queries and their answers"
new_fake
cil -- dx_runtime_host_copy_containers
eq "none exists: status 0" 0 "$RC"
eq "none exists: nothing on stdout" "" "$OUT"
eq "none exists: no Error: line" 0 "$(error_lines "$ERR")"
eq "exactly two docker calls" 2 "$(n_calls)"
argv_eq "call 1 is the copy container's ps, argv exact" "$(ps_argv "$COPY_NAME")" "$(words_of 1)"
argv_eq "call 2 is the verify container's ps, argv exact" "$(ps_argv "$VERIFY_NAME")" "$(words_of 2)"

new_fake
ps_answer "$COPY_NAME" running
cil -- dx_runtime_host_copy_containers
eq "the copy container is running: status 0" 0 "$RC"
eq "the copy container is running: one line, name and state" "$COPY_NAME running" "$OUT"
eq "the copy container is running: both queries were made" 2 "$(n_calls)"

new_fake
ps_answer "$VERIFY_NAME" exited
cil -- dx_runtime_host_copy_containers
eq "the verify container has exited: one line, name and state" "$VERIFY_NAME exited" "$OUT"
eq "the verify container has exited: status 0" 0 "$RC"

new_fake
ps_answer "$COPY_NAME" created
ps_answer "$VERIFY_NAME" running
cil -- dx_runtime_host_copy_containers
eq "both exist: two lines, the copy container first" "$(printf '%s created\n%s running' "$COPY_NAME" "$VERIFY_NAME")" "$OUT"

new_fake
ps_fail "$COPY_NAME"
cil -- dx_runtime_host_copy_containers
if [ "$RC" -ne 0 ]; then test_pass "the first ps fails: non-zero"; else test_fail "the first ps fails: non-zero"; fi
eq "the first ps fails: nothing on stdout" "" "$OUT"
eq "the first ps fails: no Error: line (the caller refuses)" 0 "$(error_lines "$ERR")"
has "the first ps fails: docker's message is passed on" "$ERR" "Cannot connect to the Docker daemon"

new_fake
ps_answer "$COPY_NAME" running
ps_fail "$VERIFY_NAME"
cil -- dx_runtime_host_copy_containers
if [ "$RC" -ne 0 ]; then test_pass "the second ps fails: non-zero"; else test_fail "the second ps fails: non-zero"; fi
eq "the second ps fails: nothing on stdout (not even the first answer)" "" "$OUT"

new_fake
cil -- dx_runtime_host_copy_containers extra
if [ "$RC" -ne 0 ]; then test_pass "an argument: refused"; else test_fail "an argument: refused"; fi
eq "an argument: no docker call" 0 "$(n_calls)"
eq "an argument: nothing on stdout" "" "$OUT"

new_fake
cil DX_RUNTIME=apple DX_REMOTE_HOST= DX_NIX_STORAGE_MODE=apple-image -- dx_runtime_host_copy_containers
if [ "$RC" -ne 0 ]; then test_pass "Apple: non-zero"; else test_fail "Apple: non-zero"; fi
has "Apple: unsupported" "$ERR" "unsupported"
eq "Apple: nothing on stdout" "" "$OUT"
eq "Apple: no tool call" "0|" "$(n_calls)|$EVENTS"

# =============================================================================
test_section "WP6.4c B: the copy and verify containers are named and labelled"
DEST="$SCRATCH/dxe-dest"
mkdir -p "$DEST"
argv_copy() { # forward|reverse [EXTRA...]
    local dir="$1"
    shift
    printf '%s\n' run --rm --network none --user 0:0 --pull never -v dx-fix-nix:/nix:ro
    if [ "$dir" = forward ]; then
        printf '%s\n' -v dx-fix-persist:/src:ro --mount "type=bind,source=$DEST,target=/dst"
    else
        printf '%s\n' --mount "type=bind,source=$DEST,target=/src,readonly" -v dx-fix-persist:/dst
    fi
    printf '%s\n' --name "$COPY_NAME"
    labels_of persist-copy
    printf '%s\n' --entrypoint "$RSYNC_EP" "$IMAGE" -aH --numeric-ids --inplace --modify-window=-1 "$@" \
        --exclude=/.dxe-persist-dir '--exclude=._*' /src/ /dst/
}
argv_verify() { # forward|reverse
    printf '%s\n' run --rm --network none --user 0:0 --pull never
    if [ "$1" = forward ]; then
        printf '%s\n' -v dx-fix-persist:/src:ro --mount "type=bind,source=$DEST,target=/dst,readonly"
    else
        printf '%s\n' --mount "type=bind,source=$DEST,target=/src,readonly" -v dx-fix-persist:/dst:ro
    fi
    printf '%s\n' --name "$VERIFY_NAME"
    labels_of persist-verify
    printf '%s\n' --entrypoint bash "$IMAGE" -c '<SCRIPT>' dx-persist-manifest verify /src /dst
}
for d in forward reverse; do
    new_fake
    cil -- dx_runtime_host_rsync "$d" dx-fix-persist "$DEST"
    eq "copy $d: status 0" 0 "$RC"
    argv_eq "copy $d: the run's argv is exact (name, labels, --inplace, --modify-window=-1)" \
        "$(argv_copy "$d")" "$(words_of "$(run_call)")"
done
new_fake
cil -- dx_runtime_host_rsync forward dx-fix-persist "$DEST" -A -X
argv_eq "copy forward -A -X: -A -X follow --modify-window=-1" "$(argv_copy forward -A -X)" "$(words_of "$(run_call)")"
for d in forward reverse; do
    new_fake
    cil -- dx_runtime_host_manifest_verify "$d" dx-fix-persist "$DEST"
    eq "verify $d: status 0" 0 "$RC"
    argv_eq "verify $d: the run's argv is exact (name, labels)" "$(argv_verify "$d")" "$(words_of "$(run_call)")"
done
new_fake
cil -- dx_runtime_host_rsync_check
argv_eq "rsync_check's --version run stays unnamed and unlabelled" \
    "$(printf '%s\n' run --rm --network none --user 0:0 --pull never -v dx-fix-nix:/nix:ro --entrypoint "$RSYNC_EP" "$IMAGE" --version)" \
    "$(words_of "$(run_call)")"

# =============================================================================
# D. The commands refuse while a copy or verify container exists.
# expect_refusal LABEL COMMAND NEEDLE...: exit 1, one Error line on stderr
# holding every NEEDLE and the command's name, nothing on stdout that starts
# "Error:", no call after the two ps queries but the lock's release, and no
# docker rm/stop/kill of anything but the lock.
expect_refusal() {
    local label="$1" cmd="$2" line k
    shift 2
    eq "$label: exit 1" 1 "$RC"
    if [ "$(error_lines "$ERR")" = 1 ] && [ "$(error_lines "$OUT")" = 0 ]; then
        test_pass "$label: exactly one Error: line, on stderr"
    else
        test_fail "$label: exactly one Error: line, on stderr (stderr: $ERR | stdout: $OUT)"
    fi
    line="$(grep '^Error:' <<<"$ERR" | head -n 1)"
    for k in "$cmd" "$@"; do
        if grep -Fq -- "$k" <<<"$line"; then test_pass "$label: the Error line names [$k]"
        else test_fail "$label: the Error line names [$k] (got: $line)"; fi
    done
    eq "$label: lock, guest check, the two ps queries, unlock -- and nothing else" \
        "lock|guest-state $GUEST|ps $COPY_NAME|ps $VERIFY_NAME|unlock" "$(events_flat)"
    eq "$label: no container is stopped, killed or removed" "" \
        "$(grep -E '^other (rm|stop|kill|container (rm|stop|kill))' <<<"$EVENTS" || true)"
    if [ -e "$FAKE_DOCKER_DIR/lock.held" ]; then test_fail "$label: the lock is released"; else test_pass "$label: the lock is released"; fi
}
mig() { cil -- dx_persist_migrate_main; }
rb() { cil -- dx_persist_rollback_main --volume dx-fix-rollback; }

for cmd in dx-persist-migrate dx-persist-rollback; do
    if [ "$cmd" = dx-persist-migrate ]; then run_cmd=mig; else run_cmd=rb; fi
    test_section "WP6.4c D: $cmd refuses while a copy or verify container exists"

    new_fake
    ps_answer "$COPY_NAME" running
    $run_cmd
    expect_refusal "$cmd, the copy container is running" "$cmd" "$COPY_NAME" running wait "docker stop $COPY_NAME"
    lacks "$cmd, the copy container is running: never told to remove a running copy" "$(grep '^Error:' <<<"$ERR" || true)" "docker rm"

    new_fake
    ps_answer "$VERIFY_NAME" running
    $run_cmd
    expect_refusal "$cmd, the verify container is running" "$cmd" "$VERIFY_NAME" running wait "docker stop $VERIFY_NAME"

    new_fake
    ps_answer "$COPY_NAME" exited
    $run_cmd
    expect_refusal "$cmd, an exited copy container" "$cmd" "$COPY_NAME" exited inspect "docker rm $COPY_NAME"

    new_fake
    ps_answer "$COPY_NAME" created
    $run_cmd
    expect_refusal "$cmd, a created (never started) copy container" "$cmd" "$COPY_NAME" created inspect "docker rm $COPY_NAME"

    new_fake
    ps_answer "$VERIFY_NAME" dead
    $run_cmd
    expect_refusal "$cmd, a dead verify container" "$cmd" "$VERIFY_NAME" dead inspect "docker rm $VERIFY_NAME"

    new_fake
    ps_answer "$COPY_NAME" exited
    ps_answer "$VERIFY_NAME" running
    $run_cmd
    expect_refusal "$cmd, both exist: the copy container decides" "$cmd" "$COPY_NAME" exited "docker rm $COPY_NAME"

    new_fake
    ps_fail "$COPY_NAME"
    $run_cmd
    eq "$cmd, the copy-container check fails: exit 1" 1 "$RC"
    eq "$cmd, the copy-container check fails: exactly one Error: line" 1 "$(error_lines "$ERR")"
    has "$cmd, the copy-container check fails: the Error says it cannot tell" "$(grep '^Error:' <<<"$ERR" || true)" "cannot tell"
    has "$cmd, the copy-container check fails: the Error names the command" "$(grep '^Error:' <<<"$ERR" || true)" "$cmd"
    eq "$cmd, the copy-container check fails: nothing after it but the unlock" \
        "lock|guest-state $GUEST|ps $COPY_NAME|unlock" "$(events_flat | sed "s/|ps $VERIFY_NAME//")"

    new_fake
    printf 'running\n' >"$FAKE_DOCKER_DIR/guest"
    ps_answer "$COPY_NAME" running
    $run_cmd
    eq "$cmd, the guest is running: refused" 1 "$RC"
    has "$cmd, the guest is running: the guest refusal comes first" "$(grep '^Error:' <<<"$ERR" || true)" "dx-stop-container"
    eq "$cmd, the guest is running: no copy-container check" "lock|guest-state $GUEST|unlock" "$(events_flat)"
done

# None exists: the command goes on to its pre-flight (here refused later, by
# the unreachable NAS shell), with the check right after the guest check.
test_section "WP6.4c D: with no copy or verify container the commands go on"
new_fake
mig
eq "dx-persist-migrate, none exists: the check sits between the guest check and the DQ6 checks" \
    "lock|guest-state $GUEST|ps $COPY_NAME|ps $VERIFY_NAME|dq6 dx-fix-persist" \
    "$(events_flat | cut -d'|' -f1-5)"
has "dx-persist-migrate, none exists: it went on to the probe" "$EVENTS" "nas "
lacks "dx-persist-migrate, none exists: no copy-container refusal" "$ERR" "$COPY_NAME"
new_fake
rb
eq "dx-persist-rollback, none exists: the check sits between the guest check and the probe" \
    "lock|guest-state $GUEST|ps $COPY_NAME|ps $VERIFY_NAME|nas sh" \
    "$(events_flat | cut -d'|' -f1-5)"
lacks "dx-persist-rollback, none exists: no copy-container refusal" "$ERR" "$COPY_NAME"

# =============================================================================
test_section "WP6.4c E: fidelity -- a killed copy resumes, a same-second change is copied (real rsync, Linux)"
fidelity_toolchain_ok() {
    local v
    v="$(bash --version 2>/dev/null)" || return 1
    case "$v" in *"version "[5-9].*) : ;; *) return 1 ;; esac
    v="$(find --version 2>/dev/null)" || return 1
    case "$v" in *"GNU findutils"*) : ;; *) return 1 ;; esac
    v="$(stat --version 2>/dev/null)" || return 1
    case "$v" in *"GNU coreutils"*) : ;; *) return 1 ;; esac
    command -v sha256sum >/dev/null 2>&1 || return 1
    command -v perl >/dev/null 2>&1 || return 1
    [ -r /proc/self/stat ] || return 1
    v="$(rsync --version 2>/dev/null)" || return 1
    v="${v%%$'\n'*}"
    v="${v#*version}"
    v="${v# }"
    v="${v# }"
    case "$v" in 3.[1-9]* | [4-9].*) return 0 ;; esac
    return 1
}

# rsync_words SRCDIR DSTDIR: RS_WORDS, the words dx_runtime_host_rsync forward
# asks docker to run (after the image word), /src/ and /dst/ swapped.
rsync_words() {
    local s="$1" d="$2" n w seen=0
    RS_WORDS=()
    new_fake
    cil -- dx_runtime_host_rsync forward dx-fix-persist "$DEST"
    n="$(run_call)"
    [ -n "$n" ] || return 1
    while IFS= read -r -d '' w; do
        if [ "$seen" = 1 ]; then
            case "$w" in
                /src/) RS_WORDS+=("$s/") ;;
                /dst/) RS_WORDS+=("$d/") ;;
                *) RS_WORDS+=("$w") ;;
            esac
        elif [ "$w" = "$IMAGE" ]; then
            seen=1
        fi
    done <"$FAKE_DOCKER_DIR/call.$n"
    [ "${#RS_WORDS[@]}" -gt 0 ]
}
manifest_verify() { # A B -> MV_OUT MV_RC
    MV_OUT="$(bash "$MANIFEST" verify "$1" "$2" 2>&1)"
    MV_RC=$?
}

# interrupt.pl FULL DIR NAME -- CMD...: CMD in its own process group; as soon
# as DIR holds NAME with 0 < size < FULL ("final") or a temp file ".NAME.*"
# with data ("temp"), the WHOLE group is SIGKILLed at once (as `docker kill`
# ends every process of a copy container), reaped, and waited for until no
# process of the group is left. Prints "killed final|temp"; "finished RC"
# (exit 3) when CMD ended first; "timeout" (exit 4) after 120 s.
HELPERS="$SCRATCH/dxe-helpers"
mkdir -p "$HELPERS"
cat >"$HELPERS/interrupt.pl" <<'PERL'
use strict;
use warnings;
use POSIX ();
my ($full, $dir, $name, $sep, @cmd) = @ARGV;
die "usage: interrupt.pl FULL DIR NAME -- CMD...\n" unless defined $sep && $sep eq '--' && @cmd;
my $pid = fork();
die "fork: $!\n" unless defined $pid;
if ($pid == 0) {
    setpgrp(0, 0) or POSIX::_exit(126);
    exec { $cmd[0] } @cmd;
    POSIX::_exit(127);
}
setpgrp($pid, $pid);
my $deadline = time + 120;
my $seen = '';
while (!$seen) {
    if (waitpid($pid, POSIX::WNOHANG()) == $pid) { printf "finished %d\n", $? >> 8; exit 3; }
    my @st = lstat("$dir/$name");
    if (@st && -f _ && $st[7] > 0 && $st[7] < $full) { $seen = 'final'; last; }
    if (opendir(my $dh, $dir)) {
        for my $e (readdir $dh) {
            next unless index($e, ".$name.") == 0;
            my @t = lstat("$dir/$e");
            if (@t && -f _ && $t[7] > 0) { $seen = 'temp'; last; }
        }
        closedir $dh;
    }
    last if $seen;
    if (time > $deadline) { kill 'KILL', -$pid; waitpid($pid, 0); print "timeout\n"; exit 4; }
    select(undef, undef, undef, 0.001);
}
kill 'KILL', -$pid;
waitpid($pid, 0);
for (1 .. 10000) {
    my $alive = 0;
    if (opendir(my $p, '/proc')) {
        for my $q (readdir $p) {
            next unless $q =~ /^\d+$/;
            open(my $fh, '<', "/proc/$q/stat") or next;
            my $s = <$fh>;
            close $fh;
            next unless defined $s && $s =~ /.*\)\s+(\S)\s+\d+\s+(\d+)/;
            $alive = 1 if $2 == $pid && $1 ne 'Z';
        }
        closedir $p;
    }
    last unless $alive;
    select(undef, undef, undef, 0.001);
}
print "killed $seen\n";
exit 0;
PERL

if ! fidelity_toolchain_ok; then
    test_skip "needs Bash 5, GNU findutils/coreutils, perl, /proc and rsync >= 3.1; covered by run-coverage-linux.sh and CI's Linux job"
else
    # --- interrupted: SIGKILL mid-file, then the same words again ---------------
    BIG=67108864
    ISRC="$SCRATCH/dxe-int-src"
    mkdir -p "$ISRC/a-dir/inner"
    head -c "$BIG" /dev/urandom >"$ISRC/big.bin"
    printf 'small\n' >"$ISRC/a-dir/small.txt"
    printf 'deeper\n' >"$ISRC/a-dir/inner/deeper.txt"
    printf 'zz\n' >"$ISRC/zz-last.txt"
    i=0
    while IFS= read -r -d "" p; do
        i=$((i + 1))
        touch -h -d "@$((1600000000 + i)).$((100000000 + i * 7919))" -- "$p"
    done < <(find "$ISRC" -mindepth 1 -depth -print0)
    BIG_SHA="$(sha256sum <"$ISRC/big.bin" | cut -d' ' -f1)"
    interrupted=""
    attempt=0
    while [ -z "$interrupted" ] && [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        IDST="$SCRATCH/dxe-int-dst.$attempt"
        mkdir -p "$IDST"
        if ! rsync_words "$ISRC" "$IDST"; then break; fi
        how="$(perl "$HELPERS/interrupt.pl" "$BIG" "$IDST" big.bin -- rsync "${RS_WORDS[@]}" 2>"$SCRATCH/int.err")"
        case "$how" in
            "killed "*) interrupted="${how#killed }" ;;
        esac
    done
    if [ -z "$interrupted" ]; then
        test_fail "interrupt: the copy was killed while the bulk file was arriving (last: [${how:-no words}] after $attempt attempts; $(cat "$SCRATCH/int.err" 2>/dev/null))"
    else
        test_pass "interrupt: the copy was killed while the bulk file was arriving (attempt $attempt)"
        eq "interrupt: with --inplace the kill leaves the partial file under its final name, no temp file" final "$interrupted"
        rsync "${RS_WORDS[@]}" >/dev/null 2>"$SCRATCH/rerun.err"
        eq "interrupt: the same rsync again exits 0" 0 "$?"
        stray="$(cd "$IDST" && find . -name '.big.bin.*' | LC_ALL=C sort | tr '\n' ' ')"
        eq "interrupt: no rsync temp file (.big.bin.*) is left in the destination" "" "$stray"
        eq "interrupt: the bulk file is complete (size)" "$BIG" "$(stat -c %s "$IDST/big.bin" 2>/dev/null)"
        eq "interrupt: the bulk file is complete (sha256)" "$BIG_SHA" "$(sha256sum <"$IDST/big.bin" 2>/dev/null | cut -d' ' -f1)"
        manifest_verify "$ISRC" "$IDST"
        eq "interrupt: the WP6.1 manifest verify passes after the rerun" 0 "$MV_RC"
        has "interrupt: verify says the manifests match" "$MV_OUT" "Manifests match"
    fi

    # --- same-second changes: a directory's mtime, a same-size file --------------
    SSRC="$SCRATCH/dxe-same-src"
    SDST="$SCRATCH/dxe-same-dst"
    mkdir -p "$SSRC/dir-a" "$SDST"
    printf 'one\n' >"$SSRC/dir-a/f.txt"
    printf 'abc\n' >"$SSRC/top.txt"
    touch -h -d @1600000101.100000001 "$SSRC/dir-a/f.txt"
    touch -h -d @1600000102.200000002 "$SSRC/top.txt"
    touch -h -d @1600000103.300000003 "$SSRC/dir-a"
    touch -h -d @1600000104.400000004 "$SSRC"
    if rsync_words "$SSRC" "$SDST"; then
        rsync "${RS_WORDS[@]}" >/dev/null 2>&1
        manifest_verify "$SSRC" "$SDST"
        eq "same-second: the first copy verifies" 0 "$MV_RC"
        printf 'abd\n' >"$SSRC/top.txt"
        touch -h -d @1600000102.900000009 "$SSRC/top.txt"
        touch -h -d @1600000103.800000008 "$SSRC/dir-a"
        touch -h -d @1600000104.400000004 "$SSRC"
        rsync "${RS_WORDS[@]}" >/dev/null 2>&1
        eq "same-second: the same rsync again exits 0" 0 "$?"
        eq "same-second: the directory's mtime now matches to the nanosecond" \
            "1600000103.800000008" "$(date -r "$SDST/dir-a" +%s.%N 2>/dev/null)"
        eq "same-second: the same-size file rewritten within the same second was copied again" \
            abd "$(cat "$SDST/top.txt" 2>/dev/null)"
        manifest_verify "$SSRC" "$SDST"
        eq "same-second: the WP6.1 manifest verify passes after the rerun" 0 "$MV_RC"
    else
        test_fail "same-second: the argument list could be taken from host_rsync's docker run"
    fi
fi

print_summary
exit_with_code
