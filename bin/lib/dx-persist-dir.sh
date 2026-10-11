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

# --- The start decision (WP4.3; plans/do D-2, D-7, D-9; spec R15, R17, R18) --
#
# In host-path mode dx-create-volumes and dx-start-container both probe the
# per-guest directory once (dx_runtime_host_dir_probe), ask whether the
# guest's named persist volume and the D-7 record exist, and pass those facts
# to the pure dx_persist_start_decision. dx-create-volumes acts on create,
# adopt and ok-fresh-start through dx_persist_dir_establish (the WP4.4 seam);
# dx-start-container starts only on ok. Every refusal is one `Error:` line
# naming the fix, printed before anything is written to the share and before
# any volume is created. Volume mode makes none of these calls.

# The D-7 record of host-path use: one entry per profile, named by the DQ6
# profile id (DX_REMOTE_HOST__DX_CONTAINER_NAME), under the controller's
# state directory. Destroy and reset never delete it; WP4.4 writes it.
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

# Host-path mode, shared by dx-create-volumes and dx-start-container: one
# probe, the volume and record lookups, then the decision. Prints the token
# on stdout when it is not a refusal; otherwise one Error line, status 1.
dx_persist_host_dir_decide() {
    local report volume=no record=no token
    if ! dx_persist_marker_valid_name "${DX_CONTAINER_NAME:-}"; then
        echo "Error: DX_CONTAINER_NAME=${DX_CONTAINER_NAME:-} cannot name a /persist host directory (it must start with a letter or digit); rename the guest or use DX_PERSIST_STORAGE=volume." >&2
        return 1
    fi
    report="$(dx_runtime_host_dir_probe "$DX_PERSIST_HOST_ROOT" "$DX_CONTAINER_NAME")" || report=""
    if dx_runtime_volume_exists "$DX_PERSIST_VOLUME"; then volume=yes; fi
    if dx_persist_dir_record_exists; then record=yes; fi
    if token="$(printf '%s\n' "$report" | dx_persist_start_decision "$DX_CONTAINER_NAME" "$volume" "$record" "${DX_PERSIST_FRESH_START:-}")"; then
        printf '%s\n' "$token"
        return 0
    fi
    dx_persist_refusal "$token" "$report" "$volume" "$record"
    return 1
}

# dx-create-volumes, before any volume is created: prints nothing in volume
# mode; in host-path mode prints the decision token, or refuses (status 1).
dx_persist_create_decision() {
    [ "${DX_PERSIST_STORAGE:-volume}" = host-path ] || return 0
    dx_persist_host_dir_decide
}

# dx-create-volumes' /persist step, given dx_persist_create_decision's token.
# Volume mode ensures the named volume exactly as before. Host-path mode never
# creates that volume: ok needs nothing, and create, adopt and ok-fresh-start
# go to dx_persist_dir_establish once.
dx_persist_storage_ensure() {
    local dir
    if [ "${DX_PERSIST_STORAGE:-volume}" != host-path ]; then
        echo "Ensuring persist volume $DX_PERSIST_VOLUME..."
        container_ensure_volume "$DX_PERSIST_VOLUME"
        return
    fi
    dir="$(dx_persist_configured_source)"
    case "${1:-}" in
        ok) echo "Using /persist directory $dir (marker ready)." ;;
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
            echo "Error: no host-path /persist decision to act on ('${1:-}'); run dx-create-volumes again." >&2
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

# dx_persist_dir_establish create|adopt|fresh-start -- the seam WP4.4
# implements: create the directory or write its `ready` marker on the NAS,
# then write the D-7 record. Until then it fails closed: one Error line, no
# runtime, remote or file-system call, status 1.
dx_persist_dir_establish() {
    echo "Error: creating or marking the /persist host directory (${1:-}) is not implemented yet (plans/do WP4.4); nothing was changed, so use DX_PERSIST_STORAGE=volume until it is." >&2
    return 1
}
