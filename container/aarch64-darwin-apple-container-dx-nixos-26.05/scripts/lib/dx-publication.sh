#!/bin/sh
# The shared guest publication-lock protocol (WP5.2; docs/reviews/2026-09-29-
# fable.md A3/B3, extends Astra R3). Safe to source: defines process_start,
# boot_id, publication_lock_acquire and publication_lock_release, produces no
# output, and does not change caller control state.
#
# This is the SAME text bin/lib/dx-bootstrap-protocol.sh's
# dx_guest_publication_protocol_snippet renders for the launcher
# (dx_bootstrap_launch_command) and the sync's guest program
# (dx_sync_guest_program) on the host side -- tests/test_refactor_contracts.sh
# asserts the two are byte-identical between the BEGIN/END markers below, so
# this file, the launcher's first-contact rendering, and the sync's rendering
# can never again silently drift the way the launcher and the sync once did
# (a missing `[ -z "$live_start" ]` clause).
#
# container/.../scripts/lib/dx-ai-lock.sh sources this file directly, as a
# plain sibling (the readDir-driven Nix table in home/tools.nix installs
# every scripts/lib/*.sh file together, so this is always present next to
# it), and wraps the four functions below with its own dx-ai-specific
# argument shape.
#
# --- BEGIN dx_guest_publication_protocol (WP5.2; bin/lib/dx-bootstrap-protocol.sh) ---
process_start() {
    stat_line=$(cat "${DX_LOCK_PROC_ROOT:-/proc}/${1:-0}/stat" 2>/dev/null) || return 1
    stat_fields=${stat_line##*) }
    set -- $stat_fields
    [ "$#" -ge 20 ] || return 1
    shift 19
    printf "%s\n" "$1"
}
boot_id() {
    dxgpp_proc_root=${DX_LOCK_PROC_ROOT:-/proc}
    if dxgpp_boot=$(cat "$dxgpp_proc_root/sys/kernel/random/boot_id" 2>/dev/null) && [ -n "$dxgpp_boot" ]; then
        case "$dxgpp_boot" in
            *[!0-9A-Fa-f-]*) ;;
            *) printf "%s\n" "$dxgpp_boot"; return 0 ;;
        esac
    fi
    [ -r "$dxgpp_proc_root/stat" ] || return 1
    while read -r dxgpp_key dxgpp_value dxgpp_extra; do
        if [ "$dxgpp_key" = btime ] && [ -z "$dxgpp_extra" ]; then
            case "$dxgpp_value" in
                ''|*[!0-9]*) return 1 ;;
                *) printf "btime:%s\n" "$dxgpp_value"; return 0 ;;
            esac
        fi
    done < "$dxgpp_proc_root/stat"
    return 1
}
publication_lock_acquire() {
    lock=$1
    timeout=${2:-30}
    self_boot=$(boot_id) || self_boot=""
    self_start=$(process_start $$) || self_start=""
    if [ -z "$self_boot" ] || [ -z "$self_start" ]; then
        echo "Error: cannot identify lock owner process; refusing publication lock acquisition." >&2
        return 1
    fi
    [ ! -L "${lock%/*}" ] || { echo "Error: publication lock parent is a symlink: ${lock%/*}" >&2; return 1; }
    mkdir -p "${lock%/*}" 2>/dev/null || { echo "Error: could not create the publication lock parent: ${lock%/*}" >&2; return 1; }
    [ -d "${lock%/*}" ] && [ ! -L "${lock%/*}" ] || { echo "Error: publication lock parent is not a plain directory: ${lock%/*}" >&2; return 1; }
    elapsed=0
    while ! mkdir "$lock" 2>/dev/null; do
        if [ -f "$lock/owner" ]; then
            tab=$(printf "\t")
            IFS="$tab" read -r owner_boot owner_pid owner_start < "$lock/owner" || true
            live_start=$(process_start "${owner_pid:-0}" || true)
            if [ -z "${owner_boot:-}" ] || [ -z "${owner_pid:-}" ] || [ -z "${owner_start:-}" ] \
                || [ "$owner_boot" != "$self_boot" ] || [ -z "$live_start" ] || [ "$owner_start" != "$live_start" ]; then
                aside="$lock.reclaim.$$"
                if [ ! -e "$aside" ] && mv "$lock" "$aside" 2>/dev/null; then rm -rf "$aside"; continue; fi
            fi
        elif [ "$elapsed" -ge 2 ]; then
            aside="$lock.reclaim.$$"
            if [ ! -e "$aside" ] && mv "$lock" "$aside" 2>/dev/null; then rm -rf "$aside"; elapsed=0; continue; fi
        fi
        [ "$elapsed" -lt "$timeout" ] || { echo "Error: timed out waiting for the guest publication lock." >&2; return 1; }
        sleep 1; elapsed=$((elapsed + 1))
    done
    owner_tmp="$lock/owner.tmp.$$"
    if ! printf "%s\t%s\t%s\n" "$self_boot" "$$" "$self_start" > "$owner_tmp" || ! mv "$owner_tmp" "$lock/owner"; then
        rm -f "$owner_tmp"; rmdir "$lock" 2>/dev/null || true
        echo "Error: could not record the publication lock owner: $lock/owner" >&2
        return 1
    fi
}
publication_lock_release() { rm -f "$1/owner"; rmdir "$1"; }
# --- END dx_guest_publication_protocol ---
