#!/usr/bin/env bash
# dx-ai's own publication lock: process-identity helpers plus a
# crash-safe directory lock. Safe to source (import-only: defines
# functions, produces no output, and does not change caller control state).
#
# Branch 11 / Fable B3 (docs/reviews/2026-09-29-fable.md): moved out of
# dx-ai.sh so this logic sits under scripts/lib, in kcov's coverage scope
# (unlike scripts/*.sh, which is exempt -- see tests/coverage/exclusions.txt).

# Return Linux /proc field 22 (starttime) without relying on awk. The comm
# field is parenthesized and may itself contain spaces or ')', so strip through
# the *last* ") " delimiter before counting the remaining fields (field 3
# onward). An optional proc root is for tests; production always uses /proc.
dx_ai_process_start() {
    local pid="$1" proc_root="${2:-/proc}" stat rest
    local IFS=' '
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "$proc_root/$pid/stat" ] || return 1
    IFS= read -r stat < "$proc_root/$pid/stat" || return 1
    rest="${stat##*) }"
    [ "$rest" != "$stat" ] || return 1
    set -- $rest
    [ "$#" -ge 20 ] || return 1
    case "${20}" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "${20}"
}

# A boot ID is part of the lock owner's identity. Prefer the kernel UUID so
# existing raw-UUID owner records remain compatible. Some minimal guests omit
# that file but retain /proc/stat's btime; prefix the fallback explicitly so
# it cannot be confused with a UUID. An optional proc root is for fixtures.
dx_ai_boot_id() {
    local proc_root="${1:-/proc}" boot key value extra
    if [ -r "$proc_root/sys/kernel/random/boot_id" ] && IFS= read -r boot < "$proc_root/sys/kernel/random/boot_id"; then
        case "$boot" in ''|*[!0-9A-Fa-f-]*) ;; *) printf '%s\n' "$boot"; return 0 ;; esac
    fi
    [ -r "$proc_root/stat" ] || return 1
    while read -r key value extra; do
        if [ "$key" = btime ] && [ -z "$extra" ]; then
            case "$value" in ''|*[!0-9]*) return 1 ;; *) printf 'btime:%s\n' "$value"; return 0 ;; esac
        fi
    done < "$proc_root/stat"
    return 1
}

# Acquire dx-ai's publication lock at $1 (an optional $2 overrides /proc, for
# tests). An owner record is `<boot id>\t<pid>\t<start time>`; a held lock is
# reclaimed the moment it is provably not held any more:
#   - ownerless: the directory exists but carries no owner file at all --
#     either a fresh `mkdir` that crashed before it could write one, or a
#     reclaim (below) that removed the owner but was itself killed before its
#     own `rmdir`. Nothing actually holds it.
#   - stale: an owner file names a boot id that is not this boot's, or a pid
#     whose recorded start time no longer matches a live process at that pid
#     (Fable R5's identity, reused here to detect death, not just identify).
# Reclaiming is `mv "$lock" "$lock.reclaim.$$"` then `rm -rf` of the moved
# copy: renaming off the shared path is what makes only one of several
# contenders able to win (whichever process's rename lands first is the only
# one that still sees the old directory to remove; every loser's own rename
# fails because its source has already vanished). If the rename itself loses
# -- its OWN target path already occupied, e.g. a leftover from a previous,
# also-killed reclaim attempt reusing this pid -- this attempt does not take
# over; it falls through to the same wait/timeout every other contender uses.
# The owner file is written via a same-directory tmp file plus `mv`, so a
# concurrent reader (via -f above) never observes a partially written record.
dx_ai_lock_acquire() {
    local lock="$1" proc_root="${2:-/proc}" elapsed=0 self_boot self_start owner_boot owner_pid owner_start live stale reclaim
    self_boot="$(dx_ai_boot_id "$proc_root" || true)"
    self_start="$(dx_ai_process_start "$$" "$proc_root" || true)"
    if [ -z "$self_boot" ] || [ -z "$self_start" ]; then
        echo "Error: cannot identify lock owner process; refusing dx-ai publication lock acquisition." >&2
        return 1
    fi
    [ ! -L "${lock%/*}" ] || { echo "Error: dx-ai publication lock parent is a symlink: ${lock%/*}" >&2; return 1; }
    mkdir -p "${lock%/*}" || { echo "Error: could not create dx-ai publication lock parent: ${lock%/*}" >&2; return 1; }
    [ -d "${lock%/*}" ] && [ ! -L "${lock%/*}" ] || { echo "Error: dx-ai publication lock parent is not a plain directory: ${lock%/*}" >&2; return 1; }
    while ! mkdir "$lock" 2>/dev/null; do
        stale=false
        if [ -e "$lock/owner" ]; then
            IFS="$(printf '\t')" read -r owner_boot owner_pid owner_start < "$lock/owner" || true
            live="$(dx_ai_process_start "${owner_pid:-0}" "$proc_root" || true)"
            if [ "$owner_boot" != "$self_boot" ] || [ -z "$live" ] || [ "$owner_start" != "$live" ]; then stale=true; fi
        else
            stale=true
        fi
        if [ "$stale" = true ]; then
            reclaim="$lock.reclaim.$$"
            if mv -T "$lock" "$reclaim" 2>/dev/null; then rm -rf "$reclaim"; continue; fi
        fi
        [ "$elapsed" -lt 30 ] || { echo "Error: timed out waiting for dx-ai publication lock." >&2; return 1; }
        sleep 1; elapsed=$((elapsed + 1))
    done
    printf '%s\t%s\t%s\n' "$self_boot" "$$" "$self_start" > "$lock/owner.tmp.$$" \
        && mv -f "$lock/owner.tmp.$$" "$lock/owner" \
        || { rm -f "$lock/owner.tmp.$$"; echo "Error: could not record dx-ai publication lock owner: $lock/owner" >&2; return 1; }
}

dx_ai_lock_release() { rm -f "$1/owner"; rmdir "$1"; }
