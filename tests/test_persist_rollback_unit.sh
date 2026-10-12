#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP6.5 (implementer unit cases) for what the acceptance suite
# (tests/test_persist_rollback.sh) does not reach:
#   - dx_persist_rollback_decide on the probe reports the acceptance cases do
#     not produce (a copying marker without source-volume);
#   - the directory inventory's failures: a container `Error:` line is passed
#     on as a `dx:` line, so the command's own Error line stays the only one;
#     an unusable number is refused with the fix;
#   - dx_persist_rollback_run with every runtime operation replaced by an
#     in-process recorder: DX_PERSIST_VOLUME is NAME for exactly the create,
#     copy and verify, and the profile's value again afterwards; an unusable
#     clock after the verification leaves the marker ready;
#   - a guest name the directory cannot carry, refused before any call.
# The rollback adds no in-container script: its new runtime operation
# (dx_runtime_host_dir_inventory) runs the very inventory script
# dx_runtime_volume_inventory runs, whose bare-image case belongs to WP6.3.

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

test_section "WP6.5: rollback helpers (in-process)"

SCRATCH="$(persist_fixture_root_create)"
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac

DX_RUNTIME=docker-ssh DX_REMOTE_HOST=nas-r.invalid DX_CONTAINER_NAME=dx-r DX_GUEST_SYSTEM=x86_64-linux
DX_PERSIST_VOLUME=dx-r-persist DX_NIX_VOLUME=dx-r-nix DX_BOOTSTRAP_VOLUME=dx-r-bootstrap DX_PERSIST_HOST_ROOT=/share-r
DX_PERSIST_HOST_MOUNT_SENTINEL=flag DX_IMAGE=img-r DXE_RUNTIME_DOCKER_BIN=docker
XDG_STATE_HOME="$SCRATCH/dxe-state"
export DX_RUNTIME DX_REMOTE_HOST DX_CONTAINER_NAME DX_GUEST_SYSTEM DX_PERSIST_VOLUME DX_NIX_VOLUME DX_BOOTSTRAP_VOLUME
export DX_PERSIST_HOST_ROOT DX_PERSIST_HOST_MOUNT_SENTINEL DX_IMAGE DXE_RUNTIME_DOCKER_BIN XDG_STATE_HOME

# Every runtime tool refuses and records: nothing here may reach a host.
BIN="$(fake_tool_dir_create "$SCRATCH")"
CALLS="$SCRATCH/calls"
for t in ssh docker container; do
    fake_tool_write "$BIN" "$t" "echo \"$t \$*\" >> '$CALLS'; exit 99"
done
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

NL=$'\n'
C0=2026-10-01T10:00:00Z
M0=2026-10-01T11:00:00Z
R_OK="root=/share-r${NL}mounted=yes"
READY="$(dx_persist_marker_format dx-r ready dx-r-persist "$C0" "$M0")"

# =============================================================================
# dx_persist_rollback_decide (pure).

decide() { # REPORT -> "STATUS|WHY|ROOT"
    local rc=0
    dx_persist_rollback_decide dx-r <<<"$1" || rc=$?
    printf '%s|%s|%s\n' "$rc" "$DX_MIGRATE_WHY" "$DX_MIGRATE_ROOT"
}
same "decide: a ready marker for this guest goes on, with the canonical root" "0|ready|/share-r" \
    "$(decide "$R_OK${NL}state=nonempty${NL}marker=present${NL}$READY")"
same "decide: a copying marker without source-volume is refused as copying (never resumed)" "1|copying|/share-r" \
    "$(decide "$R_OK${NL}state=nonempty${NL}marker=present${NL}$(dx_persist_marker_format dx-r copying "" "$C0")")"
same "decide: an absent directory is missing" "1|missing|/share-r" "$(decide "$R_OK${NL}state=absent${NL}marker=absent")"
same "decide: an empty directory is unmarked" "1|unmarked|/share-r" "$(decide "$R_OK${NL}state=empty${NL}marker=absent")"
same "decide: an empty report is the root" "1|root|" "$(decide "")"
dx_persist_rollback_decide dx-r <<<"$R_OK${NL}state=nonempty${NL}marker=present${NL}$READY"
same "decide: the ready marker's fields are left for the run" "dx-r-persist|$C0|$M0" \
    "$DX_PERSIST_MARKER_SOURCE_VOLUME|$DX_PERSIST_MARKER_CREATED_AT|$DX_PERSIST_MARKER_MIGRATED_AT"

# =============================================================================
# dx_persist_rollback_inventory: one Error line, naming the directory.

DEST=/share-r/dxe/dx-r/persist
inv_answer() { # P_INV (text) and P_INV_RC answer the directory inventory
    dx_runtime_host_dir_inventory() { printf '%s\n' "$P_INV"; return "$P_INV_RC"; }
    dx_persist_rollback_inventory "$DEST"
}
P_INV='Error: No such image: img-r' P_INV_RC=125 run_fn inv_answer
same "inventory fails with an Error: line of its own: status 1, exactly one Error line" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
check "inventory fails: the command's Error line names the directory" has "$(grep '^Error:' <<<"$ERR")" "could not read $DEST"
check "inventory fails: the container's line is passed on as a dx: line" has "$ERR" "dx: inventory: Error: No such image: img-r"
P_INV='' P_INV_RC=1 run_fn inv_answer
same "inventory fails silently: one Error line, nothing passed on" "1|1|1" "$RC|$(count_of "$ERR" '^Error:')|$(printf '%s\n' "$ERR" | awk 'END { print NR }')"
P_INV="$(printf 'df_avail_kb=9\nsize_kb=x\nentries=1\nhardlinks=0\nappledouble=0\nspecial=0\nacl=0\nxattr=0\nstatus=ok')" P_INV_RC=0 run_fn inv_answer
same "inventory with an unusable number: status 1, one Error line" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
check "inventory with an unusable number: it names the directory, the key and the fix" \
    has "$ERR" "Error: the inventory of $DEST returned no usable size_kb. Nothing was changed; check the share and the NAS's Docker, then retry."
P_INV="$(printf 'df_avail_kb=9\nsize_kb=1\nentries=1\nhardlinks=0\nappledouble=0\nspecial=0\nacl=unknown\nxattr=some\nstatus=ok')" P_INV_RC=0 run_fn inv_answer
check "inventory: acl=unknown passes, a non-numeric xattr does not" has "$ERR" "returned no usable xattr."

# =============================================================================
# dx_persist_rollback_run with in-process recorders for every runtime operation.

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
stub_ops() {
    dx_runtime_container_state() { echo absent; }
    dx_runtime_host_copy_containers() { :; } # WP6.4c: no copy or verify container is left
    dx_runtime_host_dir_probe() { printf '%s\nstate=nonempty\nmarker=present\n%s\n' "$R_OK" "$READY"; }
    dx_runtime_volume_state() { echo "state $1 DX_PERSIST_VOLUME=$DX_PERSIST_VOLUME" >>"$OPS"; echo absent; }
    dx_runtime_host_dir_inventory() { printf '%s\n' "$INV_OK"; }
    dx_runtime_host_rsync_check() { echo "rsync_check $*" >>"$OPS"; echo version=3.3.0; }
    dx_runtime_volume_create() { echo "create $1 DX_PERSIST_VOLUME=$DX_PERSIST_VOLUME" >>"$OPS"; echo "$1"; }
    dx_runtime_host_rsync() { echo "rsync $1 $2 $3 DX_PERSIST_VOLUME=$DX_PERSIST_VOLUME" >>"$OPS"; }
    dx_runtime_host_manifest_verify() { echo "verify $1 $2 DX_PERSIST_VOLUME=$DX_PERSIST_VOLUME" >>"$OPS"; }
    dx_runtime_host_dir_marker_set() { echo "marker-set $1 $3 DX_PERSIST_VOLUME=$DX_PERSIST_VOLUME" >>"$OPS"; }
}
rolled_back() {
    stub_ops
    dx_persist_rollback_run dx-r-new
    echo "after: DX_PERSIST_VOLUME=$DX_PERSIST_VOLUME"
}
: >"$OPS"
run_fn rolled_back
same "run: status 0, no Error line" "0|0" "$RC|$(count_of "$ERR" '^Error:')"
same "run: DX_PERSIST_VOLUME is the new name for the create, the copy and the verify only" \
    "$(printf '%s\n' "state dx-r-new DX_PERSIST_VOLUME=dx-r-persist" "rsync_check " \
        "create dx-r-new DX_PERSIST_VOLUME=dx-r-new" "rsync reverse dx-r-new $DEST DX_PERSIST_VOLUME=dx-r-new" \
        "verify reverse dx-r-new DX_PERSIST_VOLUME=dx-r-new" "marker-set /share-r ready DX_PERSIST_VOLUME=dx-r-persist")" \
    "$(cat "$OPS")"
same "run: the profile's DX_PERSIST_VOLUME is unchanged afterwards" "after: DX_PERSIST_VOLUME=dx-r-persist" "$(tail -n 1 <<<"$OUT")"
check "run: the volume create's own output is not part of stdout" [ "$(count_of "$OUT" '^dx-r-new$')" = 0 ]
check "run: the report names the original volume" has "$OUT" "original_volume: dx-r-persist"

bad_clock() { # the reading after the verification is unusable
    stub_ops
    dx_persist_dir_utc_now() { echo later; }
    dx_persist_rollback_run dx-r-new
}
: >"$OPS"
run_fn bad_clock
same "run: an unusable clock after the verification is status 1, one Error" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
check "run: that Error names the time it got and says the directory stays ready" has "$ERR" "('later'), so $DEST stays ready"
same "run: the copy and the verification ran, the marker was not set" "0|1|1" \
    "$(count_of "$(cat "$OPS")" '^marker-set')|$(count_of "$(cat "$OPS")" '^rsync reverse')|$(count_of "$(cat "$OPS")" '^verify reverse')"
check "run: no report" [ "$(count_of "$OUT" '^rolled_back:')" = 0 ]

# =============================================================================
# main: a guest name the directory cannot carry.

DX_CONTAINER_NAME=_bad run_fn dx_persist_rollback_main --volume dx-r-new
same "main: a guest name the directory cannot carry is refused before any call" "1|1|" "$RC|$(count_of "$ERR" '^Error:')|$CALLED"
check "main: that refusal names DX_CONTAINER_NAME" has "$ERR" "DX_CONTAINER_NAME=_bad"

print_summary
exit_with_code
