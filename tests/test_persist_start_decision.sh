#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP4.3 acceptance: the start decision and the host checks (plans/do D-2,
# D-7, D-9; spec R15, R17, R18 and the refusal list in spec section 9).
#
# Interface contract (pinned by this file; the implementation must match):
#
# 1. The pure decision, in bin/lib/dx-persist-dir.sh:
#
#      dx_persist_start_decision GUEST VOLUME_EXISTS RECORD_EXISTS OVERRIDE < REPORT
#
#    GUEST          the guest name ($DX_CONTAINER_NAME).
#    VOLUME_EXISTS  `no` when the guest's named persist volume
#                   ($DX_PERSIST_VOLUME) does not exist. Fail-closed: ANY
#                   other value (yes, "", garbage) counts as "exists".
#    RECORD_EXISTS  `no` when there is no D-7 record of host-path use.
#                   Fail-closed the same way.
#    OVERRIDE       the value of DX_PERSIST_FRESH_START ("" when unset). The
#                   function reads this argument only, never the
#                   environment variable itself.
#    REPORT (stdin) what dx_runtime_host_dir_probe ROOT GUEST printed
#                   (WP4.2): exactly the four header lines, in this order,
#                     root=<path>
#                     mounted=yes|no|unknown
#                     state=absent|symlink|empty|nonempty
#                     marker=absent|present
#                   followed, only when marker=present, by the marker
#                   file's bytes (which contain their own `state=` line;
#                   only the 4th header line is the directory state).
#                   Empty stdin (the probe failed: the root is unusable) or
#                   any malformed header (missing, out of order, unknown
#                   value) is `refuse:root`.
#
#    It prints exactly ONE line on stdout, a token, and returns 0 for
#    ok|create|adopt|ok-fresh-start and 1 for every refuse:<reason>. It makes
#    no runtime, remote or file-system call and writes nothing.
#    Evaluated in this order (first match wins):
#      a. empty/malformed report                         -> refuse:root
#      b. state=symlink (the leaf, or the dxe or the
#         dxe/<guest> level -- the probe reports all
#         three as symlink)                              -> refuse:symlink
#      c. marker=present: the marker text is parsed with
#         dx_persist_marker_parse (WP4.1):
#           does not parse                               -> refuse:marker-invalid
#           guest != GUEST (exact string compare)         -> refuse:marker-guest
#           state=copying                                -> refuse:copying
#           state=retired                                -> refuse:retired
#           state=ready                                  -> ok
#         (mounted, VOLUME_EXISTS, RECORD_EXISTS and OVERRIDE do not matter
#         here: a ready marker naming this guest proves the directory.)
#      d. state=nonempty (no marker)                     -> refuse:unmarked
#      e. state=absent:
#           VOLUME_EXISTS or RECORD_EXISTS               -> refuse:missing
#             (never create; OVERRIDE and mounted do not change this)
#           otherwise (a genuinely new guest)            -> GATE(create)
#      f. state=empty (no marker):
#           VOLUME_EXISTS or RECORD_EXISTS:
#             OVERRIDE equals GUEST exactly              -> GATE(ok-fresh-start)
#             otherwise                                  -> refuse:empty
#           otherwise (the leftover of a create that
#           failed after its mkdir, WP4.2)                -> GATE(adopt)
#             (OVERRIDE is ignored here)
#      GATE(x): mounted=yes -> x; mounted=no -> refuse:unmounted;
#               mounted=unknown -> refuse:mount-unknown.
#      i.e. every outcome that writes into the share requires mounted=yes.
#
# 2. The D-7 record (read side only; WP4.4 writes it), bin/lib/dx-persist-dir.sh:
#      dx_persist_dir_record_path    prints
#        ${XDG_STATE_HOME:-$HOME/.local/state}/dxe/persist-dirs/<profile id>
#        with <profile id> = ${DX_REMOTE_HOST}__${DX_CONTAINER_NAME} (the DQ6
#        io.dxe.profile value). An empty XDG_STATE_HOME counts as unset.
#      dx_persist_dir_record_exists  returns 0 when anything exists at that
#        path (a file, a directory, even a dangling symlink: fail-closed), 1
#        otherwise. Prints nothing, creates nothing, makes no remote call.
#
# 3. Wiring, DX_PERSIST_STORAGE=host-path (docker-ssh):
#    * bin/dx-create-volumes, in place of container_ensure_volume for the
#      persist volume, probes with
#        dx_runtime_host_dir_probe "$DX_PERSIST_HOST_ROOT" "$DX_CONTAINER_NAME"
#      (exactly one probe call), learns VOLUME_EXISTS through the runtime
#      (dx_runtime_volume_exists "$DX_PERSIST_VOLUME"), RECORD_EXISTS through
#      dx_persist_dir_record_exists and OVERRIDE from DX_PERSIST_FRESH_START,
#      and calls dx_persist_start_decision. The decision is made BEFORE any
#      volume is created (nix and bootstrap included).
#        ok              nothing more for /persist;
#        create          dx_persist_dir_establish create
#        adopt           dx_persist_dir_establish adopt
#        ok-fresh-start  dx_persist_dir_establish fresh-start
#      dx_persist_dir_establish ACTION (bin/lib/dx-persist-dir.sh) is the
#      seam WP4.4 implements: it creates the directory or writes the `ready`
#      marker, and writes the D-7 record. dx-create-volumes calls it at most
#      once, with exactly that one argument, and writes nothing to the share
#      itself. A non-zero status from it makes dx-create-volumes exit
#      non-zero. The nix and bootstrap volumes are still ensured as before;
#      the persist volume is NEVER created in host-path mode.
#    * bin/dx-start-container runs the same probe and decision after
#      dx_lifecycle_lock_acquire and before dx_runtime_container_start, and
#      starts only on `ok`. Any other token (create, adopt and ok-fresh-start
#      included: only dx-create-volumes creates or marks) stops the start.
#    * Every refusal, in either command: a non-zero exit; stderr has exactly
#      ONE line beginning `Error:` and stdout none; no `docker` call other
#      than a read (`volume inspect`, `version`, `info`); no establish call;
#      no container start and no bootstrap sync; the only NAS-shell call is
#      the probe; the share is byte-for-byte unchanged (no mkdir, no marker,
#      no temp file). The Error line contains (fixed strings):
#        refuse:root            DX_PERSIST_HOST_ROOT
#        refuse:symlink         symlink
#        refuse:marker-invalid  .dxe-persist-dir
#        refuse:marker-guest    the guest the marker names
#        refuse:copying         dx-persist-migrate
#        refuse:retired         retired   and   DX_PERSIST_STORAGE
#        refuse:unmarked        dx-persist-migrate
#        refuse:empty           DX_PERSIST_FRESH_START=<guest>
#        refuse:missing         the directory <root>/dxe/<guest>/persist, plus
#                               dx-persist-migrate when the persist volume
#                               exists, and the record path when the record
#                               exists
#        refuse:unmounted,
#        refuse:mount-unknown   DX_PERSIST_HOST_MOUNT_SENTINEL
#        start on create|adopt|ok-fresh-start: dx-create-volumes
# 4. DX_PERSIST_STORAGE=volume: both commands behave exactly as before this
#    WP (the recorded transcripts below were captured on the tree before
#    it), whatever DX_PERSIST_FRESH_START or the sentinel say: no probe.
#
# Test-only conventions: the share is a fixture root under TMPDIR served by
# the WP0.2 NAS fake (which runs the real probe script against it), docker is
# a recording fake behind it, and the entry points are sourced in a subshell
# with the functions that touch other boundaries (preflight, lock, start,
# bootstrap sync, the WP4.4 establish seam) replaced by recorders.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"
source "$BASE_DIR/bin/lib/dx-persist-dir.sh"

test_section "WP4.3: start decision and host checks"

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
unset DX_PERSIST_FRESH_START DX_PERSIST_HOST_MOUNT_SENTINEL

M_READY=$'schema=1\nguest=dx-fix\nstate=ready\ncreated-at=2026-10-11T08:00:00Z'
M_READY_MIGRATED=$'schema=1\nguest=dx-fix\nstate=ready\nsource-volume=dx-fix-persist\ncreated-at=2026-10-11T08:00:00Z\nmigrated-at=2026-10-11T09:00:00Z'
M_OTHER=$'schema=1\nguest=dx-other\nstate=ready\ncreated-at=2026-10-11T08:00:00Z'
M_LONGER=$'schema=1\nguest=dx-fix2\nstate=ready'
M_SHORTER=$'schema=1\nguest=dx-fi\nstate=ready'
M_COPYING=$'schema=1\nguest=dx-fix\nstate=copying\nsource-volume=dx-fix-persist\ncreated-at=2026-10-11T08:00:00Z'
M_RETIRED=$'schema=1\nguest=dx-fix\nstate=retired\nsource-volume=dx-fix-persist\ncreated-at=2026-10-11T08:00:00Z\nretired-at=2026-10-12T09:30:00Z'
M_SCHEMA2=$'schema=2\nguest=dx-fix\nstate=ready'
M_NOSTATE=$'schema=1\nguest=dx-fix'
M_DUP=$'schema=1\nguest=dx-fix\nstate=ready\nguest=dx-fix'
M_SMUGGLE=$'schema=1\nguest=dx-fix\nstate=ready\nmounted=yes'
M_GARBAGE='this is not a marker'

# rep MOUNTED STATE MARKER [TEXT]: a probe report as WP4.2 prints it.
rep() {
    printf 'root=/fixture/share\nmounted=%s\nstate=%s\nmarker=%s' "$1" "$2" "$3"
    if [ "$3" = present ]; then printf '\n%s' "${4-}"; fi
}

RF="$SCRATCH/report"
# row LABEL WANT VOLUME_EXISTS RECORD_EXISTS OVERRIDE REPORT|<EMPTY>
row() {
    local label="$1" want="$2" out rc want_rc=1
    if [ "$6" = "<EMPTY>" ]; then : >"$RF"; else printf '%s\n' "$6" >"$RF"; fi
    out="$(dx_persist_start_decision "$GUEST" "$3" "$4" "$5" <"$RF" 2>/dev/null)"
    rc=$?
    case "$want" in ok | create | adopt | ok-fresh-start) want_rc=0 ;; esac
    if [ "$out" = "$want" ] && [ "$rc" -eq "$want_rc" ]; then
        test_pass "decision: $label -> $want"
    else
        test_fail "decision: $label -> $want (got [$out] rc=$rc)"
    fi
}

# ---------------------------------------------------------------------------
test_section "WP4.3: the decision table (dx_persist_start_decision)"

# c. A marker that parses, names this guest and is ready: ok, whatever else.
row "ready marker, mounted=yes, new guest" ok no no "" "$(rep yes nonempty present "$M_READY")"
row "ready marker, mounted=no (the marker proves the share)" ok no no "" "$(rep no nonempty present "$M_READY")"
row "ready marker, mounted=unknown" ok no no "" "$(rep unknown nonempty present "$M_READY")"
row "ready marker, volume and record exist" ok yes yes "" "$(rep unknown nonempty present "$M_READY")"
row "ready marker after a migration (source-volume), volume kept" ok yes yes "" "$(rep yes nonempty present "$M_READY_MIGRATED")"
row "ready marker, override set to another guest (irrelevant)" ok yes yes dx-other "$(rep yes nonempty present "$M_READY")"
# c. Marker refusals.
row "marker names another guest" refuse:marker-guest no no "" "$(rep yes nonempty present "$M_OTHER")"
row "marker names another guest, even with the override" refuse:marker-guest yes yes dx-fix "$(rep yes nonempty present "$M_OTHER")"
row "marker guest is a longer name (dx-fix2)" refuse:marker-guest no no "" "$(rep yes nonempty present "$M_LONGER")"
row "marker guest is a prefix (dx-fi)" refuse:marker-guest no no "" "$(rep yes nonempty present "$M_SHORTER")"
row "marker in state copying" refuse:copying yes yes "" "$(rep yes nonempty present "$M_COPYING")"
row "marker in state copying, mounted=unknown, override set" refuse:copying yes yes dx-fix "$(rep unknown nonempty present "$M_COPYING")"
row "marker in state retired" refuse:retired yes yes "" "$(rep yes nonempty present "$M_RETIRED")"
row "malformed marker: garbage" refuse:marker-invalid no no "" "$(rep yes nonempty present "$M_GARBAGE")"
row "malformed marker: unknown schema" refuse:marker-invalid no no "" "$(rep yes nonempty present "$M_SCHEMA2")"
row "malformed marker: no state" refuse:marker-invalid no no "" "$(rep yes nonempty present "$M_NOSTATE")"
row "malformed marker: duplicate key" refuse:marker-invalid no no "" "$(rep yes nonempty present "$M_DUP")"
row "malformed marker: a smuggled mounted= line" refuse:marker-invalid no no "" "$(rep unknown nonempty present "$M_SMUGGLE")"
row "malformed marker: empty marker file" refuse:marker-invalid no no "" "$(rep yes nonempty present "")"
# b. Symlinks.
row "symlinked directory (leaf or level)" refuse:symlink no no "" "$(rep yes symlink absent)"
row "symlinked directory, volume and override set" refuse:symlink yes no dx-fix "$(rep yes symlink absent)"
# d. Unmarked non-empty: import goes through migration.
row "non-empty without a marker, new guest" refuse:unmarked no no "" "$(rep yes nonempty absent)"
row "non-empty without a marker, override set" refuse:unmarked yes no dx-fix "$(rep yes nonempty absent)"
# e. Absent directory.
row "absent, genuinely new guest, mounted=yes" create no no "" "$(rep yes absent absent)"
row "absent, genuinely new guest, mounted=unknown" refuse:mount-unknown no no "" "$(rep unknown absent absent)"
row "absent, genuinely new guest, mounted=no" refuse:unmounted no no "" "$(rep no absent absent)"
row "absent, record exists" refuse:missing no yes "" "$(rep yes absent absent)"
row "absent, record exists, mounted=unknown" refuse:missing no yes "" "$(rep unknown absent absent)"
row "absent, persist volume exists" refuse:missing yes no "" "$(rep yes absent absent)"
row "absent, persist volume and record exist" refuse:missing yes yes "" "$(rep yes absent absent)"
row "absent, persist volume exists, matching override (never create)" refuse:missing yes no dx-fix "$(rep yes absent absent)"
row "absent, record exists, matching override (never create)" refuse:missing no yes dx-fix "$(rep yes absent absent)"
row "absent, VOLUME_EXISTS is not exactly 'no' (fail-closed)" refuse:missing "" no "" "$(rep yes absent absent)"
row "absent, RECORD_EXISTS is not exactly 'no' (fail-closed)" refuse:missing no maybe "" "$(rep yes absent absent)"
# f. Empty, unmarked directory.
row "empty, persist volume exists, no override" refuse:empty yes no "" "$(rep yes empty absent)"
row "empty, persist volume exists, matching override" ok-fresh-start yes no dx-fix "$(rep yes empty absent)"
row "empty, persist volume exists, override for another guest" refuse:empty yes no dx-other "$(rep yes empty absent)"
row "empty, persist volume exists, override is a prefix (dx-fi)" refuse:empty yes no dx-fi "$(rep yes empty absent)"
row "empty, persist volume exists, override is longer (dx-fix2)" refuse:empty yes no dx-fix2 "$(rep yes empty absent)"
row "empty, persist volume exists, override is a glob (dx-*)" refuse:empty yes no 'dx-*' "$(rep yes empty absent)"
row "empty, persist volume exists, override with a trailing space" refuse:empty yes no 'dx-fix ' "$(rep yes empty absent)"
row "empty, persist volume exists, matching override, mounted=unknown" refuse:mount-unknown yes no dx-fix "$(rep unknown empty absent)"
row "empty, persist volume exists, matching override, mounted=no" refuse:unmounted yes no dx-fix "$(rep no empty absent)"
row "empty, record exists, no volume, no override" refuse:empty no yes "" "$(rep yes empty absent)"
row "empty, record exists, no volume, matching override" ok-fresh-start no yes dx-fix "$(rep yes empty absent)"
row "empty, new guest (failed create leftover), mounted=yes" adopt no no "" "$(rep yes empty absent)"
row "empty, new guest, mounted=unknown" refuse:mount-unknown no no "" "$(rep unknown empty absent)"
row "empty, new guest, mounted=no" refuse:unmounted no no "" "$(rep no empty absent)"
row "empty, new guest, override set (ignored)" adopt no no dx-fix "$(rep yes empty absent)"
# a. Unusable or malformed reports.
row "empty report (the probe failed: root unusable)" refuse:root no no "" "<EMPTY>"
row "report without the mounted line" refuse:root no no "" "$(printf 'root=/fixture/share\nstate=absent\nmarker=absent')"
row "report with an unknown mounted value" refuse:root no no "" "$(rep maybe absent absent)"
row "report with an unknown state" refuse:root no no "" "$(rep yes weird absent)"
row "report with an unknown marker value" refuse:root no no "" "$(rep yes nonempty maybe)"
row "report with its header lines out of order" refuse:root no no "" "$(printf 'mounted=yes\nroot=/fixture/share\nstate=absent\nmarker=absent')"
row "a probe error message instead of a report" refuse:root no no "" "dx: not a directory: /fixture/share"

# The decision reads its OVERRIDE argument only, and calls nothing.
PURE_BIN="$(fake_tool_dir_create "$SCRATCH")"
PURE_LOG="$SCRATCH/pure.log"
: >"$PURE_LOG"
for t in ssh docker container mkdir mv rm chmod; do
    fake_tool_write "$PURE_BIN" "$t" "echo $t >> '$PURE_LOG'; exit 99"
done
printf '%s\n' "$(rep yes empty absent)" >"$RF"
pure_out="$(
    DX_PERSIST_FRESH_START=dx-fix PATH="$PURE_BIN:$PATH"
    export DX_PERSIST_FRESH_START PATH
    dx_persist_start_decision "$GUEST" yes no "" <"$RF" 2>/dev/null
)"
if [ "$pure_out" = refuse:empty ]; then
    test_pass "decision: an exported DX_PERSIST_FRESH_START is ignored; only the OVERRIDE argument counts"
else
    test_fail "decision: an exported DX_PERSIST_FRESH_START is ignored (got [$pure_out])"
fi
printf '%s\n' "$(rep yes absent absent)" >"$RF"
(PATH="$PURE_BIN:$PATH" dx_persist_start_decision "$GUEST" no no "" <"$RF" >/dev/null 2>&1)
if [ ! -s "$PURE_LOG" ]; then
    test_pass "decision: makes no runtime, remote or file-system call"
else
    test_fail "decision: makes no runtime, remote or file-system call (called: $(tr '\n' ' ' <"$PURE_LOG"))"
fi

# ---------------------------------------------------------------------------
test_section "WP4.3: the D-7 record (read side)"

REC_HOME="$SCRATCH/rec-home"
REC_XDG="$SCRATCH/rec-xdg"
mkdir -p "$REC_HOME" "$REC_XDG"
record_path_as() { # XDG_STATE_HOME-value|<UNSET>
    (
        HOME="$REC_HOME" DX_REMOTE_HOST="$NAS" DX_CONTAINER_NAME="$GUEST"
        if [ "$1" = "<UNSET>" ]; then unset XDG_STATE_HOME; else XDG_STATE_HOME="$1"; export XDG_STATE_HOME; fi
        export HOME DX_REMOTE_HOST DX_CONTAINER_NAME
        dx_persist_dir_record_path 2>/dev/null
    )
}
got="$(record_path_as "$REC_XDG")"
if [ "$got" = "$REC_XDG/dxe/persist-dirs/${NAS}__$GUEST" ]; then
    test_pass "record: path under XDG_STATE_HOME, named by the DQ6 profile id"
else
    test_fail "record: path under XDG_STATE_HOME (got [$got])"
fi
got="$(record_path_as "<UNSET>")"
if [ "$got" = "$REC_HOME/.local/state/dxe/persist-dirs/${NAS}__$GUEST" ]; then
    test_pass "record: without XDG_STATE_HOME the path is under ~/.local/state"
else
    test_fail "record: without XDG_STATE_HOME the path is under ~/.local/state (got [$got])"
fi
got="$(record_path_as "")"
if [ "$got" = "$REC_HOME/.local/state/dxe/persist-dirs/${NAS}__$GUEST" ]; then
    test_pass "record: an empty XDG_STATE_HOME counts as unset"
else
    test_fail "record: an empty XDG_STATE_HOME counts as unset (got [$got])"
fi

REC_CALLS="$SCRATCH/rec-calls"
REC_BIN="$(fake_tool_dir_create "$SCRATCH")"
for t in ssh docker container; do
    fake_tool_write "$REC_BIN" "$t" "echo $t >> '$REC_CALLS'; exit 99"
done
record_exists_case() { # LABEL WANT_RC(0|1) SETUP(none|file|dir|dangling)
    local xdg="$SCRATCH/rec-case.$3" out rc
    mkdir -p "$xdg"
    case "$3" in
        file) mkdir -p "$xdg/dxe/persist-dirs" && : >"$xdg/dxe/persist-dirs/${NAS}__$GUEST" ;;
        dir) mkdir -p "$xdg/dxe/persist-dirs/${NAS}__$GUEST" ;;
        dangling) mkdir -p "$xdg/dxe/persist-dirs" && ln -s "$xdg/no-such-target" "$xdg/dxe/persist-dirs/${NAS}__$GUEST" ;;
        *) : ;;
    esac
    : >"$REC_CALLS"
    out="$(
        HOME="$REC_HOME" XDG_STATE_HOME="$xdg" DX_REMOTE_HOST="$NAS" DX_CONTAINER_NAME="$GUEST" PATH="$REC_BIN:$PATH"
        export HOME XDG_STATE_HOME DX_REMOTE_HOST DX_CONTAINER_NAME PATH
        dx_persist_dir_record_exists 2>&1
    )"
    rc=$?
    if [ "$rc" -eq "$2" ] && [ -z "$out" ] && [ ! -s "$REC_CALLS" ]; then
        test_pass "record: $1"
    else
        test_fail "record: $1 (rc=$rc want=$2 out=[$out] calls=$(cat "$REC_CALLS" 2>/dev/null))"
    fi
    if [ "$3" = none ]; then
        if [ ! -e "$xdg/dxe" ]; then test_pass "record: checking an absent record creates nothing"
        else test_fail "record: checking an absent record creates nothing"; fi
    fi
}
record_exists_case "no record: not found, silent, no remote call" 1 none
record_exists_case "a record file: found" 0 file
record_exists_case "a directory at the record path: found (fail-closed)" 0 dir
record_exists_case "a dangling symlink at the record path: found (fail-closed)" 0 dangling

# ---------------------------------------------------------------------------
# Wiring fixtures.
#
# world [VOLUME...]: a fresh share root served by the NAS fake, a recording
# ssh in front of it, a recording docker behind it in which exactly the named
# volumes exist (labelled for this profile), a private XDG_STATE_HOME and a
# fresh shared log. Sets ROOT TOOLS LOG STATE VOLS GDIR.
REC="$SCRATCH/rec-ssh"
mkdir -p "$REC"
fake_tool_write "$REC" ssh 'last=""
for a in "$@"; do last="$a"; done
nl="
"
printf "ssh %s\n" "${last//$nl/<NL>}" >> "${P_LOG:?}"
exec "${P_REAL_SSH:?}" "$@"'
DOCKER_FAKE='has() { case " ${P_VOLUMES:-} " in *" $1 "*) return 0 ;; esac; return 1; }
role() { case "$1" in *-nix) echo nix ;; *-persist) echo persist ;; *-bootstrap) echo bootstrap ;; *) echo none ;; esac; }
last=""
for a in "$@"; do last="$a"; done
case "$1 $2" in
    "volume inspect")
        if has "$last"; then
            if [ "$3" = --format ]; then
                printf "true|1|%s__%s|%s|%s\n" "$DX_REMOTE_HOST" "$DX_CONTAINER_NAME" "$(role "$last")" "$DX_GUEST_SYSTEM"
            else
                echo "[{\"Name\":\"$last\"}]"
            fi
            exit 0
        fi
        echo "Error: No such volume: $last" >&2
        exit 1 ;;
    "volume create") echo "$last"; exit 0 ;;
    "version --format") echo 27.3.1; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
esac
echo "fake docker: unexpected call: $*" >&2
exit 99'
STUB_DIR="$SCRATCH/stub"
mkdir -p "$STUB_DIR"
fake_tool_write "$STUB_DIR" dx-sync-bootstrap 'echo sync >> "${P_LOG:?}"
if [ "${1:-}" = --result-file ]; then printf "outcome=unchanged\ngeneration=g1\n" > "$2"; fi
exit 0'

N=0
world() {
    N=$((N + 1))
    ROOT="$(persist_fixture_root_create "$SCRATCH")"
    TOOLS="$(persist_fixture_nas_create "$ROOT" "$SCRATCH")"
    fake_tool_write "$TOOLS" docker "$DOCKER_FAKE"
    LOG="$SCRATCH/log.$N"
    : >"$LOG"
    STATE="$SCRATCH/state.$N"
    mkdir -p "$STATE"
    VOLS="$*"
    GDIR="$ROOT/dxe/$GUEST/persist"
}
put_marker() { # TEXT
    mkdir -p "$GDIR"
    printf '%s\n' "$1" >"$GDIR/.dxe-persist-dir"
}
put_sentinel() { : >"$ROOT/$SENTINEL"; }
put_record() {
    mkdir -p "$STATE/dxe/persist-dirs"
    : >"$STATE/dxe/persist-dirs/${NAS}__$GUEST"
}
record_file() { printf '%s/dxe/persist-dirs/%s__%s' "$STATE" "$NAS" "$GUEST"; }

# snap DIR: every path with its type, symlink target and file checksum.
snap() {
    (
        cd -P -- "$1" || exit 1
        find . | LC_ALL=C sort | while IFS= read -r p; do
            if [ -L "$p" ]; then printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
            elif [ -f "$p" ]; then printf 'F %s %s\n' "$p" "$(cksum <"$p")"
            elif [ -d "$p" ]; then printf 'D %s\n' "$p"
            else printf 'O %s\n' "$p"; fi
        done
    )
}

# Recorders standing in for the boundaries this WP does not own; defined in
# the entry's subshell after it has been sourced.
wiring_overrides() {
    plog() { printf '%s\n' "$*" >>"$P_LOG"; }
    dx_require_container_cli() { plog preflight; }
    dx_persist_dir_establish() { plog "establish $*"; return "${P_ESTABLISH_RC:-0}"; }
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
# clean configuration (host-path mode on the current world unless VAR=VALUE
# says otherwise), install the recorders and call MAIN. Sets RC OUT ERR
# BEFORE AFTER (share snapshots).
run_entry() {
    local entry="$1" main="$2"
    shift 2
    : >"$LOG"
    BEFORE="$(snap "$ROOT")"
    (
        for _n in $DXE_CONFIG_FIELDS; do unset "$_n"; done
        unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PERSIST_FRESH_START \
            DXE_RUNTIME_DOCKER_DAEMON_ID DX_LEGACY_WORKSPACE_VOLUME XDG_STATE_HOME
        HOME="$SCRATCH/home" XDG_STATE_HOME="$STATE" PATH="$REC:$TOOLS:/usr/bin:/bin"
        export HOME XDG_STATE_HOME PATH
        export DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$NAS" DXE_RUNTIME_DOCKER_BIN=docker
        export DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME="$GUEST"
        export DX_NIX_VOLUME=dx-fix-nix DX_PERSIST_VOLUME=dx-fix-persist DX_BOOTSTRAP_VOLUME=dx-fix-bootstrap
        export DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT="$ROOT"
        export P_LOG="$LOG" P_REAL_SSH="$TOOLS/ssh" P_VOLUMES="$VOLS"
        for _kv in "$@"; do export "${_kv?}"; done
        # shellcheck source=/dev/null
        source "$BASE_DIR/bin/$entry"
        wiring_overrides
        SCRIPT_DIR="$STUB_DIR"
        "$main"
    ) >"$SCRATCH/out.$N" 2>"$SCRATCH/err.$N" </dev/null
    RC=$?
    OUT="$(cat "$SCRATCH/out.$N")"
    ERR="$(cat "$SCRATCH/err.$N")"
    AFTER="$(snap "$ROOT")"
}

# The exact remote command dx_runtime_host_dir_probe sends for ROOT (with the
# sentinel in $2, "" for none), as the recording ssh logs it.
CAP="$SCRATCH/cap-bin"
mkdir -p "$CAP"
fake_tool_write "$CAP" ssh 'last=""
for a in "$@"; do last="$a"; done
printf "%s" "$last" > "${CAP_FILE:?}"'
probe_line() {
    : >"$SCRATCH/cap"
    (
        DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$NAS" DX_PERSIST_HOST_MOUNT_SENTINEL="$2" CAP_FILE="$SCRATCH/cap"
        PATH="$CAP:/usr/bin:/bin"
        export DX_RUNTIME DX_REMOTE_HOST DX_PERSIST_HOST_MOUNT_SENTINEL CAP_FILE PATH
        dx_runtime_host_dir_probe "$1" "$GUEST" >/dev/null 2>&1 </dev/null
    )
    printf 'ssh %s' "$(cat "$SCRATCH/cap")"
}

# log_brief: the log on one line, with each NAS-shell script abbreviated.
log_brief() { sed -e 's/^ssh sh -c .* sh /ssh sh -c <script> sh /' "$LOG" | tr '\n' '|'; }
lines_of() { grep -Fxc -- "$2" "$1" 2>/dev/null || true; }
line_no() { grep -Fxn -- "$2" "$1" 2>/dev/null | head -n1 | cut -d: -f1; }

# Pass when every NAS-shell call in the log is exactly the probe line given.
only_probe_on_nas() { # PROBE_LINE
    local l
    while IFS= read -r l; do
        case "$l" in
            "ssh sh -c "*) [ "$l" = "$1" ] || return 1 ;;
            "ssh "*) case "$l" in "ssh docker "*) : ;; *) return 1 ;; esac ;;
            *) : ;;
        esac
    done <"$LOG"
    return 0
}
# Pass when every docker call in the log is a read.
docker_reads_only() {
    local l
    while IFS= read -r l; do
        case "$l" in
            "ssh docker volume inspect "* | "ssh docker version "* | "ssh docker info "*) : ;;
            "ssh docker "*) return 1 ;;
            *) : ;;
        esac
    done <"$LOG"
    return 0
}

# expect_refused LABEL PROBE_LINE KEYWORD...: the refusal invariants.
expect_refused() {
    local label="$1" probe="$2" n_err n_out k err_line
    shift 2
    if [ "$RC" -ne 0 ]; then test_pass "$label: exits non-zero"; else test_fail "$label: exits non-zero (rc=0; out: $OUT)"; fi
    n_err="$(grep -c '^Error:' <<<"$ERR" || true)"
    n_out="$(grep -c '^Error:' <<<"$OUT" || true)"
    if [ "$n_err" = 1 ] && [ "$n_out" = 0 ]; then
        test_pass "$label: exactly one Error: line, on stderr"
    else
        test_fail "$label: exactly one Error: line, on stderr (stderr: $ERR | stdout: $OUT)"
    fi
    err_line="$(grep "^Error:" <<<"$ERR" || true)"
    for k in "$@"; do
        if grep -Fq -- "$k" <<<"$err_line"; then
            test_pass "$label: the Error line names [$k]"
        else
            test_fail "$label: the Error line names [$k] (stderr: $ERR)"
        fi
    done
    if [ "$(lines_of "$LOG" "$probe")" = 1 ] && only_probe_on_nas "$probe"; then
        test_pass "$label: the probe ran once and was the only NAS-shell call"
    else
        test_fail "$label: the probe ran once and was the only NAS-shell call (log: $(log_brief))"
    fi
    if docker_reads_only && ! grep -q '^establish' "$LOG" && ! grep -q '^start ' "$LOG" && ! grep -Fxq sync "$LOG"; then
        test_pass "$label: no create, no establish, no start, no sync"
    else
        test_fail "$label: no create, no establish, no start, no sync (log: $(log_brief))"
    fi
    if [ "$BEFORE" = "$AFTER" ]; then
        test_pass "$label: the share is unchanged (no mkdir, no marker, no temp file)"
    else
        test_fail "$label: the share is unchanged (before: $BEFORE | after: $AFTER)"
    fi
}

# expect_volumes_ensured LABEL: nix and bootstrap created, persist never.
expect_volumes_ensured() {
    if grep -Eq '^ssh docker volume create .* dx-fix-nix$' "$LOG" && grep -Eq '^ssh docker volume create .* dx-fix-bootstrap$' "$LOG"; then
        test_pass "$1: the nix and bootstrap volumes are still ensured"
    else
        test_fail "$1: the nix and bootstrap volumes are still ensured (log: $(log_brief))"
    fi
    if grep -Eq '^ssh docker volume create .*dx-fix-persist' "$LOG"; then
        test_fail "$1: the persist volume is never created in host-path mode"
    else
        test_pass "$1: the persist volume is never created in host-path mode"
    fi
}

# expect_establish LABEL ACTION|none PROBE_LINE
expect_establish() {
    local label="$1" want="$2" got
    got="$(grep '^establish' "$LOG" | tr '\n' '|')"
    if [ "$want" = none ]; then
        if [ -z "$got" ]; then test_pass "$label: no establish call"; else test_fail "$label: no establish call (got $got)"; fi
    else
        if [ "$got" = "establish $want|" ]; then test_pass "$label: dx_persist_dir_establish $want, exactly once"
        else test_fail "$label: dx_persist_dir_establish $want, exactly once (got [$got]; log: $(log_brief))"; fi
    fi
    if [ "$(lines_of "$LOG" "$3")" = 1 ] && only_probe_on_nas "$3"; then
        test_pass "$label: one probe, and dx-create-volumes itself sends nothing else to the NAS shell"
    else
        test_fail "$label: one probe, and nothing else to the NAS shell (log: $(log_brief))"
    fi
    if [ "$BEFORE" = "$AFTER" ]; then
        test_pass "$label: dx-create-volumes itself wrote nothing to the share"
    else
        test_fail "$label: dx-create-volumes itself wrote nothing to the share (before: $BEFORE | after: $AFTER)"
    fi
}

expect_success() {
    local n_err
    n_err="$(grep -c '^Error:' <<<"$ERR$OUT" || true)"
    if [ "$RC" -eq 0 ] && [ "$n_err" = 0 ]; then test_pass "$1: exits 0 with no Error line"
    else test_fail "$1: exits 0 with no Error line (rc=$RC stderr: $ERR)"; fi
}

# ---------------------------------------------------------------------------
test_section "WP4.3: dx-create-volumes in host-path mode"

cv() { run_entry dx-create-volumes create_volumes_main "$@"; }

world
put_marker "$M_READY"
P_UNKNOWN="$(probe_line "$ROOT" "")"
cv
expect_success "create-volumes, ready marker (mounted=unknown)"
expect_volumes_ensured "create-volumes, ready marker"
expect_establish "create-volumes, ready marker" none "$P_UNKNOWN"
if grep -Fxq 'ssh docker volume inspect dx-fix-persist' "$LOG"; then
    test_pass "create-volumes: asks the runtime whether the persist volume exists"
else
    test_fail "create-volumes: asks the runtime whether the persist volume exists (log: $(log_brief))"
fi

world dx-fix-persist
put_marker "$M_READY_MIGRATED"
cv
expect_success "create-volumes, migrated guest (ready marker, old volume kept)"
expect_volumes_ensured "create-volumes, migrated guest"
expect_establish "create-volumes, migrated guest" none "$(probe_line "$ROOT" "")"

world
put_sentinel
P_YES="$(probe_line "$ROOT" "$SENTINEL")"
cv DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
expect_success "create-volumes, genuinely new guest, share mounted"
expect_volumes_ensured "create-volumes, genuinely new guest"
expect_establish "create-volumes, genuinely new guest" create "$P_YES"

world
put_sentinel
cv DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL" P_ESTABLISH_RC=3
if [ "$RC" -ne 0 ] && grep -Fxq 'establish create' "$LOG"; then
    test_pass "create-volumes: a failing dx_persist_dir_establish fails the command"
else
    test_fail "create-volumes: a failing dx_persist_dir_establish fails the command (rc=$RC)"
fi

world
put_sentinel
mkdir -p "$GDIR"
cv DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
expect_success "create-volumes, empty unmarked leftover, new guest"
expect_volumes_ensured "create-volumes, adopt"
expect_establish "create-volumes, adopt" adopt "$(probe_line "$ROOT" "$SENTINEL")"

world dx-fix-persist
put_sentinel
mkdir -p "$GDIR"
cv DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL" DX_PERSIST_FRESH_START="$GUEST"
expect_success "create-volumes, empty directory, volume kept, matching override"
expect_volumes_ensured "create-volumes, fresh start"
expect_establish "create-volumes, fresh start" fresh-start "$(probe_line "$ROOT" "$SENTINEL")"

# Refusals.
world
cv
expect_refused "create-volumes, new guest, mount state unknown (no sentinel)" "$(probe_line "$ROOT" "")" DX_PERSIST_HOST_MOUNT_SENTINEL

world
cv DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
expect_refused "create-volumes, new guest, share not mounted (sentinel missing)" "$(probe_line "$ROOT" "$SENTINEL")" DX_PERSIST_HOST_MOUNT_SENTINEL

world
put_sentinel
put_record
cv DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
expect_refused "create-volumes, directory missing, record exists" "$(probe_line "$ROOT" "$SENTINEL")" "$GDIR" "$(record_file)"

world dx-fix-persist
put_sentinel
cv DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL" DX_PERSIST_FRESH_START="$GUEST"
expect_refused "create-volumes, directory missing, persist volume exists (override does not create)" "$(probe_line "$ROOT" "$SENTINEL")" "$GDIR" dx-persist-migrate

world dx-fix-persist
put_sentinel
mkdir -p "$GDIR"
cv DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
expect_refused "create-volumes, empty directory, persist volume exists" "$(probe_line "$ROOT" "$SENTINEL")" "DX_PERSIST_FRESH_START=$GUEST"

world dx-fix-persist
put_sentinel
mkdir -p "$GDIR"
cv DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL" DX_PERSIST_FRESH_START=dx-other
expect_refused "create-volumes, empty directory, override names another guest" "$(probe_line "$ROOT" "$SENTINEL")" "DX_PERSIST_FRESH_START=$GUEST"

world
mkdir -p "$GDIR"
cv
expect_refused "create-volumes, empty leftover, mount state unknown" "$(probe_line "$ROOT" "")" DX_PERSIST_HOST_MOUNT_SENTINEL

world
put_sentinel
mkdir -p "$GDIR"
printf 'data\n' >"$GDIR/notes.txt"
cv DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
expect_refused "create-volumes, non-empty directory without a marker" "$(probe_line "$ROOT" "$SENTINEL")" dx-persist-migrate

world
put_marker "$M_OTHER"
cv
expect_refused "create-volumes, marker for another guest" "$(probe_line "$ROOT" "")" dx-other

world dx-fix-persist
put_marker "$M_COPYING"
cv
expect_refused "create-volumes, marker in state copying" "$(probe_line "$ROOT" "")" dx-persist-migrate

world dx-fix-persist
put_marker "$M_RETIRED"
cv
expect_refused "create-volumes, marker in state retired" "$(probe_line "$ROOT" "")" retired DX_PERSIST_STORAGE

world
put_marker "$M_GARBAGE"
cv
expect_refused "create-volumes, malformed marker" "$(probe_line "$ROOT" "")" .dxe-persist-dir

world
mkdir -p "$ROOT/elsewhere" "$ROOT/dxe/$GUEST"
printf '%s\n' "$M_READY" >"$ROOT/elsewhere/.dxe-persist-dir"
ln -s ../../elsewhere "$GDIR"
cv
expect_refused "create-volumes, symlinked leaf (to a directory with a ready marker)" "$(probe_line "$ROOT" "")" symlink

world
mkdir -p "$ROOT/elsewhere/persist" "$ROOT/dxe"
printf '%s\n' "$M_READY" >"$ROOT/elsewhere/persist/.dxe-persist-dir"
ln -s ../elsewhere "$ROOT/dxe/$GUEST"
cv
expect_refused "create-volumes, symlinked dxe/<guest> level" "$(probe_line "$ROOT" "")" symlink

world
cv DX_PERSIST_HOST_ROOT="$ROOT/no-such-share"
expect_refused "create-volumes, unusable share root" "$(probe_line "$ROOT/no-such-share" "")" DX_PERSIST_HOST_ROOT

# ---------------------------------------------------------------------------
test_section "WP4.3: dx-start-container in host-path mode"

sc() { run_entry dx-start-container start_container_main "$@"; }

world
put_marker "$M_READY"
P_UNKNOWN="$(probe_line "$ROOT" "")"
sc
expect_success "start, ready marker"
lock_at="$(line_no "$LOG" lock)"
probe_at="$(line_no "$LOG" "$P_UNKNOWN")"
start_at="$(line_no "$LOG" "start $GUEST")"
if [ -n "$lock_at" ] && [ -n "$probe_at" ] && [ -n "$start_at" ] \
    && [ "$lock_at" -lt "$probe_at" ] && [ "$probe_at" -lt "$start_at" ]; then
    test_pass "start, ready marker: the probe runs inside the lock, before the container start"
else
    test_fail "start, ready marker: lock < probe < start (log: $(log_brief))"
fi
if grep -Fxq sync "$LOG" && [ "$BEFORE" = "$AFTER" ] && docker_reads_only && ! grep -q '^establish' "$LOG"; then
    test_pass "start, ready marker: carries on to the bootstrap sync, writes nothing"
else
    test_fail "start, ready marker: carries on to the bootstrap sync, writes nothing (log: $(log_brief))"
fi
if [ "$(lines_of "$LOG" "$P_UNKNOWN")" = 1 ] && only_probe_on_nas "$P_UNKNOWN"; then
    test_pass "start, ready marker: exactly one probe, nothing else on the NAS shell"
else
    test_fail "start, ready marker: exactly one probe (log: $(log_brief))"
fi

world dx-fix-persist
put_marker "$M_READY_MIGRATED"
put_record
sc DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
expect_success "start, migrated guest, share sentinel missing (the marker proves the share)"
if grep -Fxq "start $GUEST" "$LOG"; then test_pass "start, migrated guest: the container is started"
else test_fail "start, migrated guest: the container is started (log: $(log_brief))"; fi

start_refused() { # LABEL PROBE_LINE KEYWORD...
    expect_refused "$@"
    if grep -Fxq unlock "$LOG"; then test_pass "$1: the lifecycle lock is released"
    else test_fail "$1: the lifecycle lock is released (log: $(log_brief))"; fi
}

world dx-fix-persist
put_marker "$M_COPYING"
sc
start_refused "start, marker in state copying" "$(probe_line "$ROOT" "")" dx-persist-migrate

world dx-fix-persist
put_marker "$M_RETIRED"
sc
start_refused "start, marker in state retired" "$(probe_line "$ROOT" "")" retired DX_PERSIST_STORAGE

world
put_marker "$M_OTHER"
sc
start_refused "start, marker for another guest" "$(probe_line "$ROOT" "")" dx-other

world
put_marker "$M_DUP"
sc
start_refused "start, malformed marker" "$(probe_line "$ROOT" "")" .dxe-persist-dir

world
mkdir -p "$ROOT/elsewhere" "$ROOT/dxe/$GUEST"
printf '%s\n' "$M_READY" >"$ROOT/elsewhere/.dxe-persist-dir"
ln -s ../../elsewhere "$GDIR"
sc
start_refused "start, symlinked leaf" "$(probe_line "$ROOT" "")" symlink

world
mkdir -p "$GDIR"
printf 'data\n' >"$GDIR/notes.txt"
sc
start_refused "start, non-empty directory without a marker" "$(probe_line "$ROOT" "")" dx-persist-migrate

world dx-fix-persist
put_sentinel
mkdir -p "$GDIR"
sc DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
start_refused "start, empty directory, persist volume exists" "$(probe_line "$ROOT" "$SENTINEL")" "DX_PERSIST_FRESH_START=$GUEST"

world dx-fix-persist
put_sentinel
mkdir -p "$GDIR"
sc DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL" DX_PERSIST_FRESH_START="$GUEST"
start_refused "start, empty directory with the override (only dx-create-volumes marks it)" "$(probe_line "$ROOT" "$SENTINEL")" dx-create-volumes

world
put_sentinel
put_record
sc DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
start_refused "start, directory missing, record exists" "$(probe_line "$ROOT" "$SENTINEL")" "$GDIR" "$(record_file)"

world
put_sentinel
sc DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
start_refused "start, directory absent for a new guest (start never creates)" "$(probe_line "$ROOT" "$SENTINEL")" dx-create-volumes

world
put_sentinel
mkdir -p "$GDIR"
sc DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
start_refused "start, empty unmarked leftover (start never adopts)" "$(probe_line "$ROOT" "$SENTINEL")" dx-create-volumes

world
mkdir -p "$GDIR"
sc
start_refused "start, empty leftover, mount state unknown" "$(probe_line "$ROOT" "")" DX_PERSIST_HOST_MOUNT_SENTINEL

world
sc DX_PERSIST_HOST_ROOT="$ROOT/no-such-share"
start_refused "start, unusable share root" "$(probe_line "$ROOT/no-such-share" "")" DX_PERSIST_HOST_ROOT

# ---------------------------------------------------------------------------
test_section "WP4.3: volume mode is unchanged"

LABELS='--label io.dxe.managed=true --label io.dxe.schema=1 --label io.dxe.profile=dxe-fixture-nas.invalid__dx-fix'
CV_VOLUME_LOG="preflight
ssh docker volume inspect dx-fix-nix
ssh docker volume create $LABELS --label io.dxe.role=nix --label io.dxe.system=x86_64-linux dx-fix-nix
ssh docker volume inspect dx-workspace
ssh docker volume inspect dx-fix-persist
ssh docker volume create $LABELS --label io.dxe.role=persist --label io.dxe.system=x86_64-linux dx-fix-persist
ssh docker volume inspect dx-fix-bootstrap
ssh docker volume create $LABELS --label io.dxe.role=bootstrap --label io.dxe.system=x86_64-linux dx-fix-bootstrap"
SC_VOLUME_LOG="preflight
lock
start dx-fix
sync
unlock"

world
put_sentinel
cv DX_PERSIST_STORAGE=volume
if [ "$RC" -eq 0 ] && [ "$(cat "$LOG")" = "$CV_VOLUME_LOG" ] && [ "$BEFORE" = "$AFTER" ]; then
    test_pass "volume mode: dx-create-volumes transcript is unchanged (no probe)"
else
    test_fail "volume mode: dx-create-volumes transcript is unchanged (rc=$RC log: $(log_brief))"
fi
world
cv DX_PERSIST_STORAGE=volume DX_PERSIST_FRESH_START="$GUEST" DX_PERSIST_HOST_MOUNT_SENTINEL="$SENTINEL"
if [ "$RC" -eq 0 ] && [ "$(cat "$LOG")" = "$CV_VOLUME_LOG" ]; then
    test_pass "volume mode: DX_PERSIST_FRESH_START and the sentinel change nothing in dx-create-volumes"
else
    test_fail "volume mode: DX_PERSIST_FRESH_START and the sentinel change nothing (rc=$RC log: $(log_brief))"
fi
world dx-fix-persist
cv DX_PERSIST_STORAGE=volume
if [ "$RC" -eq 0 ] && ! grep -q '^ssh sh ' "$LOG" && ! grep -Eq '^ssh docker volume create .*dx-fix-persist' "$LOG"; then
    test_pass "volume mode: an existing persist volume is adopted as before, no probe"
else
    test_fail "volume mode: an existing persist volume is adopted as before (rc=$RC log: $(log_brief))"
fi
world
cv DX_PERSIST_STORAGE=volume DX_PERSIST_HOST_ROOT=
if [ "$RC" -eq 0 ] && [ "$(cat "$LOG")" = "$CV_VOLUME_LOG" ]; then
    test_pass "volume mode: no share root configured, transcript unchanged"
else
    test_fail "volume mode: no share root configured, transcript unchanged (rc=$RC log: $(log_brief))"
fi

world
sc DX_PERSIST_STORAGE=volume
if [ "$RC" -eq 0 ] && [ "$(cat "$LOG")" = "$SC_VOLUME_LOG" ] && [ "$BEFORE" = "$AFTER" ]; then
    test_pass "volume mode: dx-start-container transcript is unchanged (no probe, starts)"
else
    test_fail "volume mode: dx-start-container transcript is unchanged (rc=$RC log: $(log_brief))"
fi
world
mkdir -p "$GDIR"
sc DX_PERSIST_STORAGE=volume DX_PERSIST_FRESH_START=dx-other
if [ "$RC" -eq 0 ] && [ "$(cat "$LOG")" = "$SC_VOLUME_LOG" ]; then
    test_pass "volume mode: dx-start-container ignores the share and the override"
else
    test_fail "volume mode: dx-start-container ignores the share and the override (rc=$RC log: $(log_brief))"
fi

print_summary
exit_with_code
