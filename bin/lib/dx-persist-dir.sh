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
