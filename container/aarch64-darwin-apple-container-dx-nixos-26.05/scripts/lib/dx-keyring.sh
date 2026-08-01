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
