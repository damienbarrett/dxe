#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP6.7 (implementer unit cases) for what the acceptance suite
# (tests/test_persist_followup_hardening.sh) does not pin, in-process, with
# every runtime tool a refusing recorder and every call that hands the
# filesystem root to a guard made with recording stubs for rm, chmod, chown,
# mv and find in front of PATH:
#   - dx_path_names_filesystem_root (bin/lib/dx-config.sh), the one rule the
#     three checks share: its truth table, including the spellings that are
#     NOT the filesystem root ("/...", "/share/..", a relative or empty path);
#   - dx_runtime_docker_version_below: (major, minor, patch), a missing part
#     counting as 0, and the rsync refusal's one Error line;
#   - establish's checks: an earlier reason (an unknown mode) still wins, and
#     the filesystem-root reason is one `dx:` line;
#   - the start refusal for a canonical root of "/" names the filesystem root
#     (dx_persist_refusal), while any other refuse:root keeps "not a usable
#     directory"; refuse:unmarked adds the fresh-start override only when the
#     guest has used other /persist storage before;
#   - dx_persist_migrate_decide refuses root=// as it refuses root=/ (one rule
#     for both decisions);
#   - the left copy/verify container refusal: the exact paused and removing
#     lines, and the other states unchanged.

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

test_section "WP6.7: follow-up hardening (in-process)"

SCRATCH="$(persist_fixture_root_create)" || exit 1
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT

# Every runtime tool refuses and records: nothing here may reach a host.
BIN="$(fake_tool_dir_create "$SCRATCH")" || exit 1
TOOL_LOG="$SCRATCH/tool-calls"
for t in ssh scp sftp docker container tailscale; do
    fake_tool_write "$BIN" "$t" "echo \"$t \$*\" >> '$TOOL_LOG'; exit 99"
done
PATH="$BIN:$PATH"
export PATH
: >"$TOOL_LOG"

# Recording stubs for every destructive command, put in front of PATH (in a
# subshell) for each call that hands the filesystem root to a guard.
GUARD="$(fake_tool_dir_create "$SCRATCH")" || exit 1
GUARD_LOG="$SCRATCH/guard-calls"
for t in ssh scp sftp docker container tailscale rm chmod chown mv find; do
    fake_tool_write "$GUARD" "$t" "echo \"$t \$*\" >> '$GUARD_LOG'; exit 97"
done
: >"$GUARD_LOG"

DX_RUNTIME=docker-ssh DX_REMOTE_HOST=nas-u.invalid DX_CONTAINER_NAME=dx-u DX_GUEST_SYSTEM=x86_64-linux
DX_IMAGE=dxe-unit-image:1 DX_NIX_VOLUME=dx-u-nix DX_PERSIST_VOLUME=dx-u-persist
DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/fixture/share
DX_PERSIST_HOST_MOUNT_SENTINEL=dxe-share-mounted DXE_RUNTIME_DOCKER_BIN=docker
XDG_STATE_HOME="$SCRATCH/state"
export DX_RUNTIME DX_REMOTE_HOST DX_CONTAINER_NAME DX_GUEST_SYSTEM DX_IMAGE DX_NIX_VOLUME
export DX_PERSIST_VOLUME DX_PERSIST_STORAGE DX_PERSIST_HOST_ROOT DX_PERSIST_HOST_MOUNT_SENTINEL
export DXE_RUNTIME_DOCKER_BIN XDG_STATE_HOME
unset DX_BOOTSTRAP_VOLUME DX_PERSIST_FRESH_START

same() { # LABEL WANT GOT
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (want [$2] got [$3])"; fi
}
has() { # LABEL TEXT NEEDLE
    if grep -Fq -- "$3" <<<"$2"; then test_pass "$1"; else test_fail "$1 (no [$3] in [$2])"; fi
}
lacks() { # LABEL TEXT NEEDLE
    if grep -Fq -- "$3" <<<"$2"; then test_fail "$1 (found [$3] in [$2])"; else test_pass "$1"; fi
}
guard_quiet() { # LABEL: no recorded command ran, then reset the logs
    if [ -s "$GUARD_LOG" ] || [ -s "$TOOL_LOG" ]; then
        test_fail "$1 (ran: $(cat "$GUARD_LOG" "$TOOL_LOG" | tr '\n' '|'))"
    else
        test_pass "$1"
    fi
    : >"$GUARD_LOG"
    : >"$TOOL_LOG"
}

# =============================================================================
test_section "WP6.7 unit: dx_path_names_filesystem_root"

fs_root() { # PATH: yes|no, with the destructive commands stubbed
    (
        PATH="$GUARD:$PATH"
        if dx_path_names_filesystem_root "$1"; then echo yes; else echo no; fi
    )
}
got=""
for p in / // /// /. /./ /.. /../ /./../. //./ /.//..//; do
    got="$got $p=$(fs_root "$p")"
done
same "every all-empty/./.. spelling of an absolute path names the filesystem root" \
    " /=yes //=yes ///=yes /.=yes /./=yes /..=yes /../=yes /./../.=yes //./=yes /.//..//=yes" "$got"
got=""
for p in "" . ./ .. relative /share /share/ /share/example-root/ /... /.x /..x //share /share/.. "/ " /-; do
    got="$got [$p]=$(fs_root "$p")"
done
same "a relative or empty path, a real component (even /share/..), '...' or '.x' does not" \
    " []=no [.]=no [./]=no [..]=no [relative]=no [/share]=no [/share/]=no [/share/example-root/]=no [/...]=no [/.x]=no [/..x]=no [//share]=no [/share/..]=no [/ ]=no [/-]=no" "$got"
nl=$'\n'
same "a newline after the root is a component, not the root" no "$(fs_root "/$nl")"
guard_quiet "the rule is pure string work: no command ran"

# The configuration rule, in-process: the root's own Error line, after the
# colon rule (a root with both is refused for the colon first).
cross() { # VAR=value...: dx_config_validate_cross_fields on a docker-ssh host-path baseline (stderr+status)
    (
        DX_NIX_STORAGE_MODE=direct-volume DX_BOOTSTRAP_VOLUME=dx-u-boot
        export DX_NIX_STORAGE_MODE DX_BOOTSTRAP_VOLUME
        local kv
        for kv in "$@"; do
            case "$kv" in *=*) printf -v "${kv%%=*}" '%s' "${kv#*=}" ;; esac
        done
        PATH="$GUARD:$PATH"
        dx_config_validate_cross_fields 2>&1
    )
}
out="$(cross DX_PERSIST_HOST_ROOT=//)"
rc=$?
same "host-path with DX_PERSIST_HOST_ROOT=//: status 1" 1 "$rc"
same "host-path with DX_PERSIST_HOST_ROOT=//: the exact line" \
    "Error: DX_PERSIST_HOST_ROOT must not be the filesystem root (it is '//'); set it to the NAS share root the guest directories go under." "$out"
out="$(cross DX_PERSIST_HOST_ROOT=/share/..)"
rc=$?
same "host-path with /share/.. (a real component) passes the configuration; the probe's canonical root decides" "0:" "$rc:$out"
guard_quiet "the configuration rule ran no command"

# =============================================================================
test_section "WP6.7 unit: the rsync floor"

below() { if dx_runtime_docker_version_below "$1" "$2"; then echo below; else echo ok; fi; }
got=""
for v in 2.6.9 3.0.7 3.0.99 3.1 3.1.0 3.1.2 3.1.3 3.1.4 3.1.10 3.2 3.2.0 3.10.0 4.0 4.0.0; do
    got="$got $v=$(below "$v" 3.1.3)"
done
same "(major, minor, patch) against 3.1.3, numerically, a missing patch as 0" \
    " 2.6.9=below 3.0.7=below 3.0.99=below 3.1=below 3.1.0=below 3.1.2=below 3.1.3=ok 3.1.4=ok 3.1.10=ok 3.2=ok 3.2.0=ok 3.10.0=ok 4.0=ok 4.0.0=ok" "$got"
same "a floor without a patch counts it as 0 (3.1 is not below 3.1)" "ok below" "$(below 3.1 3.1) $(below 3.0.9 3.1)"
same "the floor is 3.1.3" 3.1.3 "$DX_RUNTIME_DOCKER_RSYNC_FLOOR"

gap_err="$(dx_runtime_docker_rsync_gap "$(printf 'version=3.1.2\nhard_links=yes\nacls=yes\nxattrs=yes')" yes yes 2>&1 >/dev/null)"
gap_rc=$?
same "rsync 3.1.2: refused with the one Error line" \
    "1:Error: rsync 3.1.2 in the guest's nix volume is below 3.1.3 (the copy compares modification times to the nanosecond with --modify-window=-1, which needs 3.1.3 or newer)." \
    "$gap_rc:$gap_err"
gap_err="$(dx_runtime_docker_rsync_gap "$(printf 'version=3.1.3\nhard_links=no\nacls=yes\nxattrs=yes')" no no 2>&1 >/dev/null)"
gap_rc=$?
same "rsync 3.1.3 passes the floor and is then checked for hard links" \
    "1:Error: rsync 3.1.3 in the guest's nix volume lacks hard links support." "$gap_rc:$gap_err"

# =============================================================================
test_section "WP6.7 unit: establish's checks"

establish_ok() { # MODE ROOT: dx_runtime_docker_host_dir_establish_ok's stderr+status, destructive commands stubbed
    (
        PATH="$GUARD:$PATH"
        dx_runtime_docker_host_dir_establish_ok "$1" "$2" dx-u 30033:30001 2>&1
    )
}
out="$(establish_ok create /)"
rc=$?
same "establish's check, root /: one dx: line naming the filesystem root" \
    "1:dx: refusing to establish the NAS directory: the share root '/' names the filesystem root, which is never a share root" "$rc:$out"
out="$(establish_ok bogus /..)"
rc=$?
same "an unknown mode is still the first reason, even with root /.." \
    "1:dx: refusing to establish the NAS directory: unknown mode 'bogus' (expected create, adopt or fresh-start)" "$rc:$out"
out="$(establish_ok adopt relative/root)"
rc=$?
same "a relative root keeps its own reason" \
    "1:dx: refusing to establish the NAS directory: the share root 'relative/root' cannot be bound: it must be an absolute path without ',' or a newline" "$rc:$out"
same "an ordinary root with a trailing slash passes the checks" "0:" "$(establish_ok fresh-start /share/example-root/; echo "$?:")"
guard_quiet "establish's checks ran no command"

# =============================================================================
test_section "WP6.7 unit: the start refusals"

DIR="/fixture/share/dxe/dx-u/persist"
refusal() { # TOKEN REPORT VOLUME RECORD: dx_persist_refusal's stderr
    (
        PATH="$GUARD:$PATH"
        dx_persist_refusal "$@" 2>&1
    )
}
REPORT_SLASH="$(printf 'root=/\nmounted=yes\nstate=absent\nmarker=absent')"
same "refuse:root on a canonical root of /: the filesystem-root line" \
    "Error: the share root DX_PERSIST_HOST_ROOT=/fixture/share resolves to the filesystem root (/) on nas-u.invalid (through a symlink or ..), and the filesystem root is never a share root; set DX_PERSIST_HOST_ROOT in the private profile to the share itself, then retry." \
    "$(refusal refuse:root "$REPORT_SLASH" no no)"
out="$(refusal refuse:root "$(printf 'root=//\nmounted=yes\nstate=empty\nmarker=absent')" no no)"
has "refuse:root on root=//: the filesystem-root line names it" "$out" "resolves to the filesystem root (//)"
for rep in "" "dx: not a directory: /fixture/share" "$(printf 'root=/fixture/share\nmounted=maybe\nstate=absent\nmarker=absent')"; do
    out="$(refusal refuse:root "$rep" no no)"
    same "refuse:root on [$(head -n 1 <<<"$rep")]: still 'not a usable directory'" \
        "Error: the share root DX_PERSIST_HOST_ROOT=/fixture/share is not a usable directory on nas-u.invalid, or it could not be checked; fix DX_PERSIST_HOST_ROOT in the private profile or make the share available, then retry." "$out"
done

UNMARKED="$(printf 'root=/fixture/share\nmounted=yes\nstate=nonempty\nmarker=absent')"
base="Error: $DIR is not empty and has no .dxe-persist-dir marker; data dxe did not mark is never adopted, so move it aside (the directory, or its contents; keep it if it matters), then start fresh with dx-create-volumes, or copy the guest's persist volume into the now-absent or now-empty directory with dx-persist-migrate."
same "refuse:unmarked, a new guest: the guidance, no override" "$base" "$(refusal refuse:unmarked "$UNMARKED" no no)"
hint=" Because dx-u has used other /persist storage before, starting fresh needs the emptied directory and DX_PERSIST_FRESH_START=dx-u."
same "refuse:unmarked, the persist volume exists: the override is named" "$base$hint" "$(refusal refuse:unmarked "$UNMARKED" yes no)"
same "refuse:unmarked, the record exists: the override is named" "$base$hint" "$(refusal refuse:unmarked "$UNMARKED" no yes)"

# Through the decision, the whole host-path path: a configured root that is a
# symlink to / (the probe's canonical root is /) is refused with that line.
decide() { # REPORT: dx_persist_host_dir_decide on that probe report (stdout, stderr, status)
    (
        DECIDE_REPORT="$1"
        PATH="$GUARD:$PATH"
        dx_runtime_host_dir_probe() { printf '%s\n' "$DECIDE_REPORT"; }
        dx_runtime_volume_state() { echo absent; }
        out="$(dx_persist_host_dir_decide 2>"$SCRATCH/decide.err")"
        rc=$?
        printf 'rc=%s out=[%s] err=[%s]\n' "$rc" "$out" "$(cat "$SCRATCH/decide.err")"
    )
}
got="$(decide "$REPORT_SLASH")"
has "the decision on a canonical root of /: status 1, nothing on stdout" "$got" "rc=1 out=[]"
has "the decision on a canonical root of /: the filesystem-root Error line" "$got" "err=[Error: the share root DX_PERSIST_HOST_ROOT=/fixture/share resolves to the filesystem root (/)"
lacks "the decision on a canonical root of /: never create" "$got" "create"
guard_quiet "the refusals ran no command"

# =============================================================================
test_section "WP6.7 unit: the migration's root rule is the same rule"

migrate_decide() { # ROOT: action/why for a report that would otherwise be create
    (
        PATH="$GUARD:$PATH"
        dx_persist_migrate_decide dx-u dx-u-persist <<<"$(printf 'root=%s\nmounted=yes\nstate=absent\nmarker=absent' "$1")"
        printf '%s:%s:%s\n' "$DX_MIGRATE_ACTION" "$DX_MIGRATE_WHY" "$DX_MIGRATE_ROOT"
    )
}
same "migrate decision, root=/: refused (root)" "refuse:root:" "$(migrate_decide /)"
same "migrate decision, root=//: refused (root), as the start decision does" "refuse:root:" "$(migrate_decide //)"
same "migrate decision, root=/.: refused (root)" "refuse:root:" "$(migrate_decide /.)"
same "migrate decision, an ordinary canonical root: create" "create:root:/fixture/share" "$(migrate_decide /fixture/share)"
same "migrate decision, a root with a comma: refused (root)" "refuse:root:" "$(migrate_decide /fixture/a,b)"
guard_quiet "the migration decision ran no command"

# =============================================================================
test_section "WP6.7 unit: the left copy/verify container refusal"

PS_COPY="" PS_VERIFY=""
dx_runtime_host_copy_containers() {
    if [ -n "$PS_COPY" ]; then printf 'dxe-persist-copy-x %s\n' "$PS_COPY"; fi
    if [ -n "$PS_VERIFY" ]; then printf 'dxe-persist-verify-x %s\n' "$PS_VERIFY"; fi
}
left() { # COPY_STATE VERIFY_STATE COMMAND: status and stderr
    PS_COPY="$1" PS_VERIFY="$2"
    local err rc
    err="$(dx_persist_copy_containers_none "$3" 2>&1 >/dev/null)"
    rc=$?
    printf '%s:%s' "$rc" "$err"
}
same "paused: the exact line" \
    "1:Error: the container dxe-persist-copy-x of an earlier migration or rollback is paused on nas-u.invalid; resume it there with docker unpause dxe-persist-copy-x (it then finishes and removes itself), or end it with docker stop dxe-persist-copy-x, then run dx-persist-migrate again. Nothing was changed." \
    "$(left paused "" dx-persist-migrate)"
same "removing: the exact line" \
    "1:Error: Docker is removing the container dxe-persist-verify-x of an earlier migration or rollback on nas-u.invalid; wait until docker ps -a no longer lists it, then run dx-persist-rollback again. Nothing was changed." \
    "$(left "" removing dx-persist-rollback)"
got="$(left removing paused dx-persist-migrate)"
has "the copy container decides before the verify container (removing, then paused)" "$got" "Docker is removing the container dxe-persist-copy-x"
for st in created exited dead restarting; do
    got="$(left "$st" "" dx-persist-rollback)"
    has "$st: still the inspect-then-docker rm line" "$got" "is left on nas-u.invalid in state $st; inspect it there (docker inspect dxe-persist-copy-x, docker logs dxe-persist-copy-x), then remove it with docker rm dxe-persist-copy-x and run dx-persist-rollback again. Nothing was changed."
done
same "running: still the wait-or-stop line" \
    "1:Error: the container dxe-persist-copy-x of an earlier migration or rollback is still running on nas-u.invalid; wait for it to finish, or stop it there with docker stop dxe-persist-copy-x, then run dx-persist-migrate again. Nothing was changed." \
    "$(left running "" dx-persist-migrate)"
same "none left: status 0, silent" "0:" "$(left "" "" dx-persist-migrate)"
guard_quiet "the container refusals ran no command"

print_summary
exit_with_code
