#!/bin/bash
# Shared forward/reverse SSH control-master state engine. Safe to source.

dx_tunnel_direction_valid() { case "$1" in forward|reverse) return 0 ;; *) return 1 ;; esac; }

dx_tunnel_validate_port() {
    local value="$1" label="$2" allow_privileged="${3:-false}" port
    case "$value" in ''|*[!0-9]*) echo "Error: $label port '$value' is not an integer." >&2; return 1 ;; esac
    [ "${#value}" -le 5 ] || { echo "Error: $label port '$value' must be in 1..65535." >&2; return 1; }
    port="$((10#$value))"
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { echo "Error: $label port '$value' must be in 1..65535." >&2; return 1; }
    [ "$allow_privileged" = true ] || [ "$port" -ge 1024 ] || { echo "Error: $label port '$value' is privileged; use a $label port >= 1024." >&2; return 1; }
}

# Not /tmp: macOS sweeps it daily for anything untouched for three days, which
# deletes a live tunnel's metadata from under its own still-running SSH master.
# Sockets live here too, so keep the path short -- AF_UNIX paths cap near 104.
# One expansion rather than a branch: the suite always sets the override, so a
# separate fallback line would never be executed and could never be covered.
dx_tunnel_state_dir() { printf '%s\n' "${DX_TUNNEL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dxe/tunnels}"; }
dx_tunnel_key() { printf '%s:%s:%s' "$1" "$DX_CONTAINER_NAME" "$2"; }
dx_tunnel_hash() { dx_short_hash "$(dx_tunnel_key "$1" "$2")"; }
dx_tunnel_socket_path() { printf '%s/s-%s.sock\n' "$(dx_tunnel_state_dir)" "$(dx_tunnel_hash "$1" "$2")"; }
dx_tunnel_metadata_path() { printf '%s/m-%s.meta\n' "$(dx_tunnel_state_dir)" "$(dx_tunnel_hash "$1" "$2")"; }
dx_tunnel_lock_path() { printf '%s/locks/%s.lock\n' "$(dx_tunnel_state_dir)" "$(dx_tunnel_hash "$1" "$2")"; }
dx_tunnel_legacy_socket_path() { printf '%s/dx-%s-%s-%s.sock\n' "${TMPDIR:-/tmp}" "$1" "$DX_CONTAINER_NAME" "$2"; }

dx_tunnel_prepare_state() {
    local state uid
    state="$(dx_tunnel_state_dir)"
    [ ! -L "$state" ] || { echo "Error: refusing symlinked tunnel state directory $state." >&2; return 1; }
    if [ ! -e "$state" ]; then mkdir -p "$state" 2>/dev/null || [ -d "$state" ] || return 1; fi
    [ ! -L "$state" ] && [ -d "$state" ] || { echo "Error: tunnel state path is not a safe directory: $state." >&2; return 1; }
    uid="$(dx_path_uid "$state")"
    [ "$uid" = "$(id -u)" ] || { echo "Error: tunnel state directory is not owned by the current user: $state." >&2; return 1; }
    [ ! -L "$state/locks" ] || { echo "Error: refusing symlinked tunnel lock directory $state/locks." >&2; return 1; }
    if [ ! -e "$state/locks" ]; then mkdir "$state/locks" 2>/dev/null || [ -d "$state/locks" ] || return 1; fi
    [ ! -L "$state/locks" ] && [ -d "$state/locks" ] || { echo "Error: tunnel lock path is not a safe directory: $state/locks." >&2; return 1; }
    uid="$(dx_path_uid "$state/locks")"
    [ "$uid" = "$(id -u)" ] || { echo "Error: tunnel lock directory is not owned by the current user: $state/locks." >&2; return 1; }
    chmod 0700 "$state" "$state/locks"
}

dx_tunnel_metadata_read() {
    local file="$1" line name value seen=" "
    DX_TUNNEL_META_DIRECTION=""; DX_TUNNEL_META_CONTAINER=""; DX_TUNNEL_META_KEY=""; DX_TUNNEL_META_PEER=""
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *=*) name=${line%%=*}; value=${line#*=} ;; *) return 1 ;; esac
        case "$name" in direction|container|key_port|peer_port) ;; *) return 1 ;; esac
        case "$seen" in *" $name "*) return 1 ;; esac; seen="$seen$name "
        case "$name" in
            direction) DX_TUNNEL_META_DIRECTION=$value ;;
            container) DX_TUNNEL_META_CONTAINER=$value ;;
            key_port) DX_TUNNEL_META_KEY=$value ;;
            peer_port) DX_TUNNEL_META_PEER=$value ;;
        esac; :; done < "$file"
    dx_tunnel_direction_valid "$DX_TUNNEL_META_DIRECTION" && [ "$DX_TUNNEL_META_CONTAINER" = "$DX_CONTAINER_NAME" ] &&
        dx_tunnel_validate_port "$DX_TUNNEL_META_KEY" key true >/dev/null 2>&1 && dx_tunnel_validate_port "$DX_TUNNEL_META_PEER" peer true >/dev/null 2>&1
}

# The state directory lives under /tmp, which macOS sweeps daily for anything
# untouched for three days (com.apple.tmp_cleaner). An SSH master holds its
# socket open indefinitely, so a tunnel that is left up but not re-established
# outlives the metadata file describing it. Restamping the file every time the
# tunnel is confirmed active keeps the pair together for as long as the tunnel
# is in use; dx_tunnel_recover_peer handles the case where it was reaped anyway.
dx_tunnel_metadata_refresh() { [ ! -f "$1" ] || touch "$1" 2>/dev/null || true; }

dx_tunnel_metadata_write() {
    local direction="$1" key_port="$2" peer_port="$3" target tmp state
    state="$(dx_tunnel_state_dir)"; target="$(dx_tunnel_metadata_path "$direction" "$key_port")"
    tmp="$(mktemp "$state/.metadata.XXXXXX")" || return 1
    if ! printf 'direction=%s\ncontainer=%s\nkey_port=%s\npeer_port=%s\n' \
        "$direction" "$DX_CONTAINER_NAME" "$key_port" "$peer_port" > "$tmp" \
        || ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi
}

dx_tunnel_ssh_common() {
    DX_TUNNEL_SSH_OPTS=(-p "$DX_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
}

dx_tunnel_control_active() {
    local socket="$1"
    [ -e "$socket" ] || return 1
    dx_tunnel_ssh_common
    ssh -S "$socket" -O check "${DX_TUNNEL_SSH_OPTS[@]}" dx@127.0.0.1 >/dev/null 2>&1
}

dx_tunnel_remove_state() {
    local direction="$1" key_port="$2" socket="$3"
    rm -f "$socket"
    if [ "$socket" = "$(dx_tunnel_socket_path "$direction" "$key_port")" ]; then rm -f "$(dx_tunnel_metadata_path "$direction" "$key_port")"; else rm -f "$socket.meta"; fi
}

dx_tunnel_legacy_peer() {
    local direction="$1" socket="$2" field
    if [ "$direction" = forward ]; then field=guest_port; else field=host_port; fi
    [ -f "$socket.meta" ] || return 0
    awk -F= -v field="$field" '$1 == field && $2 ~ /^[0-9]+$/ {print $2; exit}' "$socket.meta"
}

# Separated so tests can supply a process table; overriding `ps` itself would
# mean putting a fake on PATH for every command the engine runs.
dx_tunnel_process_list() { ps -xo args= 2>/dev/null; }

# The metadata file only ever caches what the running master already knows: the
# mapping is right there in its argv, exactly as dx_tunnel_start wrote it. So a
# missing or unreadable file is recoverable rather than fatal -- read the peer
# back off the master and republish. Only canonical state is republished; a
# legacy socket has no place in the current layout and gets reported as-is.
dx_tunnel_recover_peer() {
    local direction="$1" key_port="$2" socket="$3" needle line peer
    if [ "$direction" = forward ]; then needle="-S $socket -L"; else needle="-S $socket -R"; fi
    needle="$needle 127.0.0.1:$key_port:127.0.0.1:"
    while IFS= read -r line; do
        case "$line" in *"$needle"*) ;; *) continue ;; esac
        peer=${line#*"$needle"}; peer=${peer%% *}
        dx_tunnel_validate_port "$peer" peer true >/dev/null 2>&1 || continue
        if [ "$socket" = "$(dx_tunnel_socket_path "$direction" "$key_port")" ]; then
            dx_tunnel_metadata_write "$direction" "$key_port" "$peer" || return 1
        fi
        printf '%s\n' "$peer"; return 0; done < <(dx_tunnel_process_list)
    return 1
}

# Discovery is keyed by the metadata file, so a reaped file also hid its socket:
# --list reported nothing while a master still held the port, and --stop-all
# walked straight past it. The key port is in the master's argv too, but unlike
# the peer it has to be proved rather than believed -- re-deriving the socket
# path from the recovered key is what establishes that this socket really is
# this direction's, for this container, on that port.
dx_tunnel_recover_key() {
    local direction="$1" socket="$2" needle line key
    if [ "$direction" = forward ]; then needle="-S $socket -L 127.0.0.1:"; else needle="-S $socket -R 127.0.0.1:"; fi
    while IFS= read -r line; do
        case "$line" in *"$needle"*) ;; *) continue ;; esac
        key=${line#*"$needle"}; key=${key%%:*}
        dx_tunnel_validate_port "$key" key true >/dev/null 2>&1 || continue
        [ "$socket" = "$(dx_tunnel_socket_path "$direction" "$key")" ] || continue
        printf '%s\n' "$key"; return 0; done < <(dx_tunnel_process_list)
    return 1
}

dx_tunnel_peer_for_socket() {
    local direction="$1" key_port="$2" socket="$3" metadata peer
    if [ "$socket" = "$(dx_tunnel_socket_path "$direction" "$key_port")" ]; then
        metadata="$(dx_tunnel_metadata_path "$direction" "$key_port")"
        if dx_tunnel_metadata_read "$metadata"; then
            dx_tunnel_metadata_refresh "$metadata"; printf '%s\n' "$DX_TUNNEL_META_PEER"; return 0
        fi
        dx_tunnel_recover_peer "$direction" "$key_port" "$socket"
    else
        # An unrecoverable legacy peer is missing data, not an error: callers run
        # under `set -e` and have always been able to treat "unknown" as a value.
        peer="$(dx_tunnel_legacy_peer "$direction" "$socket")"
        [ -n "$peer" ] || peer="$(dx_tunnel_recover_peer "$direction" "$key_port" "$socket" || true)"
        [ -z "$peer" ] || printf '%s\n' "$peer"
    fi
}

dx_tunnel_require_prerequisites() {
    local wait_command="$1"
    [ -f "$DX_SSH_KEY" ] || { echo "Error: SSH key file not found at $DX_SSH_KEY." >&2; return 1; }
    dx_require_container_cli || return
    container_system_ensure_started || return
    container_exists "$DX_CONTAINER_NAME" || { echo "Error: Container $DX_CONTAINER_NAME does not exist. Run ./bin/dx first." >&2; return 1; }
    container_is_running "$DX_CONTAINER_NAME" || { echo "Error: Container $DX_CONTAINER_NAME is not running. Run ./bin/dx-start-container first." >&2; return 1; }
    "$wait_command"
}

dx_tunnel_print_active() {
    local direction="$1" key_port="$2" peer_port="$3"
    if [ "$direction" = forward ]; then echo "Active http://127.0.0.1:$key_port -> $DX_CONTAINER_NAME:$peer_port"
    else echo "Active $DX_CONTAINER_NAME 127.0.0.1:$key_port -> host 127.0.0.1:$peer_port"; fi
}

dx_tunnel_start() {
    local direction="$1" key_port="$2" peer_port="$3" socket metadata lock existing="" mapping option
    dx_tunnel_direction_valid "$direction" || return 1
    dx_tunnel_prepare_state || return
    socket="$(dx_tunnel_socket_path "$direction" "$key_port")"; metadata="$(dx_tunnel_metadata_path "$direction" "$key_port")"; lock="$(dx_tunnel_lock_path "$direction" "$key_port")"
    dx_lock_acquire "$lock" "$DX_TUNNEL_LOCK_TIMEOUT" || return
    if dx_tunnel_control_active "$socket"; then
        if dx_tunnel_metadata_read "$metadata"; then
            existing=$DX_TUNNEL_META_PEER; dx_tunnel_metadata_refresh "$metadata"
        else
            existing="$(dx_tunnel_recover_peer "$direction" "$key_port" "$socket" || true)"
            [ -z "$existing" ] || echo "Recovered dx-$direction metadata for port $key_port from its running SSH master."
        fi
        if [ -z "$existing" ]; then echo "Error: port $key_port has an active dx-$direction socket whose peer could not be recovered; run dx-$direction --stop $key_port before changing it." >&2; dx_lock_release "$lock"; return 1; fi
        if [ "$existing" != "$peer_port" ]; then echo "Error: port $key_port is already managed with peer port $existing; stop it before changing it." >&2; dx_lock_release "$lock"; return 1; fi
        dx_tunnel_print_active "$direction" "$key_port" "$peer_port"; dx_lock_release "$lock"; return 0
    fi
    [ ! -e "$socket" ] || { echo "Removing stale dx-$direction socket for port $key_port."; dx_tunnel_remove_state "$direction" "$key_port" "$socket"; }
    if [ "$direction" = forward ] && dx_port_in_use "$key_port"; then echo "Error: Host port 127.0.0.1:$key_port is already in use and is not managed by dx-forward." >&2; dx_lock_release "$lock"; return 1; fi
    dx_tunnel_ssh_common
    # Both directions bind key_port and connect peer_port on the far side, so the
    # mapping text is identical; only the SSH option differs.
    mapping="127.0.0.1:${key_port}:127.0.0.1:${peer_port}"
    if [ "$direction" = forward ]; then option=-L; else option=-R; fi
    if ! ssh -f -N -M -S "$socket" "$option" "$mapping" -i "$DX_SSH_KEY" "${DX_TUNNEL_SSH_OPTS[@]}" -o IdentitiesOnly=yes -o ConnectTimeout="$DX_SSH_CONNECT_TIMEOUT" -o ExitOnForwardFailure=yes dx@127.0.0.1; then dx_lock_release "$lock"; return 1; fi
    if ! dx_tunnel_metadata_write "$direction" "$key_port" "$peer_port"; then
        ssh -S "$socket" -O exit "${DX_TUNNEL_SSH_OPTS[@]}" dx@127.0.0.1 >/dev/null 2>&1 || true
        rm -f "$socket" "$metadata"; dx_lock_release "$lock"; return 1
    fi
    if [ "$direction" = forward ]; then echo "Forwarded http://127.0.0.1:$key_port -> $DX_CONTAINER_NAME:$peer_port"
    else echo "Reverse forwarded $DX_CONTAINER_NAME 127.0.0.1:$key_port -> host 127.0.0.1:$peer_port"; fi
    dx_lock_release "$lock"
}

dx_tunnel_discover() {
    local direction="$1" state path key socket prefix base
    state="$(dx_tunnel_state_dir)"
    if [ -d "$state" ]; then
        for path in "$state"/m-*.meta; do
            [ -f "$path" ] || continue
            if dx_tunnel_metadata_read "$path" && [ "$DX_TUNNEL_META_DIRECTION" = "$direction" ]; then
                socket="$(dx_tunnel_socket_path "$direction" "$DX_TUNNEL_META_KEY")"
                printf '%s\t%s\n' "$DX_TUNNEL_META_KEY" "$socket"
            fi
        done
        for path in "$state"/s-*.sock; do
            [ -e "$path" ] || continue
            key="$(dx_tunnel_recover_key "$direction" "$path")" || continue
            # Orphans only. The metadata loop above already emitted every socket
            # whose file survives, and only the legacy loop below is deduplicated,
            # so emitting a healthy socket here would list it twice.
            if dx_tunnel_metadata_read "$(dx_tunnel_metadata_path "$direction" "$key")"; then continue; fi
            printf '%s\t%s\n' "$key" "$path"
        done
    fi
    prefix="dx-${direction}-${DX_CONTAINER_NAME}-"
    for path in "${TMPDIR:-/tmp}"/"$prefix"*.sock "${TMPDIR:-/tmp}"/"$prefix"*.sock.meta; do
        [ -e "$path" ] || continue; case "$path" in *.meta) path=${path%.meta} ;; esac
        base=${path##*/}; key=${base#"$prefix"}; key=${key%.sock}
        case "$key" in ''|*[!0-9]*) continue ;; esac
        printf '%s\t%s\n' "$key" "$path"
    done | sort -u
}

dx_tunnel_stop_socket_locked() {
    local direction="$1" key_port="$2" socket="$3" metadata
    if dx_tunnel_control_active "$socket"; then
        dx_tunnel_ssh_common
        if ! ssh -S "$socket" -O exit "${DX_TUNNEL_SSH_OPTS[@]}" dx@127.0.0.1 >/dev/null 2>&1 && dx_tunnel_control_active "$socket"; then
            echo "Error: Could not stop dx-$direction port $key_port; its SSH master is still active. State retained at $socket." >&2; return 1
        fi
        dx_tunnel_remove_state "$direction" "$key_port" "$socket"
        if [ "$direction" = forward ]; then echo "Stopped http://127.0.0.1:$key_port"; else echo "Stopped reverse $DX_CONTAINER_NAME 127.0.0.1:$key_port"; fi
    elif [ -e "$socket" ]; then dx_tunnel_remove_state "$direction" "$key_port" "$socket"; echo "Removed stale dx-$direction socket for port $key_port."
    else
        if [ "$socket" = "$(dx_tunnel_socket_path "$direction" "$key_port")" ]; then metadata="$(dx_tunnel_metadata_path "$direction" "$key_port")"; else metadata="$socket.meta"; fi
        if [ -f "$metadata" ]; then dx_tunnel_remove_state "$direction" "$key_port" "$socket"; echo "Removed orphan dx-$direction metadata for port $key_port."; else return 2; fi
    fi
}

dx_tunnel_stop() {
    local direction="$1" key_port="$2" lock socket legacy found=false failed=0 status
    dx_tunnel_direction_valid "$direction" || return 1
    dx_tunnel_prepare_state || return
    lock="$(dx_tunnel_lock_path "$direction" "$key_port")"
    dx_lock_acquire "$lock" "$DX_TUNNEL_LOCK_TIMEOUT" || return
    socket="$(dx_tunnel_socket_path "$direction" "$key_port")"; legacy="$(dx_tunnel_legacy_socket_path "$direction" "$key_port")"
    for socket in "$socket" "$legacy"; do
        if dx_tunnel_stop_socket_locked "$direction" "$key_port" "$socket"; then found=true; else status=$?; [ "$status" -eq 2 ] || failed=1; fi
    done
    dx_lock_release "$lock"
    if [ "$found" = false ] && [ "$failed" -eq 0 ]; then
        if [ "$direction" = forward ]; then echo "No dx-forward forward found for host port $key_port."; else echo "No dx-reverse reverse forward found for guest port $key_port."; fi
    fi
    return "$failed"
}

dx_tunnel_list() {
    local direction="$1" found=false key socket peer
    while IFS="$(printf '\t')" read -r key socket; do
        [ -n "$key" ] || continue; found=true; peer="$(dx_tunnel_peer_for_socket "$direction" "$key" "$socket" || true)"
        if dx_tunnel_control_active "$socket"; then dx_tunnel_print_active "$direction" "$key" "${peer:-unknown}"; echo "  Socket: $socket"
        elif [ -e "$socket" ]; then echo "Stale dx-$direction socket for port $key: $socket"
        else echo "Orphan dx-$direction metadata for port $key: ${socket}.meta"; fi; done < <(dx_tunnel_discover "$direction")
    if [ "$found" = false ]; then if [ "$direction" = forward ]; then echo "No dx-forward forwards found for $DX_CONTAINER_NAME."; else echo "No dx-reverse reverse forwards found for $DX_CONTAINER_NAME."; fi; fi
}

dx_tunnel_stop_all() {
    local direction="$1" found=false failed=0 key socket seen=" "
    while IFS="$(printf '\t')" read -r key socket; do
        [ -n "$key" ] || continue; case "$seen" in *" $key "*) continue ;; esac; seen="$seen$key "; found=true
        dx_tunnel_stop "$direction" "$key" || failed=1; done < <(dx_tunnel_discover "$direction")
    if [ "$found" = false ]; then if [ "$direction" = forward ]; then echo "No dx-forward forwards found for $DX_CONTAINER_NAME."; else echo "No dx-reverse reverse forwards found for $DX_CONTAINER_NAME."; fi; fi
    return "$failed"
}
