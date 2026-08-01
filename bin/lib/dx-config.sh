#!/bin/bash
# Sourceable DXE configuration registry and data-file parser.
# This file intentionally does not set shell options or initialize configuration.

DXE_CONFIG_SNAPSHOT_VERSION_CURRENT=1
DXE_CONFIG_FIELDS="DX_CONTAINER_NAME DX_IMAGE DX_SSH_PORT DX_SSH_KEY DX_SSH_KEY_PUB DX_SSH_CONNECT_TIMEOUT DX_CONTEXT_DIR DX_BOOTSTRAP_SOURCE DX_BOOTSTRAP_VOLUME DX_BOOTSTRAP_PATH DX_BOOTSTRAP_WAIT_TIMEOUT DX_GUEST_ACTIVATION_TIMEOUT DX_GUEST_ACTIVATION_ATTEMPTS DX_GUEST_ACTIVATION_RETRY_DELAY DX_NIX_VOLUME DX_NIX_MOUNT DX_NIX_DISK DX_NIX_DISK_SIZE DX_PERSIST_VOLUME DX_GIT_MOUNT_SOURCE DX_GIT_MOUNT_TARGET DX_GUEST_WORKDIR DX_CONTAINER_MEMORY DX_CONTAINER_CPUS DX_CONTAINER_VOLUME_DIR DX_STOP_GRACE_SECONDS DX_STOP_COMMAND_TIMEOUT DX_STOP_WAIT_TIMEOUT DX_DELETE_COMMAND_TIMEOUT DX_MOUNT_IDENTITY_DIR DX_TUNNEL_LOCK_TIMEOUT"

dx_config_is_field() {
    case " $DXE_CONFIG_FIELDS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

dx_config_path_field() {
    case "$1" in
        DX_SSH_KEY|DX_SSH_KEY_PUB|DX_CONTEXT_DIR|DX_BOOTSTRAP_SOURCE|DX_BOOTSTRAP_PATH|DX_NIX_MOUNT|DX_NIX_DISK|DX_GIT_MOUNT_SOURCE|DX_GIT_MOUNT_TARGET|DX_GUEST_WORKDIR|DX_CONTAINER_VOLUME_DIR|DX_MOUNT_IDENTITY_DIR) return 0 ;;
        *) return 1 ;;
    esac
}

dx_config_default() {
    case "$1" in
        DX_CONTAINER_NAME) printf '%s' dx-host ;;
        DX_IMAGE) printf '%s' dx-nixos-26.05 ;;
        DX_SSH_PORT) printf '%s' 2222 ;;
        DX_SSH_KEY) printf '%s/dx_key' "$DX_PROJECT_ROOT" ;;
        DX_SSH_KEY_PUB) printf '%s/dx_key.pub' "$DX_PROJECT_ROOT" ;;
        DX_SSH_CONNECT_TIMEOUT) printf '%s' 15 ;;
        DX_CONTEXT_DIR) printf '%s/container/aarch64-darwin-apple-container-dx-nixos-26.05' "$DX_PROJECT_ROOT" ;;
        DX_BOOTSTRAP_SOURCE) printf '%s' "${DX_CONTEXT_DIR:-$DX_PROJECT_ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05}" ;;
        DX_BOOTSTRAP_VOLUME) printf '%s' dx-bootstrap ;;
        DX_BOOTSTRAP_PATH) printf '%s' /guest-bootstrap ;;
        DX_BOOTSTRAP_WAIT_TIMEOUT) printf '%s' 30 ;;
        DX_GUEST_ACTIVATION_TIMEOUT) printf '%s' 1800 ;;
        DX_GUEST_ACTIVATION_ATTEMPTS) printf '%s' 2 ;;
        DX_GUEST_ACTIVATION_RETRY_DELAY) printf '%s' 5 ;;
        DX_NIX_VOLUME) printf '%s' dx-nix ;;
        DX_NIX_MOUNT) printf '%s' /nix ;;
        DX_NIX_DISK) printf '%s/.dx-cache/nix-store.img' "${HOME:?}" ;;
        DX_NIX_DISK_SIZE) printf '%s' 20G ;;
        DX_PERSIST_VOLUME) printf '%s' dx-persist ;;
        DX_GIT_MOUNT_SOURCE) printf '%s' '' ;;
        DX_GIT_MOUNT_TARGET) printf '%s' /workspace ;;
        DX_GUEST_WORKDIR) printf '%s' '' ;;
        DX_CONTAINER_MEMORY) printf '%s' 12G ;;
        DX_CONTAINER_CPUS) printf '%s' 4 ;;
        DX_CONTAINER_VOLUME_DIR) printf '%s/Library/Application Support/com.apple.container/volumes' "${HOME:?}" ;;
        DX_STOP_GRACE_SECONDS) printf '%s' 5 ;;
        DX_STOP_COMMAND_TIMEOUT) printf '%s' 15 ;;
        DX_STOP_WAIT_TIMEOUT) printf '%s' 5 ;;
        DX_DELETE_COMMAND_TIMEOUT) printf '%s' 15 ;;
        DX_MOUNT_IDENTITY_DIR) printf '%s/.dx-cache/mount-identities' "${HOME:?}" ;;
        DX_TUNNEL_LOCK_TIMEOUT) printf '%s' 5 ;;
        *) return 1 ;;
    esac
}

dx_config_validate_value() {
    local name="$1" value="$2" number
    case "$name" in
        DX_CONTAINER_NAME|DX_NIX_VOLUME|DX_PERSIST_VOLUME|DX_BOOTSTRAP_VOLUME)
            case "$value" in ''|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
            ;;
        DX_IMAGE)
            case "$value" in ''|[.-]*|*[!A-Za-z0-9_./:-]*) return 1 ;; esac
            ;;
        DX_SSH_PORT)
            case "$value" in ''|*[!0-9]*) return 1 ;; esac
            [ "$value" -ge 1 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null || return 1
            ;;
        DX_SSH_CONNECT_TIMEOUT|DX_BOOTSTRAP_WAIT_TIMEOUT|DX_GUEST_ACTIVATION_TIMEOUT|DX_GUEST_ACTIVATION_ATTEMPTS|DX_GUEST_ACTIVATION_RETRY_DELAY|DX_CONTAINER_CPUS|DX_STOP_GRACE_SECONDS|DX_STOP_COMMAND_TIMEOUT|DX_STOP_WAIT_TIMEOUT|DX_DELETE_COMMAND_TIMEOUT|DX_TUNNEL_LOCK_TIMEOUT)
            case "$value" in ''|*[!0-9]*|0) return 1 ;; esac
            ;;
        DX_NIX_DISK_SIZE|DX_CONTAINER_MEMORY)
            case "$value" in
                *[KMGTPkmgpt]) number=${value%?} ;;
                *) number=$value ;;
            esac
            case "$number" in ''|*[!0-9]*|0) return 1 ;; esac
            ;;
        DX_BOOTSTRAP_PATH|DX_NIX_MOUNT|DX_GIT_MOUNT_TARGET)
            case "$value" in /*) ;; *) return 1 ;; esac
            ;;
        DX_SSH_KEY|DX_SSH_KEY_PUB|DX_CONTEXT_DIR|DX_BOOTSTRAP_SOURCE|DX_NIX_DISK|DX_CONTAINER_VOLUME_DIR|DX_MOUNT_IDENTITY_DIR)
            case "$value" in /*) ;; *) return 1 ;; esac
            ;;
        DX_GIT_MOUNT_SOURCE|DX_GUEST_WORKDIR)
            case "$value" in ''|/*) ;; *) return 1 ;; esac
            ;;
    esac
}

dx_config_parse_error() {
    echo "Error: $1:$2: $3" >&2
    return 1
}

# Parse NAME=value records as data into DXE_PARSED_<NAME> variables.
dx_parse_config_file() {
    local file="$1" line number=0 name value seen=" " parsed_name
    for name in $DXE_CONFIG_FIELDS; do
        unset "DXE_PARSED_$name"
    done
    [ -f "$file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        number=$((number + 1))
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in export\ *) line=${line#export } ;; esac
        case "$line" in
            *=*) name=${line%%=*}; value=${line#*=} ;;
            *) dx_config_parse_error "$file" "$number" "expected NAME=value"; return 1 ;;
        esac
        dx_config_is_field "$name" || { dx_config_parse_error "$file" "$number" "unknown configuration field '$name'"; return 1; }
        case "$seen" in *" $name "*) dx_config_parse_error "$file" "$number" "duplicate configuration field '$name'"; return 1 ;; esac
        seen="$seen$name "

        case "$value" in
            *\`*) dx_config_parse_error "$file" "$number" "shell syntax is not allowed in configuration data"; return 1 ;;
        esac
        case "$value" in
            *\\*|*\'*|*\"*|*\;*|*\&*|*\|*|*\<*|*\>*|*'$('*) dx_config_parse_error "$file" "$number" "quotes, escapes, substitutions, and control operators are not allowed"; return 1 ;;
        esac
        if [ "$value" = '${DX_PROJECT_ROOT}' ]; then
            dx_config_path_field "$name" || { dx_config_parse_error "$file" "$number" "DX_PROJECT_ROOT placeholder is not allowed for '$name'"; return 1; }
            value="$DX_PROJECT_ROOT"
        else
            case "$value" in
                *'${DX_PROJECT_ROOT}'*)
                    dx_config_path_field "$name" || { dx_config_parse_error "$file" "$number" "DX_PROJECT_ROOT placeholder is not allowed for '$name'"; return 1; }
                    value=${value//'${DX_PROJECT_ROOT}'/$DX_PROJECT_ROOT}
                    ;;
                *'$'*) dx_config_parse_error "$file" "$number" "variable expansion is not allowed"; return 1 ;;
            esac
        fi
        dx_config_validate_value "$name" "$value" || { dx_config_parse_error "$file" "$number" "invalid value for '$name'"; return 1; }
        parsed_name="DXE_PARSED_$name"
        printf -v "$parsed_name" '%s' "$value"; done < "$file"
}

dx_validate_config_snapshot() {
    local expected_root="$1" name origin_name value
    [ "${DXE_CONFIG_SNAPSHOT_VERSION:-}" = "$DXE_CONFIG_SNAPSHOT_VERSION_CURRENT" ] || {
        echo "Error: stale or unknown DXE configuration snapshot version '${DXE_CONFIG_SNAPSHOT_VERSION:-unset}'." >&2
        return 1
    }
    [ "${DX_PROJECT_ROOT:-}" = "$expected_root" ] || {
        echo "Error: DXE configuration snapshot belongs to a different project root." >&2
        return 1
    }
    for name in $DXE_CONFIG_FIELDS; do
        [ "${!name+x}" = x ] || { echo "Error: incomplete DXE configuration snapshot: missing $name." >&2; return 1; }
        origin_name="DXE_CONFIG_ORIGIN_$name"
        [ "${!origin_name+x}" = x ] || { echo "Error: incomplete DXE configuration snapshot: missing $origin_name." >&2; return 1; }
        case "${!origin_name}" in
            default|environment|root:.env|profile:*|flag|mount-plan|mount-derived|manifest|legacy) : ;;
            *) echo "Error: invalid origin for $name in resolved DXE configuration snapshot." >&2; return 1 ;;
        esac
        value=${!name}
        dx_config_validate_value "$name" "$value" || { echo "Error: invalid $name in resolved DXE configuration snapshot." >&2; return 1; }
    done
}

dx_config_set_resolved() {
    local name="$1" value="$2" origin="$3" origin_name
    dx_config_is_field "$name" || { echo "Error: unknown resolved configuration field '$name'." >&2; return 1; }
    dx_config_validate_value "$name" "$value" || { echo "Error: invalid resolved value for $name." >&2; return 1; }
    origin_name="DXE_CONFIG_ORIGIN_$name"
    printf -v "$name" '%s' "$value"
    printf -v "$origin_name" '%s' "$origin"
    export "${name?}" "${origin_name?}"
}

dx_init_config() {
    local root="${1:-}" name parsed_name origin_name value origin env_present
    if [ -z "$root" ]; then
        root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    fi

    if [ "${DXE_CONFIG_RESOLVED:-}" = 1 ]; then
        dx_validate_config_snapshot "$root"
        return
    fi
    if [ -n "${DXE_CONFIG_RESOLVED:-}${DXE_CONFIG_SNAPSHOT_VERSION:-}" ]; then
        echo "Error: partial DXE configuration snapshot markers were inherited; refusing to re-resolve." >&2
        return 1
    fi
    if [ -n "${DX_WORKSPACE_VOLUME:-}" ] || [ -n "${DX_WORKSPACE_PATH:-}" ]; then
        echo "Error: workspace persistence variables were renamed." >&2
        echo "Use DX_PERSIST_VOLUME for the persistent volume and remove DX_WORKSPACE_PATH; /persist is fixed." >&2
        return 1
    fi

    DX_PROJECT_ROOT="$root"
    export DX_PROJECT_ROOT
    dx_parse_config_file "$DX_PROJECT_ROOT/.env"

    for name in $DXE_CONFIG_FIELDS; do
        parsed_name="DXE_PARSED_$name"
        origin_name="DXE_CONFIG_ORIGIN_$name"
        env_present=${!name+x}
        if [ "$env_present" = x ]; then
            value=${!name}
            origin=${!origin_name:-environment}
        elif [ "${!parsed_name+x}" = x ]; then
            value=${!parsed_name}
            origin="root:.env"
        else
            value=$(dx_config_default "$name")
            origin=default
        fi
        dx_config_set_resolved "$name" "$value" "$origin"
        unset "$parsed_name"
    done

    DXE_CONFIG_SNAPSHOT_VERSION=$DXE_CONFIG_SNAPSHOT_VERSION_CURRENT
    DXE_CONFIG_RESOLVED=1
    export DXE_CONFIG_SNAPSHOT_VERSION DXE_CONFIG_RESOLVED
}
