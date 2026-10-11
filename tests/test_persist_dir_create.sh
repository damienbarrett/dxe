#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP4.4 acceptance: directory creation and the record of host-path use
# (plans/do D-2, D-3, D-7, D-9, D-10 (2026-10-11 revisions); spec R15, R17,
# R18). WP4.3 wired `dx_persist_dir_establish create|adopt|fresh-start` into
# dx-create-volumes as a fail-closed placeholder; this file pins what it does.
#
# Interface contract (pinned by this file; the implementation must match):
#
# A. The owner. Spec R15: a new directory gets the owner and mode today's
#    volume root has; the Q-10 inspection found 30033:30001, mode 0755.
#    bin/lib/dx-persist-dir.sh defines, when sourced, the plain shell variable
#        DX_PERSIST_DIR_OWNER=30033:30001
#    The repository defines no fixed UID/GID for the guest's dx user: the
#    bootstrap allocates it with groupadd/useradd on the nixos/nix base (whose
#    nixbld users hold 30001-30032 and nixbld group 30000, so dx gets
#    30033:30001), or reuses the durable identity of an existing /nix store
#    (create_user, record_durable_nix_identity), and setup_persist re-asserts
#    dx:dx 0755 on /persist at every boot. This variable is the one host-side
#    copy of that result. dx_persist_dir_establish reads it when it runs (a
#    caller may override it), so neither establish nor the container script
#    holds the literal.
#
# B. dx_runtime_volume_state NAME (declared in bin/lib/dx-runtime.sh,
#    implemented as dx_runtime_{apple,docker}_volume_state). Prints exactly one
#    line, `present`, `absent` or `unknown`; status 0 for present and absent,
#    non-zero for unknown; never prints a line beginning `Error:`.
#    docker-ssh: exactly ONE docker call through the adapter's transport, with
#    exactly the argv `volume inspect NAME`. Exit 0 -> present. A failure whose
#    stderr contains "no such volume" in any letter case (the CLI's
#    "Error: No such volume: NAME", the daemon's "Error response from daemon:
#    get NAME: no such volume") -> absent. Any other failure (daemon
#    unreachable, permission denied, the ssh connection failing) -> unknown.
#    Apple: `container volume inspect NAME` succeeding -> present, one call
#    (its failure mapping is not pinned: host-path mode never runs on Apple).
#
# C. dx_runtime_host_dir_establish MODE ROOT GUEST OWNER MARKER_TEXT
#    (bin/lib/dx-runtime.sh; dx_runtime_{apple,docker}_host_dir_establish).
#    MODE is create, adopt or fresh-start.
#    Apple: non-zero, nothing on stdout, a stderr line containing
#    "unsupported", and NO tool call (container, ssh, docker).
#    docker-ssh refuses BEFORE any call (non-zero, empty stdout, a reason on
#    stderr, no ssh call at all) when: MODE is not one of the three; ROOT is
#    empty, "-", not absolute, or contains "," (it would add --mount options)
#    or a newline; GUEST is not a marker-class name
#    (dx_persist_marker_valid_name); OWNER is not <digits>:<digits>;
#    MARKER_TEXT does not satisfy dx_persist_marker_parse; or
#    DX_PERSIST_HOST_MOUNT_SENTINEL is empty.
#    Otherwise it makes exactly ONE docker call through the transport
#    (dx_runtime_docker_cli; the binary is DXE_RUNTIME_DOCKER_BIN) whose argv
#    is exactly these 22 words:
#        run --rm -i --network none --user 0:0 --pull never
#        --mount type=bind,source=<ROOT>,target=/dxe-share
#        --entrypoint sh <DX_IMAGE> -c <SCRIPT> sh
#        /dxe-share <GUEST> <MODE> <OWNER> <DX_PERSIST_HOST_MOUNT_SENTINEL>
#    i.e. one root one-off container from $DX_IMAGE with no network that never
#    pulls, the share root bound with --mount (never -v/--volume, which would
#    create a missing ROOT), and the data as positional words. SCRIPT is ONE
#    constant, single-line POSIX sh program: the same text for every mode and
#    input, it never names /dxe-share or any data word (it reads them from
#    "$@"), it passes `sh -n` and `dash -n`, and it behaves the same under sh
#    and dash. The marker bytes -- MARKER_TEXT plus exactly one trailing
#    newline (unless it already ends in one), as WP4.2's create -- travel on
#    stdin (hence -i), never in argv. It prints nothing on stdout; its status
#    is the container's.
#    The container (root; Docker's default umask 022), working from the bind:
#      1. the sentinel must be a regular file (not a symlink) at the bind
#         root, else it refuses (the share was unmounted after the probe);
#      2. it refuses when dxe, dxe/<GUEST> or dxe/<GUEST>/persist is a symlink
#         (even a dangling one), writing nothing through it;
#      3. create: refuses when the leaf exists in any form; makes dxe and
#         dxe/<GUEST> when missing (mode 0755, owned by the container's root,
#         never chowned) and leaves existing ones alone (no chmod, no chown);
#         then mkdir of the leaf.
#         adopt and fresh-start: the leaf must already be a directory with no
#         entries at all (a marker, a temp file or any dotfile counts); it is
#         never created by them.
#      4. chown OWNER on the leaf and mode 0755 on the leaf: the only chown of
#         the run, and both BEFORE the marker;
#      5. the marker last, as WP4.2's marker step: a temp file in the leaf,
#         mode 0644, then ONE mv onto .dxe-persist-dir -- the only mv of the
#         run and the commit point. If anything fails after the leaf exists,
#         only that temp file is removed (no rm -r, no rmdir): the leaf stays,
#         empty and unmarked, and the status is non-zero.
#    A refusal in 1-3 writes nothing at all and exits non-zero.
#
# D. dx_persist_dir_establish MODE (bin/lib/dx-persist-dir.sh, WP4.3's seam).
#    Reads DX_CONTAINER_NAME, DX_PERSIST_HOST_ROOT,
#    DX_PERSIST_HOST_MOUNT_SENTINEL, DX_PERSIST_DIR_OWNER and the record path
#    (dx_persist_dir_record_path, WP4.3). Before any remote call it refuses
#    (status 1, exactly one stderr line beginning `Error:`) when MODE is not
#    create, adopt or fresh-start; when DX_PERSIST_HOST_MOUNT_SENTINEL is empty
#    (nothing proves the share is mounted); or when the record path cannot be
#    formed.
#    Otherwise it takes ONE UTC timestamp T (YYYY-MM-DDTHH:MM:SSZ) on the
#    controller and calls, exactly once,
#        dx_runtime_host_dir_establish MODE "$DX_PERSIST_HOST_ROOT" \
#            "$DX_CONTAINER_NAME" "$DX_PERSIST_DIR_OWNER" <marker>
#    with <marker> = dx_persist_marker_format GUEST ready "" T (WP4.1), so the
#    marker file holds exactly these lines and nothing else:
#        schema=1
#        guest=<GUEST>
#        state=ready
#        created-at=<T>
#    If that call fails: status 1, exactly one `Error:` line on stderr naming
#    the directory <ROOT>/dxe/<GUEST>/persist, and no record is written (an
#    existing record is left byte-for-byte).
#    Then, and only then (the record is written AFTER the marker), the D-7
#    record at dx_persist_dir_record_path, exactly these lines:
#        schema=1
#        guest=<DX_CONTAINER_NAME>
#        root=<DX_PERSIST_HOST_ROOT, as configured>
#        mode=<MODE>
#        created-at=<T, the marker's own value>
#    with file mode 0600, its missing parent directories created, written
#    atomically: a temp file in the record's own directory, then ONE mv onto
#    the record path (no temp file is left behind). An existing record is
#    replaced. If the record cannot be written: status 1 and exactly one
#    `Error:` line naming the record path. Success: status 0, no `Error:` line.
#    Only establish writes the record: dx-start-container never does, and a
#    refusal or a failed establish leaves it exactly as it was.
#
# E. Wiring, DX_PERSIST_STORAGE=host-path (WP4.3's placement is kept).
#    bin/dx-create-volumes probes, learns the persist volume's state through
#    dx_runtime_volume_state (absent ONLY when it says absent), checks the
#    record, decides (WP4.3's table) and on create/adopt/ok-fresh-start calls
#    dx_persist_dir_establish once: after the nix volume is ensured and before
#    the bootstrap volume. When the volume state is unknown, dx-create-volumes
#    and dx-start-container both refuse: non-zero, exactly one `Error:` line
#    on stderr naming the volume and containing "inspect", no establish (no
#    docker run), no volume create, no container start, nothing written to
#    the share or the state directory. A failed probe (an unusable root, or
#    the ssh call itself failing) means no establish and no record. A crash
#    (the container's marker mv failing on its first call) leaves an empty,
#    unmarked leaf and no record; the next dx-create-volumes, still for a new
#    guest, adopts it and finishes.
#
# Test-only conventions. The share is a fixture root under a private TMPDIR
# area served by the WP0.2 NAS fake (the "remote" shell runs locally with
# cwd = the fixture root). Its fake `docker` records every argv and EXECUTES
# a `run`: it maps the bind target to the fixture root (as a mount would),
# rejects a missing bind source as Docker does (exit 125), and runs the
# entrypoint's argv under sh or dash with umask 022 from an empty scratch
# "container root", on a PATH whose chown is a RECORDING stub (it never
# changes an owner on this machine) and whose chmod, mv and rm are recording
# wrappers that refuse any recursive flag or any operand outside the bound
# fixture root, and otherwise run the real tool. These stubs stand in for a
# root container on the NAS; WP7 validates them against the real boundary.
# Container-side log lines name paths as @/<path below the bound root>. The
# crash is the harness's own fake `mv` (with_fake_runtime) put first on the
# container's PATH with fake_fail_nth mv 1 1. The controller's `mv` is a
# recording pass-through, so the record's temp-file-plus-mv is observable.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
# shellcheck source=../bin/lib/dx-config.sh
source "$BASE_DIR/bin/lib/dx-config.sh"
# shellcheck source=../bin/lib/dx-host-util.sh
source "$BASE_DIR/bin/lib/dx-host-util.sh"
# shellcheck source=../bin/lib/dx-runtime.sh
source "$BASE_DIR/bin/lib/dx-runtime.sh"
# shellcheck source=../bin/lib/dx-container.sh
source "$BASE_DIR/bin/lib/dx-container.sh"
# shellcheck source=../bin/lib/dx-persist-dir.sh
source "$BASE_DIR/bin/lib/dx-persist-dir.sh"

test_section "WP4.4: directory creation and record"

SCRATCH="$(persist_fixture_root_create)"
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac
mkdir -p "$SCRATCH/home"

GUEST=dx-fix
NAS="$PERSIST_FIXTURE_NAS_HOST"
SENTINEL=dxe-share-mounted
IMAGE=dx-fix-image
TARGET=/dxe-share
OWNER_PIN=30033:30001
MARKER_NAME=.dxe-persist-dir
unset DX_PERSIST_FRESH_START
SH_BIN="$(command -v sh)"
DASH_BIN="$(command -v dash 2>/dev/null || true)"

# --- small assertion helpers -------------------------------------------------
eq() { # LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (expected [$2], got [$3])"; fi
}
ok() { # LABEL CMD...
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then test_pass "$label"; else test_fail "$label"; fi
}
not() { # LABEL CMD...
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then test_fail "$label"; else test_pass "$label"; fi
}
have() { type "$1" >/dev/null 2>&1; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
not_after() { # A B: A <= B (ISO UTC strings compare lexically)
    [ "$1" = "$2" ] || [ "$1" \< "$2" ]
}
count_lines() { # FILE PATTERN(ERE): matching lines in FILE (0 when none)
    grep -Ec -- "$2" "$1" 2>/dev/null || true
}
error_lines() { grep -c '^Error:' <<<"$1" || true; }

# snap DIR: every path below DIR with its type, mode, link target and file
# checksum ("ABSENT" when DIR does not exist).
snap() {
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
        echo ABSENT
        return 0
    fi
    (
        cd -P -- "$1" || exit 1
        find . | LC_ALL=C sort | while IFS= read -r p; do
            if [ -L "$p" ]; then printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
            elif [ -f "$p" ]; then printf 'F %s %s %s\n' "$p" "$(file_mode "$p")" "$(cksum <"$p")"
            elif [ -d "$p" ]; then printf 'D %s %s\n' "$p" "$(file_mode "$p")"
            else printf 'O %s\n' "$p"; fi
        done
    )
}
entries_of() { (cd -P -- "$1" && find . -mindepth 1 | LC_ALL=C sort); }

# --- the container's tools: a recording chown, guarded chmod/mv/rm ---------
GUARD="$SCRATCH/guard-bin"
mkdir -p "$GUARD"
GUARD_BODY='log="${DXE_FAKE_CLOG:?}"
conf="${DXE_FAKE_CONFINE:?}"
res() {
    local p="$1" d b
    if [ -d "$p" ] && [ ! -L "$p" ]; then
        (cd -P -- "$p" 2>/dev/null && pwd -P) || printf "?%s" "$p"
        return 0
    fi
    d="$(dirname -- "$p")"
    b="$(basename -- "$p")"
    if d="$(cd -P -- "$d" 2>/dev/null && pwd -P)"; then printf "%s/%s" "${d%/}" "$b"; else printf "?%s" "$p"; fi
}
spec=""
first=1
ops=()
for a in "$@"; do
    case "$a" in
        --) continue ;;
        --recursive | -*[Rr]*) printf "%s REFUSED-RECURSIVE %s\n" "$tool" "$*" >>"$log"; exit 97 ;;
        -*) continue ;;
    esac
    if [ "$first" = 1 ] && { [ "$tool" = chown ] || [ "$tool" = chmod ]; }; then
        spec="$a"
        first=0
        continue
    fi
    first=0
    ops+=("$a")
done
line="$tool"
[ -z "$spec" ] || line="$line $spec"
for a in "${ops[@]}"; do
    r="$(res "$a")"
    case "$r" in
        "$conf") line="$line @" ;;
        "$conf"/*) line="$line @${r#"$conf"}" ;;
        *) printf "%s REFUSED-OUTSIDE %s\n" "$tool" "$r" >>"$log"; exit 97 ;;
    esac
done
printf "%s\n" "$line" >>"$log"
[ "$real" = yes ] || exit 0
exec "/bin/$tool" "$@"'
fake_tool_write "$GUARD" chown "$(printf 'tool=chown\nreal=no\n%s' "$GUARD_BODY")"
for t in chmod mv rm; do
    fake_tool_write "$GUARD" "$t" "$(printf 'tool=%s\nreal=yes\n%s' "$t" "$GUARD_BODY")"
done

# --- the NAS's docker: records argv, serves volumes, executes `run` --------
DOCKER_FAKE='d="${P_DDIR:?}"
n=1
while [ -e "$d/call.$n" ]; do n=$((n + 1)); done
: >"$d/call.$n"
for a in "$@"; do printf "%s\n" "$a" >>"$d/call.$n"; done
has() { case " ${P_VOLUMES:-} " in *" $1 "*) return 0 ;; esac; return 1; }
role() { case "$1" in *-nix) echo nix ;; *-persist) echo persist ;; *-bootstrap) echo bootstrap ;; *) echo none ;; esac; }
last=""
for a in "$@"; do last="$a"; done
case "$1 ${2:-}" in
    "volume inspect")
        case " ${P_INSPECT_DOWN:-} " in
            *" $last "*)
                echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
                exit 1 ;;
        esac
        if has "$last"; then
            if [ "${3:-}" = --format ]; then
                printf "true|1|%s__%s|%s|%s\n" "$DX_REMOTE_HOST" "$DX_CONTAINER_NAME" "$(role "$last")" "${DX_GUEST_SYSTEM:-x86_64-linux}"
            else
                echo "[{\"Name\":\"$last\"}]"
            fi
            exit 0
        fi
        if [ "${P_INSPECT_STYLE:-cli}" = daemon ]; then
            echo "Error response from daemon: get $last: no such volume" >&2
        else
            echo "Error: No such volume: $last" >&2
        fi
        exit 1 ;;
    "volume create") echo "$last"; exit 0 ;;
    "version --format") echo 27.3.1; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "run "*) shift ;;
    *) echo "fake docker: unexpected call: $*" >&2; exit 99 ;;
esac
mount=""
entry=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rm | -i) shift ;;
        --network | --user | --pull) shift 2 ;;
        --mount) mount="$2"; shift 2 ;;
        --entrypoint) entry="$2"; shift 2 ;;
        -*) echo "fake docker: unexpected run option: $1" >&2; exit 99 ;;
        *) break ;;
    esac
done
[ "$#" -ge 1 ] || { echo "fake docker: no image" >&2; exit 99; }
shift
case "$mount" in
    type=bind,source=*,target=*) : ;;
    *) echo "fake docker: unexpected mount [$mount]" >&2; exit 99 ;;
esac
rest="${mount#type=bind,source=}"
src="${rest%,target=*}"
tgt="${rest##*,target=}"
if [ ! -d "$src" ]; then
    echo "docker: Error response from daemon: invalid mount config for type \"bind\": bind source path does not exist: $src" >&2
    exit 125
fi
srcp="$(cd -P -- "$src" && pwd -P)" || exit 125
[ "$entry" = sh ] || { echo "fake docker: unexpected entrypoint [$entry]" >&2; exit 99; }
args=()
for a in "$@"; do
    case "$a" in
        "$tgt") a="$srcp" ;;
        "$tgt"/*) a="$srcp/${a#"$tgt"/}" ;;
    esac
    args+=("$a")
done
croot="$(mktemp -d "${P_SCRATCH:?}/dxe-croot.XXXXXX")" || exit 125
cd "$croot" || exit 125
umask 022
DXE_FAKE_CONFINE="$srcp"
DXE_FAKE_CLOG="${P_CLOG:?}"
PATH="${P_CPRE:+$P_CPRE:}${P_GUARD:?}:/usr/bin:/bin"
export DXE_FAKE_CONFINE DXE_FAKE_CLOG PATH
exec "${P_SH:?}" "${args[@]}"'

# A recording ssh in front of the NAS fake: one line per call (the remote
# command, newlines shown as <NL>); P_SSH_FAIL (a glob) makes matching calls
# fail the way an unreachable host does.
REC="$SCRATCH/rec-ssh"
mkdir -p "$REC"
fake_tool_write "$REC" ssh 'last=""
for a in "$@"; do last="$a"; done
nl="
"
printf "ssh %s\n" "${last//$nl/<NL>}" >> "${P_LOG:?}"
if [ -n "${P_SSH_FAIL:-}" ]; then
    case "$last" in
        $P_SSH_FAIL) echo "ssh: connect to host dxe-fixture-nas.invalid port 22: Connection refused" >&2; exit 255 ;;
    esac
fi
exec "${P_REAL_SSH:?}" "$@"'

# The controller's mv, recorded (the record must be written by one mv).
CTRL="$SCRATCH/ctrl-bin"
mkdir -p "$CTRL"
fake_tool_write "$CTRL" mv 'ops=()
for a in "$@"; do
    case "$a" in -*) continue ;; esac
    ops+=("$a")
done
printf "%s\n" "${ops[*]}" >> "${P_MVLOG:?}"
exec /bin/mv "$@"'

STUB_DIR="$SCRATCH/stub"
mkdir -p "$STUB_DIR"
fake_tool_write "$STUB_DIR" dx-sync-bootstrap 'echo sync >> "${P_LOG:?}"
if [ "${1:-}" = --result-file ]; then printf "outcome=unchanged\ngeneration=g1\n" > "$2"; fi
exit 0'

# world [VOLUME...]: a fresh share root and NAS fake, a fresh state directory
# and logs; exactly the named volumes exist. Sets ROOT TOOLS W DDIR
# STATE LOG CLOG MVLOG VOLS GDIR REC_FILE.
N=0
world() {
    N=$((N + 1))
    ROOT="$(persist_fixture_root_create "$SCRATCH")"
    TOOLS="$(persist_fixture_nas_create "$ROOT" "$SCRATCH")"
    fake_tool_write "$TOOLS" docker "$DOCKER_FAKE"
    W="$SCRATCH/w.$N"
    DDIR="$W/docker"
    STATE="$W/state"
    mkdir -p "$DDIR" "$STATE"
    LOG="$W/log"
    CLOG="$W/clog"
    MVLOG="$W/mvlog"
    : >"$LOG"
    : >"$CLOG"
    : >"$MVLOG"
    VOLS="$*"
    GDIR="$ROOT/dxe/$GUEST/persist"
    REC_FILE="$STATE/dxe/persist-dirs/${NAS}__$GUEST"
}
put_sentinel() { : >"$ROOT/$SENTINEL"; }
put_record() { # [TEXT]
    mkdir -p "$STATE/dxe/persist-dirs"
    printf '%s' "${1:-}" >"$REC_FILE"
}
reset_logs() {
    rm -f "$DDIR"/call.* 2>/dev/null
    : >"$LOG"
    : >"$CLOG"
    : >"$MVLOG"
}

# The environment every call below shares (inside its subshell).
env_common() {
    HOME="$SCRATCH/home" XDG_STATE_HOME="$STATE" PATH="$CTRL:$REC:$TOOLS:/usr/bin:/bin"
    export HOME XDG_STATE_HOME PATH
    export DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$NAS" DXE_RUNTIME_DOCKER_BIN=docker
    export DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME="$GUEST"
    export DX_NIX_VOLUME=dx-fix-nix DX_PERSIST_VOLUME=dx-fix-persist DX_BOOTSTRAP_VOLUME=dx-fix-bootstrap
    export DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT="$ROOT" DX_IMAGE="$IMAGE"
    export DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
    export P_LOG="$LOG" P_REAL_SSH="$TOOLS/ssh" P_VOLUMES="$VOLS" P_DDIR="$DDIR" P_CLOG="$CLOG"
    export P_MVLOG="$MVLOG" P_GUARD="$GUARD" P_SCRATCH="$SCRATCH" P_SH="${P_SH_DEFAULT:-$SH_BIN}"
}

# lib_call [VAR=VALUE...] -- CMD...: run CMD (a library or adapter function)
# in a subshell on the current world. Sets RC OUT ERR BEFORE AFTER
# STATE_BEFORE STATE_AFTER T0 T1.
lib_call() {
    local kv=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        kv+=("$1")
        shift
    done
    shift
    reset_logs
    BEFORE="$(snap "$ROOT")"
    STATE_BEFORE="$(snap "$STATE")"
    T0="$(utc_now)"
    (
        unset DX_PERSIST_FRESH_START
        env_common
        for _kv in "${kv[@]+"${kv[@]}"}"; do export "${_kv?}"; done
        "$@"
    ) >"$W/out" 2>"$W/err" </dev/null
    RC=$?
    T1="$(utc_now)"
    OUT="$(cat "$W/out")"
    ERR="$(cat "$W/err")"
    AFTER="$(snap "$ROOT")"
    STATE_AFTER="$(snap "$STATE")"
}

# The entry points' other boundaries, replaced by recorders (as in WP4.3);
# dx_persist_dir_establish is NOT replaced: it is what this file tests.
wiring_overrides() {
    plog() { printf '%s\n' "$*" >>"$P_LOG"; }
    dx_require_container_cli() { plog preflight; }
    container_exists() { return 0; }
    container_is_running() { return 1; }
    dx_lifecycle_lock_acquire() { plog lock; }
    dx_lifecycle_lock_release() { plog unlock; }
    dx_nix_volume_claim_acquire() { :; }
    dx_runtime_container_mounts() { return 1; }
    dx_runtime_container_start() { plog "start $1"; }
    dx_runtime_exec() { :; }
    dx_runtime_logs() { :; }
    dx_bootstrap_lease_listing() { :; }
    dx_bootstrap_report_drift() { :; }
    dx_bootstrap_confirm_publication() { :; }
}

# run_entry ENTRY MAIN [VAR=VALUE...]: source bin/ENTRY in a subshell with a
# clean host-path configuration on the current world and call MAIN.
run_entry() {
    local entry="$1" main="$2"
    shift 2
    reset_logs
    BEFORE="$(snap "$ROOT")"
    STATE_BEFORE="$(snap "$STATE")"
    T0="$(utc_now)"
    (
        for _n in $DXE_CONFIG_FIELDS; do unset "$_n"; done
        unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PERSIST_FRESH_START \
            DXE_RUNTIME_DOCKER_DAEMON_ID DX_LEGACY_WORKSPACE_VOLUME XDG_STATE_HOME
        env_common
        for _kv in "$@"; do export "${_kv?}"; done
        # shellcheck source=/dev/null
        source "$BASE_DIR/bin/$entry"
        wiring_overrides
        SCRIPT_DIR="$STUB_DIR"
        "$main"
    ) >"$W/out" 2>"$W/err" </dev/null
    RC=$?
    T1="$(utc_now)"
    OUT="$(cat "$W/out")"
    ERR="$(cat "$W/err")"
    AFTER="$(snap "$ROOT")"
    STATE_AFTER="$(snap "$STATE")"
}
cv() { run_entry dx-create-volumes create_volumes_main "$@"; }
sc() { run_entry dx-start-container start_container_main "$@"; }

# --- reading what happened ----------------------------------------------------
# run_calls: the docker call files whose first word is `run`, in call order.
run_calls() {
    local n=1
    while [ -e "$DDIR/call.$n" ]; do
        if [ "$(sed -n 1p "$DDIR/call.$n")" = run ]; then printf '%s\n' "$DDIR/call.$n"; fi
        n=$((n + 1))
    done
}
n_runs() { run_calls | awk 'END { print NR }'; }
# expected_run ROOT MODE OWNER SENTINEL: the pinned argv, SCRIPT as <SCRIPT>.
expected_run() {
    printf '%s\n' run --rm -i --network none --user 0:0 --pull never --mount \
        "type=bind,source=$1,target=$TARGET" --entrypoint sh "$IMAGE" -c '<SCRIPT>' sh \
        "$TARGET" "$GUEST" "$2" "$3" "$4"
}
normalized_run() { awk 'NR == 16 { print "<SCRIPT>"; next } { print }' "$1"; }
script_of() { sed -n 16p "$1"; }

# expect_run LABEL ROOT MODE OWNER SENTINEL: exactly one docker run, with the
# pinned argv. Leaves its call file in RUN_FILE.
expect_run() {
    local label="$1" files want got
    files="$(run_calls)"
    RUN_FILE="$(printf '%s\n' "$files" | sed -n 1p)"
    if [ "$(n_runs)" = 1 ]; then
        test_pass "$label: exactly one docker run"
    else
        test_fail "$label: exactly one docker run (got $(n_runs); log: $(tr '\n' '|' <"$LOG"))"
        return 0
    fi
    want="$(expected_run "$2" "$3" "$4" "$5")"
    got="$(normalized_run "$RUN_FILE")"
    if [ "$got" = "$want" ]; then
        test_pass "$label: the docker run argv is exactly the pinned one"
    else
        test_fail "$label: the docker run argv is exactly the pinned one (got: $(printf '%s' "$got" | tr '\n' ' '))"
    fi
}

# expect_marker LABEL DIR: DIR/.dxe-persist-dir holds exactly the ready marker
# for GUEST with a created-at taken during the call; sets MARKER_T.
expect_marker() {
    local label="$1" f="$2/$MARKER_NAME" want
    MARKER_T="$(sed -n 's/^created-at=//p' "$f" 2>/dev/null | head -n1)"
    want="$W/marker.want"
    printf 'schema=1\nguest=%s\nstate=ready\ncreated-at=%s\n' "$GUEST" "$MARKER_T" >"$want"
    if [ -f "$f" ] && [ ! -L "$f" ] && cmp -s "$want" "$f"; then
        test_pass "$label: the marker is exactly schema/guest/state=ready/created-at"
    else
        test_fail "$label: the marker is exactly schema/guest/state=ready/created-at (got: $(tr '\n' '|' 2>/dev/null <"$f"))"
    fi
    if dx_persist_marker_valid_timestamp "$MARKER_T" && not_after "$T0" "$MARKER_T" && not_after "$MARKER_T" "$T1"; then
        test_pass "$label: created-at is a UTC timestamp taken during the run"
    else
        test_fail "$label: created-at is a UTC timestamp taken during the run (got [$MARKER_T], run $T0..$T1)"
    fi
    eq "$label: the marker's mode is 0644" 644 "$(file_mode "$f" 2>/dev/null)"
}

# expect_record LABEL MODE: the D-7 record, exactly (its created-at is the
# leaf marker's own), written atomically.
expect_record() {
    local label="$1" mode="$2" want="$W/record.want" movers tmp_file marker_t
    marker_t="$(sed -n 's/^created-at=//p' "$GDIR/$MARKER_NAME" 2>/dev/null | head -n1)"
    if [ -z "$marker_t" ]; then
        test_fail "$label: the leaf has a marker whose created-at the record can repeat"
    fi
    printf 'schema=1\nguest=%s\nroot=%s\nmode=%s\ncreated-at=%s\n' "$GUEST" "$ROOT" "$mode" "$marker_t" >"$want"
    if [ -f "$REC_FILE" ] && [ ! -L "$REC_FILE" ] && cmp -s "$want" "$REC_FILE"; then
        test_pass "$label: the record is exactly schema/guest/root/mode=$mode/created-at (the marker's)"
    else
        test_fail "$label: the record is exactly schema/guest/root/mode=$mode/created-at (got: $(tr '\n' '|' 2>/dev/null <"$REC_FILE"))"
    fi
    eq "$label: the record's mode is 0600" 600 "$(file_mode "$REC_FILE" 2>/dev/null)"
    eq "$label: the record's directory holds only the record (no temp file)" "./${NAS}__$GUEST" \
        "$(entries_of "$STATE/dxe/persist-dirs" 2>/dev/null)"
    movers="$(awk -v r="$REC_FILE" '{ n = split($0, w, " "); if (n >= 2 && w[n] == r) c++ } END { print c + 0 }' "$MVLOG")"
    tmp_file="$(awk -v r="$REC_FILE" '{ n = split($0, w, " "); if (n >= 2 && w[n] == r) print w[n - 1] }' "$MVLOG" | head -n1)"
    if [ "$movers" = 1 ] && [ "${tmp_file%/*}" = "${REC_FILE%/*}" ] && [ "$tmp_file" != "$REC_FILE" ] && [ ! -e "$tmp_file" ]; then
        test_pass "$label: the record arrives by ONE mv from a temp file in its own directory"
    else
        test_fail "$label: the record arrives by ONE mv from a temp file in its own directory (mv log: $(tr '\n' '|' <"$MVLOG"))"
    fi
}

# expect_owner_before_marker LABEL OWNER: the container chowned only the leaf,
# once, and set its owner and mode before the one mv onto the marker.
expect_owner_before_marker() {
    local label="$1" owner="$2" leaf="@/dxe/$GUEST/persist" chown_at mv_at chmod_at
    eq "$label: exactly one chown, of the leaf, to $owner" "chown $owner $leaf" "$(grep '^chown' "$CLOG" | tr '\n' '|' | sed 's/|$//')"
    eq "$label: exactly one mv in the container, onto the marker" "1" "$(count_lines "$CLOG" "^mv ")"
    chown_at="$(grep -n '^chown' "$CLOG" | head -n1 | cut -d: -f1)"
    mv_at="$(grep -n "^mv .* $leaf/$MARKER_NAME\$" "$CLOG" | head -n1 | cut -d: -f1)"
    chmod_at="$(grep -n "^chmod [^ ]* $leaf\$" "$CLOG" | tail -n1 | cut -d: -f1)"
    if [ -n "$chown_at" ] && [ -n "$mv_at" ] && [ "$chown_at" -lt "$mv_at" ] \
        && { [ -z "$chmod_at" ] || [ "$chmod_at" -lt "$mv_at" ]; }; then
        test_pass "$label: owner and mode are set before the marker is moved into place"
    else
        test_fail "$label: owner and mode are set before the marker is moved into place (container log: $(tr '\n' '|' <"$CLOG"))"
    fi
    if grep -q REFUSED "$CLOG"; then
        test_fail "$label: no recursive or out-of-share chmod/chown/mv/rm (container log: $(tr '\n' '|' <"$CLOG"))"
    else
        test_pass "$label: no recursive or out-of-share chmod/chown/mv/rm"
    fi
}

# expect_leaf LABEL: the leaf is a real 0755 directory holding only the marker.
expect_leaf() {
    local label="$1"
    if [ -d "$GDIR" ] && [ ! -L "$GDIR" ]; then test_pass "$label: the leaf is a real directory"
    else test_fail "$label: the leaf is a real directory"; fi
    eq "$label: the leaf's mode is 0755" 755 "$(file_mode "$GDIR" 2>/dev/null)"
    eq "$label: the leaf holds only the marker" "./$MARKER_NAME" "$(entries_of "$GDIR" 2>/dev/null)"
}

expect_ok() { # LABEL
    if [ "$RC" -eq 0 ] && [ "$(error_lines "$ERR$OUT")" = 0 ]; then
        test_pass "$1: exits 0 with no Error line"
    else
        test_fail "$1: exits 0 with no Error line (rc=$RC stderr: $ERR)"
    fi
}

# expect_refused LABEL KEYWORD...: non-zero, exactly one Error line (stderr),
# naming each KEYWORD; the share and the state directory are unchanged and
# nothing was chowned.
expect_refused() {
    local label="$1" k line
    shift
    if [ "$RC" -ne 0 ]; then test_pass "$label: exits non-zero"; else test_fail "$label: exits non-zero"; fi
    if [ "$(error_lines "$ERR")" = 1 ] && [ "$(error_lines "$OUT")" = 0 ]; then
        test_pass "$label: exactly one Error: line, on stderr"
    else
        test_fail "$label: exactly one Error: line, on stderr (stderr: $ERR | stdout: $OUT)"
    fi
    line="$(grep '^Error:' <<<"$ERR" || true)"
    for k in "$@"; do
        if grep -Fq -- "$k" <<<"$line"; then test_pass "$label: the Error line names [$k]"
        else test_fail "$label: the Error line names [$k] (stderr: $ERR)"; fi
    done
    if [ "$BEFORE" = "$AFTER" ]; then test_pass "$label: the share is unchanged"
    else test_fail "$label: the share is unchanged (before: $BEFORE | after: $AFTER)"; fi
    if [ "$STATE_BEFORE" = "$STATE_AFTER" ]; then test_pass "$label: the record and state directory are unchanged"
    else test_fail "$label: the record and state directory are unchanged (before: $STATE_BEFORE | after: $STATE_AFTER)"; fi
    if grep -q '^chown' "$CLOG"; then test_fail "$label: nothing was chowned"; else test_pass "$label: nothing was chowned"; fi
}

# ---------------------------------------------------------------------------
test_section "WP4.4: the operations exist, the owner is defined once"

ok "dx_runtime_volume_state is declared (dx-runtime.sh)" have dx_runtime_volume_state
ok "dx_runtime_apple_volume_state is implemented" have dx_runtime_apple_volume_state
ok "dx_runtime_docker_volume_state is implemented" have dx_runtime_docker_volume_state
ok "dx_runtime_host_dir_establish is declared (dx-runtime.sh)" have dx_runtime_host_dir_establish
ok "dx_runtime_apple_host_dir_establish is implemented" have dx_runtime_apple_host_dir_establish
ok "dx_runtime_docker_host_dir_establish is implemented" have dx_runtime_docker_host_dir_establish
eq "DX_PERSIST_DIR_OWNER is the guest's dx UID:GID (Q-10: 30033:30001)" "$OWNER_PIN" "${DX_PERSIST_DIR_OWNER:-}"
if [ -n "$DASH_BIN" ]; then test_pass "dash is available to run the container script under"
else test_fail "dash is available to run the container script under"; fi

# ---------------------------------------------------------------------------
test_section "WP4.4: dx_runtime_volume_state (present | absent | unknown)"

# vs_case LABEL WANT_WORD WANT_RC(0|1) [VAR=VALUE...]: one docker-ssh call.
vs_case() {
    local label="$1" want="$2" want_rc="$3" rc_ok=no
    shift 3
    lib_call "$@" -- dx_runtime_volume_state dx-fix-persist
    if [ "$want_rc" = 0 ] && [ "$RC" -eq 0 ]; then rc_ok=yes; fi
    if [ "$want_rc" != 0 ] && [ "$RC" -ne 0 ]; then rc_ok=yes; fi
    if [ "$OUT" = "$want" ] && [ "$rc_ok" = yes ]; then
        test_pass "volume_state: $label -> $want"
    else
        test_fail "volume_state: $label -> $want (got [$OUT] rc=$RC stderr: $ERR)"
    fi
    eq "volume_state: $label: no Error: line" 0 "$(error_lines "$ERR")"
}
world dx-fix-persist
vs_case "inspect succeeds" present 0
eq "volume_state: one docker call, exactly 'volume inspect dx-fix-persist'" \
    "$(printf 'volume\ninspect\ndx-fix-persist')" "$(cat "$DDIR/call.1" 2>/dev/null)"
extra_calls=""
for call_file in "$DDIR"/*; do
    [ -e "$call_file" ] || continue
    [ "$call_file" = "$DDIR/call.1" ] || extra_calls="$extra_calls ${call_file##*/}"
done
eq "volume_state: no second docker call" "" "$extra_calls"
world
vs_case "the CLI's 'Error: No such volume'" absent 0
eq "volume_state (absent): one docker call, exactly 'volume inspect dx-fix-persist'" \
    "$(printf 'volume\ninspect\ndx-fix-persist')" "$(cat "$DDIR/call.1" 2>/dev/null)"
world
vs_case "the daemon's 'get NAME: no such volume'" absent 0 P_INSPECT_STYLE=daemon
world dx-fix-persist
vs_case "the daemon is unreachable" unknown 1 P_INSPECT_DOWN=dx-fix-persist
world
vs_case "the ssh connection fails" unknown 1 'P_SSH_FAIL=*'
world
fake_tool_write "$TOOLS" docker 'printf "%s\n" "$@" > "${P_DDIR:?}/call.1"
echo "permission denied while trying to connect to the Docker daemon socket" >&2
exit 1'
vs_case "permission denied" unknown 1

apple_vs() {
    local tools calls="$SCRATCH/apple-vs-calls" out rc
    tools="$(fake_tool_dir_create "$SCRATCH")"
    : >"$calls"
    fake_tool_write "$tools" container "printf '%s\n' \"\$*\" >> '$calls'; exit 0"
    for t in ssh docker; do
        fake_tool_write "$tools" "$t" "echo $t >> '$calls'; exit 99"
    done
    out="$(DX_RUNTIME=apple PATH="$tools:$PATH" dx_runtime_volume_state dx-fix-persist 2>/dev/null)"
    rc=$?
    if [ "$out" = present ] && [ "$rc" -eq 0 ]; then test_pass "volume_state (apple): an existing volume is present"
    else test_fail "volume_state (apple): an existing volume is present (got [$out] rc=$rc)"; fi
    eq "volume_state (apple): one call, 'volume inspect dx-fix-persist'" "volume inspect dx-fix-persist" "$(cat "$calls")"
}
apple_vs

# ---------------------------------------------------------------------------
test_section "WP4.4: dx_runtime_host_dir_establish (adapter)"

M_TEXT="$(dx_persist_marker_format "$GUEST" ready "" 2026-10-11T08:00:00Z)"

apple_establish() {
    local tools calls="$SCRATCH/apple-est-calls" root out rc err
    if ! have dx_runtime_apple_host_dir_establish; then
        test_fail "establish (apple): dx_runtime_apple_host_dir_establish is missing"
        return 0
    fi
    tools="$(fake_tool_dir_create "$SCRATCH")"
    : >"$calls"
    for t in container ssh docker; do
        fake_tool_write "$tools" "$t" "echo $t >> '$calls'; exit 99"
    done
    root="$(persist_fixture_root_create "$SCRATCH")"
    : >"$root/$SENTINEL"
    out="$(DX_RUNTIME=apple DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL" DX_IMAGE="$IMAGE" PATH="$tools:$PATH" \
        dx_runtime_host_dir_establish create "$root" "$GUEST" "$OWNER_PIN" "$M_TEXT" 2>"$SCRATCH/apple-est.err")"
    rc=$?
    err="$(cat "$SCRATCH/apple-est.err")"
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 99 ]; then test_pass "establish (apple): non-zero"
    else test_fail "establish (apple): non-zero (rc=$rc)"; fi
    eq "establish (apple): nothing on stdout" "" "$out"
    if grep -Fq unsupported <<<"$err"; then test_pass "establish (apple): stderr says unsupported"
    else test_fail "establish (apple): stderr says unsupported (got: $err)"; fi
    eq "establish (apple): no runtime tool was called" "" "$(cat "$calls")"
    eq "establish (apple): nothing was created on the share" "./$SENTINEL" "$(entries_of "$root")"
}
apple_establish

# adapter_refused LABEL [VAR=VALUE...] -- ARGS...: refused before any call.
adapter_refused() {
    local label="$1"
    shift
    if ! have dx_runtime_docker_host_dir_establish; then
        test_fail "establish refuses $label (dx_runtime_docker_host_dir_establish is missing)"
        return 0
    fi
    world
    put_sentinel
    lib_call "$@"
    if [ "$RC" -ne 0 ]; then test_pass "establish refuses $label: non-zero"
    else test_fail "establish refuses $label: non-zero"; fi
    eq "establish refuses $label: nothing on stdout" "" "$OUT"
    if [ -n "$ERR" ]; then test_pass "establish refuses $label: a reason on stderr"
    else test_fail "establish refuses $label: a reason on stderr"; fi
    eq "establish refuses $label: no ssh call at all" "" "$(cat "$LOG")"
    eq "establish refuses $label: the share is unchanged" "$BEFORE" "$AFTER"
}
NL='
'
adapter_refused "an unknown mode" -- dx_runtime_host_dir_establish destroy "$SCRATCH" "$GUEST" "$OWNER_PIN" "$M_TEXT"
adapter_refused "an empty mode" -- dx_runtime_host_dir_establish "" "$SCRATCH" "$GUEST" "$OWNER_PIN" "$M_TEXT"
adapter_refused "an empty root" -- dx_runtime_host_dir_establish create "" "$GUEST" "$OWNER_PIN" "$M_TEXT"
adapter_refused "a root of '-'" -- dx_runtime_host_dir_establish create - "$GUEST" "$OWNER_PIN" "$M_TEXT"
adapter_refused "a relative root" -- dx_runtime_host_dir_establish create share/root "$GUEST" "$OWNER_PIN" "$M_TEXT"
adapter_refused "a root with a comma" -- dx_runtime_host_dir_establish create "$SCRATCH/a,readonly" "$GUEST" "$OWNER_PIN" "$M_TEXT"
adapter_refused "a root with a newline" -- dx_runtime_host_dir_establish create "$SCRATCH/a${NL}b" "$GUEST" "$OWNER_PIN" "$M_TEXT"
adapter_refused "a guest with a slash" -- dx_runtime_host_dir_establish create "$SCRATCH" "dx/fix" "$OWNER_PIN" "$M_TEXT"
adapter_refused "a guest with a leading dash" -- dx_runtime_host_dir_establish create "$SCRATCH" "-dx" "$OWNER_PIN" "$M_TEXT"
adapter_refused "a guest of '..'" -- dx_runtime_host_dir_establish create "$SCRATCH" ".." "$OWNER_PIN" "$M_TEXT"
for bad_owner in dx:dx 30033 :30001 30033: 30033:30001:0 -1:0 "30033 :30001" ""; do
    adapter_refused "the owner [$bad_owner]" -- dx_runtime_host_dir_establish create "$SCRATCH" "$GUEST" "$bad_owner" "$M_TEXT"
done
adapter_refused "an invalid marker text" -- dx_runtime_host_dir_establish create "$SCRATCH" "$GUEST" "$OWNER_PIN" "this is not a marker"
adapter_refused "an empty marker text" -- dx_runtime_host_dir_establish create "$SCRATCH" "$GUEST" "$OWNER_PIN" ""
adapter_refused "without a mount sentinel" DX_PERSIST_HOST_MOUNT_SENTINEL= -- \
    dx_runtime_host_dir_establish create "$SCRATCH" "$GUEST" "$OWNER_PIN" "$M_TEXT"

# The argv, the stdin and the script, with a share root whose path has spaces.
world
SPACED="$ROOT/my share root"
mkdir -p "$SPACED"
: >"$SPACED/$SENTINEL"
lib_call -- dx_runtime_host_dir_establish create "$SPACED" "$GUEST" "$OWNER_PIN" "$M_TEXT"
eq "establish (adapter, create): exit 0" 0 "$RC"
eq "establish (adapter, create): nothing on stdout" "" "$OUT"
expect_run "establish (adapter, create, a root with spaces)" "$SPACED" create "$OWNER_PIN" "$SENTINEL"
printf '%s\n' "$M_TEXT" >"$W/marker.sent"
if cmp -s "$W/marker.sent" "$SPACED/dxe/$GUEST/persist/$MARKER_NAME"; then
    test_pass "establish (adapter): the marker file holds MARKER_TEXT plus one newline (sent on stdin)"
else
    test_fail "establish (adapter): the marker file holds MARKER_TEXT plus one newline (got: $(cat "$SPACED/dxe/$GUEST/persist/$MARKER_NAME" 2>/dev/null))"
fi
if grep -Fq 'schema=1' "$RUN_FILE" 2>/dev/null; then
    test_fail "establish (adapter): the marker text is not an argv word"
else
    test_pass "establish (adapter): the marker text is not an argv word"
fi
SCRIPT_CREATE="$(script_of "$RUN_FILE" 2>/dev/null)"
printf '%s\n' "$SCRIPT_CREATE" >"$W/script.sh"
eq "establish (adapter): SCRIPT is a single line" 1 "$(awk 'END { print NR }' "$W/script.sh")"
ok "establish (adapter): SCRIPT passes sh -n" sh -n "$W/script.sh"
if [ -n "$DASH_BIN" ]; then ok "establish (adapter): SCRIPT passes dash -n" "$DASH_BIN" -n "$W/script.sh"; fi
for word in "$TARGET" "$GUEST" "$OWNER_PIN" "$SENTINEL" "$SCRATCH" "schema="; do
    if grep -Fq -- "$word" "$W/script.sh"; then test_fail "establish (adapter): SCRIPT does not embed [$word]"
    else test_pass "establish (adapter): SCRIPT does not embed [$word]"; fi
done
if grep -Fq -- "\$'" "$LOG"; then test_fail "establish (adapter): no bash-only \$'...' quoting reaches the NAS shell"
else test_pass "establish (adapter): no bash-only \$'...' quoting reaches the NAS shell"; fi

# The owner is a parameter, not a literal in the script.
world
put_sentinel
lib_call -- dx_runtime_host_dir_establish create "$ROOT" "$GUEST" 41000:41001 "$M_TEXT"
eq "establish (adapter, OWNER 41000:41001): exit 0" 0 "$RC"
expect_run "establish (adapter, OWNER 41000:41001)" "$ROOT" create 41000:41001 "$SENTINEL"
eq "establish (adapter, OWNER 41000:41001): the leaf is chowned to that owner" \
    "chown 41000:41001 @/dxe/$GUEST/persist" "$(grep '^chown' "$CLOG" | tr '\n' '|' | sed 's/|$//')"

# The same script for adopt and fresh-start.
world
put_sentinel
mkdir -p "$GDIR"
lib_call -- dx_runtime_host_dir_establish adopt "$ROOT" "$GUEST" "$OWNER_PIN" "$M_TEXT"
eq "establish (adapter, adopt): exit 0" 0 "$RC"
expect_run "establish (adapter, adopt)" "$ROOT" adopt "$OWNER_PIN" "$SENTINEL"
eq "establish (adapter): adopt runs the very same SCRIPT as create" "$SCRIPT_CREATE" "$(script_of "$RUN_FILE" 2>/dev/null)"
world
put_sentinel
mkdir -p "$GDIR"
lib_call -- dx_runtime_host_dir_establish fresh-start "$ROOT" "$GUEST" "$OWNER_PIN" "$M_TEXT"
eq "establish (adapter, fresh-start): exit 0" 0 "$RC"
expect_run "establish (adapter, fresh-start)" "$ROOT" fresh-start "$OWNER_PIN" "$SENTINEL"
eq "establish (adapter): fresh-start runs the very same SCRIPT as create" "$SCRIPT_CREATE" "$(script_of "$RUN_FILE" 2>/dev/null)"

# ---------------------------------------------------------------------------
# dx_persist_dir_establish, run directly, under sh and under dash.
est() { lib_call "$@" -- dx_persist_dir_establish "${EST_MODE-}"; }

establish_cases() {
    local shl="$1" tag
    tag="[$(basename "$shl")]"
    P_SH_DEFAULT="$shl"
    test_section "WP4.4: dx_persist_dir_establish $tag"

    # create, nothing below the share yet.
    world
    put_sentinel
    EST_MODE=create est
    expect_ok "create $tag"
    expect_run "create $tag" "$ROOT" create "$OWNER_PIN" "$SENTINEL"
    expect_leaf "create $tag"
    expect_marker "create $tag" "$GDIR"
    expect_owner_before_marker "create $tag" "$OWNER_PIN"
    eq "create $tag: dxe and dxe/$GUEST are made with mode 0755" "755 755" \
        "$(file_mode "$ROOT/dxe" 2>/dev/null) $(file_mode "$ROOT/dxe/$GUEST" 2>/dev/null)"
    eq "create $tag: the share holds exactly the new tree (and the sentinel)" \
        "$(printf './%s\n./dxe\n./dxe/%s\n./dxe/%s/persist\n./dxe/%s/persist/%s' "$SENTINEL" "$GUEST" "$GUEST" "$GUEST" "$MARKER_NAME" | LC_ALL=C sort)" \
        "$(entries_of "$ROOT")"
    expect_record "create $tag" create

    # create below existing parents: they are left alone.
    world
    put_sentinel
    mkdir -p "$ROOT/dxe/other-guest" "$ROOT/dxe/$GUEST"
    chmod 0750 "$ROOT/dxe"
    chmod 0700 "$ROOT/dxe/$GUEST"
    EST_MODE=create est
    expect_ok "create below existing parents $tag"
    expect_leaf "create below existing parents $tag"
    expect_marker "create below existing parents $tag" "$GDIR"
    eq "create below existing parents $tag: dxe keeps its mode" 750 "$(file_mode "$ROOT/dxe")"
    eq "create below existing parents $tag: dxe/$GUEST keeps its mode" 700 "$(file_mode "$ROOT/dxe/$GUEST")"
    eq "create below existing parents $tag: no chmod or chown of a parent" 0 \
        "$(count_lines "$CLOG" "^(chmod|chown) [^ ]+ @/dxe(/$GUEST)?\$")"
    ok "create below existing parents $tag: other guests' directories are untouched" test -d "$ROOT/dxe/other-guest"
    expect_record "create below existing parents $tag" create

    # adopt: the empty, unmarked leaf a failed create left behind.
    world
    put_sentinel
    mkdir -p "$GDIR"
    chmod 0700 "$GDIR"
    EST_MODE=adopt est
    expect_ok "adopt $tag"
    expect_run "adopt $tag" "$ROOT" adopt "$OWNER_PIN" "$SENTINEL"
    expect_leaf "adopt $tag"
    expect_marker "adopt $tag" "$GDIR"
    expect_owner_before_marker "adopt $tag" "$OWNER_PIN"
    expect_record "adopt $tag" adopt

    # fresh-start: an empty leaf, the old volume kept; an old record is replaced.
    world dx-fix-persist
    put_sentinel
    mkdir -p "$GDIR"
    put_record "$(printf 'schema=1\nguest=%s\nroot=/elsewhere\nmode=create\ncreated-at=2026-01-01T00:00:00Z\n' "$GUEST")"
    EST_MODE=fresh-start est DX_PERSIST_FRESH_START="$GUEST"
    expect_ok "fresh-start $tag"
    expect_run "fresh-start $tag" "$ROOT" fresh-start "$OWNER_PIN" "$SENTINEL"
    expect_leaf "fresh-start $tag"
    expect_marker "fresh-start $tag" "$GDIR"
    expect_owner_before_marker "fresh-start $tag" "$OWNER_PIN"
    expect_record "fresh-start $tag (the old record is replaced)" fresh-start

    # The owner comes from DX_PERSIST_DIR_OWNER at call time.
    world
    put_sentinel
    EST_MODE=create est DX_PERSIST_DIR_OWNER=41000:41001
    expect_ok "create with DX_PERSIST_DIR_OWNER=41000:41001 $tag"
    expect_run "create with DX_PERSIST_DIR_OWNER=41000:41001 $tag" "$ROOT" create 41000:41001 "$SENTINEL"
    expect_owner_before_marker "create with DX_PERSIST_DIR_OWNER=41000:41001 $tag" 41000:41001

    # The tree changed since the probe: the container refuses, writes nothing.
    world
    put_sentinel
    mkdir -p "$GDIR"
    EST_MODE=create est
    expect_refused "create, but the leaf now exists (empty) $tag" "$GDIR"

    world
    put_sentinel
    mkdir -p "$ROOT/dxe/$GUEST"
    ln -s "$ROOT/no-such-target" "$GDIR"
    EST_MODE=create est
    expect_refused "create, but the leaf is now a dangling symlink $tag" "$GDIR"

    world
    put_sentinel
    mkdir -p "$ROOT/elsewhere"
    ln -s elsewhere "$ROOT/dxe"
    EST_MODE=create est
    expect_refused "create, but the dxe level is now a symlink $tag" "$GDIR"
    eq "create, but the dxe level is now a symlink $tag: nothing was created through it" "" "$(entries_of "$ROOT/elsewhere")"

    world
    put_sentinel
    mkdir -p "$ROOT/elsewhere" "$ROOT/dxe"
    ln -s ../elsewhere "$ROOT/dxe/$GUEST"
    EST_MODE=create est
    expect_refused "create, but the dxe/$GUEST level is now a symlink $tag" "$GDIR"
    eq "create, but the dxe/$GUEST level is now a symlink $tag: nothing was created through it" "" "$(entries_of "$ROOT/elsewhere")"

    world
    EST_MODE=create est
    expect_refused "create, but the share's sentinel is gone (unmounted) $tag" "$GDIR"
    not "create, but the share's sentinel is gone $tag: no dxe level was made" test -e "$ROOT/dxe"

    world
    printf 'x\n' >"$ROOT/real-sentinel"
    ln -s real-sentinel "$ROOT/$SENTINEL"
    EST_MODE=create est
    expect_refused "create, but the sentinel is a symlink $tag" "$GDIR"

    world
    put_sentinel
    mkdir -p "$GDIR"
    printf 'data\n' >"$GDIR/notes.txt"
    EST_MODE=adopt est
    expect_refused "adopt, but the leaf now holds a file $tag" "$GDIR"

    world
    put_sentinel
    mkdir -p "$GDIR"
    : >"$GDIR/.hidden"
    EST_MODE=adopt est
    expect_refused "adopt, but the leaf now holds a dotfile $tag" "$GDIR"

    world
    put_sentinel
    mkdir -p "$GDIR"
    printf 'schema=1\nguest=%s\nstate=ready\n' "$GUEST" >"$GDIR/$MARKER_NAME"
    EST_MODE=adopt est
    expect_refused "adopt, but the leaf is now marked $tag" "$GDIR"

    world
    put_sentinel
    EST_MODE=adopt est
    expect_refused "adopt, but the leaf is gone (adopt never creates) $tag" "$GDIR"
    not "adopt, but the leaf is gone $tag: no dxe level was made" test -e "$ROOT/dxe"

    world
    put_sentinel
    mkdir -p "$ROOT/empty-elsewhere" "$ROOT/dxe/$GUEST"
    ln -s ../../empty-elsewhere "$GDIR"
    EST_MODE=adopt est
    expect_refused "adopt, but the leaf is now a symlink to an empty directory $tag" "$GDIR"
    eq "adopt through a symlinked leaf $tag: nothing was written through it" "" "$(entries_of "$ROOT/empty-elsewhere")"

    world dx-fix-persist
    put_sentinel
    mkdir -p "$GDIR"
    printf 'data\n' >"$GDIR/notes.txt"
    put_record "$(printf 'schema=1\nguest=%s\nroot=/elsewhere\nmode=create\ncreated-at=2026-01-01T00:00:00Z\n' "$GUEST")"
    EST_MODE=fresh-start est DX_PERSIST_FRESH_START="$GUEST"
    expect_refused "fresh-start, but the leaf now holds a file (the old record is kept) $tag" "$GDIR"

    world dx-fix-persist
    put_sentinel
    EST_MODE=fresh-start est DX_PERSIST_FRESH_START="$GUEST"
    expect_refused "fresh-start, but the leaf is gone (never created) $tag" "$GDIR"

    # The share root itself is gone: Docker refuses the bind; nothing is made.
    world
    rm_root="$ROOT"
    ROOT="$rm_root/no-such-share"
    GDIR="$ROOT/dxe/$GUEST/persist"
    EST_MODE=create est
    expect_refused "create, but the share root is gone $tag" "$GDIR"
    not "create, but the share root is gone $tag: the root was not created (no -v)" test -e "$ROOT"
    ROOT="$rm_root"
    GDIR="$ROOT/dxe/$GUEST/persist"

    P_SH_DEFAULT=""
}
establish_cases "$SH_BIN"
if [ -n "$DASH_BIN" ]; then establish_cases "$DASH_BIN"; fi

# ---------------------------------------------------------------------------
test_section "WP4.4: dx_persist_dir_establish refuses before any remote call"

est_refused_early() { # LABEL KEYWORD [VAR=VALUE...]
    local label="$1" key="$2"
    shift 2
    world
    put_sentinel
    lib_call "$@" -- dx_persist_dir_establish "${EST_MODE-}"
    expect_refused "establish $label" "$key"
    eq "establish $label: no ssh or docker call" "" "$(cat "$LOG")$(ls "$DDIR")"
}
EST_MODE=destroy est_refused_early "with an unknown mode" destroy
EST_MODE="" est_refused_early "with an empty mode" Error
EST_MODE=create est_refused_early "without DX_PERSIST_HOST_MOUNT_SENTINEL" DX_PERSIST_HOST_MOUNT_SENTINEL DX_PERSIST_HOST_MOUNT_SENTINEL=
EST_MODE=create est_refused_early "when the record path cannot be formed (no DX_REMOTE_HOST)" Error DX_REMOTE_HOST=

# The record cannot be written: one Error line naming it, and no record.
world
put_sentinel
printf 'not a directory\n' >"$STATE/dxe"
EST_MODE=create est
if [ "$RC" -ne 0 ] && [ "$(error_lines "$ERR")" = 1 ]; then
    test_pass "establish, the record cannot be written: non-zero, exactly one Error line"
else
    test_fail "establish, the record cannot be written: non-zero, exactly one Error line (rc=$RC stderr: $ERR)"
fi
if grep -Fq -- "$STATE/dxe/persist-dirs/${NAS}__$GUEST" <<<"$(grep '^Error:' <<<"$ERR" || true)"; then
    test_pass "establish, the record cannot be written: the Error line names the record path"
else
    test_fail "establish, the record cannot be written: the Error line names the record path (stderr: $ERR)"
fi
eq "establish, the record cannot be written: the state file is left as it was" "not a directory" "$(cat "$STATE/dxe")"

# The container fails: an existing record is kept byte-for-byte.
world dx-fix-persist
put_sentinel
mkdir -p "$GDIR"
OLD_RECORD="$(printf 'schema=1\nguest=%s\nroot=/elsewhere\nmode=create\ncreated-at=2026-01-01T00:00:00Z\n' "$GUEST")"
put_record "$OLD_RECORD"
EST_MODE=fresh-start est DX_PERSIST_FRESH_START="$GUEST" 'P_SSH_FAIL=docker run *'
expect_refused "establish, the docker run itself fails (ssh)" "$GDIR"
eq "establish, the docker run itself fails: the old record is kept" "$OLD_RECORD" "$(cat "$REC_FILE")"

# ---------------------------------------------------------------------------
test_section "WP4.4: dx-create-volumes creates, adopts and fresh-starts"

LEAF_TREE="$(printf './%s\n./dxe\n./dxe/%s\n./dxe/%s/persist\n./dxe/%s/persist/%s' "$SENTINEL" "$GUEST" "$GUEST" "$GUEST" "$MARKER_NAME" | LC_ALL=C sort)"
line_of() { grep -n -- "$2" "$1" 2>/dev/null | head -n1 | cut -d: -f1; }

# A genuinely new guest.
world
put_sentinel
cv
expect_ok "create-volumes, new guest"
expect_run "create-volumes, new guest" "$ROOT" create "$OWNER_PIN" "$SENTINEL"
expect_leaf "create-volumes, new guest"
expect_marker "create-volumes, new guest" "$GDIR"
expect_owner_before_marker "create-volumes, new guest" "$OWNER_PIN"
eq "create-volumes, new guest: the share holds exactly the new tree" "$LEAF_TREE" "$(entries_of "$ROOT")"
expect_record "create-volumes, new guest" create
probe_at="$(line_of "$LOG" '^ssh sh -c ')"
nix_at="$(line_of "$LOG" '^ssh docker volume create .* dx-fix-nix$')"
run_at="$(line_of "$LOG" '^ssh docker run ')"
boot_at="$(line_of "$LOG" '^ssh docker volume create .* dx-fix-bootstrap$')"
if [ -n "$probe_at" ] && [ -n "$nix_at" ] && [ -n "$run_at" ] && [ -n "$boot_at" ] \
    && [ "$probe_at" -lt "$nix_at" ] && [ "$nix_at" -lt "$run_at" ] && [ "$run_at" -lt "$boot_at" ]; then
    test_pass "create-volumes, new guest: probe, nix volume, establish, bootstrap volume -- in that order"
else
    test_fail "create-volumes, new guest: probe < nix volume < establish < bootstrap volume (log: $(tr '\n' '|' <"$LOG"))"
fi
eq "create-volumes, new guest: the persist volume is never created" 0 \
    "$(count_lines "$LOG" '^ssh docker volume create .*dx-fix-persist')"

# The probe fails: nothing is created, nothing recorded.
world
put_sentinel
cv DX_PERSIST_HOST_ROOT="$ROOT/no-such-share"
expect_refused "create-volumes, the root probe fails (unusable root)" DX_PERSIST_HOST_ROOT
eq "create-volumes, the root probe fails: no docker run" 0 "$(n_runs)"
not "create-volumes, the root probe fails: the root is not created" test -e "$ROOT/no-such-share"

world
put_sentinel
cv 'P_SSH_FAIL=sh -c *'
expect_refused "create-volumes, the probe's ssh call fails" DX_PERSIST_HOST_ROOT
eq "create-volumes, the probe's ssh call fails: no docker run" 0 "$(n_runs)"

# A crash between the directory and the marker: the container's mv fails on
# its first call (fake_fail_nth), then the next run adopts the leftover.
world
put_sentinel
SAVED_PATH="$PATH"
TMPDIR="$SCRATCH" with_fake_runtime mv
fake_fail_nth mv 1 1
PATH="$SAVED_PATH"
: >"$FAKE_TRANSCRIPT"
cv P_CPRE="$DXE_FAKE_RUNTIME_DIR"
if [ "$RC" -ne 0 ] && [ "$(error_lines "$ERR")" = 1 ] && grep -Fq -- "$GDIR" <<<"$(grep '^Error:' <<<"$ERR" || true)"; then
    test_pass "crash: dx-create-volumes fails with one Error line naming the directory"
else
    test_fail "crash: dx-create-volumes fails with one Error line naming the directory (rc=$RC stderr: $ERR)"
fi
eq "crash: the container's mv was called once, onto the marker" "1" \
    "$(count_lines "$FAKE_TRANSCRIPT" "^.*\\$MARKER_NAME *\$")$(awk 'END { print (NR == 1 ? "" : " calls=" NR) }' "$FAKE_TRANSCRIPT")"
if [ -d "$GDIR" ] && [ ! -L "$GDIR" ] && [ -z "$(entries_of "$GDIR")" ]; then
    test_pass "crash: an empty, unmarked leaf is left (no temp file)"
else
    test_fail "crash: an empty, unmarked leaf is left (entries: $(entries_of "$GDIR" 2>/dev/null | tr '\n' ' '))"
fi
eq "crash: the leftover leaf already has mode 0755" 755 "$(file_mode "$GDIR" 2>/dev/null)"
eq "crash: the leftover leaf was already chowned (before the marker)" "chown $OWNER_PIN @/dxe/$GUEST/persist" \
    "$(grep '^chown' "$CLOG" | tr '\n' '|' | sed 's/|$//')"
not "crash: no record was written" test -e "$REC_FILE"
eq "crash: nothing at all under the record directory" "" "$(entries_of "$STATE/dxe/persist-dirs" 2>/dev/null)"
cv
expect_ok "after the crash, the next dx-create-volumes"
expect_run "after the crash, the next dx-create-volumes (adopt)" "$ROOT" adopt "$OWNER_PIN" "$SENTINEL"
expect_leaf "after the crash, adopt"
expect_marker "after the crash, adopt" "$GDIR"
expect_owner_before_marker "after the crash, adopt" "$OWNER_PIN"
expect_record "after the crash, adopt" adopt

# An empty leftover from an earlier crash, mode 0700: adopted.
world
put_sentinel
mkdir -p "$GDIR"
chmod 0700 "$GDIR"
cv P_INSPECT_STYLE=daemon
expect_ok "create-volumes, empty leftover (absent volume reported by the daemon)"
expect_run "create-volumes, empty leftover" "$ROOT" adopt "$OWNER_PIN" "$SENTINEL"
expect_leaf "create-volumes, empty leftover"
expect_marker "create-volumes, empty leftover" "$GDIR"
expect_record "create-volumes, empty leftover" adopt

# Fresh start: the empty directory, the old volume kept untouched.
world dx-fix-persist
put_sentinel
mkdir -p "$GDIR"
cv DX_PERSIST_FRESH_START="$GUEST"
expect_ok "create-volumes, fresh start"
expect_run "create-volumes, fresh start" "$ROOT" fresh-start "$OWNER_PIN" "$SENTINEL"
expect_leaf "create-volumes, fresh start"
expect_marker "create-volumes, fresh start" "$GDIR"
expect_record "create-volumes, fresh start" fresh-start
untouched=yes
for f in "$DDIR"/call.*; do
    if grep -Fq dx-fix-persist "$f" && [ "$(cat "$f")" != "$(printf 'volume\ninspect\ndx-fix-persist')" ]; then untouched=no; fi
done
eq "create-volumes, fresh start: the old volume is only ever inspected (no rm, no create, no mount)" yes "$untouched"

# Fresh start with only a record (no volume): the record is replaced.
world
put_sentinel
mkdir -p "$GDIR"
put_record "$(printf 'schema=1\nguest=%s\nroot=/elsewhere\nmode=create\ncreated-at=2026-01-01T00:00:00Z\n' "$GUEST")"
cv DX_PERSIST_FRESH_START="$GUEST"
expect_ok "create-volumes, fresh start over an old record"
expect_marker "create-volumes, fresh start over an old record" "$GDIR"
expect_record "create-volumes, fresh start over an old record (replaced)" fresh-start

# A refusal keeps the record byte-for-byte.
world
put_sentinel
mkdir -p "$GDIR"
put_record "$OLD_RECORD"
cv
expect_refused "create-volumes, empty directory with a record and no override" "DX_PERSIST_FRESH_START=$GUEST"
eq "create-volumes, refused: no docker run" 0 "$(n_runs)"

# A ready directory: nothing is established, no record is written.
world
put_sentinel
mkdir -p "$GDIR"
printf 'schema=1\nguest=%s\nstate=ready\ncreated-at=2026-10-11T08:00:00Z\n' "$GUEST" >"$GDIR/$MARKER_NAME"
cv
expect_ok "create-volumes, ready directory"
eq "create-volumes, ready directory: no docker run" 0 "$(n_runs)"
eq "create-volumes, ready directory: the share is unchanged" "$BEFORE" "$AFTER"

# ---------------------------------------------------------------------------
test_section "WP4.4: an unknown persist-volume state refuses"

world
put_sentinel
cv P_INSPECT_DOWN=dx-fix-persist
expect_refused "create-volumes, the persist volume cannot be inspected" dx-fix-persist inspect
eq "create-volumes, volume state unknown: no docker run" 0 "$(n_runs)"
eq "create-volumes, volume state unknown: no volume is created" 0 "$(count_lines "$LOG" '^ssh docker volume create ')"

world
put_sentinel
mkdir -p "$GDIR"
cv P_INSPECT_DOWN=dx-fix-persist
expect_refused "create-volumes, empty leftover, the persist volume cannot be inspected" dx-fix-persist inspect
eq "create-volumes, empty leftover, volume state unknown: no docker run" 0 "$(n_runs)"

world
put_sentinel
sc P_INSPECT_DOWN=dx-fix-persist
expect_refused "start-container, the persist volume cannot be inspected" dx-fix-persist inspect
if grep -q '^start ' "$LOG"; then test_fail "start-container, volume state unknown: no container start"
else test_pass "start-container, volume state unknown: no container start"; fi
eq "start-container, volume state unknown: no docker run" 0 "$(n_runs)"

# ---------------------------------------------------------------------------
test_section "WP4.4: only establish writes the record"

world
put_sentinel
mkdir -p "$GDIR"
printf 'schema=1\nguest=%s\nstate=ready\ncreated-at=2026-10-11T08:00:00Z\n' "$GUEST" >"$GDIR/$MARKER_NAME"
sc
expect_ok "start-container, ready directory, no record"
if grep -Fxq "start $GUEST" "$LOG"; then test_pass "start-container, ready directory: the container is started"
else test_fail "start-container, ready directory: the container is started (log: $(tr '\n' '|' <"$LOG"))"; fi
eq "start-container never writes a record" "$STATE_BEFORE" "$STATE_AFTER"
eq "start-container: no docker run" 0 "$(n_runs)"

print_summary
exit_with_code
