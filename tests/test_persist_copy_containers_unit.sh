#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP6.4c (implementer unit cases) for what the acceptance suite
# (tests/test_persist_copy_resume.sh) does not pin, in-process with the one
# docker call replaced by a recorder:
#   - dx_runtime_docker_host_copy_containers reads the LAST line of each `ps`
#     answer, without a carriage return; an answer of blank lines is no
#     container;
#   - dx_persist_copy_containers_none: the first line decides; every refusal
#     says nothing was changed and that the container is from an earlier
#     migration or rollback (both commands share the two names); a running
#     container is to be stopped (never removed); a left one is to be
#     inspected (docker inspect, docker logs) before docker rm.

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

test_section "WP6.4c: copy and verify containers (in-process)"

SCRATCH="$(persist_fixture_root_create)" || exit 1
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac

DX_RUNTIME=docker-ssh DX_REMOTE_HOST=nas-c.invalid DX_CONTAINER_NAME=dx-c DX_GUEST_SYSTEM=x86_64-linux
DXE_RUNTIME_DOCKER_BIN=docker
export DX_RUNTIME DX_REMOTE_HOST DX_CONTAINER_NAME DX_GUEST_SYSTEM DXE_RUNTIME_DOCKER_BIN

# Every runtime tool refuses and records: nothing here may reach a host.
BIN="$(fake_tool_dir_create "$SCRATCH")" || exit 1
TOOL_CALLS="$SCRATCH/tool-calls"
for t in ssh docker container; do
    fake_tool_write "$BIN" "$t" "echo \"$t \$*\" >> '$TOOL_CALLS'; exit 99"
done
PATH="$BIN:$PATH"
export PATH
: >"$TOOL_CALLS"

COPY=dxe-persist-copy-nas-c.invalid__dx-c
VERIFY=dxe-persist-verify-nas-c.invalid__dx-c
CALLS="$SCRATCH/cli-calls"
ANSWERS="$SCRATCH/answers"
mkdir -p "$ANSWERS"

same() { # LABEL WANT GOT
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (want [$2] got [$3])"; fi
}
has() { # LABEL TEXT NEEDLE
    if grep -Fq -- "$3" <<<"$2"; then test_pass "$1"; else test_fail "$1 (no [$3] in [$2])"; fi
}
lacks() { # LABEL TEXT NEEDLE
    if grep -Fq -- "$3" <<<"$2"; then test_fail "$1 (found [$3] in [$2])"; else test_pass "$1"; fi
}
count_of() { grep -c -- "$2" <<<"$1" || true; }

# The one docker call, recorded: `ps -a` answers the bytes in ANSWERS/<name>
# (printf %b), nothing when there is no such file.
dx_runtime_docker_cli() {
    local f="" prev="" a
    echo "cli $*" >>"$CALLS"
    for a in "$@"; do
        if [ "$prev" = --filter ]; then f="$a"; fi
        prev="$a"
    done
    f="${f#name=^/}"
    f="${f%\$}"
    if [ -f "$ANSWERS/$f" ]; then printf '%b' "$(cat "$ANSWERS/$f")"; fi
    return 0
}
answer() { printf '%s' "$2" >"$ANSWERS/$1"; } # NAME BYTES (printf %b escapes)

# run_fn FN [ARG...]: FN in a subshell; sets RC OUT ERR.
run_fn() {
    : >"$CALLS"
    OUT="$("$@" 2>"$SCRATCH/err")"
    RC=$?
    ERR="$(cat "$SCRATCH/err")"
}

# --- the adapter: the last line of each answer, no carriage return -----------
answer "$COPY" 'running\r\n'
run_fn dx_runtime_docker_host_copy_containers
same "a state ending in CR: read without it" "0|$COPY running" "$RC|$OUT"

/bin/rm -f "$ANSWERS/$COPY"
answer "$VERIFY" 'created\nexited\n'
run_fn dx_runtime_docker_host_copy_containers
same "two answer lines: the last one is the state" "$VERIFY exited" "$OUT"

/bin/rm -f "$ANSWERS/$VERIFY"
answer "$COPY" '\n\n'
run_fn dx_runtime_docker_host_copy_containers
same "an answer of blank lines: no container, status 0" "0|" "$RC|$OUT"
same "both names were asked about, in order" \
    "$(printf 'cli ps -a --filter name=^/%s$ --format {{.State}}\ncli ps -a --filter name=^/%s$ --format {{.State}}' "$COPY" "$VERIFY")" \
    "$(cat "$CALLS")"
same "no runtime tool ran" "" "$(cat "$TOOL_CALLS")"

# --- the refusal ----------------------------------------------------------------
# found LINES: the operation's answer, status 0. lost: the operation fails.
found() { FOUND="$1"; dx_runtime_host_copy_containers() { printf '%s\n' "$FOUND"; }; }
lost() { dx_runtime_host_copy_containers() { echo "docker: the daemon went away" >&2; return 1; }; }

found ""
run_fn dx_persist_copy_containers_none dx-persist-migrate
same "none left: status 0, nothing printed" "0||" "$RC|$OUT|$ERR"

found "$(printf '%s running\n%s exited' "$VERIFY" "$COPY")"
run_fn dx_persist_copy_containers_none dx-persist-rollback
same "running: status 1, one Error line" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
has "running: the first line decides (the verify container named first here)" "$ERR" "$VERIFY"
lacks "running: the second line is not reported" "$ERR" "$COPY"
has "running: either command's earlier run" "$ERR" "earlier migration or rollback"
has "running: still running on the NAS" "$ERR" "still running on nas-c.invalid"
has "running: stop it, or wait" "$ERR" "wait for it to finish, or stop it there with docker stop $VERIFY"
lacks "running: never removed" "$ERR" "docker rm"
has "running: nothing was changed" "$ERR" "Nothing was changed."

found "$COPY dead"
run_fn dx_persist_copy_containers_none dx-persist-migrate
same "left: status 1, one Error line" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
has "left: the state" "$ERR" "is left on nas-c.invalid in state dead"
has "left: inspect it first" "$ERR" "docker inspect $COPY, docker logs $COPY"
has "left: then remove it and run the command again" "$ERR" "docker rm $COPY and run dx-persist-migrate again"
lacks "left: no docker stop" "$ERR" "docker stop"
has "left: nothing was changed" "$ERR" "Nothing was changed."

lost
run_fn dx_persist_copy_containers_none dx-persist-rollback
same "the check fails: status 1, one Error line" "1|1" "$RC|$(count_of "$ERR" '^Error:')"
has "the check fails: the operation's own line comes first" "$(head -n 1 <<<"$ERR")" "docker: the daemon went away"
has "the check fails: cannot tell, on the NAS" "$ERR" "cannot tell whether a copy or verify container of an earlier migration or rollback is still on nas-c.invalid"
has "the check fails: run the command again" "$ERR" "then run dx-persist-rollback again. Nothing was changed."

print_summary
exit_with_code
