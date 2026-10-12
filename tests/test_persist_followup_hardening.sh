#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP6.7 (plans/do plan.md; follow-ups found while verifying WP4.3, WP6.2,
# WP6.4b, WP6.4c and WP-T1): acceptance tests for a bundle of small hardening
# items. Written before the fixes; the implementer builds them to satisfy
# exactly this contract. Every case drives a library function (or
# bin/dx-profile) with the docker-ssh transport replaced by an in-process
# recorder, so no ssh, docker or NAS is ever reached; every runtime tool on
# PATH is a refusing recorder; and every call that hands the filesystem root
# to a guard runs with recording stubs for rm, chmod, chown, mv and find in
# front of PATH, so a broken guard can do no real damage.
#
# Interface contract:
#
#  "Names the filesystem root" (items C1-C3): an absolute path every one of
#  whose "/"-separated components is empty, "." or ".." -- "/", "//", "/.",
#  "/./", "/.." and the like. "/share/example-root/" (a trailing slash) does
#  not.
#
#  A. The start refusal for a non-empty directory with no marker
#     (refuse:unmarked; dx_persist_refusal in bin/lib/dx-persist-dir.sh, seen
#     here through dx_persist_host_dir_decide and dx_persist_start_check, the
#     dx-create-volumes and dx-start-container paths). dx-persist-migrate also
#     refuses a non-empty unmarked directory, so the refusal must not say
#     "import it with dx-persist-migrate". Whatever the persist volume and the
#     D-7 record say: status 1, nothing on stdout, exactly one stderr line,
#     starting "Error:", that holds these fixed strings:
#         "is not empty and has no .dxe-persist-dir marker"   (kept: the live
#             suite and docs/troubleshooting.md pin it)
#         "move it aside"           (it is not dxe's: never adopted)
#         "start fresh"             (with the directory moved away ...)
#         "dx-create-volumes"       (... dx-create-volumes starts afresh)
#         "dx-persist-migrate"      (... or copies the persist volume into the
#                                    now-absent, or now-empty, directory)
#     where the first "move it aside" comes before the first occurrence of
#     each of the other three; and it does NOT hold "import it".
#     (docs/troubleshooting.md already says this; its pins are unchanged.)
#
#  B. The rsync floor (dx_runtime_host_rsync_check; the docker adapter's
#     version gate in bin/lib/dx-runtime-docker-lifecycle.sh). The copy runs
#     rsync --modify-window=-1, which compares modification times to the
#     nanosecond only when the receiving rsync is at least 3.1.3 (rsync's NEWS
#     for 3.1.3: "Added the ability for rsync to compare nanosecond times in
#     its file-check comparisons"; rsync(1), --modify-window: "If you specify
#     a negative value (and the receiver is at least version 3.1.3) then
#     nanoseconds will also be taken into account"). The floor is 3.1.3,
#     compared numerically by (major, minor, patch), a missing patch counting
#     as 0:
#       refused: 3.1.2, 3.1.0, 3.1 and 3.0.9 -- non-zero, nothing on stdout,
#         exactly one stderr line starting "Error:" that holds the version
#         found and "below 3.1.3";
#       accepted: 3.1.3, 3.1.10, 3.2, 3.2.0 and 3.4.1 -- status 0, nothing on
#         stderr, the four fact lines with version=<as found> first.
#     (tests/test_persist_rsync_ops.sh's "below 3.1" pin becomes "below 3.1.3"
#     with this item.)
#
#  C. The filesystem root is never a share root.
#     C1. dx_config_validate_cross_fields (bin/lib/dx-config.sh; so also
#         dx_init_config, inherited snapshots and bin/dx-profile): with
#         DX_PERSIST_STORAGE=host-path, a DX_PERSIST_HOST_ROOT that names the
#         filesystem root is refused: status 1, exactly one stderr line,
#         starting "Error:" and holding
#             "DX_PERSIST_HOST_ROOT must not be the filesystem root"
#         and none of the other rules' strings ("is required", "must not
#         contain ':'", "docs/guest.md"). In volume mode such a root is still
#         ignored (status 0, silent), and "/share/example-root/" is still
#         accepted. bin/dx-profile on a profile with DX_PERSIST_HOST_ROOT=/
#         exits non-zero, prints that message and never runs its command.
#         (An empty or relative root is already refused, and pinned by
#         tests/test_persist_storage_config*.sh.)
#     C2. dx_runtime_host_dir_establish MODE ROOT GUEST OWNER MARKER under
#         docker-ssh refuses a ROOT that names the filesystem root, for every
#         MODE, before any runtime call: non-zero, nothing on stdout, a stderr
#         line holding "refusing to establish the NAS directory" and
#         "filesystem root"; no transport call, no runtime tool and no rm,
#         chmod, chown, mv or find is run. "/share/example-root/" still makes
#         its one `run`. (Apple refuses every establish as unsupported.)
#     C3. dx_persist_start_decision: a probe report whose root= line names
#         the filesystem root ("root=/", "root=//": a configured root that is
#         a symlink to /) is refuse:root, whatever the state and marker, as
#         dx_persist_migrate_decide already refuses it (WP6.4b).
#
#  D. The left copy/verify container refusal (dx_persist_copy_containers_none
#     COMMAND in bin/lib/dx-persist-dir.sh; WP6.4c). Docker refuses
#     `docker rm` of a paused container, and of one it is already removing:
#       - "<name> paused": status 1, nothing on stdout, exactly one stderr
#         line starting "Error:", holding <name>, "paused",
#         "docker unpause <name>" (it then finishes), "docker stop <name>",
#         "earlier migration or rollback", COMMAND (to run again) and
#         "Nothing was changed."; never "docker rm";
#       - "<name> removing" (Docker removes every copy and verify container
#         when it ends, since they run with --rm): status 1, exactly one
#         Error line holding <name>, "removing", "wait", COMMAND and "Nothing
#         was changed."; never "docker rm".
#     In both, the only runtime calls are the two `ps -a` queries (nothing is
#     unpaused, stopped or removed by the tooling). Running, created, exited
#     and dead keep their WP6.4c wording (tests/test_persist_copy_resume.sh,
#     whose "any other state" now means any state but these two).
#
#  E. docs/qnap-runbook.md: pinned by the amendment to
#     tests/test_persist_runbook_docs.sh (11.4's first bullet points to the
#     left-container bullet; 11.2 gains the inode check of the NAS Docker data
#     root and the rsync 3.1.3 floor).
#
#  F. Stdin hygiene (dx_ssh_probe_login_shell in bin/lib/dx-ssh-common.sh,
#     the readiness probe of bin/dx-wait-ssh and bin/dx-status): its ssh
#     reads /dev/null, never the caller's stdin, as WP-T1 made the docker
#     adapter's own probes do. A caller with pending stdin still reads it
#     after the probe, and the probe's ssh received none of it; the probe
#     still makes its one ssh call with "BatchMode=yes" and "bash -lc 'true'"
#     and returns ssh's status.

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
# shellcheck source=../bin/lib/dx-ssh-common.sh
source "$BASE_DIR/bin/lib/dx-ssh-common.sh"

test_section "WP6.7: follow-up hardening"

SCRATCH="$(persist_fixture_root_create)"
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT

# Every runtime tool refuses and records: nothing here may reach a host.
BIN="$(fake_tool_dir_create "$SCRATCH")"
TOOL_LOG="$SCRATCH/tool-calls"
for t in ssh scp sftp docker container tailscale; do
    fake_tool_write "$BIN" "$t" "echo \"$t \$*\" >> '$TOOL_LOG'; exit 99"
done
PATH="$BIN:$PATH"
export PATH

# Recording stubs for every destructive command, put in front of PATH for
# each call that hands the filesystem root to a guard.
GUARD="$(fake_tool_dir_create "$SCRATCH")"
GUARD_LOG="$SCRATCH/guard-calls"
for t in ssh scp sftp docker container tailscale rm chmod chown mv find; do
    fake_tool_write "$GUARD" "$t" "echo \"$t \$*\" >> '$GUARD_LOG'; exit 97"
done

DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-fix
DX_GUEST_SYSTEM=x86_64-linux DX_IMAGE=dxe-followup-image:1
DX_NIX_VOLUME=dx-fix-nix DX_PERSIST_VOLUME=dx-fix-persist
DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/fixture/share
DX_PERSIST_HOST_MOUNT_SENTINEL=dxe-share-mounted DXE_RUNTIME_DOCKER_BIN=docker
XDG_STATE_HOME="$SCRATCH/state"
export DX_RUNTIME DX_REMOTE_HOST DX_CONTAINER_NAME DX_GUEST_SYSTEM DX_IMAGE DX_NIX_VOLUME
export DX_PERSIST_VOLUME DX_PERSIST_STORAGE DX_PERSIST_HOST_ROOT DX_PERSIST_HOST_MOUNT_SENTINEL
export DXE_RUNTIME_DOCKER_BIN XDG_STATE_HOME
unset DX_BOOTSTRAP_VOLUME DX_PERSIST_FRESH_START DXE_RUNTIME_GUEST_SSH_ADDRESS
PROFILE_ID="dxe-fixture-nas.invalid__dx-fix"

# The docker-ssh transport, recorded in-process: every docker call the
# adapter makes ends here (one line per call in T_LOG). It answers the nix
# volume's DQ6 inspect with this profile's labels (any other volume is
# absent), a `run` with T_RUN_OUT and T_RUN_RC (draining stdin for `run -i`),
# and the copy/verify `ps -a` queries with T_PS_COPY / T_PS_VERIFY (nothing
# when empty).
T_LOG="$SCRATCH/transport-calls"
T_RUN_OUT="" T_RUN_RC=0 T_PS_COPY="" T_PS_VERIFY=""
: >"$T_LOG"
dx_runtime_docker_ssh_exec() {
    local IFS=' ' a last="" filter=""
    printf '%s\n' "$*" >>"$T_LOG"
    for a in "$@"; do
        case "$a" in name=*) filter="$a" ;; esac
        last="$a"
    done
    case "${2:-} ${3:-}" in
        "volume inspect")
            if [ "$last" = "$DX_NIX_VOLUME" ]; then
                printf 'true|1|%s|nix|%s\n' "$PROFILE_ID" "$DX_GUEST_SYSTEM"
                return 0
            fi
            echo "Error: No such volume: $last" >&2
            return 1 ;;
    esac
    case "${2:-}" in
        run)
            case " $* " in *" -i "*) cat >/dev/null ;; esac
            if [ -n "$T_RUN_OUT" ]; then printf '%s\n' "$T_RUN_OUT"; fi
            return "$T_RUN_RC" ;;
        ps)
            case "$filter" in
                *dxe-persist-copy-*) if [ -n "$T_PS_COPY" ]; then printf '%s\n' "$T_PS_COPY"; fi ;;
                *dxe-persist-verify-*) if [ -n "$T_PS_VERIFY" ]; then printf '%s\n' "$T_PS_VERIFY"; fi ;;
            esac
            return 0 ;;
    esac
    echo "transport recorder: unexpected call: $*" >&2
    return 98
}

has() { grep -Fq -- "$2" <<<"$1"; }
error_count() { awk 'index($0, "Error:") == 1 { n++ } END { print n + 0 }' <<<"$1"; }
line_count() { awk 'END { print NR }' <<<"$1"; }
# pos_of TEXT NEEDLE: 1-based position of NEEDLE's first occurrence in the
# one-line TEXT, 0 when it is absent.
pos_of() { awk -v n="$2" 'BEGIN { p = 0 } p == 0 { i = index($0, n); if (i) p = i } END { print p }' <<<"$1"; }
verdict() { # LABEL WHY: pass when WHY is empty
    if [ -z "$2" ]; then test_pass "$1"; else test_fail "$1:$2"; fi
}
file_text() { if [ -f "$1" ]; then cat "$1"; fi; }
# calls_of FILE: the recorded calls, each cut to its first 100 characters, on one line.
calls_of() { if [ -f "$1" ]; then cut -c1-100 "$1" | tr "\n" "|"; fi; }

# =============================================================================
test_section "WP6.7 A: the refusal for a non-empty unmarked directory gives guidance that works"

# a_run VOLUME RECORD FN: FN (dx_persist_host_dir_decide or
# dx_persist_start_check) on a probe that finds a non-empty directory with no
# marker; VOLUME (yes|no) is whether the persist volume exists, RECORD
# (yes|no) whether the D-7 record does. Sets A_RC, A_OUT, A_ERR.
a_run() {
    local volume="$1" record="$2" fn="$3"
    A_OUT="$(
        XDG_STATE_HOME="$SCRATCH/state-a-$volume-$record"
        if [ "$record" = yes ]; then
            mkdir -p "$XDG_STATE_HOME/dxe/persist-dirs" && : >"$XDG_STATE_HOME/dxe/persist-dirs/$PROFILE_ID"
        fi
        dx_runtime_host_dir_probe() { printf 'root=/fixture/share\nmounted=yes\nstate=nonempty\nmarker=absent\n'; }
        dx_runtime_volume_state() { if [ "$volume" = yes ]; then echo present; else echo absent; fi; }
        "$fn" 2>"$SCRATCH/a.err"
    )"
    A_RC=$?
    A_ERR="$(file_text "$SCRATCH/a.err")"
}
a_check() { # LABEL
    local why="" line k at_move at
    line="$(grep '^Error:' <<<"$A_ERR" | head -n 1)"
    [ "$A_RC" = 1 ] || why="$why status $A_RC;"
    [ -z "$A_OUT" ] || why="$why stdout [$A_OUT];"
    [ "$(error_count "$A_ERR")" = 1 ] || why="$why $(error_count "$A_ERR") Error lines;"
    for k in "is not empty and has no .dxe-persist-dir marker" "move it aside" "start fresh" \
        "dx-create-volumes" "dx-persist-migrate"; do
        has "$line" "$k" || why="$why no [$k];"
    done
    if has "$line" "import it"; then why="$why still says [import it];"; fi
    at_move="$(pos_of "$line" "move it aside")"
    for k in "start fresh" "dx-create-volumes" "dx-persist-migrate"; do
        at="$(pos_of "$line" "$k")"
        if [ "$at_move" -eq 0 ] || [ "$at" -eq 0 ] || [ "$at" -lt "$at_move" ]; then
            why="$why [$k] does not come after [move it aside];"
        fi
    done
    verdict "$1" "${why:+$why (stderr: $A_ERR)}"
}
for volume in no yes; do
    for record in no yes; do
        a_run "$volume" "$record" dx_persist_host_dir_decide
        a_check "dx-create-volumes' decision (persist volume: $volume, record: $record): move it aside, then start fresh or migrate -- never 'import it'"
    done
done
a_run yes no dx_persist_start_check
a_check "dx-start-container's check (persist volume: yes): the same guidance"

# =============================================================================
test_section "WP6.7 B: rsync below 3.1.3 is refused (--modify-window=-1 compares nanoseconds from 3.1.3)"

CAPS_FULL='64-bit files, socketpairs, symlinks, symtimes, hardlinks, hardlink-specials, hardlink-symlinks, IPv6, batchfiles, inplace, append, ACLs, xattrs, iconv, prealloc'
caps_of() { # VERSION: a canned `rsync --version` with every capability
    printf 'rsync  version %s  protocol version 31\nCopyright (C) 1996-2024 by Andrew Tridgell, Wayne Davison, and others.\n\nCapabilities:\n    %s\nOptimizations:\n    SIMD-roll, no asm-roll\n\nrsync comes with ABSOLUTELY NO WARRANTY.\n' "$1" "$CAPS_FULL"
}
b_run() { # VERSION: rsync_check -A -X against that output; sets B_RC B_OUT B_ERR
    : >"$T_LOG"
    T_RUN_OUT="$(caps_of "$1")"
    T_RUN_RC=0
    B_OUT="$(dx_runtime_host_rsync_check -A -X 2>"$SCRATCH/b.err")"
    B_RC=$?
    B_ERR="$(file_text "$SCRATCH/b.err")"
}
for v in 3.1.2 3.1.0 3.1 3.0.9; do
    b_run "$v"
    why=""
    [ "$B_RC" != 0 ] || why="$why accepted (status 0: $B_OUT);"
    [ -z "$B_OUT" ] || [ "$B_RC" = 0 ] || why="$why stdout [$B_OUT];"
    [ "$(error_count "$B_ERR")" = 1 ] || why="$why $(error_count "$B_ERR") Error lines;"
    has "$(grep '^Error:' <<<"$B_ERR")" "$v" || why="$why the Error line does not name $v;"
    has "$(grep '^Error:' <<<"$B_ERR")" "below 3.1.3" || why="$why no [below 3.1.3];"
    verdict "rsync $v is refused as below 3.1.3, with one Error line naming the version" "${why:+$why (stderr: $B_ERR)}"
done
why=""
b_run 3.1.2
[ "$B_RC" != 0 ] || why="$why 3.1.2 accepted;"
for v in 3.1.3 3.1.10 3.2 3.2.0 3.4.1; do
    b_run "$v"
    if [ "$B_RC" != 0 ] || [ "$(sed -n 1p <<<"$B_OUT")" != "version=$v" ] || [ "$(line_count "$B_OUT")" != 4 ] || [ -n "$B_ERR" ]; then
        why="$why $v not accepted (status $B_RC, stdout [$B_OUT], stderr [$B_ERR]);"
    fi
done
verdict "the floor is exactly 3.1.3, compared by (major, minor, patch): 3.1.2 refused; 3.1.3, 3.1.10, 3.2, 3.2.0 and 3.4.1 accepted" "$why"

# =============================================================================
test_section "WP6.7 C1: the configuration refuses a share root that names the filesystem root"

ROOT_MSG="DX_PERSIST_HOST_ROOT must not be the filesystem root"
cross() { # VAR=value...: dx_config_validate_cross_fields on a valid docker-ssh host-path baseline; prints its stderr
    (
        DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_NIX_STORAGE_MODE=direct-volume
        DX_NIX_VOLUME=n DX_PERSIST_VOLUME=p DX_BOOTSTRAP_VOLUME=b
        DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/share/example-root
        export DX_RUNTIME DX_REMOTE_HOST DX_NIX_STORAGE_MODE DX_NIX_VOLUME DX_PERSIST_VOLUME DX_BOOTSTRAP_VOLUME
        export DX_PERSIST_STORAGE DX_PERSIST_HOST_ROOT
        local kv rc
        for kv in "$@"; do
            case "$kv" in *=*) printf -v "${kv%%=*}" '%s' "${kv#*=}" ;; esac
        done
        PATH="$GUARD:$PATH"
        dx_config_validate_cross_fields >/dev/null 2>"$SCRATCH/cross.err"
        rc=$?
        cat "$SCRATCH/cross.err"
        exit "$rc"
    )
}
for root in / // /. /./ /..; do
    : >"$GUARD_LOG"
    out="$(cross "DX_PERSIST_HOST_ROOT=$root")"
    rc=$?
    why=""
    [ "$rc" = 1 ] || why="$why status $rc;"
    [ "$(line_count "$out")" = 1 ] && [ "$(error_count "$out")" = 1 ] || why="$why not exactly one Error line;"
    has "$out" "$ROOT_MSG" || why="$why no [$ROOT_MSG];"
    for k in "is required" "must not contain ':'" "docs/guest.md"; do
        if has "$out" "$k"; then why="$why another rule's [$k];"; fi
    done
    vol="$(cross DX_PERSIST_STORAGE=volume "DX_PERSIST_HOST_ROOT=$root")"
    vrc=$?
    [ "$vrc" = 0 ] && [ -z "$vol" ] || why="$why volume mode no longer ignores it (status $vrc: $vol);"
    trail="$(cross DX_PERSIST_HOST_ROOT=/share/example-root/)"
    trc=$?
    [ "$trc" = 0 ] && [ -z "$trail" ] || why="$why /share/example-root/ is refused (status $trc: $trail);"
    [ ! -s "$GUARD_LOG" ] || why="$why a command ran: $(cat "$GUARD_LOG");"
    verdict "host-path with DX_PERSIST_HOST_ROOT=$root is refused with its own Error line (volume mode still ignores it)" "${why:+$why (stderr: $out)}"
done

# bin/dx-profile: the user-facing path. The command after the profile is a
# recorder; it must not run.
PROFILES="$SCRATCH/profiles"
mkdir -p "$PROFILES" "$SCRATCH/home"
write_profile() { # NAME ROOT
    printf '%s\n' 'export DX_RUNTIME=docker-ssh' 'export DX_REMOTE_HOST=dxe-fixture-nas.invalid' \
        'export DX_GUEST_SYSTEM=x86_64-linux' 'export DX_NIX_STORAGE_MODE=direct-volume' \
        'export DX_PERSIST_STORAGE=host-path' "export DX_PERSIST_HOST_ROOT=$2" >"$PROFILES/$1.env"
}
RAN="$SCRATCH/profile-command-ran"
fake_tool_write "$BIN" dxe-followup-command "echo \"\$DX_PERSIST_HOST_ROOT\" >> '$RAN'"
profile_run() { # NAME
    env -i HOME="$SCRATCH/home" PATH="$GUARD:$BIN:/usr/bin:/bin" DX_PROFILES_DIR="$PROFILES" \
        "$BASE_DIR/bin/dx-profile" "$1" "$BIN/dxe-followup-command" 2>&1
}
write_profile fs-root /
write_profile ok-root /share/example-root
: >"$GUARD_LOG"
out="$(profile_run fs-root)"
rc=$?
ran_fs="$(file_text "$RAN")"
: >"$RAN"
out_ok="$(profile_run ok-root)"
rc_ok=$?
why=""
[ "$rc" != 0 ] || why="$why status 0;"
has "$out" "$ROOT_MSG" || why="$why no [$ROOT_MSG];"
[ -z "$ran_fs" ] || why="$why the command ran with DX_PERSIST_HOST_ROOT=$ran_fs;"
[ "$rc_ok" = 0 ] && [ "$(file_text "$RAN")" = /share/example-root ] || why="$why the control profile did not run its command (status $rc_ok: $out_ok);"
[ ! -s "$GUARD_LOG" ] || why="$why a command ran: $(cat "$GUARD_LOG");"
verdict "bin/dx-profile refuses a profile whose DX_PERSIST_HOST_ROOT is / and runs nothing" "${why:+$why (output: $out)}"

# =============================================================================
test_section "WP6.7 C2: establish refuses the filesystem root before any runtime call"

MARKER_READY="$(dx_persist_marker_format dx-fix ready "" 2026-10-12T00:00:00Z)"
c_establish() { # MODE ROOT: sets C_RC C_OUT C_ERR (the destructive commands stubbed)
    : >"$T_LOG"
    : >"$GUARD_LOG"
    : >"$TOOL_LOG"
    T_RUN_OUT=""
    T_RUN_RC=0
    C_OUT="$(
        PATH="$GUARD:$PATH"
        dx_runtime_host_dir_establish "$1" "$2" dx-fix 30033:30001 "$MARKER_READY" 2>"$SCRATCH/c.err"
    )"
    C_RC=$?
    C_ERR="$(file_text "$SCRATCH/c.err")"
}
c_refused() { # MODE ROOT
    local why=""
    c_establish "$1" "$2"
    [ "$C_RC" != 0 ] || why="$why status 0;"
    [ -z "$C_OUT" ] || why="$why stdout [$C_OUT];"
    has "$C_ERR" "refusing to establish the NAS directory" || why="$why no [refusing to establish the NAS directory];"
    has "$C_ERR" "filesystem root" || why="$why no [filesystem root];"
    [ ! -s "$T_LOG" ] || why="$why transport calls: $(calls_of "$T_LOG");"
    [ ! -s "$GUARD_LOG" ] || why="$why commands run: $(calls_of "$GUARD_LOG");"
    [ ! -s "$TOOL_LOG" ] || why="$why runtime tools run: $(calls_of "$TOOL_LOG");"
    if [ "$1:$2" = create:/ ]; then
        # The control: an ordinary root with a trailing slash still reaches its one run.
        c_establish create /share/example-root/
        if [ "$C_RC" != 0 ] || [ "$(line_count "$(cat "$T_LOG")")" != 1 ] || ! grep -q '^docker run --rm -i ' "$T_LOG"; then
            why="$why /share/example-root/ did not make exactly its one run (status $C_RC: $(calls_of "$T_LOG") $C_ERR);"
        fi
        c_establish "$1" "$2"
    fi
    verdict "establish $1 with ROOT $2 is refused before any call or command" "${why:+$why (stderr: $C_ERR)}"
}
for mode in create adopt fresh-start; do
    c_refused "$mode" /
done
for root in // /. /..; do
    c_refused create "$root"
done

# =============================================================================
test_section "WP6.7 C3: the start decision refuses a canonical root of /"

c_decide() { # ROOT REPORT-TAIL: the decision token for a report with that root=
    (
        PATH="$GUARD:$PATH"
        printf 'root=%s\nmounted=yes\n%s' "$1" "$2" | dx_persist_start_decision dx-fix no no "" 2>/dev/null
    )
}
READY_TAIL="$(printf 'state=nonempty\nmarker=present\n%s' "$MARKER_READY")"
for root in / //; do
    : >"$GUARD_LOG"
    why=""
    for tail in "$(printf 'state=absent\nmarker=absent')" "$(printf 'state=empty\nmarker=absent')" "$READY_TAIL"; do
        got="$(c_decide "$root" "$tail")"
        [ "$got" = refuse:root ] || why="$why [$(sed -n 1p <<<"$tail")] -> [$got];"
    done
    # The control: the same reports under an ordinary root keep their tokens.
    ctl="$(c_decide /fixture/share "$(printf 'state=absent\nmarker=absent')")|$(c_decide /fixture/share "$(printf 'state=empty\nmarker=absent')")|$(c_decide /fixture/share "$READY_TAIL")"
    [ "$ctl" = "create|adopt|ok" ] || why="$why the ordinary root gave [$ctl];"
    [ ! -s "$GUARD_LOG" ] || why="$why commands run: $(calls_of "$GUARD_LOG");"
    verdict "a probe report with root=$root is refuse:root, whatever the directory's state" "$why"
done

# =============================================================================
test_section "WP6.7 D: a paused or removing copy/verify container is never to be docker rm'd"

COPY="dxe-persist-copy-$PROFILE_ID"
VERIFY="dxe-persist-verify-$PROFILE_ID"
d_run() { # COPY_STATE VERIFY_STATE COMMAND: sets D_RC D_OUT D_ERR D_LINE D_CALLS
    : >"$T_LOG"
    T_PS_COPY="$1"
    T_PS_VERIFY="$2"
    D_OUT="$(dx_persist_copy_containers_none "$3" 2>"$SCRATCH/d.err")"
    D_RC=$?
    D_ERR="$(file_text "$SCRATCH/d.err")"
    D_LINE="$(grep '^Error:' <<<"$D_ERR" | head -n 1)"
    D_CALLS="$(cat "$T_LOG")"
}
# The two ps queries and nothing else.
d_only_ps() {
    [ "$(line_count "$D_CALLS")" = 2 ] && [ "$(grep -c '^docker ps -a ' <<<"$D_CALLS")" = 2 ]
}
d_paused() { # NAME COMMAND
    local why="" k
    [ "$D_RC" = 1 ] || why="$why status $D_RC;"
    [ -z "$D_OUT" ] || why="$why stdout [$D_OUT];"
    [ "$(error_count "$D_ERR")" = 1 ] || why="$why $(error_count "$D_ERR") Error lines;"
    for k in "$1" paused "docker unpause $1" "docker stop $1" "earlier migration or rollback" "$2" "Nothing was changed."; do
        has "$D_LINE" "$k" || why="$why no [$k];"
    done
    verdict "$2, $1 paused: one Error line -- docker unpause it (it then finishes) or docker stop it, then run $2 again" "${why:+$why (stderr: $D_ERR)}"
    why=""
    if has "$D_ERR" "docker rm"; then why="$why says [docker rm];"; fi
    d_only_ps || why="$why calls: $(tr '\n' '|' <<<"$D_CALLS");"
    verdict "$2, $1 paused: never told to docker rm it (Docker refuses that), and nothing but the two ps queries" "${why:+$why (stderr: $D_ERR)}"
}
d_removing() { # NAME COMMAND
    local why="" k
    [ "$D_RC" = 1 ] || why="$why status $D_RC;"
    [ -z "$D_OUT" ] || why="$why stdout [$D_OUT];"
    [ "$(error_count "$D_ERR")" = 1 ] || why="$why $(error_count "$D_ERR") Error lines;"
    for k in "$1" removing wait "$2" "Nothing was changed."; do
        has "$D_LINE" "$k" || why="$why no [$k];"
    done
    if has "$D_ERR" "docker rm"; then why="$why says [docker rm];"; fi
    d_only_ps || why="$why calls: $(tr '\n' '|' <<<"$D_CALLS");"
    verdict "$2, $1 being removed: one Error line -- wait until Docker has removed it, then run $2 again (never docker rm)" "${why:+$why (stderr: $D_ERR)}"
}
d_run paused "" dx-persist-migrate
d_paused "$COPY" dx-persist-migrate
d_run "" paused dx-persist-rollback
d_paused "$VERIFY" dx-persist-rollback
d_run removing "" dx-persist-rollback
d_removing "$COPY" dx-persist-rollback
d_run "" removing dx-persist-migrate
d_removing "$VERIFY" dx-persist-migrate

# =============================================================================
test_section "WP6.7 F: the SSH login-shell probe never reads the caller's stdin"

F_DIR="$SCRATCH/f"
mkdir -p "$F_DIR"
F_BIN="$(fake_tool_dir_create "$SCRATCH")"
# A recording ssh: its argv, one word per line, and every byte of its stdin.
fake_tool_write "$F_BIN" ssh "printf '%s\n' \"\$@\" > '$F_DIR/argv'; cat > '$F_DIR/stdin'; exit 0"
: >"$SCRATCH/f-key"
F_RESULT="$(
    PATH="$F_BIN:$PATH"
    DX_RUNTIME=apple DX_REMOTE_HOST="" DX_SSH_KEY="$SCRATCH/f-key" DX_SSH_PORT=2222 DX_SSH_CONNECT_TIMEOUT=1
    export DX_RUNTIME DX_REMOTE_HOST DX_SSH_KEY DX_SSH_PORT DX_SSH_CONNECT_TIMEOUT
    {
        dx_ssh_probe_login_shell "$F_DIR/probe.err"
        rc=$?
        rest=""
        IFS= read -r rest || :
        printf 'rc=%s\nrest=%s\n' "$rc" "$rest"
    } <<<"pending-line"
)"
why=""
f_stdin="$(file_text "$F_DIR/stdin")"
[ -f "$F_DIR/argv" ] || why="$why ssh was not run;"
[ -z "$f_stdin" ] || why="$why its ssh read [$f_stdin] from the caller's stdin;"
grep -Fqx BatchMode=yes "$F_DIR/argv" 2>/dev/null || why="$why no BatchMode=yes;"
[ "$(tail -n 1 "$F_DIR/argv" 2>/dev/null)" = "bash -lc 'true'" ] || why="$why the command is not [bash -lc 'true'];"
has "$F_RESULT" "rc=0" || why="$why ssh's status was not passed through ($F_RESULT);"
verdict "the probe's ssh reads /dev/null, not the caller's stdin (one call, BatchMode=yes, bash -lc 'true')" "$why"
if grep -Fqx "rest=pending-line" <<<"$F_RESULT"; then
    test_pass "a caller's pending stdin is still there after the probe"
else
    test_fail "a caller's pending stdin is still there after the probe (got: $(tr '\n' '|' <<<"$F_RESULT"))"
fi

print_summary
exit_with_code
