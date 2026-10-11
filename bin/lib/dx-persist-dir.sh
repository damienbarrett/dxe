#!/bin/bash
# Host-side module for the per-guest /persist directory on a NAS (plan D-8).
# Safe to source; performs no I/O merely by being sourced.
#
# The marker FORMAT (what .dxe-persist-dir contains, how it is parsed and
# written) is POSIX sh shared with the guest, so it lives in
# container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh. Like
# bin/lib/dx-backup.sh and its selector, this module sources it directly by
# path -- both live in the same repository checkout on the host.

DX_PERSIST_DIR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DX_PERSIST_DIR_PROJECT_ROOT="$(cd "$DX_PERSIST_DIR_LIB_DIR/../.." && pwd)"
DX_PERSIST_DIR_MARKER_SOURCE="$DX_PERSIST_DIR_PROJECT_ROOT/container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh"
# shellcheck source=../../container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh
source "$DX_PERSIST_DIR_MARKER_SOURCE"

# The owner a new /persist directory gets (spec R15: the owner and mode
# today's volume root has, which the Q-10 inspection found to be
# 30033:30001, mode 0755). The repository fixes no UID or GID for the
# guest's dx user: the bootstrap allocates it with groupadd/useradd on the
# nixos/nix base (nixbld group 30000, nixbld users 30001-30032, so dx gets
# UID 30033 and its own group 30001), or reuses the durable identity of an
# existing /nix store, and setup_persist re-asserts dx:dx 0755 on /persist
# at every boot. This is the one host-side copy of that result;
# dx_persist_dir_establish reads it when it runs.
DX_PERSIST_DIR_OWNER=30033:30001

# --- The start decision (WP4.3; plans/do D-2, D-7, D-9; spec R15, R17, R18) --
#
# In host-path mode dx-create-volumes and dx-start-container both probe the
# per-guest directory once (dx_runtime_host_dir_probe), ask whether the
# guest's named persist volume and the D-7 record exist, and pass those facts
# to the pure dx_persist_start_decision. dx-create-volumes acts on create,
# adopt and ok-fresh-start through dx_persist_dir_establish (WP4.4, below);
# dx-start-container starts only on ok. Every refusal is one `Error:` line
# naming the fix, printed before anything is written to the share and before
# any volume is created. Volume mode makes none of these calls.

# The D-7 record of host-path use: one entry per profile, named by the DQ6
# profile id (DX_REMOTE_HOST__DX_CONTAINER_NAME), under the controller's
# state directory. Destroy and reset never delete it; dx_persist_dir_establish
# and the ok path's backfill write it (WP4.4).
# Non-zero, printing nothing, when the path cannot be formed.
dx_persist_dir_record_path() {
    local state="${XDG_STATE_HOME:-}"
    if [ -z "$state" ]; then
        [ -n "${HOME:-}" ] || return 1
        state="$HOME/.local/state"
    fi
    [ -n "${DX_REMOTE_HOST:-}" ] && [ -n "${DX_CONTAINER_NAME:-}" ] || return 1
    printf '%s/dxe/persist-dirs/%s__%s\n' "$state" "$DX_REMOTE_HOST" "$DX_CONTAINER_NAME"
}

# 0 when anything is at the record path (a file, a directory, a dangling
# symlink) or when the path cannot be formed: fail-closed, because a missed
# record would let an existing guest pass as new. 1 only for a clean absence.
dx_persist_dir_record_exists() {
    local path
    path="$(dx_persist_dir_record_path)" || return 0
    [ -e "$path" ] || [ -L "$path" ]
}

# dx_persist_dir_record_write PATH MODE CREATED_AT: the record itself, five
# lines -- schema=1, guest=, root= (DX_PERSIST_HOST_ROOT as configured),
# mode= (create, adopt, fresh-start or backfill) and created-at= (the
# marker's) -- mode 0600, written atomically: missing parent directories are
# made, then a temp file in the record's own directory and ONE mv onto PATH,
# which replaces an existing record. A directory at PATH is refused (mv
# would move the file into it). Silent; non-zero on any failure, with no
# temp file left behind.
dx_persist_dir_record_write() {
    local path="$1" dir="${1%/*}" tmp
    [ ! -d "$path" ] || return 1
    mkdir -p -- "$dir" 2>/dev/null || return 1
    tmp="$(mktemp "$dir/.${path##*/}.XXXXXX" 2>/dev/null)" || return 1
    if printf 'schema=1\nguest=%s\nroot=%s\nmode=%s\ncreated-at=%s\n' \
        "${DX_CONTAINER_NAME:-}" "${DX_PERSIST_HOST_ROOT:-}" "$2" "$3" >"$tmp" \
        && chmod 0600 "$tmp" && mv -f -- "$tmp" "$path" 2>/dev/null; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

# The controller's clock, as the marker and the record spell it.
dx_persist_dir_utc_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# _dx_persist_gate MOUNTED TOKEN: every outcome that writes into the share
# needs proof that the share is mounted.
_dx_persist_gate() {
    case "$1" in
        yes) printf '%s\n' "$2"; return 0 ;;
        no) printf 'refuse:unmounted\n' ;;
        *) printf 'refuse:mount-unknown\n' ;;
    esac
    return 1
}

# dx_persist_start_decision GUEST VOLUME_EXISTS RECORD_EXISTS OVERRIDE < REPORT
#
# REPORT is what dx_runtime_host_dir_probe printed: the root=, mounted=,
# state= and marker= lines in that order, then the marker bytes only when
# marker=present. VOLUME_EXISTS and RECORD_EXISTS mean "absent" only when
# exactly `no`. OVERRIDE is DX_PERSIST_FRESH_START's value, read from this
# argument and never from the environment. Prints one token -- ok, create,
# adopt or ok-fresh-start (status 0), or refuse:<reason> (status 1) -- and
# makes no runtime, remote or file-system call. First match wins:
#   unusable or malformed report         refuse:root
#   a symlinked level                    refuse:symlink
#   a marker: invalid / another guest / copying / retired / ready
#                                        refuse:marker-invalid / -guest /
#                                        refuse:copying / refuse:retired / ok
#   non-empty, no marker                 refuse:unmarked
#   absent: volume or record exists      refuse:missing (never create)
#           otherwise                    create          (needs mounted=yes)
#   empty:  volume or record exists      ok-fresh-start with OVERRIDE=GUEST,
#                                        else refuse:empty
#           otherwise                    adopt           (needs mounted=yes)
dx_persist_start_decision() {
    local guest="$1" volume="$2" record="$3" override="$4"
    local root="" mounted="" state="" marker="" extra="" valid=yes
    IFS= read -r root || :
    IFS= read -r mounted || :
    IFS= read -r state || :
    IFS= read -r marker || :
    case "$root" in
        root=/*) : ;;
        *) valid=no ;;
    esac
    case "$mounted" in
        mounted=yes | mounted=no | mounted=unknown) mounted="${mounted#mounted=}" ;;
        *) valid=no ;;
    esac
    case "$state" in
        state=absent | state=symlink | state=empty | state=nonempty) state="${state#state=}" ;;
        *) valid=no ;;
    esac
    case "$marker" in
        marker=present) marker=present ;;
        marker=absent)
            marker=absent
            if IFS= read -r extra || [ -n "$extra" ]; then valid=no; fi
            ;;
        *) valid=no ;;
    esac
    if [ "$valid" != yes ]; then
        printf 'refuse:root\n'
        return 1
    fi
    if [ "$state" = symlink ]; then
        printf 'refuse:symlink\n'
        return 1
    fi
    if [ "$marker" = present ]; then
        if ! dx_persist_marker_parse; then
            printf 'refuse:marker-invalid\n'
            return 1
        fi
        if [ "$DX_PERSIST_MARKER_GUEST" != "$guest" ]; then
            printf 'refuse:marker-guest\n'
            return 1
        fi
        case "$DX_PERSIST_MARKER_STATE" in
            ready) printf 'ok\n'; return 0 ;;
            copying) printf 'refuse:copying\n' ;;
            *) printf 'refuse:retired\n' ;;
        esac
        return 1
    fi
    if [ "$state" = nonempty ]; then
        printf 'refuse:unmarked\n'
        return 1
    fi
    if [ "$state" = absent ]; then
        if [ "$volume" = no ] && [ "$record" = no ]; then
            _dx_persist_gate "$mounted" create
            return
        fi
        printf 'refuse:missing\n'
        return 1
    fi
    if [ "$volume" = no ] && [ "$record" = no ]; then
        _dx_persist_gate "$mounted" adopt
        return
    fi
    if [ -n "$override" ] && [ "$override" = "$guest" ]; then
        _dx_persist_gate "$mounted" ok-fresh-start
        return
    fi
    printf 'refuse:empty\n'
    return 1
}

# dx_persist_refusal TOKEN REPORT VOLUME_EXISTS RECORD_EXISTS: the one
# `Error:` line (stderr) for a refuse:<reason> token, naming the fix.
dx_persist_refusal() {
    local token="$1" report="$2" volume="$3" record="$4"
    local guest="${DX_CONTAINER_NAME:-}" root="${DX_PERSIST_HOST_ROOT:-}"
    local sentinel="${DX_PERSIST_HOST_MOUNT_SENTINEL:-}" override="${DX_PERSIST_FRESH_START:-}"
    local dir mounted src rec evidence="" hint="" msg
    dir="$(dx_persist_configured_source)"
    mounted="$(printf '%s\n' "$report" | sed -n '2s/^mounted=//p')"
    dx_persist_marker_parse 2>/dev/null <<<"$(printf '%s\n' "$report" | sed '1,4d')" || :
    src="${DX_PERSIST_MARKER_SOURCE_VOLUME:-}"
    src="${src:+ $src}"
    case "$token" in
        refuse:root)
            msg="the share root DX_PERSIST_HOST_ROOT=$root is not a usable directory on ${DX_REMOTE_HOST:-the NAS}, or it could not be checked; fix DX_PERSIST_HOST_ROOT in the private profile or make the share available, then retry." ;;
        refuse:symlink)
            msg="$dir, or a level above it under the share root (dxe, dxe/$guest), is a symlink; /persist must be a real directory, so replace the symlink with the directory itself, then retry." ;;
        refuse:marker-invalid)
            msg="$dir/$DX_PERSIST_MARKER_NAME is not a valid /persist marker; inspect the directory and restore a valid marker, or move the directory aside, then retry." ;;
        refuse:marker-guest)
            msg="$dir/$DX_PERSIST_MARKER_NAME names guest ${DX_PERSIST_MARKER_GUEST:-?}, not $guest; this directory belongs to another guest, so check DX_PERSIST_HOST_ROOT and DX_CONTAINER_NAME in the profile." ;;
        refuse:copying)
            msg="$dir is marked copying: a migration into it from the persist volume$src has not finished; resume it with dx-persist-migrate, or roll it back, before starting $guest." ;;
        refuse:retired)
            msg="$dir is marked retired: a rollback returned $guest to the persist volume$src; set DX_PERSIST_STORAGE=volume in the profile, or migrate again with dx-persist-migrate." ;;
        refuse:unmarked)
            msg="$dir is not empty and has no $DX_PERSIST_MARKER_NAME marker; existing data is never adopted automatically, so import it with dx-persist-migrate or move it aside, then retry." ;;
        refuse:empty)
            [ "$volume" = no ] || evidence="the persist volume $DX_PERSIST_VOLUME exists"
            [ "$record" = no ] || evidence="${evidence:+$evidence and }a host-path record exists"
            [ -z "$override" ] || hint=" (DX_PERSIST_FRESH_START=$override does not name this guest.)"
            msg="$dir is empty and unmarked, but $guest has used other /persist storage before ($evidence), so its data may still be there. To start fresh on purpose (new SSH host keys, no credentials; the old volume is kept), run dx-create-volumes once with DX_PERSIST_FRESH_START=$guest.$hint" ;;
        refuse:missing)
            rec="$(dx_persist_dir_record_path)" || rec="(path unavailable)"
            [ "$volume" = no ] || evidence="the persist volume $DX_PERSIST_VOLUME exists (import it with dx-persist-migrate)"
            [ "$record" = no ] || evidence="${evidence:+$evidence; }the record $rec says it used this directory (restore the directory from a NAS snapshot or backup; if it was removed on purpose, delete that record too)"
            case "$mounted" in
                no) hint=" The share may not be mounted: its sentinel DX_PERSIST_HOST_MOUNT_SENTINEL=$sentinel is missing, so mount or unlock it first." ;;
                unknown) hint=" If the share is not mounted, mount or unlock it first (set DX_PERSIST_HOST_MOUNT_SENTINEL to have this checked)." ;;
                *) hint="" ;;
            esac
            msg="$dir is missing, but $guest already has /persist data: $evidence. The tooling never creates empty replacement storage.$hint" ;;
        refuse:unmounted)
            msg="the share root $root does not look mounted: its sentinel file DX_PERSIST_HOST_MOUNT_SENTINEL=$sentinel is missing (an unmounted or locked volume can leave an empty mount point); mount or unlock the share, then retry." ;;
        refuse:mount-unknown)
            msg="cannot tell whether the share root $root is mounted, and creating or marking $dir needs that proof; set DX_PERSIST_HOST_MOUNT_SENTINEL in the profile to a file that exists at the share root only while it is mounted, then retry." ;;
        *)
            msg="unexpected /persist decision '$token' for $dir; refusing to continue." ;;
    esac
    printf 'Error: %s\n' "$msg" >&2
}

# A guest name the derived directory can carry: a plain marker-class name,
# because it is a path component on the NAS. Otherwise one Error line.
dx_persist_host_dir_guest_ok() {
    dx_persist_marker_valid_name "${DX_CONTAINER_NAME:-}" && return 0
    echo "Error: DX_CONTAINER_NAME=${DX_CONTAINER_NAME:-} cannot name a /persist host directory (it must start with a letter or digit); rename the guest or use DX_PERSIST_STORAGE=volume." >&2
    return 1
}

# Host-path mode, shared by dx-create-volumes and dx-start-container: one
# probe, the volume and record lookups, then the decision. Prints the token
# on stdout when it is not a refusal -- with --report, followed by the probe
# report it was decided on -- and otherwise one Error line, status 1. The
# persist volume counts as absent only when the runtime says so
# (dx_runtime_volume_state): one it cannot inspect stops here, because "no
# volume" can lead to a new, empty /persist.
dx_persist_host_dir_decide() {
    local report volume=no record=no state token
    dx_persist_host_dir_guest_ok || return 1
    report="$(dx_runtime_host_dir_probe "$DX_PERSIST_HOST_ROOT" "$DX_CONTAINER_NAME")" || report=""
    if ! state="$(dx_runtime_volume_state "$DX_PERSIST_VOLUME")"; then
        echo "Error: cannot tell whether the persist volume $DX_PERSIST_VOLUME exists: docker volume inspect on ${DX_REMOTE_HOST:-the NAS} failed for a reason other than 'no such volume' (see above), and a missing volume can mean a new, empty /persist; fix the NAS connection or its Docker daemon, then retry. Nothing was changed." >&2
        return 1
    fi
    [ "$state" = absent ] || volume=yes
    if dx_persist_dir_record_exists; then record=yes; fi
    if token="$(printf '%s\n' "$report" | dx_persist_start_decision "$DX_CONTAINER_NAME" "$volume" "$record" "${DX_PERSIST_FRESH_START:-}")"; then
        printf '%s\n' "$token"
        [ "${1:-}" != --report ] || printf '%s\n' "$report"
        return 0
    fi
    dx_persist_refusal "$token" "$report" "$volume" "$record"
    return 1
}

# dx-create-volumes, before any volume is created: prints nothing in volume
# mode; in host-path mode prints the decision token on its first line and the
# probe report after it (the ok path reads the marker's created-at from it,
# so nothing is probed twice), or refuses (status 1).
dx_persist_create_decision() {
    [ "${DX_PERSIST_STORAGE:-volume}" = host-path ] || return 0
    dx_persist_host_dir_decide --report
}

# dx-create-volumes, after the nix volume: a legacy volume (LEGACY,
# DX_LEGACY_WORKSPACE_VOLUME's dx-workspace default) whose data has not
# reached DX_PERSIST_VOLUME yet stops the command before /persist storage is
# set up, so it is never left behind. In host-path mode the way on is two
# steps: dx-migrate-persist into the persist volume, then dx-persist-migrate
# into the host directory.
dx_persist_legacy_volume_check() {
    local legacy="$1" next
    if [ "$legacy" = "$DX_PERSIST_VOLUME" ] || ! dx_runtime_volume_exists "$legacy" \
        || dx_runtime_volume_exists "$DX_PERSIST_VOLUME"; then
        return 0
    fi
    next="Run bin/dx-migrate-persist before creating the new /persist volume."
    if [ "${DX_PERSIST_STORAGE:-volume}" = host-path ]; then
        next="Run bin/dx-migrate-persist to copy it into the persist volume $DX_PERSIST_VOLUME, then dx-persist-migrate to move that volume into the host directory $(dx_persist_configured_source)."
    fi
    printf 'Error: legacy persistence volume %s exists, but %s does not.\n%s\nSet DX_LEGACY_WORKSPACE_VOLUME=<old> and DX_PERSIST_VOLUME=<new> for custom volume names.\n' \
        "$legacy" "$DX_PERSIST_VOLUME" "$next" >&2
    return 1
}

# dx-create-volumes' /persist step, given what dx_persist_create_decision
# printed (the token, then the probe report). Volume mode ensures the named
# volume exactly as before. Host-path mode never creates that volume: ok
# writes the record if it is missing (dx_persist_dir_record_backfill), and
# create, adopt and ok-fresh-start go to dx_persist_dir_establish once.
dx_persist_storage_ensure() {
    local nl=$'\n' action="${1:-}" token report="" dir
    if [ "${DX_PERSIST_STORAGE:-volume}" != host-path ]; then
        echo "Ensuring persist volume $DX_PERSIST_VOLUME..."
        container_ensure_volume "$DX_PERSIST_VOLUME"
        return
    fi
    token="${action%%"$nl"*}"
    [ "$token" = "$action" ] || report="${action#*"$nl"}"
    dir="$(dx_persist_configured_source)"
    case "$token" in
        ok)
            echo "Using /persist directory $dir (marker ready)."
            dx_persist_dir_record_backfill "$report" ;;
        create)
            echo "Creating /persist directory $dir..."
            dx_persist_dir_establish create ;;
        adopt)
            echo "Completing the empty /persist directory $dir left by an interrupted create..."
            dx_persist_dir_establish adopt ;;
        ok-fresh-start)
            echo "Fresh start (DX_PERSIST_FRESH_START): marking the empty /persist directory $dir ready; the persist volume $DX_PERSIST_VOLUME is kept..."
            dx_persist_dir_establish fresh-start ;;
        *)
            echo "Error: no host-path /persist decision to act on ('$token'); run dx-create-volumes again." >&2
            return 1 ;;
    esac
}

# dx-start-container, inside the lifecycle lock and just before the container
# start: nothing in volume mode; in host-path mode the start goes ahead only
# on ok. Only dx-create-volumes creates or marks the directory, so create,
# adopt and ok-fresh-start stop the start too.
dx_persist_start_check() {
    local token dir why
    [ "${DX_PERSIST_STORAGE:-volume}" = host-path ] || return 0
    token="$(dx_persist_host_dir_decide)" || return 1
    [ "$token" != ok ] || return 0
    dir="$(dx_persist_configured_source)"
    case "$token" in
        create) why="it does not exist yet" ;;
        adopt) why="it is empty and has no marker" ;;
        *) why="it is empty and has no marker; DX_PERSIST_FRESH_START is applied by dx-create-volumes" ;;
    esac
    echo "Error: $dir is not ready for $DX_CONTAINER_NAME ($why); run dx-create-volumes first, which alone creates or marks the directory." >&2
    return 1
}

# --- Creating the directory and the record (WP4.4; plans/do D-2, D-3, D-7;
# spec R15, R18) ---------------------------------------------------------------

# dx_persist_dir_establish create|adopt|fresh-start, dx-create-volumes' one
# write to the share. It takes one UTC time T on the controller, then makes
# ONE dx_runtime_host_dir_establish call, which on the NAS, as root: creates
# <root>/dxe/<guest>/persist (create), or takes the existing empty directory
# (adopt: the leftover of an interrupted create; fresh-start: the
# DX_PERSIST_FRESH_START override); gives it DX_PERSIST_DIR_OWNER and mode
# 0755; and writes the `ready` marker (created-at=T) last. Only after that
# succeeds is the D-7 record written (mode=MODE, created-at=T), so a failure
# anywhere leaves no record, and the next run, still for a new guest, adopts
# the empty directory. Refusals come before any remote call; any failure is
# one Error line and status 1, with an existing record left as it was.
dx_persist_dir_establish() {
    local mode="${1:-}" dir rec now marker
    dir="$(dx_persist_configured_source)"
    case "$mode" in
        create | adopt | fresh-start) : ;;
        *)
            echo "Error: unknown /persist directory action '$mode' (expected create, adopt or fresh-start); nothing was changed." >&2
            return 1 ;;
    esac
    dx_persist_host_dir_guest_ok || return 1
    if [ -z "${DX_PERSIST_HOST_MOUNT_SENTINEL:-}" ]; then
        echo "Error: DX_PERSIST_HOST_MOUNT_SENTINEL is not set, so nothing proves the share root ${DX_PERSIST_HOST_ROOT:-} is mounted and $dir was not touched; set it in the private profile to a file that exists at the share root only while it is mounted, then retry." >&2
        return 1
    fi
    if ! rec="$(dx_persist_dir_record_path)"; then
        echo "Error: the host-path record path cannot be formed (it needs XDG_STATE_HOME or HOME, DX_REMOTE_HOST and DX_CONTAINER_NAME), so $dir was not touched; fix the environment, then retry." >&2
        return 1
    fi
    now="$(dx_persist_dir_utc_now)"
    if ! marker="$(dx_persist_marker_format "$DX_CONTAINER_NAME" ready "" "$now" 2>/dev/null)"; then
        echo "Error: the controller's clock gave no usable UTC time ('$now'), so no marker could be made for $dir; nothing was changed." >&2
        return 1
    fi
    if ! dx_runtime_host_dir_establish "$mode" "${DX_PERSIST_HOST_ROOT:-}" "$DX_CONTAINER_NAME" "$DX_PERSIST_DIR_OWNER" "$marker"; then
        echo "Error: could not set up $dir on the NAS ($mode; see the lines above), so no host-path record was written; fix the cause, then run dx-create-volumes again." >&2
        return 1
    fi
    if ! dx_persist_dir_record_write "$rec" "$mode" "$now"; then
        echo "Error: $dir is ready, but its host-path record $rec could not be written; make that path writable, then run dx-create-volumes again, which writes the missing record." >&2
        return 1
    fi
    echo "Recorded host-path use of $dir in $rec."
}

# dx_persist_dir_record_backfill REPORT (dx-create-volumes, on ok): a ready
# directory whose record is missing -- an earlier run marked it but could not
# write the record -- gets it now, with mode=backfill and the created-at of
# the marker in REPORT (the probe report the decision was made on), or the
# controller's time when that marker has none. Anything already at the record
# path is left alone, and nothing is sent to the NAS. A failed write is one
# Warning line and status 0: the directory is ready, and the next run tries
# again.
dx_persist_dir_record_backfill() {
    local rec created="" dir
    if dx_persist_dir_record_exists; then return 0; fi
    rec="$(dx_persist_dir_record_path)" || return 0
    dir="$(dx_persist_configured_source)"
    if dx_persist_marker_parse 2>/dev/null <<<"$(printf '%s\n' "${1:-}" | sed '1,4d')"; then
        created="$DX_PERSIST_MARKER_CREATED_AT"
    fi
    [ -n "$created" ] || created="$(dx_persist_dir_utc_now)"
    if dx_persist_dir_record_write "$rec" backfill "$created"; then
        echo "Recorded host-path use of $dir in $rec (it was missing)."
        return 0
    fi
    echo "Warning: the host-path record $rec could not be written; $dir is ready and in use, and the next dx-create-volumes tries again." >&2
    return 0
}

# --- dx-persist-inventory (WP6.3; plan D-10; spec R37) -------------------------
# The pre-migration inventory of a guest's /persist VOLUME: what a copy to the
# NAS directory would carry, whether rsync can carry it, and whether the target
# and a rollback volume have room. Strictly read-only (one read-only container,
# the rsync version check, one `df`); the report is built in full before any of
# it is printed, so a refusal or a failed read prints no partial report.
#   exit 0  complete, nothing blocks;  1  refusal / failed read;  2  usage;
#   3  complete, but rsync_check is refused or a room line says "no".

dx_persist_inventory_usage() {
    echo "Usage: dx-persist-inventory"
    echo "  Read-only inventory of the guest's /persist volume before a host-path migration."
    echo "  Exit: 0 ok, 1 refused or unreadable, 2 usage, 3 report names a blocker."
}

# dx_persist_inventory_value OUTPUT KEY: the value of the first KEY=value line.
dx_persist_inventory_value() {
    sed -n "/^$2=/{s///p;q;}" <<<"$1"
}

# dx_persist_inventory_number VALUE: a plain non-negative integer.
dx_persist_inventory_number() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac
}

# dx_persist_inventory_present VALUE: none|present|unknown for a count or "unknown".
dx_persist_inventory_present() {
    case "$1" in
        0) echo none ;;
        unknown) echo unknown ;;
        *) echo present ;;
    esac
}

# dx_persist_inventory_lines OUTPUT KEY LABEL: "LABEL: value" for every KEY=value
# line, or "LABEL: none".
dx_persist_inventory_lines() {
    local lines
    lines="$(sed -n "s/^$2=//p" <<<"$1")"
    if [ -z "$lines" ]; then
        printf '%s: none\n' "$3"
        return 0
    fi
    sed "s/^/$3: /" <<<"$lines"
}

# dx_persist_inventory_read VOLUME: validate the container's output (stdout,
# merged with stderr) into DX_INV_OUT; one Error line on failure.
dx_persist_inventory_read() {
    local out rc=0 key value
    out="$(dx_runtime_volume_inventory "$1" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        if ! grep -q '^Error:' <<<"$out"; then
            echo "Error: could not read volume '$1' (exit $rc)." >&2
        fi
        [ -z "$out" ] || printf '%s\n' "$out" >&2
        return 1
    fi
    if ! grep -Fqx status=ok <<<"$out"; then
        echo "Error: the volume read of '$1' did not finish (no status=ok)." >&2
        return 1
    fi
    for key in size_kb entries hardlinks appledouble special df_avail_kb; do
        value="$(dx_persist_inventory_value "$out" "$key")"
        dx_persist_inventory_number "$value" || {
            echo "Error: the volume read of '$1' returned no usable $key." >&2
            return 1
        }
    done
    for key in acl xattr; do
        value="$(dx_persist_inventory_value "$out" "$key")"
        [ "$value" = unknown ] || dx_persist_inventory_number "$value" || {
            echo "Error: the volume read of '$1' returned no usable $key." >&2
            return 1
        }
    done
    DX_INV_OUT="$out"
}

# dx_persist_inventory_rsync ACLS XATTRS: prints "VERSION|CHECK" -- the version
# (or unknown) and "ok" or "refused: <message>". Needs -A / -X unless "none".
dx_persist_inventory_rsync() {
    local flags=() out rc=0 message version
    if [ "$1" != none ]; then flags+=(-A); fi
    if [ "$2" != none ]; then flags+=(-X); fi
    out="$(dx_runtime_host_rsync_check "${flags[@]+"${flags[@]}"}" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        message="$(sed -n '/^Error: /{s///p;q;}' <<<"$out")"
        echo "unknown|refused: ${message:-rsync check failed}"
        return 0
    fi
    version="$(dx_persist_inventory_value "$out" version)"
    echo "${version:-unknown}|ok"
}

dx_persist_inventory_main() {
    local out free target_free size rollback_free rc=0 acls xattrs rsync_result
    local target_room=yes rollback_room=yes blocked=0 report root
    case "$#:${1:-}" in
        0:) : ;;
        1:-h|1:--help) dx_persist_inventory_usage; return 0 ;;
        *) dx_persist_inventory_usage >&2; return 2 ;;
    esac
    if [ "${DX_RUNTIME:-}" != docker-ssh ]; then
        echo "Error: dx-persist-inventory needs DX_RUNTIME=docker-ssh (the volume is on a NAS Docker host)." >&2
        return 1
    fi
    root="${DX_PERSIST_HOST_ROOT:-}"
    if [ -z "$root" ]; then
        echo "Error: DX_PERSIST_HOST_ROOT is empty; set the NAS share root the migration would copy to." >&2
        return 1
    fi
    dx_persist_inventory_read "$DX_PERSIST_VOLUME" || return 1
    out="$DX_INV_OUT"
    free="$(dx_runtime_host_dir_free "$root")" || {
        echo "Error: could not read the free space of '$root' on the NAS." >&2
        return 1
    }
    target_free="$(dx_persist_inventory_value "$free" avail_kb)"
    dx_persist_inventory_number "$target_free" || {
        echo "Error: the free-space read of '$root' returned no usable avail_kb." >&2
        return 1
    }
    acls="$(dx_persist_inventory_present "$(dx_persist_inventory_value "$out" acl)")"
    xattrs="$(dx_persist_inventory_present "$(dx_persist_inventory_value "$out" xattr)")"
    rsync_result="$(dx_persist_inventory_rsync "$acls" "$xattrs")"
    size="$(dx_persist_inventory_value "$out" size_kb)"
    rollback_free="$(dx_persist_inventory_value "$out" df_avail_kb)"
    if [ "$target_free" -lt "$size" ]; then target_room=no; blocked=1; fi
    if [ "$rollback_free" -lt "$size" ]; then rollback_room=no; blocked=1; fi
    if [ "${rsync_result#*|}" != ok ]; then blocked=1; fi
    report="$(
        printf 'volume: %s\n' "$DX_PERSIST_VOLUME"
        printf 'size_kb: %s\n' "$size"
        printf 'entries: %s\n' "$(dx_persist_inventory_value "$out" entries)"
        printf 'hard_links: %s\n' "$(dx_persist_inventory_value "$out" hardlinks)"
        printf 'appledouble_count: %s\n' "$(dx_persist_inventory_value "$out" appledouble)"
        dx_persist_inventory_lines "$out" apple appledouble
        printf 'special_count: %s\n' "$(dx_persist_inventory_value "$out" special)"
        dx_persist_inventory_lines "$out" special_path special
        printf 'acls: %s\n' "$acls"
        printf 'xattrs: %s\n' "$xattrs"
        printf 'rsync_version: %s\n' "${rsync_result%%|*}"
        printf 'rsync_check: %s\n' "${rsync_result#*|}"
        printf 'target_root: %s\n' "$root"
        printf 'target_free_kb: %s\n' "$target_free"
        printf 'target_room: %s\n' "$target_room"
        printf 'rollback_free_kb: %s\n' "$rollback_free"
        printf 'rollback_room: %s\n' "$rollback_room"
    )"
    printf '%s\n' "$report"
    [ "$blocked" -eq 0 ] || rc=3
    return "$rc"
}

# --- dx-persist-migrate (WP6.4; plan D-3, D-6, D-7, D-8, D-10; spec R31-R35,
# section 6) -------------------------------------------------------------------
# The forward migration of a stopped guest's /persist volume into its NAS
# directory <canonical root>/dxe/<guest>/persist. Every write into the share is
# a root one-off container (establish, the rsync copy, the marker change); the
# volume is only ever mounted read-only. Order: refusals that need no runtime
# call; the lifecycle lock (held to the end); the guest must be stopped; the
# read-only pre-flight (DQ6 checks, the probe, the inventory, rsync_check); the
# destination with a `copying` marker; rsync; the manifest verify; the `ready`
# marker; the D-7 record; the report. An interrupted run is resumed by running
# the command again: a `copying` marker for this guest and volume is the only
# non-empty destination it accepts. It never starts the guest and never edits
# the profile.
#   exit 0  migrated and verified;  1  refused, or failed before the
#   verification;  2  usage;  3  the copy did not verify (the marker stays
#   copying).

dx_persist_migrate_usage() {
    echo "Usage: dx-persist-migrate"
    echo "  Copy the stopped guest's /persist volume into its NAS directory"
    echo "  (DX_PERSIST_HOST_ROOT/dxe/DX_CONTAINER_NAME/persist), verify the copy, and mark it ready."
    echo "  After an interruption, run it again: it resumes into the same directory."
    echo "  Exit: 0 migrated, 1 refused or failed, 2 usage, 3 the copy did not verify."
}

# The refusals that need no runtime call, in the contract's order; one Error
# line each. Sets DX_MIGRATE_RECORD (the D-7 record path).
dx_persist_migrate_preconditions() {
    if [ "${DX_RUNTIME:-}" != docker-ssh ]; then
        echo "Error: dx-persist-migrate needs DX_RUNTIME=docker-ssh (the volume and the host directory are on a NAS Docker host)." >&2
        return 1
    fi
    if [ -z "${DX_PERSIST_HOST_ROOT:-}" ]; then
        echo "Error: DX_PERSIST_HOST_ROOT is empty; set the NAS share root to migrate into in the private profile." >&2
        return 1
    fi
    if [ -z "${DX_PERSIST_HOST_MOUNT_SENTINEL:-}" ]; then
        echo "Error: DX_PERSIST_HOST_MOUNT_SENTINEL is not set, so nothing proves the share root $DX_PERSIST_HOST_ROOT is mounted; set it in the private profile to a file that exists at the share root only while it is mounted, then retry." >&2
        return 1
    fi
    if ! DX_MIGRATE_RECORD="$(dx_persist_dir_record_path)"; then
        echo "Error: the host-path record path cannot be formed (it needs XDG_STATE_HOME or HOME, DX_REMOTE_HOST and DX_CONTAINER_NAME); fix the environment, then retry." >&2
        return 1
    fi
    dx_persist_host_dir_guest_ok
}

# dx_persist_migrate_decide GUEST VOLUME < REPORT: the destination decision on
# a dx_runtime_host_dir_probe report (root=, mounted=, state=, marker=, then
# the marker bytes when marker=present). Pure: no call. Sets DX_MIGRATE_ACTION
# to create, adopt or resume (status 0) or refuse (status 1, with the reason
# in DX_MIGRATE_WHY: root, unmounted, symlink, unmarked, marker, guest,
# copying, ready or retired); DX_MIGRATE_ROOT to the canonical root once it is
# usable; DX_MIGRATE_CREATED to a resumed marker's created-at. First match:
#   malformed report; root= not absolute, "/" or holding ","   root
#   mounted= other than yes                                   unmounted
#   state=symlink                                             symlink
#   state=absent / empty                                      create / adopt
#   non-empty without a marker                                unmarked
#   a marker: invalid / another guest                         marker / guest
#     copying from VOLUME                                     resume
#     copying from another or no volume / ready / retired     copying / ready / retired
dx_persist_migrate_decide() {
    local guest="$1" volume="$2" root="" mounted="" state="" marker="" extra=""
    DX_MIGRATE_ACTION=refuse
    DX_MIGRATE_WHY=root
    DX_MIGRATE_ROOT=""
    DX_MIGRATE_CREATED=""
    IFS= read -r root || :
    IFS= read -r mounted || :
    IFS= read -r state || :
    IFS= read -r marker || :
    case "$root" in
        root=/ | root=*,* | root=) return 1 ;;
        root=/*) : ;;
        *) return 1 ;;
    esac
    case "$state:$marker" in
        state=nonempty:marker=present) : ;;
        state=absent:marker=absent | state=symlink:marker=absent | state=empty:marker=absent | state=nonempty:marker=absent)
            if IFS= read -r extra || [ -n "$extra" ]; then return 1; fi ;;
        *) return 1 ;;
    esac
    case "$mounted" in
        mounted=yes) : ;;
        mounted=no | mounted=unknown) DX_MIGRATE_WHY=unmounted; return 1 ;;
        *) return 1 ;;
    esac
    DX_MIGRATE_ROOT="${root#root=}"
    case "$state:$marker" in
        state=symlink:*) DX_MIGRATE_WHY=symlink; return 1 ;;
        state=absent:*) DX_MIGRATE_ACTION=create; return 0 ;;
        state=empty:*) DX_MIGRATE_ACTION=adopt; return 0 ;;
        *:marker=absent) DX_MIGRATE_WHY=unmarked; return 1 ;;
    esac
    if ! dx_persist_marker_parse 2>/dev/null; then
        DX_MIGRATE_WHY=marker
        return 1
    fi
    if [ "$DX_PERSIST_MARKER_GUEST" != "$guest" ]; then
        DX_MIGRATE_WHY=guest
        return 1
    fi
    DX_MIGRATE_WHY="$DX_PERSIST_MARKER_STATE"
    if [ "$DX_PERSIST_MARKER_STATE" = copying ] && [ "$DX_PERSIST_MARKER_SOURCE_VOLUME" = "$volume" ]; then
        DX_MIGRATE_ACTION=resume
        DX_MIGRATE_CREATED="$DX_PERSIST_MARKER_CREATED_AT"
        return 0
    fi
    return 1
}

# dx_persist_migrate_refusal DEST: the one Error line for DX_MIGRATE_WHY (the
# marker fields are still those dx_persist_migrate_decide parsed).
dx_persist_migrate_refusal() {
    local dest="$1" root="${DX_PERSIST_HOST_ROOT:-}" msg from
    case "$DX_MIGRATE_WHY" in
        root)
            msg="the share root DX_PERSIST_HOST_ROOT=$root could not be checked on ${DX_REMOTE_HOST:-the NAS}, or it does not resolve to an absolute directory other than / without a comma; fix DX_PERSIST_HOST_ROOT in the private profile or make the share available, then retry." ;;
        unmounted)
            msg="the share root $root does not look mounted: its sentinel file DX_PERSIST_HOST_MOUNT_SENTINEL=${DX_PERSIST_HOST_MOUNT_SENTINEL:-} is missing (an unmounted or locked volume can leave an empty mount point); mount or unlock the share, then retry." ;;
        symlink)
            msg="$dest, or a level above it under the share root (dxe, dxe/$DX_CONTAINER_NAME), is a symlink; the migration copies only into a real directory, so replace the symlink with a directory, then retry." ;;
        unmarked)
            msg="$dest is not empty and has no $DX_PERSIST_MARKER_NAME marker; the migration copies only into an empty directory and never merges, so move its contents aside, then retry." ;;
        marker)
            msg="$dest/$DX_PERSIST_MARKER_NAME is not a valid /persist marker; inspect the directory, then move it aside, then retry." ;;
        guest)
            msg="$dest/$DX_PERSIST_MARKER_NAME names guest $DX_PERSIST_MARKER_GUEST, not $DX_CONTAINER_NAME; this directory belongs to another guest, so check DX_PERSIST_HOST_ROOT and DX_CONTAINER_NAME in the profile." ;;
        copying)
            from="${DX_PERSIST_MARKER_SOURCE_VOLUME:-no recorded volume}"
            msg="$dest is marked copying from another source ($from), not the persist volume $DX_PERSIST_VOLUME, so this migration cannot resume into it; finish or abandon that copy (move the directory aside), then retry." ;;
        ready)
            msg="$dest is already migrated (marker ready); to use it, set DX_PERSIST_STORAGE=host-path in the profile and run dx-recreate. Migrating again needs a new empty directory." ;;
        *)
            msg="$dest is marked retired (a rollback returned $DX_CONTAINER_NAME to a volume); migrating again needs a new empty directory, so move the retired one aside by hand first." ;;
    esac
    printf 'Error: %s\n' "$msg" >&2
}

# dx_persist_migrate_seconds START END: whole seconds between two `date +%s`
# readings, or "unknown" when either is not a plain number.
dx_persist_migrate_seconds() {
    case "$1:$2" in
        *[!0-9:]* | :* | *:) echo unknown ;;
        *) echo "$(($2 - $1))" ;;
    esac
}

# dx_persist_migrate_report DEST COPY VERIFY INVENTORY: the report that ends
# stdout (spec section 6 step 3; R32: the dropped `._*` files, from the
# inventory's apple= lines in order).
dx_persist_migrate_report() {
    local apple
    apple="$(sed -n 's/^apple=//p' <<<"$4")"
    printf 'migrated: %s\n' "$1"
    printf 'source_volume: %s\n' "$DX_PERSIST_VOLUME"
    printf 'marker: ready\n'
    printf 'record: %s\n' "$DX_MIGRATE_RECORD"
    printf 'copy_seconds: %s\n' "$2"
    printf 'verify_seconds: %s\n' "$3"
    printf 'appledouble_dropped_count: %s\n' "$(dx_persist_inventory_value "$4" appledouble)"
    if [ -z "$apple" ]; then
        printf 'appledouble_dropped: none\n'
    else
        printf '%s\n' "$apple" | sed 's/^/appledouble_dropped: /'
    fi
    printf 'next: set DX_PERSIST_STORAGE=host-path in the profile, then run dx-recreate (the volume %s is kept).\n' "$DX_PERSIST_VOLUME"
}

# dx_persist_migrate_guest_stopped GUEST OUTCOME: status 0 when the guest is
# stopped or absent (J1); otherwise one Error line, running or unknown, that
# ends with OUTCOME (what the refusal leaves behind at that point), status 1.
dx_persist_migrate_guest_stopped() {
    local state
    state="$(dx_runtime_container_state "$1")" || state=unknown
    case "$state" in
        stopped | absent) return 0 ;;
        running)
            echo "Error: $1 is running; stop it with dx-stop-container first (it must stay stopped for the whole copy and verification), then run dx-persist-migrate again. $2" >&2 ;;
        *)
            echo "Error: cannot tell whether $1 is stopped (Docker on ${DX_REMOTE_HOST:-the NAS} did not say; see above); make sure it is stopped and the NAS is reachable, then retry. $2" >&2 ;;
    esac
    return 1
}

# dx_persist_migrate_run: everything after the lock (the caller holds it).
dx_persist_migrate_run() {
    local guest="$DX_CONTAINER_NAME" volume="$DX_PERSIST_VOLUME" report canon dest inv
    local flags=() created="" copying now ready t0 t1 t2 t3 rc=0
    dx_persist_migrate_guest_stopped "$guest" "Nothing was changed." || return 1
    dx_runtime_volume_owned "$volume" "migrate from" || return 1
    dx_runtime_volume_owned "${DX_NIX_VOLUME:-}" "run rsync from" || return 1
    report="$(dx_runtime_host_dir_probe "$DX_PERSIST_HOST_ROOT" "$guest")" || report=""
    if ! dx_persist_migrate_decide "$guest" "$volume" <<<"$report"; then
        dx_persist_migrate_refusal "${DX_MIGRATE_ROOT:-$DX_PERSIST_HOST_ROOT}/dxe/$guest/persist"
        return 1
    fi
    canon="$DX_MIGRATE_ROOT"
    dest="$canon/dxe/$guest/persist"
    dx_persist_inventory_read "$volume" || return 1
    inv="$DX_INV_OUT"
    [ "$(dx_persist_inventory_value "$inv" acl)" = 0 ] || flags+=(-A)
    [ "$(dx_persist_inventory_value "$inv" xattr)" = 0 ] || flags+=(-X)
    dx_runtime_host_rsync_check "${flags[@]+"${flags[@]}"}" >/dev/null || return 1
    if [ "$DX_MIGRATE_ACTION" = resume ]; then
        created="$DX_MIGRATE_CREATED"
        echo "Resuming the interrupted copy into $dest (marker copying)..."
    else
        created="$(dx_persist_dir_utc_now)"
        if ! copying="$(dx_persist_marker_format "$guest" copying "$volume" "$created" 2>/dev/null)"; then
            echo "Error: the controller's clock gave no usable UTC time ('$created'), so no marker could be made for $dest; nothing was changed." >&2
            return 1
        fi
        echo "Creating $dest with the marker copying..."
        if ! dx_runtime_host_dir_establish "$DX_MIGRATE_ACTION" "$canon" "$guest" "$DX_PERSIST_DIR_OWNER" "$copying"; then
            echo "Error: could not set up $dest on the NAS ($DX_MIGRATE_ACTION; see the lines above); nothing was copied. Fix the cause, then run dx-persist-migrate again." >&2
            return 1
        fi
    fi
    echo "Copying the persist volume $volume into $dest (the guest stays stopped)..."
    t0="$(date +%s)"
    dx_runtime_host_rsync forward "$volume" "$dest" "${flags[@]+"${flags[@]}"}" >&2 || rc=$?
    t1="$(date +%s)"
    if [ "$rc" -ne 0 ]; then
        echo "Error: the copy into $dest stopped before it finished (rsync exit $rc); its marker stays copying, so the guest cannot start on it. Run dx-persist-migrate again to resume the copy." >&2
        return 1
    fi
    echo "Verifying $dest against $volume (manifest)..."
    t2="$(date +%s)"
    dx_runtime_host_manifest_verify forward "$volume" "$dest" || rc=$?
    t3="$(date +%s)"
    if [ "$rc" -ne 0 ]; then
        echo "Error: $dest does not verify against the persist volume $volume (manifest exit $rc; see above), so its marker stays copying and the guest cannot start on it. Investigate, then run dx-persist-migrate again (it resumes and verifies again), or abandon it: the profile is still in volume mode and the volume is unchanged." >&2
        return 3
    fi
    now="$(dx_persist_dir_utc_now)"
    if ! ready="$(dx_persist_marker_format "$guest" ready "$volume" "${created:-$now}" "$now" 2>/dev/null)"; then
        echo "Error: the controller's clock gave no usable UTC time ('$now'), so $dest stays copying; run dx-persist-migrate again." >&2
        return 1
    fi
    # The guest must still be stopped when the copy is declared good (WP6.4b):
    # one started during the copy or the verification may have changed its
    # volume after rsync read it.
    dx_persist_migrate_guest_stopped "$guest" "The copy verified, but $dest stays copying, because the guest may have changed its volume during the copy; the next run resumes and verifies again." || return 1
    if ! dx_runtime_host_dir_marker_set "$canon" "$guest" copying "$ready"; then
        echo "Error: $dest verified, but its marker could not be set to ready (see above), so it stays copying; run dx-persist-migrate again (it resumes and verifies again)." >&2
        return 1
    fi
    if ! dx_persist_dir_record_write "$DX_MIGRATE_RECORD" migrate "${created:-$now}"; then
        echo "Error: $dest is migrated and ready, but its host-path record $DX_MIGRATE_RECORD could not be written; make that path writable. dx-create-volumes writes the missing record once the profile uses DX_PERSIST_STORAGE=host-path (dx-recreate)." >&2
        return 1
    fi
    dx_persist_migrate_report "$dest" "$(dx_persist_migrate_seconds "$t0" "$t1")" "$(dx_persist_migrate_seconds "$t2" "$t3")" "$inv"
}

dx_persist_migrate_main() {
    local rc=0
    case "$#:${1:-}" in
        0:) : ;;
        1:-h | 1:--help) dx_persist_migrate_usage; return 0 ;;
        *) dx_persist_migrate_usage >&2; return 2 ;;
    esac
    dx_persist_migrate_preconditions || return 1
    dx_lifecycle_lock_hold || return 1
    dx_persist_migrate_run || rc=$?
    dx_lifecycle_lock_drop
    return "$rc"
}
