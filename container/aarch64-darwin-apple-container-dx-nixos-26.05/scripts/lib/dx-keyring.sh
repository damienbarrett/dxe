#!/usr/bin/env bash
# Shared keyring address data primitives. Safe to source.

dx_keyring_socket_from_address() {
    local address="${1:-}" socket rest
    case "$address" in unix:path=/*) ;; *) return 1 ;; esac
    socket=${address#unix:path=}; rest=""
    case "$socket" in *,*) rest=${socket#*,}; socket=${socket%%,*} ;; esac
    [ -n "$socket" ] || return 1
    case "$socket" in *[[:cntrl:]]*) return 1 ;; esac
    if [ -n "$rest" ]; then case "$rest" in guid=|guid=*[!0-9A-Fa-f]*) return 1 ;; esac; fi
    printf '%s\n' "$socket"
}

dx_keyring_address_valid() { dx_keyring_socket_from_address "${1:-}" >/dev/null; }
dx_keyring_address_is_live() { local socket; socket="$(dx_keyring_socket_from_address "${1:-}")" || return 1; [ -S "$socket" ]; }

dx_keyring_read_address() {
    local file="$1" address extra
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    {
        IFS= read -r address || [ -n "$address" ] || return 1
        if IFS= read -r extra; then : "$extra"; return 1; fi
        :; } < "$file"
    dx_keyring_address_valid "$address" || return 1
    printf '%s\n' "$address"
}

dx_keyring_read_legacy_env() {
    local file="$1" line extra prefix="export DBUS_SESSION_BUS_ADDRESS='" address
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    {
        IFS= read -r line || return 1
        if IFS= read -r extra; then : "$extra"; return 1; fi
        :; } < "$file"
    case "$line" in "$prefix"*"'") ;; *) return 1 ;; esac
    address=${line#"$prefix"}; address=${address%"'"}
    case "$address" in *\'*) return 1 ;; esac
    dx_keyring_address_valid "$address" || return 1
    printf '%s\n' "$address"
}

dx_keyring_write_address() {
    local file="$1" address="$2" dir tmp
    dx_keyring_address_valid "$address" || return 1
    dir=${file%/*}
    [ ! -L "$dir" ] || return 1
    mkdir -p "$dir" || return 1
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    chmod 0700 "$dir" || return 1
    [ ! -L "$file" ] || return 1
    tmp="$(mktemp "$dir/.keyring-address.XXXXXX")" || return 1
    if ! printf '%s\n' "$address" > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
}

dx_keyring_session_config() {
    local dbus_bin="$1" real prefix
    real="$(readlink -f "$dbus_bin")" || return 1; prefix=${real%/bin/dbus-daemon}
    if [ -f "$prefix/share/dbus-1/session.conf" ]; then printf '%s\n' "$prefix/share/dbus-1/session.conf"
    elif [ -f "$prefix/etc/dbus-1/session.conf" ]; then printf '%s\n' "$prefix/etc/dbus-1/session.conf"
    else echo "Error: could not locate dbus session.conf for $dbus_bin." >&2; return 1; fi
}

# --- Branch 16: real liveness, staleness and idempotent start/status. ---
#
# The stale-socket-file defect this branch fixes: after
# dx-stop-container/dx-start-container, the previous boot's /tmp/dbus-*
# socket FILE survives in the container's writable layer. The old check
# (dx_keyring_address_is_live, above) only asked `[ -S "$socket" ]` -- true
# for both a live bus *and* a dead one, since the filesystem entry's type
# does not change when its listener process is gone. Verified live in a
# throwaway container pinned to this guest's exact nixpkgs revision
# (nixos-26.05, d57af924f160a5084293c71c2043f058bd1cdb60): killing the
# dbus-daemon that owns a socket leaves `[ -S ... ]` true, but a real client
# then gets an immediate "Connection refused" (ECONNREFUSED) -- no hang, no
# timeout needed for *that* half, but dbus-send itself is still bounded
# below in case the remote end is alive but wedged. A `kill -0 PID` check on
# a recorded owner pid was tried and rejected: a killed-but-unreaped process
# still answers `kill -0` successfully while zombied (observed in the same
# probe), so pid liveness alone is not the "REAL" test this branch asks for.
# `dbus-send`'s ListNames is the pinned `dbus` package's own client tool
# (verified present alongside dbus-daemon in the same derivation; no busctl
# in this build) and doubles as the Secret Service check G4(b) wants:
# `org.freedesktop.secrets` appears in the same ListNames reply once
# gnome-keyring-daemon is up.
DX_KEYRING_PROBE_TIMEOUT=${DX_KEYRING_PROBE_TIMEOUT:-5}

# A REAL liveness test for a recorded bus address: the socket must exist as
# a real socket-typed filesystem entry AND a live D-Bus client call must
# actually succeed against it, bounded so a wedged remote cannot hang the
# caller. `--print-reply` blocks: `--reply-timeout` (server-side D-Bus wait,
# milliseconds) bounds the RPC itself, and the outer `timeout` (whole
# seconds) also bounds dbus-send's own connect step, since (per the probe
# above) a dead-but-still-socket-typed path returns ECONNREFUSED immediately
# but a partially-alive or misbehaving one might not.
dx_keyring_probe() {
    local address="${1:-}" socket dbus_send
    socket="$(dx_keyring_socket_from_address "$address")" || return 1
    [ -S "$socket" ] || return 1
    dbus_send="$(command -v dbus-send 2>/dev/null)" || return 1
    DBUS_SESSION_BUS_ADDRESS="$address" timeout "$DX_KEYRING_PROBE_TIMEOUT" \
        "$dbus_send" --session --dest=org.freedesktop.DBus --print-reply --reply-timeout=2000 \
        /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1
}

# Whether gnome-keyring-daemon's Secret Service is already registered on a
# live bus -- used by dx_keyring_start to decide whether starting it again
# is necessary (idempotent: a live bus + a running keyring means no new
# processes).
dx_keyring_secrets_registered() {
    local address="${1:-}" dbus_send names
    dbus_send="$(command -v dbus-send 2>/dev/null)" || return 1
    # One physical line, unlike dx_keyring_probe's backslash-continued form
    # above: kcov's bash instrumentation did not attribute any hit to the
    # first physical line of a backslash-continued command when that command
    # is itself the body of a `var="$(...)"` assignment (verified: identical
    # logic, split the same way, inside dx_keyring_probe -- a bare command,
    # not a `$(...)` assignment -- was fully covered by the same test run).
    names="$(DBUS_SESSION_BUS_ADDRESS="$address" timeout "$DX_KEYRING_PROBE_TIMEOUT" "$dbus_send" --session --dest=org.freedesktop.DBus --print-reply --reply-timeout=2000 /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null)" || return 1
    case "$names" in *org.freedesktop.secrets*) return 0 ;; *) return 1 ;; esac
}

# Removes a recorded address's socket file and the address file itself, but
# only when the probe actually fails -- never touches a live bus. Silently a
# no-op when there is no recorded address to begin with (nothing is stale).
dx_keyring_clear_stale() {
    local address_file="$1" address socket
    address="$(dx_keyring_read_address "$address_file" 2>/dev/null)" || return 0
    dx_keyring_probe "$address" && return 0
    socket="$(dx_keyring_socket_from_address "$address" 2>/dev/null)" || socket=""
    [ -z "$socket" ] || rm -f "$socket"
    rm -f "$address_file"
}

# Best-effort pids of processes whose /proc/PID/cmdline contains a literal
# substring -- no `ps`/`pgrep` dependency (neither is guaranteed on this
# guest's minimal profile), matching the existing /proc-reading idiom
# scripts/dx-ai.sh's dx_ai_process_start already uses for the same reason.
# One pid per line; empty output (not an error) when nothing matches.
dx_keyring_pids_matching() {
    local pattern="$1" proc_root="${2:-/proc}" p pid cmd
    for p in "$proc_root"/[0-9]*; do
        pid="${p##*/}"
        [ -r "$p/cmdline" ] || continue
        cmd="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" || continue
        case "$cmd" in *"$pattern"*) printf '%s\n' "$pid" ;; esac
    done
}

# Starts (or reuses) the guest's D-Bus session bus + gnome-keyring Secret
# Service. Resolves dbus-daemon/dbus-send/gnome-keyring-daemon via PATH: the
# caller (dx-ai or the dx-keyring command) always runs through the guest's
# login shell, which already has the published AI generation's profile
# prepended (home/shell.nix's profileExtra), falling back to dx's Home
# Manager profile the same way that PATH itself does. Idempotent: a live bus
# with the Secret Service already registered starts nothing new.
dx_keyring_start() {
    local address_file="$1" address="" dbus_bin config keyring_bin

    address="$(dx_keyring_read_address "$address_file" 2>/dev/null || true)"
    if [ -n "$address" ] && dx_keyring_probe "$address"; then
        echo "D-Bus session bus already running."
    else
        dx_keyring_clear_stale "$address_file"
        dbus_bin="$(command -v dbus-daemon 2>/dev/null)" || {
            echo "Error: dbus-daemon is unavailable; the keyring service cannot start." >&2
            return 1
        }
        config="$(dx_keyring_session_config "$dbus_bin")" || return 1
        address="$("$dbus_bin" --config-file="$config" --fork --print-address)" || return 1
        dx_keyring_address_valid "$address" || {
            echo "Error: dbus-daemon returned an invalid bus address." >&2
            return 1
        }
        dx_keyring_write_address "$address_file" "$address" || return 1
        echo "D-Bus session bus started."
    fi

    export DBUS_SESSION_BUS_ADDRESS="$address"

    if dx_keyring_secrets_registered "$address"; then
        echo "gnome-keyring Secret Service already running."
        return 0
    fi
    if keyring_bin="$(command -v gnome-keyring-daemon 2>/dev/null)"; then
        printf '' | DBUS_SESSION_BUS_ADDRESS="$address" "$keyring_bin" --unlock --start --components=secrets >/dev/null 2>&1 || true
        echo "gnome-keyring Secret Service started."
    else
        echo "Warning: gnome-keyring-daemon is unavailable; secrets will not be unlocked." >&2
    fi
}

# Prints exactly one of live/stale/absent for the recorded address, plus
# pids when live.
dx_keyring_status() {
    local address_file="$1" address dbus_pids keyring_pids
    if [ ! -f "$address_file" ]; then
        echo "absent"
        return 0
    fi
    address="$(dx_keyring_read_address "$address_file" 2>/dev/null || true)"
    if [ -z "$address" ]; then
        echo "absent"
        return 0
    fi
    if ! dx_keyring_probe "$address"; then
        echo "stale"
        return 0
    fi
    echo "live"
    dbus_pids="$(dx_keyring_pids_matching dbus-daemon)"
    keyring_pids="$(dx_keyring_pids_matching gnome-keyring-daemon)"
    printf 'dbus-daemon pid(s): %s\n' "${dbus_pids:-none}"
    printf 'gnome-keyring-daemon pid(s): %s\n' "${keyring_pids:-none}"
}
