#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP4.4 (implementer unit cases): in-process cases for the directory creation
# helpers that the acceptance suite (tests/test_persist_dir_create.sh) does
# not reach: Apple's two-state volume_state, the Docker answer's message
# handling, the adapter's last pre-call refusal, dx_persist_dir_establish's
# own refusals and record failures (with the adapter replaced by a
# recorder), the record writer, the backfill's edge arms, and the
# dx-create-volumes helpers around them -- the legacy-volume check in both
# modes, the unknown volume state, and the decision's report.

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

test_section "WP4.4: directory creation helpers (in-process)"

SCRATCH="$(persist_fixture_root_create)"
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac

DX_RUNTIME=docker-ssh DX_REMOTE_HOST=nas-u.invalid DX_CONTAINER_NAME=dx-u
DX_PERSIST_VOLUME=dx-u-persist DX_PERSIST_HOST_ROOT=/share-u DX_PERSIST_STORAGE=host-path
DX_PERSIST_HOST_MOUNT_SENTINEL=flag DX_IMAGE=img-u DXE_RUNTIME_DOCKER_BIN=docker
STATE="$SCRATCH/dxe-state"
XDG_STATE_HOME="$STATE"
export DX_RUNTIME DX_REMOTE_HOST DX_CONTAINER_NAME DX_PERSIST_VOLUME DX_PERSIST_HOST_ROOT
export DX_PERSIST_STORAGE DX_PERSIST_HOST_MOUNT_SENTINEL DX_IMAGE DXE_RUNTIME_DOCKER_BIN XDG_STATE_HOME
unset DX_PERSIST_FRESH_START
DIR=/share-u/dxe/dx-u/persist
REC="$STATE/dxe/persist-dirs/nas-u.invalid__dx-u"
TEXT="$(dx_persist_marker_format dx-u ready "" 2026-10-11T08:00:00Z)"

# Every runtime tool refuses and records (in CALLS for the case at hand and in
# TOOL_LOG for the whole file): nothing here may reach a host.
BIN="$(fake_tool_dir_create "$SCRATCH")"
CALLS="$SCRATCH/calls"
TOOL_LOG="$SCRATCH/tool-log"
: >"$TOOL_LOG"
refusing_tools() {
    local t
    for t in ssh docker container; do
        fake_tool_write "$BIN" "$t" "echo \"$t \$*\" | tee -a '$TOOL_LOG' >> '$CALLS'; exit 99"
    done
}
refusing_tools
PATH="$BIN:$PATH"
export PATH

check() { # LABEL CONDITION...
    local label="$1"
    shift
    if "$@"; then test_pass "$label"; else test_fail "$label"; fi
}
same() { # LABEL WANT GOT
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (want [$2] got [$3])"; fi
}
has() { grep -Fq -- "$2" <<<"$1"; }
count_of() { grep -c -- "$2" <<<"$1" || true; }

# run_fn FN [ARG...]: FN in a subshell (so overrides stay there); sets RC OUT
# ERR and CALLED (the runtime tools reached).
run_fn() {
    : >"$CALLS"
    OUT="$("$@" 2>"$SCRATCH/err")"
    RC=$?
    ERR="$(cat "$SCRATCH/err")"
    CALLED="$(cat "$CALLS")"
}
reset_state() {
    persist_fixture_cleanup "$STATE"
    mkdir -p "$STATE"
}
record_entries() { (cd "$STATE/dxe/persist-dirs" 2>/dev/null && ls -A); }
empty_dir() { [ -d "$1" ] && [ -z "$(ls -A "$1")" ]; }

# --- dx_runtime_volume_state -------------------------------------------------
fake_tool_write "$BIN" container "echo \"container \$*\" >> '$CALLS'; echo 'volume missing' >&2; exit 1"
DX_RUNTIME=apple run_fn dx_runtime_volume_state dx-u-persist
same "volume_state (apple): a failed inspect is absent, status 0" "0|absent" "$RC|$OUT"
same "volume_state (apple): exactly one call, volume inspect NAME" "container volume inspect dx-u-persist" "$CALLED"
refusing_tools

vs_cli() { # the docker transport answers with P_ERRTEXT on stderr and status 1
    dx_runtime_docker_cli() { echo "cli $*" >>"$CALLS"; printf '%b' "$P_ERRTEXT" >&2; return 1; }
    dx_runtime_volume_state dx-u-persist
}
P_ERRTEXT='Error: permission denied\nsecond line\n' run_fn vs_cli
same "volume_state (docker): another failure is unknown, non-zero" "1|unknown" "$RC|$OUT"
same "volume_state (docker): one call through the transport" "cli volume inspect dx-u-persist" "$CALLED"
same "volume_state (docker): the message is passed on as dx: lines, never an Error line" \
    "$(printf 'dx: volume inspect: Error: permission denied\ndx: volume inspect: second line')" "$ERR"
P_ERRTEXT='' run_fn vs_cli
same "volume_state (docker): a silent failure is unknown, with nothing on stderr" "1|unknown|" "$RC|$OUT|$ERR"
P_ERRTEXT='ERROR: NO SUCH VOLUME: dx-u-persist\n' run_fn vs_cli
same "volume_state (docker): 'no such volume' in any letter case is absent, silent" "0|absent|" "$RC|$OUT|$ERR"

# --- the adapter's last pre-call refusal --------------------------------------
DX_IMAGE='' run_fn dx_runtime_host_dir_establish create /share-u dx-u 30033:30001 "$TEXT"
same "establish (adapter) without DX_IMAGE: non-zero, no stdout, no call" "1||" "$RC|$OUT|$CALLED"
check "establish (adapter) without DX_IMAGE: one dx: reason naming DX_IMAGE" has "$ERR" "dx: refusing to establish the NAS directory: no DX_IMAGE"
run_fn dx_runtime_host_dir_establish destroy "" -x dx:dx "$TEXT"
same "establish (adapter), several bad inputs: one reason line, the first one" \
    "1|dx: refusing to establish the NAS directory: unknown mode 'destroy' (expected create, adopt or fresh-start)|" "$RC|$ERR|$CALLED"

# --- dx_persist_dir_establish, the adapter replaced by a recorder -------------
EST_ARGS="$SCRATCH/est-args"
est() { # dx_persist_dir_establish MODE with a recording adapter (status P_EST_RC)
    dx_runtime_host_dir_establish() { printf '%s\n' "$@" >"$EST_ARGS"; return "${P_EST_RC:-0}"; }
    dx_persist_dir_establish "$@"
}
reset_state
rm -f "$EST_ARGS"
run_fn est create
same "establish: success is status 0, no Error line" "0|0" "$RC|$(count_of "$ERR" '^Error:')"
check "establish: says where the record went" has "$OUT" "Recorded host-path use of $DIR in $REC."
T="$(sed -n 's/^created-at=//p' "$REC" 2>/dev/null)"
check "establish: one UTC timestamp, valid" dx_persist_marker_valid_timestamp "$T"
same "establish: the adapter gets mode, root, guest, the owner and the ready marker (created-at T)" \
    "$(printf 'create\n/share-u\ndx-u\n30033:30001\nschema=1\nguest=dx-u\nstate=ready\ncreated-at=%s' "$T")" \
    "$(cat "$EST_ARGS" 2>/dev/null)"
same "establish: the record (created-at T)" \
    "$(printf 'schema=1\nguest=dx-u\nroot=/share-u\nmode=create\ncreated-at=%s' "$T")" "$(cat "$REC")"
same "establish: the record is 0600, alone in its directory" "600|$(basename "$REC")" "$(file_mode "$REC")|$(record_entries)"

reset_state
rm -f "$EST_ARGS"
DX_CONTAINER_NAME=_bad run_fn est create
same "establish: a guest name the directory cannot carry is refused, status 1" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
check "establish: that refusal names DX_CONTAINER_NAME" has "$ERR" "DX_CONTAINER_NAME=_bad cannot name a /persist host directory"
check "establish: no adapter call for a bad guest name" [ ! -e "$EST_ARGS" ]

DATE_BIN="$SCRATCH/date-bin"
mkdir -p "$DATE_BIN"
fake_tool_write "$DATE_BIN" date 'echo not-a-time'
PATH="$DATE_BIN:$PATH" run_fn est create
same "establish: an unusable clock is refused before the NAS, status 1, one Error" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
check "establish: the clock refusal names the time it got" has "$ERR" "no usable UTC time ('not-a-time')"
check "establish: no adapter call without a timestamp" [ ! -e "$EST_ARGS" ]
same "establish: no record without a timestamp" "" "$(record_entries)"

P_EST_RC=4 run_fn est adopt
same "establish: a failing adapter is status 1, one Error" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
check "establish: that Error names the directory and the mode" has "$ERR" "could not set up $DIR on the NAS (adopt"
same "establish: no record after a failing adapter" "" "$(record_entries)"

reset_state
mkdir -p "$REC"
run_fn est fresh-start
same "establish: a directory at the record path fails the record, status 1, one Error" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
check "establish: that Error names the record path" has "$ERR" "its host-path record $REC could not be written"
check "establish: the directory at the record path is left as it was (empty)" empty_dir "$REC"

reset_state
mkdir -p "${REC%/*}"
printf 'old\n' >"$REC"
MV_BIN="$SCRATCH/mv-bin"
mkdir -p "$MV_BIN"
fake_tool_write "$MV_BIN" mv 'exit 1'
PATH="$MV_BIN:$PATH" run_fn est create
same "establish: a failing mv fails the record, status 1, one Error" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
same "establish: after a failing mv the old record is kept and no temp file is left" \
    "old|$(basename "$REC")" "$(cat "$REC")|$(record_entries)"

# The real adapter refuses (a ',' in the root): still exactly one Error line.
reset_state
DX_PERSIST_HOST_ROOT=/share,u run_fn dx_persist_dir_establish create
same "establish over a refusing adapter: status 1, exactly one Error line, no call" \
    "1|1|" "$RC|$(count_of "$ERR" '^Error:')|$CALLED"
check "establish over a refusing adapter: the adapter's reason is a dx: line" has "$ERR" "dx: refusing to establish the NAS directory: the share root '/share,u' cannot be bound"
same "establish over a refusing adapter: no record" "" "$(record_entries)"

# --- dx_persist_dir_record_write --------------------------------------------
reset_state
deep="$STATE/a/b/rec"
run_fn dx_persist_dir_record_write "$deep" backfill 2026-10-11T08:00:00Z
same "record write: missing parents are made, silent, status 0" "0||" "$RC|$OUT|$ERR"
same "record write: exactly the five lines, mode 0600" \
    "$(printf 'schema=1\nguest=dx-u\nroot=/share-u\nmode=backfill\ncreated-at=2026-10-11T08:00:00Z')|600" \
    "$(cat "$deep")|$(file_mode "$deep")"
chmod 0644 "$deep"
run_fn dx_persist_dir_record_write "$deep" create 2026-10-12T09:00:00Z
same "record write: an existing record is replaced, back to 0600" "0|mode=create|600" \
    "$RC|$(sed -n 4p "$deep")|$(file_mode "$deep")"
printf 'not a directory\n' >"$STATE/file"
run_fn dx_persist_dir_record_write "$STATE/file/rec" create 2026-10-11T08:00:00Z
same "record write: unmakeable parents are status 1, silent" "1||" "$RC|$OUT|$ERR"

# --- dx_persist_dir_record_backfill -----------------------------------------
report_with() { # MARKER-TEXT: a probe report for a ready directory
    printf 'root=/share-u\nmounted=unknown\nstate=nonempty\nmarker=present\n%s' "$1"
}
reset_state
run_fn dx_persist_dir_record_backfill "$(report_with "$(printf 'schema=1\nguest=dx-u\nstate=ready\ncreated-at=2026-09-01T01:02:03Z')")"
same "backfill: the marker's created-at, mode=backfill" \
    "0|$(printf 'schema=1\nguest=dx-u\nroot=/share-u\nmode=backfill\ncreated-at=2026-09-01T01:02:03Z')" "$RC|$(cat "$REC")"
check "backfill: says the record was missing" has "$OUT" "Recorded host-path use of $DIR in $REC (it was missing)."
reset_state
run_fn dx_persist_dir_record_backfill ""
T="$(sed -n 's/^created-at=//p' "$REC" 2>/dev/null)"
check "backfill without a report: the controller's UTC time" dx_persist_marker_valid_timestamp "$T"
printf 'kept\n' >"$REC"
run_fn dx_persist_dir_record_backfill "$(report_with "$(printf 'schema=1\nguest=dx-u\nstate=ready')")"
same "backfill: an existing record is left alone, silently" "0|||kept" "$RC|$OUT|$ERR|$(cat "$REC")"
reset_state
DX_REMOTE_HOST='' run_fn dx_persist_dir_record_backfill ""
same "backfill: no record path (fail-closed as present): nothing, silently" "0|||" "$RC|$OUT|$ERR|$(record_entries)"
printf 'not a directory\n' >"$STATE/dxe"
run_fn dx_persist_dir_record_backfill ""
same "backfill: an unwritable record is status 0 with one Warning, no Error" "0|1|0" \
    "$RC|$(count_of "$ERR" '^Warning:')|$(count_of "$ERR" '^Error:')"
check "backfill: the Warning names the record path" has "$ERR" "the host-path record $REC could not be written"

# --- dx_persist_legacy_volume_check (dx-create-volumes) -----------------------
legacy() { # LEGACY: the check, with exactly the volumes in P_VOLS present
    dx_runtime_volume_exists() {
        echo "exists $1" >>"$CALLS"
        case " $P_VOLS " in *" $1 "*) return 0 ;; esac
        return 1
    }
    dx_persist_legacy_volume_check "$@"
}
P_VOLS=dx-workspace DX_PERSIST_STORAGE=volume run_fn legacy dx-workspace
same "legacy, volume mode: refused with today's three lines" "1|$(printf '%s\n%s\n%s' \
    'Error: legacy persistence volume dx-workspace exists, but dx-u-persist does not.' \
    'Run bin/dx-migrate-persist before creating the new /persist volume.' \
    'Set DX_LEGACY_WORKSPACE_VOLUME=<old> and DX_PERSIST_VOLUME=<new> for custom volume names.')" "$RC|$ERR"
P_VOLS=dx-workspace run_fn legacy dx-workspace
same "legacy, host-path: refused, one Error line" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
check "legacy, host-path: names both migration steps and the host directory" \
    has "$ERR" "Run bin/dx-migrate-persist to copy it into the persist volume dx-u-persist, then dx-persist-migrate to move that volume into the host directory $DIR."
same "legacy, host-path: never speaks of creating the /persist volume" 0 "$(count_of "$ERR" 'creating the new /persist volume')"
P_VOLS="dx-workspace dx-u-persist" run_fn legacy dx-workspace
same "legacy: already migrated (the persist volume exists) passes silently" "0||exists dx-workspace|exists dx-u-persist" \
    "$RC|$ERR|$(tr '\n' '|' <<<"$CALLED" | sed 's/|$//')"
P_VOLS="" run_fn legacy dx-workspace
same "legacy: no legacy volume passes after one lookup" "0|exists dx-workspace" "$RC|$CALLED"
P_VOLS=dx-u-persist run_fn legacy dx-u-persist
same "legacy: the legacy name is the persist volume's own: no lookup" "0|" "$RC|$CALLED"

# --- dx_persist_host_dir_decide and dx_persist_storage_ensure ----------------
P_REPORT="$(printf 'root=/share-u\nmounted=yes\nstate=absent\nmarker=absent')"
decide() { # the decision with the probe and the volume lookup replaced
    dx_runtime_host_dir_probe() { printf '%s\n' "$P_REPORT"; }
    dx_runtime_volume_state() { echo "state $1" >>"$CALLS"; printf '%s\n' "$P_STATE"; [ "$P_STATE" != unknown ]; }
    dx_persist_dir_record_exists() { echo "record" >>"$CALLS"; return 1; }
    dx_persist_host_dir_decide "$@"
}
P_STATE=unknown run_fn decide
same "decide: an unknown volume state refuses, one Error line, nothing on stdout" "1|1|" \
    "$RC|$(count_of "$ERR" '^Error:')|$OUT"
check "decide: that Error names the volume and the inspect" has "$ERR" "cannot tell whether the persist volume dx-u-persist exists: docker volume inspect"
same "decide: no record lookup after an unknown volume state" "state dx-u-persist" "$CALLED"
P_STATE=absent run_fn decide --report
same "decide --report: the token, then the probe report" "0|$(printf 'create\n%s' "$P_REPORT")" "$RC|$OUT"
P_STATE=present run_fn decide
same "decide: a present volume is not absent (refuse:missing), without --report no report" "1|" "$RC|$OUT"

run_fn dx_persist_storage_ensure "$(printf 'bogus\nroot=/share-u')"
same "ensure: an unknown token is one Error line naming the token only" \
    "1|Error: no host-path /persist decision to act on ('bogus'); run dx-create-volumes again." "$RC|$ERR"

same "no runtime tool was reached outside the Apple fake" "" "$(grep -v '^container volume inspect dx-u-persist$' "$TOOL_LOG")"

print_summary
exit_with_code
