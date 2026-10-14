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
# Q-2 (filesystem + mount), Q-8 and Q-10 (owner + mode of the volume root)
# are read by ONE read-only one-off container (`--network none`, the volume
# mounted `:ro` on /v), because the SSH account is not root and the volume
# path is root-only. Q-1 (the share root) is read host-side.
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

# df_fields <exit status> <df -P output, stderr merged>: sets DF_FS and
# DF_MOUNT from the data row, or DF_ERR (and empty fs/mount) when df failed
# or printed no data row. A header line is never treated as data.
DF_FS=""
DF_MOUNT=""
DF_ERR=""
df_fields() {
    local row
    DF_FS=""
    DF_MOUNT=""
    DF_ERR=""
    if [ "$1" -ne 0 ]; then
        DF_ERR="$(printf '%s\n' "$2" | grep . | head -n1)"
        DF_ERR="${DF_ERR:-exit status $1}"
        return
    fi
    row="$(printf '%s\n' "$2" | sed -n '2p')"
    if [ -z "$row" ]; then
        DF_ERR="no data row"
        return
    fi
    DF_FS="$(printf '%s' "$row" | awk '{print $1}')"
    DF_MOUNT="$(printf '%s' "$row" | awk '{print $NF}')"
}

# The read-only inspection container's script (POSIX sh, no write verb,
# literal /v). Prints tagged lines; a failing command gives n/a, never a
# partial number.
INSPECT_SCRIPT=""
read -r -d '' INSPECT_SCRIPT <<'EOS' || true
o=$(df -P /v 2>&1); r=$?
if [ "$r" -ne 0 ]; then
  echo "df-error=$(printf '%s\n' "$o" | grep . | head -n1)"
else
  row=$(printf '%s\n' "$o" | sed -n 2p)
  if [ -z "$row" ]; then echo "df-error=no data row"
  else
    printf '%s\n' "$row" | awk '{print "fs=" $1; print "mount=" $NF}'
  fi
fi
o=$(du -sk /v 2>/dev/null); r=$?
if [ "$r" -eq 0 ]; then echo "size_kb=$(printf '%s\n' "$o" | awk '{print $1; exit}')"; else echo size_kb=n/a; fi
fcount() {
  { find /v "$@" 2>/dev/null; echo "find-rc=$?"; } | awk '/^find-rc=/{rc=substr($0,9);next}{n++}END{if (rc+0==0) print n+0; else print "n/a"}'
}
echo "entries=$(fcount)"
echo "hardlinks=$(fcount -type f -links +1)"
o=$(find /v -name "._*" 2>/dev/null); r=$?
if [ "$r" -eq 0 ]; then
  echo "appledouble=$(printf '%s\n' "$o" | grep -c .)"
  printf '%s\n' "$o" | grep . | head -n 20 | sed 's/^/apple=/'
else echo appledouble=n/a; fi
echo "special=$(fcount -type s -o -type p -o -type b -o -type c)"
if command -v getfacl >/dev/null 2>&1; then echo "acl=$(getfacl -R -s -p /v 2>/dev/null | grep -c '^# file:')"; else echo acl=n/a; fi
if command -v getfattr >/dev/null 2>&1; then echo "xattr=$(getfattr -R -h -d -m - /v 2>/dev/null | grep -c '^# file:')"; else echo xattr=n/a; fi
s=$(stat -c '%u:%g %a' /v 2>/dev/null)
if [ -n "$s" ]; then echo "owner=${s%% *}"; echo "mode=${s#* }"; else echo owner=n/a; echo mode=n/a; fi
EOS

# tag <name>: the first value of a `name=value` line in INSPECT_OUT.
INSPECT_OUT=""
tag() { printf '%s\n' "$INSPECT_OUT" | sed -n "s/^$1=//p" | head -n1; }

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
remote "df -P $SHARE_Q 2>&1"
df_fields "$R_RC" "$R_OUT"
if [ "$q1_rc" -eq 0 ] && [ -z "$DF_ERR" ]; then q1_st=ok; else q1_st=fail; fi
if [ -n "$DF_ERR" ]; then
    q1_df="df failed: $DF_ERR"
else
    q1_df="fs=$DF_FS mount=$DF_MOUNT"
fi
set_q 1 "$q1_st" "canonical=${q1_canon:-n/a} $q1_df given=$SHARE_ROOT"

# --- Q-2 / Q-8 / Q-10 inputs: the volume, read by ONE read-only container ------
#
# The management account is not root and Container Station's volume path is
# root-only, so nothing reads the mountpoint host-side: a one-off container
# mounts the volume read-only on /v and prints tagged lines. The mountpoint
# from `volume inspect` is reported but is never an operand of an ssh call.

MOUNTPOINT=""
INSPECTED=0
if [ -n "$DOCKER" ]; then
    remote "$DOCKER volume inspect --format '{{.Mountpoint}}' $(rq "$VOLUME")"
    if [ "$R_RC" -eq 0 ]; then MOUNTPOINT="$(printf '%s' "$R_OUT" | head -n1)"; fi
fi
if [ -n "$MOUNTPOINT" ]; then
    remote "$DOCKER run --rm --network none -v $(rq "$VOLUME:/v:ro") --entrypoint sh $(rq "${DXE_QNAP_PROBE_IMAGE:-$(dxe_qnap_probe_image_default)}") -c $(rq "$INSPECT_SCRIPT")"
    INSPECT_OUT="$R_OUT"
    if [ "$R_RC" -eq 0 ]; then INSPECTED=1; fi
fi

if [ -z "$DOCKER" ]; then
    set_q 2 fail "mountpoint=n/a fs=n/a mount=n/a (docker CLI not found on the NAS)"
elif [ -z "$MOUNTPOINT" ]; then
    set_q 2 fail "mountpoint=n/a fs=n/a mount=n/a (docker volume inspect $VOLUME failed)"
elif [ "$INSPECTED" -eq 0 ]; then
    set_q 2 fail "mountpoint=$MOUNTPOINT fs=n/a mount=n/a (inspection container failed) volume=$VOLUME"
else
    q2_fs="$(tag fs)"
    q2_mount="$(tag mount)"
    q2_err="$(tag df-error)"
    if [ -n "$q2_err" ] || [ -z "$q2_fs" ]; then
        set_q 2 fail "mountpoint=$MOUNTPOINT df failed: ${q2_err:-no data row} volume=$VOLUME"
    else
        set_q 2 ok "mountpoint=$MOUNTPOINT fs=$q2_fs mount=${q2_mount:-n/a} volume=$VOLUME"
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

# --- Q-9 input: the remote uid ---------------------------------------------------

remote "id -u"
uid_rc=$R_RC
uid="$(printf '%s' "$R_OUT" | head -n1)"

# --- Q-8: size and contents of the volume (from the container) -----------------------

if [ "$INSPECTED" -eq 0 ]; then
    set_q 8 fail "size_kb=n/a entries=n/a hardlinks=n/a appledouble=n/a special=n/a acl=n/a xattr=n/a (no volume read)"
else
    q8_st=ok
    q8_partial=""
    # Each count is a bare integer or n/a (its find or du failed).
    size_kb="$(int "$(tag size_kb)")"
    entries="$(int "$(tag entries)")"
    hardlinks="$(int "$(tag hardlinks)")"
    appledouble="$(int "$(tag appledouble)")"
    special="$(int "$(tag special)")"
    acl="$(int "$(tag acl)")"
    xattr="$(int "$(tag xattr)")"
    [ "$size_kb" != "n/a" ] || q8_st=fail
    for kv in "entries=$entries" "hardlinks=$hardlinks" "appledouble=$appledouble" "special=$special"; do
        if [ "${kv#*=}" = "n/a" ]; then q8_st=fail; q8_partial="${q8_partial:+$q8_partial,}${kv%%=*}"; fi
    done
    apple_paths=""
    if [ "$appledouble" != "n/a" ]; then
        apple_paths="$(printf '%s\n' "$INSPECT_OUT" | sed -n 's/^apple=//p' | tr '\n' ' ')"
        if [ "$appledouble" -gt 20 ]; then apple_paths="$apple_paths(+$((appledouble - 20)) more)"; fi
    fi
    q8_notes=""
    if [ -n "$q8_partial" ]; then q8_notes=" partial (find failed: $q8_partial)"; fi
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
if [ "$INSPECTED" -eq 0 ]; then
    q10_st=fail
else
    owner="$(tag owner)"
    mode="$(tag mode)"
    if [ -z "$owner" ] || [ "$owner" = "n/a" ]; then q10_st=fail; fi
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
