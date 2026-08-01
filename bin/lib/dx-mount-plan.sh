#!/bin/bash
# Pure mount planning and bounded manifest codec. Safe to source.

# These registries and decoded DX_RECORDED_* values are consumed by dx-mount.
# shellcheck disable=SC2034

DX_MOUNT_MANIFEST_FIELDS="CONTAINER_NAME GIT_MOUNT_SOURCE GIT_MOUNT_TARGET IMAGE NIX_VOLUME PERSIST_VOLUME BOOTSTRAP_VOLUME SSH_KEY SSH_KEY_PUB SSH_PORT"
DX_MOUNT_RESOURCE_FIELDS="GIT_MOUNT_SOURCE GIT_MOUNT_TARGET IMAGE NIX_VOLUME PERSIST_VOLUME BOOTSTRAP_VOLUME SSH_KEY SSH_KEY_PUB SSH_PORT"

dx_mount_manifest_var() { printf 'DX_RECORDED_%s\n' "$1"; }

dx_mount_manifest_clear() {
    local field var
    for field in $DX_MOUNT_MANIFEST_FIELDS; do var="$(dx_mount_manifest_var "$field")"; unset "$var"; done
    DX_MOUNT_MANIFEST_FORMAT=""
    DX_MOUNT_MANIFEST_COMPLETE=false
}

dx_mount_legacy_decode_value() {
    local input="$1" output="" body="" char next esc oct i=0 length
    if [ "$input" = "''" ]; then printf '%s' ''; return; fi
    case "$input" in
        \$\'*)
            case "$input" in *\') ;; *) return 1 ;; esac
            body=${input#\$\'}; body=${body%\'}
            length=${#body}; i=0
            while [ "$i" -lt "$length" ]; do
                char=${body:$i:1}
                if [ "$char" = "'" ]; then return 1; fi
                if [ "$char" != "\\" ]; then output="$output$char"; i=$((i + 1)); continue; fi
                i=$((i + 1)); [ "$i" -lt "$length" ] || return 1
                esc=${body:$i:1}
                case "$esc" in
                    n) output="$output"$'\n' ;;
                    r) output="$output"$'\r' ;;
                    t) output="$output"$'\t' ;;
                    a) output="$output"$'\a' ;;
                    b) output="$output"$'\b' ;;
                    e|E) output="$output"$'\033' ;;
                    f) output="$output"$'\f' ;;
                    v) output="$output"$'\v' ;;
                    \\) output="$output\\" ;;
                    \") output="$output\"" ;;
                    \') output="$output'" ;;
                    [0-7])
                        oct=$esc
                        next=${body:$((i + 1)):1}; case "$next" in [0-7]) oct="$oct$next"; i=$((i + 1)) ;; esac
                        next=${body:$((i + 1)):1}; case "$next" in [0-7]) oct="$oct$next"; i=$((i + 1)) ;; esac
                        [ "$oct" != 000 ] || return 1
                        printf -v char "\\$oct"
                        output="$output$char"
                        ;;
                    *) return 1 ;;
                esac
                i=$((i + 1))
            done
            ;;
        *)
            length=${#input}
            while [ "$i" -lt "$length" ]; do
                char=${input:$i:1}
                if [ "$char" = "\\" ]; then
                    i=$((i + 1)); [ "$i" -lt "$length" ] || return 1
                    output="$output${input:$i:1}"
                else
                    case "$char" in [A-Za-z0-9_@%+=:,./-]) output="$output$char" ;; *) return 1 ;; esac
                fi
                i=$((i + 1))
            done
            ;;
    esac
    printf '%s' "$output"
}

dx_mount_base64_encode() {
    local encoded
    encoded="$(printf '%s' "$1" | base64)" || return 1
    printf '%s' "$encoded" | tr -d '\r\n'
}

dx_mount_base64_decode() {
    local encoded="$1" decoded canonical
    case "$encoded" in ''|*[!A-Za-z0-9+/=]*) return 1 ;; esac
    if decoded="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null; status=$?; printf .; exit "$status")"; then :
    elif decoded="$(printf '%s' "$encoded" | base64 -D 2>/dev/null; status=$?; printf .; exit "$status")"; then :
    else return 1
    fi
    decoded=${decoded%.}
    canonical="$(dx_mount_base64_encode "$decoded")"
    [ "$canonical" = "$encoded" ] || return 1
    printf '%s' "$decoded"
}

dx_mount_manifest_field_allowed() {
    case " $DX_MOUNT_MANIFEST_FIELDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

dx_mount_manifest_set() {
    local field="$1" value="$2" var
    dx_mount_manifest_field_allowed "$field" || return 1
    var="$(dx_mount_manifest_var "$field")"
    [ "${!var+x}" != x ] || return 1
    printf -v "$var" '%s' "$value"
}

dx_mount_manifest_validate_field() {
    local field="$1" value="$2"
    case "$field" in
        CONTAINER_NAME|NIX_VOLUME|PERSIST_VOLUME|BOOTSTRAP_VOLUME)
            case "$value" in ''|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac ;;
        IMAGE)
            case "$value" in ''|[.-]*|*[!A-Za-z0-9_./:-]*) return 1 ;; esac ;;
        GIT_MOUNT_SOURCE|GIT_MOUNT_TARGET|SSH_KEY|SSH_KEY_PUB)
            case "$value" in /*) ;; *) return 1 ;; esac ;;
        SSH_PORT)
            case "$value" in ''|*[!0-9]*) return 1 ;; esac
            [ "$value" -ge 1 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null || return 1 ;;
        *) return 1 ;;
    esac
}

dx_mount_manifest_finalize() {
    local field var complete=true
    for field in $DX_MOUNT_MANIFEST_FIELDS; do
        var="$(dx_mount_manifest_var "$field")"
        if [ "${!var+x}" = x ]; then
            dx_mount_manifest_validate_field "$field" "${!var}" || { echo "Error: invalid $field in mount manifest." >&2; return 1; }
        else
            complete=false
        fi
    done
    DX_MOUNT_MANIFEST_COMPLETE=$complete
}

dx_mount_manifest_read_v2() {
    local file="$1" line field encoded value expected number=0
    while IFS="$(printf '\t')" read -r field encoded extra || [ -n "$field$encoded${extra:-}" ]; do
        number=$((number + 1))
        [ "$number" -gt 1 ] || { [ "$field" = DX_MOUNT_MANIFEST_V2 ] && [ -z "$encoded${extra:-}" ] || return 1; continue; }
        expected=$(printf '%s\n' $DX_MOUNT_MANIFEST_FIELDS | sed -n "$((number - 1))p")
        [ -n "$expected" ] && [ "$field" = "$expected" ] && [ -z "${extra:-}" ] || return 1
        value="$(dx_mount_base64_decode "$encoded")" || return 1
        dx_mount_manifest_set "$field" "$value" || return 1; done < "$file"
    [ "$number" -eq 11 ] || return 1
    DX_MOUNT_MANIFEST_FORMAT=2
}

dx_mount_manifest_read_legacy() {
    local file="$1" line number=0 name raw value field version=0
    while IFS= read -r line || [ -n "$line" ]; do
        number=$((number + 1))
        case "$line" in *=*) name=${line%%=*}; raw=${line#*=} ;; *) return 1 ;; esac
        if [ "$name" = DX_MARKER_VERSION ]; then
            [ "$raw" = 1 ] && [ "$version" = 0 ] || return 1
            version=1
            continue
        fi
        case "$name" in DX_RECORDED_*) field=${name#DX_RECORDED_} ;; *) return 1 ;; esac
        dx_mount_manifest_field_allowed "$field" || return 1
        value="$(dx_mount_legacy_decode_value "$raw")" || return 1
        dx_mount_manifest_set "$field" "$value" || return 1; done < "$file"
    DX_MOUNT_MANIFEST_FORMAT=$version
}

dx_mount_manifest_read() {
    local file="$1" first
    dx_mount_manifest_clear
    [ -f "$file" ] || return 1
    IFS= read -r first < "$file" || true
    if [ "$first" = DX_MOUNT_MANIFEST_V2 ]; then
        dx_mount_manifest_read_v2 "$file" || { echo "Error: malformed v2 mount manifest: $file" >&2; return 1; }
    else
        dx_mount_manifest_read_legacy "$file" || { echo "Error: unsafe or malformed legacy mount manifest: $file" >&2; return 1; }
    fi
    dx_mount_manifest_finalize
}

dx_mount_manifest_secure_read() {
    local file="$1" uid
    [ ! -L "$file" ] || { echo "Error: refusing symlinked mount manifest $file." >&2; return 1; }
    [ -f "$file" ] || return 1
    uid="$(dx_mount_path_uid "$file")"
    [ "$uid" = "$(id -u)" ] || { echo "Error: mount manifest is not owned by the current user: $file." >&2; return 1; }
    dx_mount_manifest_read "$file"
}

dx_mount_path_uid() {
    dx_path_uid "$1"
}

dx_mount_prepare_identity_dir() {
    local dir="$1" uid
    if [ -L "$dir" ]; then echo "Error: refusing symlinked mount identity directory $dir." >&2; return 1; fi
    if [ ! -e "$dir" ]; then mkdir -p "$dir"; chmod 0700 "$dir"; fi
    [ -d "$dir" ] || { echo "Error: mount identity path is not a directory: $dir." >&2; return 1; }
    uid="$(dx_mount_path_uid "$dir")"
    [ "$uid" = "$(id -u)" ] || { echo "Error: mount identity directory is not owned by the current user: $dir." >&2; return 1; }
    chmod 0700 "$dir"
}

dx_mount_manifest_write_file() {
    local file="$1" field var value encoded
    printf '%s\n' DX_MOUNT_MANIFEST_V2 > "$file" || return 1
    for field in $DX_MOUNT_MANIFEST_FIELDS; do
        var="$(dx_mount_manifest_var "$field")"; value=${!var}
        encoded="$(dx_mount_base64_encode "$value")" || return 1
        printf '%s\t%s\n' "$field" "$encoded" >> "$file" || return 1
    done
    chmod 0600 "$file" || return 1
}

dx_mount_manifest_publish_new() {
    local target="$1" dir tmp
    dir=${target%/*}
    dx_mount_prepare_identity_dir "$dir" || return
    [ ! -L "$target" ] || { echo "Error: refusing symlinked mount manifest $target." >&2; return 1; }
    tmp="$(mktemp "$dir/.manifest.XXXXXX")" || return 1
    if ! dx_mount_manifest_write_file "$tmp" || ! dx_mount_manifest_read "$tmp"; then rm -f "$tmp"; return 1; fi
    if ! ln "$tmp" "$target" 2>/dev/null; then rm -f "$tmp"; return 2; fi
    rm -f "$tmp"
}

dx_mount_manifest_replace_v2() {
    local target="$1" dir tmp
    dir=${target%/*}; dx_mount_prepare_identity_dir "$dir" || return
    tmp="$(mktemp "$dir/.manifest.XXXXXX")" || return 1
    if ! dx_mount_manifest_write_file "$tmp" || ! dx_mount_manifest_read "$tmp"; then rm -f "$tmp"; return 1; fi
    mv -f "$tmp" "$target"
}

dx_mount_manifest_load_plan_values() {
    DX_RECORDED_CONTAINER_NAME="$DX_CONTAINER_NAME"
    DX_RECORDED_GIT_MOUNT_SOURCE="$DX_GIT_MOUNT_SOURCE"
    DX_RECORDED_GIT_MOUNT_TARGET="$DX_GIT_MOUNT_TARGET"
    DX_RECORDED_IMAGE="$DX_IMAGE"
    DX_RECORDED_NIX_VOLUME="$DX_NIX_VOLUME"
    DX_RECORDED_PERSIST_VOLUME="$DX_PERSIST_VOLUME"
    DX_RECORDED_BOOTSTRAP_VOLUME="$DX_BOOTSTRAP_VOLUME"
    DX_RECORDED_SSH_KEY="$DX_SSH_KEY"
    DX_RECORDED_SSH_KEY_PUB="$DX_SSH_KEY_PUB"
    DX_RECORDED_SSH_PORT="$DX_SSH_PORT"
}
