#!/bin/bash
# tests/qnap/phase1-persist-inspect.sh
#
# Spec section 9 "QNAP inspection (W2)", checks Q-1 .. Q-10, for the
# /persist host-access plan (plan WP2.1). Versioned, non-interactive,
# idempotent. Read-only on the NAS unless --write-probe is given.
#
# Usage: tests/qnap/phase1-persist-inspect.sh [--write-probe] [--report FILE] [--help]
#
# Environment:
#   DXE_QNAP_HOST                 ssh_config alias for the QNAP (default: qnap-dxe)
#   DXE_QNAP_DOCKER               absolute docker path ON THE NAS (discovered if unset)
#   DXE_QNAP_SHARE_ROOT           REQUIRED: the candidate share path on the NAS
#   DXE_QNAP_PERSIST_VOLUME       volume to inspect (default: dx-qnap-persist)
#   DXE_QNAP_PROBE_IMAGE          image for the write probe (default: the
#                                 spike's pinned base image, tag only)
#   DXE_QNAP_SSH_CONNECT_TIMEOUT  seconds (default: 10)
#
# Output: exactly ten lines `Q-<n> | <ok|fail|manual|unknown> | <evidence>`
# on stdout and in the report file (default
# $HOME/dxe-recovery/qnap/phase1-persist-inspect-<UTC date>.md, overwritten
# on a re-run). Q-3, Q-5, Q-6 and Q-7 are manual. Exit 0 when no check is
# `fail`, else 1. The report is private (the NAS is a production system and
# this repository is public): it is never written inside the repository.
#
# Write probe (Q-10 only, --write-probe): ONE `docker run` of a one-off
# container named dxe-spike-* and labelled dxe.role=spike, bind-mounting
# only the share root. Inside it: mkdir <root>/.dxe-spike-<random> (directly
# in the share root; <root>/dxe is never needed), chown 30033:30033, and a
# 0700 mkdir as root, each VERIFIED by reading the owner and mode back with
# `stat -c '%u:%g %a'` (a chown that exits 0 but changes nothing, a
# root-squashed create or an ignored mode is a fail, reported with its
# observed= value), then removal of that one directory. Every write operand
# is that .dxe-spike-* path. The removal is unconditional and the container
# is --rm. If the ssh connection is cut mid-probe, remove a leftover
# <root>/.dxe-spike-* directory by hand.
#
# Every remote command is POSIX sh (the QNAP shell is busybox sh, and the
# probe runs sh inside an image): no pipefail, no bashisms. A find in a
# count pipeline reports its own exit status as a trailing find-rc=<n> line.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/phase0-common.sh
source "$SCRIPT_DIR/lib/phase0-common.sh"

WRITE_PROBE=0
REPORT_PATH=""

usage() {
    echo "Usage: $(basename "$0") [--write-probe] [--report FILE] [--help]" >&2
    echo "Requires DXE_QNAP_SHARE_ROOT (candidate share path on the NAS)." >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --write-probe) WRITE_PROBE=1; shift ;;
        --report) [ "$#" -ge 2 ] || { echo "Error: --report requires FILE." >&2; exit 2; }; REPORT_PATH="$2"; shift 2 ;;
        --report=*) REPORT_PATH="${1#*=}"; shift ;;
        --help) usage; exit 0 ;;
        *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

SHARE_ROOT="${DXE_QNAP_SHARE_ROOT:-}"
if [ -z "$SHARE_ROOT" ]; then
    echo "Error: DXE_QNAP_SHARE_ROOT is required (the candidate share path on the NAS)." >&2
    usage
    exit 2
fi
VOLUME="${DXE_QNAP_PERSIST_VOLUME:-dx-qnap-persist}"
[ -n "$REPORT_PATH" ] || REPORT_PATH="$(dxe_qnap_private_dir)/phase1-persist-inspect-$(dxe_qnap_utc_date).md"

# --- helpers ----------------------------------------------------------------

# rq <path>: the string as one remote-shell word. Plain paths stay as they
# are; anything else is single-quoted (embedded quotes escaped).
rq() {
    case "$1" in
        '' | *[!A-Za-z0-9_./:@%+=,-]*)
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s' "$1" ;;
    esac
}

# remote <command string>: one ssh call; sets R_OUT (stdout) and R_RC.
R_OUT=""
R_RC=0
remote() {
    R_OUT="$(dxe_qnap_ssh_raw "$1" 2>/dev/null)"
    R_RC=$?
}

# int <text>: a trimmed non-negative integer, else n/a.
int() {
    local v
    v="$(printf '%s' "$1" | tr -d '[:space:]')"
    case "$v" in
        '' | *[!0-9]*) printf 'n/a' ;;
        *) printf '%s' "$v" ;;
    esac
}

# one-line, pipe-free evidence text
oneline() { printf '%s' "$1" | tr '\n\t' '  ' | sed -e 's/ [|] / \/ /g' -e 's/  */ /g' -e 's/^ //' -e 's/ $//'; }

QS=("" "" "" "" "" "" "" "" "" "" "")
QE=("" "" "" "" "" "" "" "" "" "" "")
set_q() { QS[$1]="$2"; QE[$1]="$(oneline "$3")"; }
for n in 3 5 6 7; do QS[$n]=manual; done
QE[3]="manual: who can open the share (including guest access)"
QE[5]="manual: how 30033-owned and root-only files look in Finder and the NAS UI"
QE[6]="manual: SMB, NFS and file-station access paths to the share"
QE[7]="manual: confirm the plan's mount and Finder behaviour on the Mac"

# df_fields <df -P output>: sets DF_FS and DF_MOUNT from the data row.
DF_FS=""
DF_MOUNT=""
df_fields() {
    local row
    row="$(printf '%s\n' "$1" | tail -n1)"
    DF_FS="$(printf '%s' "$row" | awk '{print $1}')"
    DF_MOUNT="$(printf '%s' "$row" | awk '{print $NF}')"
}

# The probe's default image: the spike's pinned base image, tag only (the
# NAS pulls by tag), falling back to the pinned nixos/nix release.
dxe_qnap_probe_image_default() {
    local ref
    ref="$(sed -n 's/^FROM //p' "$BASE_DIR/container/dx-nixos-26.05/Containerfile" 2>/dev/null | head -n1 | sed 's/@sha256:[0-9a-f]*$//')"
    printf '%s' "${ref:-nixos/nix:2.34.8}"
}

# --- preflight --------------------------------------------------------------

dxe_qnap_require_reachable || exit 1

DOCKER="${DXE_QNAP_DOCKER:-}"
if [ -z "$DOCKER" ]; then
    DOCKER="$(dxe_qnap_ssh_raw "$(dxe_qnap_docker_discovery_remote_script)" 2>/dev/null | tail -n1)"
    case "$DOCKER" in
        '' | NOTFOUND) DOCKER="" ;;
    esac
fi
if [ -n "$DOCKER" ]; then DOCKER="$(rq "$DOCKER")"; fi

# --- Q-1: the share, its canonical path and pool ------------------------------

SHARE_Q="$(rq "$SHARE_ROOT")"
remote "readlink -f $SHARE_Q"
q1_canon="$(printf '%s' "$R_OUT" | tail -n1)"
q1_rc=$R_RC
remote "df -P $SHARE_Q"
q1_df_rc=$R_RC
df_fields "$R_OUT"
if [ "$q1_rc" -eq 0 ] && [ "$q1_df_rc" -eq 0 ]; then q1_st=ok; else q1_st=fail; fi
set_q 1 "$q1_st" "canonical=${q1_canon:-n/a} fs=${DF_FS:-n/a} mount=${DF_MOUNT:-n/a} given=$SHARE_ROOT"

# --- Q-2: the volume's mountpoint and pool -------------------------------------

MOUNTPOINT=""
if [ -z "$DOCKER" ]; then
    set_q 2 fail "mountpoint=n/a fs=n/a mount=n/a (docker CLI not found on the NAS)"
else
    remote "$DOCKER volume inspect --format '{{.Mountpoint}}' $(rq "$VOLUME")"
    if [ "$R_RC" -eq 0 ]; then MOUNTPOINT="$(printf '%s' "$R_OUT" | head -n1)"; fi
    if [ -n "$MOUNTPOINT" ]; then
        remote "df -P $(rq "$MOUNTPOINT")"
        df_rc=$R_RC
        df_fields "$R_OUT"
        if [ "$df_rc" -eq 0 ]; then q2_st=ok; else q2_st=fail; fi
        set_q 2 "$q2_st" "mountpoint=$MOUNTPOINT fs=${DF_FS:-n/a} mount=${DF_MOUNT:-n/a} volume=$VOLUME"
    else
        set_q 2 fail "mountpoint=n/a fs=n/a mount=n/a (docker volume inspect $VOLUME failed)"
    fi
fi

# --- Q-4: Container Station's docker root --------------------------------------

if [ -z "$DOCKER" ]; then
    set_q 4 fail "DockerRootDir=n/a (docker CLI not found on the NAS)"
else
    remote "$DOCKER info --format '{{.DockerRootDir}}'"
    q4_root="$(printf '%s\n' "$R_OUT" | grep . | tail -n1)"
    if [ "$R_RC" -eq 0 ] && [ -n "$q4_root" ]; then q4_st=ok; else q4_st=fail; fi
    set_q 4 "$q4_st" "DockerRootDir=${q4_root:-n/a}"
fi

# --- Q-9 input needed by Q-8: the remote uid ------------------------------------

remote "id -u"
uid_rc=$R_RC
uid="$(printf '%s' "$R_OUT" | head -n1)"

# --- Q-8: size and contents of the volume ----------------------------------------

if [ -z "$MOUNTPOINT" ]; then
    set_q 8 fail "size_kb=n/a entries=n/a hardlinks=n/a appledouble=n/a special=n/a acl=n/a xattr=n/a (no volume mountpoint)"
else
    MP="$(rq "$MOUNTPOINT")"
    q8_st=ok
    q8_partial=""
    # count <label> <remote command>: sets COUNT; a failed command fails Q-8.
    count() {
        remote "$2"
        if [ "$R_RC" -ne 0 ]; then q8_st=fail; fi
        COUNT="$(int "$R_OUT")"
    }
    # find_rc <output>: splits the trailing find-rc=<n> status line off a
    # find group's output; sets FIND_RC (0 if absent) and FIND_OUT.
    find_rc() {
        FIND_RC="$(printf '%s\n' "$1" | sed -n 's/^find-rc=\([0-9]*\)$/\1/p' | tail -n1)"
        FIND_RC="${FIND_RC:-0}"
        FIND_OUT="$(printf '%s\n' "$1" | sed '/^find-rc=[0-9]*$/d')"
    }
    # find_failed <label>: Q-8 fails and is marked partial.
    find_failed() {
        q8_st=fail
        q8_partial="${q8_partial:+$q8_partial,}$1"
    }
    # fcount <label> <find arguments>: sets COUNT to the number of lines
    # find printed, or n/a (and marks Q-8 partial) when find exited non-zero.
    fcount() {
        remote "{ find $MP $2; echo \"find-rc=\$?\"; } | awk '/^find-rc=/{rc=substr(\$0,9);next}{n++}END{print n+0, rc+0}'"
        COUNT="$(int "$(printf '%s' "$R_OUT" | awk '{print $1; exit}')")"
        FIND_RC="$(printf '%s' "$R_OUT" | awk '{print $2; exit}')"
        if [ "$R_RC" -ne 0 ] || [ "$COUNT" = "n/a" ] || [ "${FIND_RC:-0}" != 0 ]; then
            find_failed "$1"
            COUNT="n/a"
        fi
    }
    remote "du -sk $MP"
    if [ "$R_RC" -ne 0 ]; then q8_st=fail; fi
    size_kb="$(int "$(printf '%s' "$R_OUT" | awk '{print $1; exit}')")"
    fcount entries ""; entries="$COUNT"
    fcount hardlinks "-type f -links +1"; hardlinks="$COUNT"
    remote "{ find $MP -name '._*'; echo \"find-rc=\$?\"; }"
    find_rc "$R_OUT"
    apple_out="$FIND_OUT"
    apple_paths=""
    if [ "$R_RC" -ne 0 ] || [ "$FIND_RC" != 0 ]; then
        find_failed appledouble
        appledouble="n/a"
    else
        appledouble="$(printf '%s\n' "$apple_out" | grep -c .)"
        apple_paths="$(printf '%s\n' "$apple_out" | grep . | head -n 20 | tr '\n' ' ')"
        if [ "$appledouble" -gt 20 ]; then apple_paths="$apple_paths(+$((appledouble - 20)) more)"; fi
    fi
    fcount special "-type s -o -type p -o -type b -o -type c"; special="$COUNT"
    # A missing getfacl/getfattr on the NAS is reported as n/a, not a failure.
    count acl "if command -v getfacl >/dev/null 2>&1; then getfacl -R -s -p $MP 2>/dev/null | grep -c '^# file:' || true; else echo n/a; fi"; acl="$COUNT"
    count xattr "if command -v getfattr >/dev/null 2>&1; then getfattr -R -h -d -m - $MP 2>/dev/null | grep -c '^# file:' || true; else echo n/a; fi"; xattr="$COUNT"
    q8_notes=""
    if [ -n "$q8_partial" ]; then q8_notes=" partial (find failed: $q8_partial)"; fi
    case "$uid" in
        '' | *[!0-9]* | 0) : ;;
        *) q8_notes="$q8_notes non-root (remote uid $uid: unreadable paths are possible)" ;;
    esac
    set_q 8 "$q8_st" "size_kb=$size_kb entries=$entries hardlinks=$hardlinks appledouble=$appledouble special=$special acl=$acl xattr=$xattr appledouble_paths: ${apple_paths:-none}$q8_notes"
fi

# --- Q-9: rsync and the shell tools ------------------------------------------------

q9_st=ok
remote "rsync --version"
rsync_rc=$R_RC
rsync_out="$R_OUT"
if [ "$rsync_rc" -ne 0 ]; then q9_st=fail; fi
rsync_ver="$(printf '%s\n' "$rsync_out" | sed -n 's/^[^0-9]*version \([0-9][0-9.]*\).*/\1/p' | head -n1)"
caps="$(printf '%s\n' "$rsync_out" | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//')"
yesno() { if grep -Fxq -e "$1" <<<"$caps"; then printf yes; else printf no; fi; }
remote "rsync --help 2>&1"
if grep -Fq -e '--numeric-ids' <<<"$R_OUT"; then numeric=yes; else numeric=no; fi
if [ "$uid_rc" -ne 0 ]; then q9_st=fail; fi
missing=""
for tool in readlink mv du mktemp; do
    remote "command -v $tool"
    if [ "$R_RC" -ne 0 ]; then missing="${missing:+$missing,}$tool"; fi
done
if [ -n "$missing" ]; then q9_st=fail; tools="missing:$missing"; else tools=ok; fi
set_q 9 "$q9_st" "rsync=${rsync_ver:-n/a} hardlinks=$(yesno hardlinks) acls=$(yesno ACLs) xattrs=$(yesno xattrs) numeric-ids=$numeric uid=${uid:-n/a} tools=$tools"

# --- Q-10: owner and mode of the volume root; the optional write probe ---------------

q10_st=ok
owner="n/a"
mode="n/a"
if [ -z "$MOUNTPOINT" ]; then
    q10_st=fail
else
    remote "stat -c '%u:%g %a' $(rq "$MOUNTPOINT")"
    if [ "$R_RC" -ne 0 ]; then q10_st=fail; fi
    owner="$(printf '%s' "$R_OUT" | awk '{print $1}')"
    mode="$(printf '%s' "$R_OUT" | awk '{print $2}')"
fi
probe_ev="write-probe=skipped"
if [ "$WRITE_PROBE" -eq 1 ]; then
    if [ -z "$DOCKER" ]; then
        q10_st=fail
        probe_ev="write-probe=fail (docker CLI not found on the NAS)"
    else
        suffix="$(date -u +%Y%m%d%H%M%S)-$$-$RANDOM"
        # POSIX sh inside the container; single-quoted for the remote shell,
        # so no single quote may appear in it. Write operands are only the
        # .dxe-spike-* path (redirect-free mkdir/chown/rm commands, each ended by an explicit ;).
        probe_script="d=/share/.dxe-spike-$suffix; "'rb() { stat -c "%u:%g %a" "$1" 2>/dev/null; }
if mkdir "$d"; then
  chown 30033:30033 "$d";
  o=$(rb "$d"); o=${o%% *}
  if [ "$o" = 30033:30033 ]; then echo chown=ok; else echo "chown=fail(observed=${o:-n/a})"; fi
  if mkdir -m 0700 "$d/.dxe-spike-0700" && s=$(rb "$d/.dxe-spike-0700") && [ -n "$s" ]; then
    if [ "$s" = "0:0 700" ]; then echo mkdir0700=ok; else echo "mkdir0700=fail(observed=${s%% *}/${s#* })"; fi
  else echo "mkdir0700=fail(observed=n/a)"; fi
else echo "chown=fail(observed=n/a)"; echo "mkdir0700=fail(observed=n/a)"; fi
rm -rf "$d"'
        remote "$DOCKER run --rm --name dxe-spike-inspect-$suffix --label dxe.role=spike --network none -v $(rq "$SHARE_ROOT:/share") --entrypoint sh $(rq "${DXE_QNAP_PROBE_IMAGE:-$(dxe_qnap_probe_image_default)}") -c '$probe_script'"
        p_chown="$(printf '%s\n' "$R_OUT" | sed -n 's/^chown=\(.*\)$/\1/p' | head -n1)"
        p_mkdir="$(printf '%s\n' "$R_OUT" | sed -n 's/^mkdir0700=\(.*\)$/\1/p' | head -n1)"
        if [ "$R_RC" -eq 0 ] && [ "$p_chown" = ok ] && [ "$p_mkdir" = ok ]; then
            probe_ev="write-probe=ok chown=ok mkdir0700=ok"
        else
            q10_st=fail
            probe_ev="write-probe=fail chown=${p_chown:-n/a} mkdir0700=${p_mkdir:-n/a}"
            if [ "$R_RC" -ne 0 ]; then probe_ev="$probe_ev (docker run failed)"; fi
        fi
    fi
fi
set_q 10 "$q10_st" "owner=${owner:-n/a} mode=${mode:-n/a} $probe_ev"

# --- report -----------------------------------------------------------------------

qlines() {
    local n=1
    while [ "$n" -le 10 ]; do
        printf 'Q-%s | %s | %s\n' "$n" "${QS[$n]}" "${QE[$n]}"
        n=$((n + 1))
    done
}

mkdir -p "$(dirname "$REPORT_PATH")"
{
    dxe_qnap_report_header "$BASE_DIR" "QNAP /persist inspection (Q-1 .. Q-10)"
    qlines | dxe_redact_secrets
} >"$REPORT_PATH"
qlines | dxe_redact_secrets
echo "Report: $REPORT_PATH"

n=1
rc=0
while [ "$n" -le 10 ]; do
    if [ "${QS[$n]}" = fail ]; then rc=1; fi
    n=$((n + 1))
done
exit "$rc"
