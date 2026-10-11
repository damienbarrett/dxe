#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP6.4 (implementer unit cases) for what the acceptance suite
# (tests/test_persist_migrate.sh) does not reach:
#   - the in-container scripts the migration runs from $DX_IMAGE, executed
#     here with PATH holding ONLY the tools the bare nixos/nix base has (sh,
#     bash, coreutils, findutils): on docker-ssh $DX_IMAGE has no sed and no
#     awk (2026-10-12 live finding), so a script that needs one must fail here;
#   - Apple's container_state answers and Docker's edge answers;
#   - the manifest verify's last pre-call refusals;
#   - dx_persist_migrate_decide's malformed reports;
#   - dx_persist_migrate_run's clock failures, with every runtime operation
#     replaced by an in-process recorder.

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

test_section "WP6.4: migration helpers (in-process)"

SCRATCH="$(persist_fixture_root_create)"
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac

DX_RUNTIME=docker-ssh DX_REMOTE_HOST=nas-m.invalid DX_CONTAINER_NAME=dx-m DX_GUEST_SYSTEM=x86_64-linux
DX_PERSIST_VOLUME=dx-m-persist DX_NIX_VOLUME=dx-m-nix DX_PERSIST_HOST_ROOT=/share-m
DX_PERSIST_HOST_MOUNT_SENTINEL=flag DX_IMAGE=img-m DXE_RUNTIME_DOCKER_BIN=docker
XDG_STATE_HOME="$SCRATCH/dxe-state"
export DX_RUNTIME DX_REMOTE_HOST DX_CONTAINER_NAME DX_GUEST_SYSTEM DX_PERSIST_VOLUME DX_NIX_VOLUME
export DX_PERSIST_HOST_ROOT DX_PERSIST_HOST_MOUNT_SENTINEL DX_IMAGE DXE_RUNTIME_DOCKER_BIN XDG_STATE_HOME

# Every runtime tool refuses and records: nothing here may reach a host.
BIN="$(fake_tool_dir_create "$SCRATCH")"
CALLS="$SCRATCH/calls"
refusing_tools() {
    local t
    for t in ssh docker container; do
        fake_tool_write "$BIN" "$t" "echo \"$t \$*\" >> '$CALLS'; exit 99"
    done
}
refusing_tools
PATH="$BIN:$PATH"
export PATH

same() { # LABEL WANT GOT
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (want [$2] got [$3])"; fi
}
check() { # LABEL CONDITION...
    local label="$1"
    shift
    if "$@"; then test_pass "$label"; else test_fail "$label"; fi
}
has() { grep -Fq -- "$2" <<<"$1"; }
count_of() { grep -c -- "$2" <<<"$1" || true; }

# run_fn FN [ARG...]: FN in a subshell; sets RC OUT ERR CALLED.
run_fn() {
    : >"$CALLS"
    OUT="$("$@" 2>"$SCRATCH/err")"
    RC=$?
    ERR="$(cat "$SCRATCH/err")"
    CALLED="$(cat "$CALLS")"
}

# =============================================================================
# The in-container scripts, with only the bare image's tools on PATH.

# restricted DIR TOOL...: DIR holds a symlink to each TOOL (found on the
# normal PATH) and nothing else.
restricted() {
    local dir="$1" t p
    shift
    mkdir -p "$dir"
    for t in "$@"; do
        p="$(command -v "$t")" || { echo "restricted: no $t on this host" >&2; return 1; }
        ln -s "$p" "$dir/$t"
    done
}
ENV_BIN="$(command -v env)"
in_bare() { # DIR CMD ARG...: CMD with an empty environment and PATH=DIR
    local dir="$1"
    shift
    "$ENV_BIN" -i PATH="$dir" HOME="$SCRATCH" TMPDIR="$SCRATCH" "$@"
}
mode_of() { file_mode "$1" 2>/dev/null; }

# The marker-set script (J2): the shell and the marker step's coreutils only.
MS_TOOLS="$SCRATCH/bare-marker-set"
restricted "$MS_TOOLS" sh mktemp cat chmod mv rm
in_bare "$MS_TOOLS" "$MS_TOOLS/sh" -c 'sed -n p </dev/null' >/dev/null 2>&1
check "bare PATH: sed is not reachable (the restriction is real)" [ "$?" -ne 0 ]
in_bare "$MS_TOOLS" "$MS_TOOLS/sh" -c 'awk 1 </dev/null' >/dev/null 2>&1
check "bare PATH: awk is not reachable" [ "$?" -ne 0 ]

MS_ROOT="$SCRATCH/dxe-ms-share"
LEAF="$MS_ROOT/dxe/dx-m/persist"
mkdir -p "$LEAF"
dx_persist_marker_format dx-m copying dx-m-persist 2026-10-01T10:00:00Z >"$LEAF/.dxe-persist-dir"
printf 'data\n' >"$LEAF/plain.txt"
READY="$(dx_persist_marker_format dx-m ready dx-m-persist 2026-10-01T10:00:00Z 2026-10-01T11:00:00Z)"
printf '%s\n' "$READY" | in_bare "$MS_TOOLS" "$MS_TOOLS/sh" -c "$DX_RUNTIME_DOCKER_HOST_DIR_MARKER_SET_SCRIPT" sh \
    "$MS_ROOT" dx-m copying dx-m-persist 2>"$SCRATCH/ms.err"
same "marker-set script, bare tools: copying -> ready succeeds" "0|" "$?|$(cat "$SCRATCH/ms.err")"
same "marker-set script, bare tools: the marker is the new text" "$READY" "$(cat "$LEAF/.dxe-persist-dir")"
same "marker-set script, bare tools: mode 0644, no temp file left" "644|.dxe-persist-dir plain.txt" \
    "$(mode_of "$LEAF/.dxe-persist-dir")|$(cd "$LEAF" && ls -A | tr '\n' ' ' | sed 's/ $//')"
printf '%s\n' "$READY" | in_bare "$MS_TOOLS" "$MS_TOOLS/sh" -c "$DX_RUNTIME_DOCKER_HOST_DIR_MARKER_SET_SCRIPT" sh \
    "$MS_ROOT" dx-m copying dx-m-persist 2>"$SCRATCH/ms.err"
check "marker-set script, bare tools: a second copying -> ready is refused (compare-and-set)" [ "$?" -ne 0 ]
check "marker-set script, bare tools: the refusal says why, as a dx: line" has "$(cat "$SCRATCH/ms.err")" "dx: the marker in dxe/dx-m/persist is not copying"
same "marker-set script, bare tools: the refused run changed nothing" "$READY" "$(cat "$LEAF/.dxe-persist-dir")"
printf 'source-volume=dx-m-persist\nsource-volume=dx-m-persist\n' >>"$LEAF/.dxe-persist-dir"
printf '%s\n' "$READY" | in_bare "$MS_TOOLS" "$MS_TOOLS/sh" -c "$DX_RUNTIME_DOCKER_HOST_DIR_MARKER_SET_SCRIPT" sh \
    "$MS_ROOT" dx-m ready dx-m-persist 2>/dev/null
check "marker-set script: a repeated source-volume line is refused" [ "$?" -ne 0 ]

# The establish script (WP4.4), which the migration runs with the copying
# marker: the shell and its coreutils (the owner is this user's own, which a
# non-root chown may set).
EST_TOOLS="$SCRATCH/bare-establish"
restricted "$EST_TOOLS" sh mkdir ls chown chmod mktemp cat mv rm
EST_ROOT="$SCRATCH/dxe-est-share"
mkdir -p "$EST_ROOT"
: >"$EST_ROOT/flag"
COPYING="$(dx_persist_marker_format dx-m copying dx-m-persist 2026-10-01T10:00:00Z)"
printf '%s\n' "$COPYING" | in_bare "$EST_TOOLS" "$EST_TOOLS/sh" -c "$DX_RUNTIME_DOCKER_HOST_DIR_ESTABLISH_SCRIPT" sh \
    "$EST_ROOT" dx-m create "$(id -u):$(id -g)" flag 2>"$SCRATCH/est.err"
same "establish script, bare tools: create succeeds" "0|" "$?|$(cat "$SCRATCH/est.err")"
same "establish script, bare tools: the leaf is 0755 with the copying marker" "755|$COPYING" \
    "$(mode_of "$EST_ROOT/dxe/dx-m/persist")|$(cat "$EST_ROOT/dxe/dx-m/persist/.dxe-persist-dir" 2>/dev/null)"

# The manifest tool (J3) under bash with only the coreutils and findutils it
# names. It needs Bash 5 with GNU find and sha256sum (the guest image's), so
# this case runs where those exist (the Linux coverage container and CI).
gnu_toolchain() {
    local v
    v="$(bash --version 2>/dev/null)" || return 1
    case "$v" in *"version "[5-9].*) : ;; *) return 1 ;; esac
    v="$(find --version 2>/dev/null)" || return 1
    case "$v" in *"GNU findutils"*) : ;; *) return 1 ;; esac
    command -v sha256sum >/dev/null 2>&1
}
if gnu_toolchain; then
    MF_TOOLS="$SCRATCH/bare-manifest"
    restricted "$MF_TOOLS" bash mktemp rm rmdir find xargs sha256sum sort tr wc
    MANIFEST_TEXT="$(cat "$DX_RUNTIME_DOCKER_MANIFEST_TOOL")"
    TREE_A="$SCRATCH/dxe-tree-a"
    TREE_B="$SCRATCH/dxe-tree-b"
    mkdir -p "$TREE_A/sub" "$TREE_B"
    printf 'one\n' >"$TREE_A/sub/file"
    ln -s sub/file "$TREE_A/link"
    in_bare "$MF_TOOLS" "$MF_TOOLS/bash" -c "$MANIFEST_TEXT" dx-persist-manifest verify "$TREE_A" "$TREE_A" >"$SCRATCH/mf.out" 2>"$SCRATCH/mf.err"
    same "manifest tool, bare tools: identical trees match (status 0)" "0|" "$?|$(cat "$SCRATCH/mf.err")"
    check "manifest tool, bare tools: says they match" has "$(cat "$SCRATCH/mf.out")" "Manifests match"
    in_bare "$MF_TOOLS" "$MF_TOOLS/bash" -c "$MANIFEST_TEXT" dx-persist-manifest verify "$TREE_A" "$TREE_B" >"$SCRATCH/mf.out" 2>"$SCRATCH/mf.err"
    same "manifest tool, bare tools: different trees differ (status 1), no tool missing" "1|" "$?|$(cat "$SCRATCH/mf.err")"
else
    echo "  (manifest tool with bare tools: needs Bash 5, GNU findutils and sha256sum; runs in the Linux coverage container)"
fi

# =============================================================================
# container_state

fake_tool_write "$BIN" container 'echo "container $*" >>"'"$CALLS"'"
[ -z "${P_CRC:-}" ] || exit "$P_CRC"
case "$*" in
    "list -a --quiet") printf "dx-up\ndx-down\n" ;;
    "list --quiet") printf "dx-up\n" ;;
esac'
for pair in dx-up:running dx-down:stopped dx-gone:absent; do
    DX_RUNTIME=apple run_fn dx_runtime_container_state "${pair%%:*}"
    same "container_state (apple) ${pair%%:*}: ${pair#*:}, status 0" "0|${pair#*:}" "$RC|$OUT"
done
same "container_state (apple): the two quiet listings" "$(printf 'container list -a --quiet\ncontainer list --quiet')" "$CALLED"
P_CRC=1 DX_RUNTIME=apple run_fn dx_runtime_container_state dx-up
same "container_state (apple): a failed listing is unknown, non-zero, no Error line" "1|unknown|0" "$RC|$OUT|$(count_of "$ERR" '^Error:')"
DX_RUNTIME=apple run_fn dx_runtime_container_state ""
same "container_state (apple): an empty name is unknown, with no call" "1|unknown|" "$RC|$OUT|$CALLED"
refusing_tools

run_fn dx_runtime_container_state ""
same "container_state (docker): an empty name is unknown, with no call" "1|unknown||" "$RC|$OUT|$ERR|$CALLED"
cs_cli() { # the transport answers P_ANSWER with status P_ANSWER_RC
    dx_runtime_docker_cli() { echo "cli $*" >>"$CALLS"; printf '%b' "$P_ANSWER"; return "$P_ANSWER_RC"; }
    dx_runtime_container_state dx-m
}
P_ANSWER='Warning: something\r\ntrue\r\n' P_ANSWER_RC=0 run_fn cs_cli
same "container_state (docker): the last line counts, CR stripped" "0|running" "$RC|$OUT"
P_ANSWER='<no value>\n' P_ANSWER_RC=0 run_fn cs_cli
same "container_state (docker): an answer neither true nor false is unknown" "1|unknown" "$RC|$OUT"
same "container_state (docker): that answer is passed on as a dx: line" "dx: container inspect: <no value>" "$ERR"
P_ANSWER='' P_ANSWER_RC=255 run_fn cs_cli
same "container_state (docker): a silent failure is unknown, nothing on stderr" "1|unknown|" "$RC|$OUT|$ERR"

# =============================================================================
# The manifest verify's last refusals (no call).

DX_IMAGE='' run_fn dx_runtime_host_manifest_verify forward dx-m-persist /share-m/dxe/dx-m/persist
same "manifest_verify without DX_IMAGE: status 1, no stdout, no call" "1||" "$RC|$OUT|$CALLED"
check "manifest_verify without DX_IMAGE: a dx: reason naming DX_IMAGE" has "$ERR" "dx: refusing to verify the manifest: no DX_IMAGE"
mf_missing() {
    DX_RUNTIME_DOCKER_MANIFEST_TOOL="$SCRATCH/no-such-tool.sh"
    dx_runtime_host_manifest_verify forward dx-m-persist /share-m/dxe/dx-m/persist
}
run_fn mf_missing
same "manifest_verify, the tool text cannot be read: status 2 (an error), no call" "2||" "$RC|$OUT|$CALLED"
check "manifest_verify, the tool text cannot be read: one Error line naming it" has "$ERR" "Error: cannot read the manifest tool $SCRATCH/no-such-tool.sh."
check "the manifest tool path points at the WP6.1 tool" [ -f "$DX_RUNTIME_DOCKER_MANIFEST_TOOL" ]

# =============================================================================
# dx_persist_migrate_decide on malformed and edge reports (pure).

decide() { # REPORT -> "ACTION|WHY|ROOT|CREATED"
    dx_persist_migrate_decide dx-m dx-m-persist <<<"$1"
    printf '%s|%s|%s|%s\n' "$DX_MIGRATE_ACTION" "$DX_MIGRATE_WHY" "$DX_MIGRATE_ROOT" "$DX_MIGRATE_CREATED"
}
NL=$'\n'
R_OK="root=/s${NL}mounted=yes"
same "decide: an empty report" "refuse|root||" "$(decide "")"
same "decide: a relative root" "refuse|root||" "$(decide "root=s${NL}mounted=yes${NL}state=absent${NL}marker=absent")"
same "decide: absent" "create|root|/s|" "$(decide "$R_OK${NL}state=absent${NL}marker=absent")"
same "decide: empty" "adopt|root|/s|" "$(decide "$R_OK${NL}state=empty${NL}marker=absent")"
same "decide: an extra line after marker=absent" "refuse|root||" "$(decide "$R_OK${NL}state=absent${NL}marker=absent${NL}x")"
same "decide: a marker without a non-empty state" "refuse|root||" "$(decide "$R_OK${NL}state=empty${NL}marker=present${NL}schema=1")"
same "decide: an unknown state" "refuse|root||" "$(decide "$R_OK${NL}state=odd${NL}marker=absent")"
same "decide: a garbled mounted= line" "refuse|root||" "$(decide "root=/s${NL}mounted=maybe${NL}state=absent${NL}marker=absent")"
same "decide: mounted=unknown is unmounted" "refuse|unmounted||" "$(decide "root=/s${NL}mounted=unknown${NL}state=absent${NL}marker=absent")"
same "decide: a copying marker for this volume without created-at resumes" "resume|copying|/s|" \
    "$(decide "$R_OK${NL}state=nonempty${NL}marker=present${NL}$(dx_persist_marker_format dx-m copying dx-m-persist)")"
same "decide: a copying marker's created-at is kept for the resume" "resume|copying|/s|2026-10-01T10:00:00Z" \
    "$(decide "$R_OK${NL}state=nonempty${NL}marker=present${NL}$COPYING")"

# =============================================================================
# dx_persist_migrate_seconds

same "seconds: the difference" 120 "$(dx_persist_migrate_seconds 10 130)"
same "seconds: an empty reading is unknown" unknown "$(dx_persist_migrate_seconds "" 130)"
same "seconds: a non-numeric reading is unknown" unknown "$(dx_persist_migrate_seconds 10 x)"

# =============================================================================
# dx_persist_migrate_run with in-process recorders for every runtime operation.

OPS="$SCRATCH/ops"
INV_OK='df_avail_kb=900
size_kb=100
entries=5
hardlinks=0
appledouble=0
special=0
acl=0
xattr=0
status=ok'
PROBE_ABSENT='root=/share-m
mounted=yes
state=absent
marker=absent'
stub_ops() {
    dx_runtime_container_state() { echo stopped; }
    dx_runtime_volume_owned() { echo "owned $*" >>"$OPS"; }
    dx_runtime_host_dir_probe() { printf '%s\n' "$PROBE_ABSENT"; }
    dx_runtime_volume_inventory() { printf '%s\n' "$INV_OK"; }
    dx_runtime_host_rsync_check() { echo version=3.3.0; }
    dx_runtime_host_dir_establish() { echo "establish $1" >>"$OPS"; }
    dx_runtime_host_rsync() { echo "rsync $1" >>"$OPS"; }
    dx_runtime_host_manifest_verify() { echo "verify $1" >>"$OPS"; }
    dx_runtime_host_dir_marker_set() { echo "marker-set $3" >>"$OPS"; }
}
CLOCK_FILE="$SCRATCH/utc-calls"
bad_first_clock() { # the first UTC reading is unusable
    stub_ops
    : >"$CLOCK_FILE"
    dx_persist_dir_utc_now() { echo not-a-time; }
    dx_persist_migrate_preconditions && dx_persist_migrate_run
}
: >"$OPS"
run_fn bad_first_clock
same "run: an unusable clock before the copying marker is status 1, one Error" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
check "run: that Error names the time it got" has "$ERR" "no usable UTC time ('not-a-time')"
same "run: nothing was established, copied or marked" "$(printf 'owned dx-m-persist migrate from\nowned dx-m-nix run rsync from')" "$(cat "$OPS")"

bad_second_clock() { # the reading after the verification is unusable
    stub_ops
    : >"$CLOCK_FILE"
    dx_persist_dir_utc_now() {
        if [ -s "$CLOCK_FILE" ]; then echo later; else echo x >"$CLOCK_FILE"; echo 2026-10-12T01:00:00Z; fi
    }
    dx_persist_migrate_preconditions && dx_persist_migrate_run
}
: >"$OPS"
run_fn bad_second_clock
same "run: an unusable clock after the verification is status 1, one Error" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
check "run: that Error says the directory stays copying" has "$ERR" "('later'), so /share-m/dxe/dx-m/persist stays copying"
same "run: the copy and verification ran, the marker was not set" \
    "$(printf 'owned dx-m-persist migrate from\nowned dx-m-nix run rsync from\nestablish create\nrsync forward\nverify forward')" "$(cat "$OPS")"
check "run: no record without the ready marker" [ ! -e "$XDG_STATE_HOME/dxe/persist-dirs/nas-m.invalid__dx-m" ]

DATE_BIN="$SCRATCH/date-bin"
mkdir -p "$DATE_BIN"
fake_tool_write "$DATE_BIN" date 'case "$*" in "+%s") echo soon; exit 0 ;; esac
exec /bin/date "$@"'
odd_seconds() {
    stub_ops
    PATH="$DATE_BIN:$PATH"
    dx_persist_migrate_preconditions && dx_persist_migrate_run
}
run_fn odd_seconds
same "run: a clock without seconds still migrates, status 0" 0 "$RC"
check "run: the copy time is reported as unknown" has "$OUT" "copy_seconds: unknown"
check "run: the verify time is reported as unknown" has "$OUT" "verify_seconds: unknown"

DX_CONTAINER_NAME=_bad run_fn dx_persist_migrate_main
same "main: a guest name the directory cannot carry is refused before any call" "1|1|" "$RC|$(count_of "$ERR" '^Error:')|$CALLED"

print_summary
exit_with_code
