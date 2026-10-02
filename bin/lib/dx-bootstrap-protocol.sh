#!/bin/bash
# The shared guest publication-lock protocol (WP5.2; docs/reviews/2026-09-29-
# fable.md A3/B3, extends Astra R3). Safe to source.
#
# Before this file existed, the SAME process-identity plus crash-safe
# directory-lock protocol was hand-copied three times: the launcher heredoc
# in dx_bootstrap_launch_command (bin/lib/dx-ssh-common.sh), the sync's
# guest program (dx_sync_guest_program, bin/lib/dx-bootstrap-sync.sh), and
# the guest's own dx-ai-lock.sh
# (container/.../scripts/lib/dx-ai-lock.sh). The two host copies had
# already drifted once -- an `[ -z "$live_start" ]` clause present in the
# launcher and missing from the sync (harmless today only because
# `owner_start` is already checked non-empty earlier in the same OR-chain,
# but nothing forced the next edit to one copy to follow in the other).
# dx-ai-lock.sh was a third, independently written copy with its own gaps:
# no grace period before reclaiming an ownerless lock directory (the two
# host copies always waited two seconds first), and a GNU-only `mv -T` for
# its stale-owner takeover.
#
# dx_guest_publication_protocol_snippet renders ONE canonical POSIX sh text
# defining process_start, boot_id, publication_lock_acquire and
# publication_lock_release. The launcher and the sync each concatenate this
# in front of their own remaining logic instead of inlining their own
# copies; the health probe (dx_bootstrap_health_command) prepends it too,
# for process_start alone -- WP6.7 had duplicated a fourth copy of just
# that function. The exact same text ships as
# container/.../scripts/lib/dx-publication.sh (a contract in
# tests/test_refactor_contracts.sh asserts the two are byte-identical),
# which dx-ai-lock.sh sources as a plain sibling file (the readDir-driven
# Nix table in home/tools.nix installs every scripts/lib/*.sh file
# together, so dx-publication.sh is always present next to it) and wraps
# with its own dx-ai-specific argument shape (dx_ai_lock_acquire's existing
# `<lock> <proc_root>` signature, kept for its own callers/tests) -- so all
# three now run the exact same, fixture-proven code.
#
# Process-root override: every function below resolves proc paths under
# ${DX_LOCK_PROC_ROOT:-/proc}, never a hardcoded "/proc" literal, so a test
# fixture can point it at a fake tree without touching the real host/guest
# filesystem. Production callers never set DX_LOCK_PROC_ROOT, so this is
# invisible in normal operation, and every existing fixture that fakes the
# real `cat`/`awk` binaries on PATH to simulate /proc keeps working exactly
# as before.
#
# Policy (decided, WP5.2): a stale owner is reclaimed automatically only on
# provable staleness -- its recorded boot id differs from the live boot id,
# or its pid is gone, or its /proc start time no longer matches -- never on
# a timeout alone. An ownerless lock directory (no owner file at all,
# meaning a crash between `mkdir` and the owner write, or a reclaim that
# itself died before its own cleanup) still gets the same small grace
# period the two host copies always used (two loop iterations) before
# being reclaimed, closing dx-ai-lock.sh's own narrower race (it used to
# reclaim an ownerless directory immediately, with no such grace). A
# takeover -- stale owner or ownerless -- is rename-then-remove, never the
# non-atomic `rm -f owner; rmdir` the two host copies used (Fable B3: a
# second contender reading a stale owner could otherwise delete the FIRST
# contender's freshly written owner and rmdir out from under it, yielding
# two simultaneous holders). The rename target names the reclaimer's own
# pid, and losing that rename (another contender's own leftover already
# occupies it) means this attempt does not take over this iteration -- it
# falls through to the same wait/timeout every other contender uses. The
# portable `[ ! -e "$aside" ] && mv "$lock" "$aside"` form is used rather
# than GNU mv's `-T`, since the guest's own `mv` may not support it.
#
# boot_id's raw-UUID short circuit only trusts a
# /proc/sys/kernel/random/boot_id whose content is a hex/dash string (`case
# "$dxgpp_boot" in *[!0-9A-Fa-f-]*) : ;; esac`), falling through to the
# /proc/stat btime fallback otherwise -- dx-ai-lock.sh's own pre-WP5.2
# dx_ai_boot_id had this same validation; unifying the three implementations
# had silently dropped it, which would have let a corrupted or non-Linux
# boot_id file be accepted verbatim as an identity instead of failing closed.
# The garbage-branch case arm is `: ;;`, not a bare `;;` -- kcov cannot mark
# an empty case arm as hit even when it runs, so the no-op `:` gives it a
# statement to attribute coverage to. The stat-scan loop's own `done <
# "$dxgpp_proc_root/stat"` line carries a `KCOV_LOOP_TERMINATOR` marker for
# the same reason tests/run-coverage-linux.sh already excludes
# KCOV_SUBSHELL_TERMINATOR lines: kcov's bash tracer does not attribute a
# hit to a `done < file` loop-redirect line, so it is excluded from the
# coverage gate rather than chased.
dx_guest_publication_protocol_snippet() {
    cat <<'DX_GUEST_PUBLICATION_PROTOCOL'
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
            *[!0-9A-Fa-f-]*) : ;;
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
    done < "$dxgpp_proc_root/stat" # KCOV_LOOP_TERMINATOR
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
# An execution lease ("<generation>\t<boot id>\t<pid>\t<start time>", file name
# "<generation>.<pid>") is live only when its whole incarnation identity still
# holds: well-formed, boot id equal to the current one, a process with that PID
# present, and that process's start time equal to the recorded one. Boot id alone
# is not enough: inside a Docker container it is the host kernel's and survives a
# container restart, so the previous incarnation's PID 1 lease carries the same
# boot id as the live one and only the start time tells them apart.
execution_lease_live() {
    dxgpp_tab=$(printf "\t")
    dxgpp_lgen="" dxgpp_lboot="" dxgpp_lpid="" dxgpp_lstart=""
    IFS="$dxgpp_tab" read -r dxgpp_lgen dxgpp_lboot dxgpp_lpid dxgpp_lstart < "$1" || true
    case "$dxgpp_lgen" in ""|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    case "$dxgpp_lboot" in ""|*[!A-Za-z0-9:-]*) return 1 ;; esac
    case "$dxgpp_lpid" in ""|*[!0-9]*) return 1 ;; esac
    case "$dxgpp_lstart" in ""|*[!0-9]*) return 1 ;; esac
    [ "${1##*/}" = "$dxgpp_lgen.$dxgpp_lpid" ] || return 1
    dxgpp_now=$(boot_id) || return 1
    [ "$dxgpp_lboot" = "$dxgpp_now" ] || return 1
    dxgpp_live=$(process_start "$dxgpp_lpid") || return 1
    [ "$dxgpp_lstart" = "$dxgpp_live" ]
}
# Remove every lease in directory $1 that is not live. Dot-names are in-flight
# temporary writes (generation ids cannot start with a dot) and are left alone.
execution_leases_prune() {
    for dxgpp_lease in "$1"/*; do
        [ -f "$dxgpp_lease" ] || continue
        execution_lease_live "$dxgpp_lease" || rm -f "$dxgpp_lease"
    done
    return 0
}
# Print the names of the live leases in directory $1, one per line (read-only).
execution_leases_live() {
    for dxgpp_lease in "$1"/*; do
        [ -f "$dxgpp_lease" ] || continue
        if execution_lease_live "$dxgpp_lease"; then printf "%s\n" "${dxgpp_lease##*/}"; fi
    done
    return 0
}
# --- END dx_guest_publication_protocol ---
DX_GUEST_PUBLICATION_PROTOCOL
}
