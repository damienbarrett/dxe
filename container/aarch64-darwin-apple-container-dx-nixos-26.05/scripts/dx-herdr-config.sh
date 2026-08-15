#!/usr/bin/env bash
set -euo pipefail

declare -a DX_HERDR_SCALAR_ORDER=()
declare -a DX_HERDR_COMMAND_ORDER=()
declare -A DX_HERDR_SCALAR_LINES=()
declare -A DX_HERDR_COMMAND_BLOCKS=()
declare -A DX_HERDR_EXISTING_TABLES=()
declare -A DX_HERDR_EXISTING_SCALARS=()
declare -A DX_HERDR_EXISTING_COMMANDS=()
declare -A DX_HERDR_EXISTING_BINDINGS=()
declare -A DX_HERDR_EMITTED_TABLES=()

dx_herdr_flush_template_command() {
    local command_key="$1" command_block="$2"
    [ -n "$command_block" ] || return 0
    [ -n "$command_key" ] || {
        echo "Error: Herdr template contains a command without a simple string key." >&2
        return 1
    }
    [ -z "${DX_HERDR_COMMAND_BLOCKS[$command_key]:-}" ] || {
        echo "Error: Herdr template contains duplicate command key $command_key." >&2
        return 1
    }
    DX_HERDR_COMMAND_ORDER+=("$command_key")
    DX_HERDR_COMMAND_BLOCKS["$command_key"]="$command_block"
}

dx_herdr_read_template() {
    local template="$1"
    local scalar_header_re='^[[:space:]]*\[([A-Za-z0-9_.-]+)\][[:space:]]*(#.*)?$'
    local array_header_re='^[[:space:]]*\[\[([A-Za-z0-9_.-]+)\]\][[:space:]]*(#.*)?$'
    local assignment_re='^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*='
    local command_key_re='^[[:space:]]*key[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*(#.*)?$'
    local line current_table="" scalar_key scalar_id
    local in_command=0 command_key="" command_block=""

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ $array_header_re ]]; then
            dx_herdr_flush_template_command "$command_key" "$command_block"
            current_table="${BASH_REMATCH[1]}"
            in_command=0
            command_key=""
            command_block=""
            if [ "$current_table" = keys.command ]; then
                in_command=1
                command_block="$line"
            fi
            continue
        fi
        if [[ $line =~ $scalar_header_re ]]; then
            dx_herdr_flush_template_command "$command_key" "$command_block"
            current_table="${BASH_REMATCH[1]}"
            in_command=0
            command_key=""
            command_block=""
            continue
        fi
        if [ "$in_command" -eq 1 ]; then
            command_block+=$'\n'
            command_block+="$line"
            if [[ $line =~ $command_key_re ]]; then command_key="${BASH_REMATCH[1]}"; fi
            continue
        fi
        case "$current_table" in
            keys|ui|ui.sidebar.agents|experimental|advanced)
                if [[ $line =~ $assignment_re ]]; then
                    scalar_key="${BASH_REMATCH[1]}"
                    scalar_id="$current_table|$scalar_key"
                    [ -z "${DX_HERDR_SCALAR_LINES[$scalar_id]:-}" ] || {
                        echo "Error: Herdr template contains duplicate $current_table.$scalar_key." >&2
                        return 1
                    }
                    DX_HERDR_SCALAR_ORDER+=("$scalar_id")
                    DX_HERDR_SCALAR_LINES["$scalar_id"]="$line"
                fi
                ;;
        esac
    done < "$template"
    dx_herdr_flush_template_command "$command_key" "$command_block"
}

dx_herdr_read_existing() {
    local config_file="$1"
    local scalar_header_re='^[[:space:]]*\[([A-Za-z0-9_.-]+)\][[:space:]]*(#.*)?$'
    local array_header_re='^[[:space:]]*\[\[([A-Za-z0-9_.-]+)\]\][[:space:]]*(#.*)?$'
    local assignment_re='^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*='
    local command_key_re='^[[:space:]]*key[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*(#.*)?$'
    local command_key_literal_re="^[[:space:]]*key[[:space:]]*=[[:space:]]*'([^']+)'[[:space:]]*(#.*)?$"
    local binding_re='^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*(#.*)?$'
    local binding_literal_re="^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*'([^']+)'[[:space:]]*(#.*)?$"
    local line current_table="" scalar_key

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ $array_header_re ]]; then
            current_table="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ $line =~ $scalar_header_re ]]; then
            current_table="${BASH_REMATCH[1]}"
            case "$current_table" in keys|ui|ui.sidebar.agents|experimental|advanced) DX_HERDR_EXISTING_TABLES["$current_table"]=1 ;; esac
            continue
        fi
        if [ "$current_table" = keys.command ] && [[ $line =~ $command_key_re ]]; then
            DX_HERDR_EXISTING_COMMANDS["${BASH_REMATCH[1]}"]=1
            continue
        fi
        if [ "$current_table" = keys.command ] && [[ $line =~ $command_key_literal_re ]]; then
            DX_HERDR_EXISTING_COMMANDS["${BASH_REMATCH[1]}"]=1
            continue
        fi
        case "$current_table" in
            keys|ui|ui.sidebar.agents|experimental|advanced)
                if [[ $line =~ $assignment_re ]]; then
                    scalar_key="${BASH_REMATCH[1]}"
                    DX_HERDR_EXISTING_SCALARS["$current_table|$scalar_key"]=1
                fi
                if [ "$current_table" = keys ] && [[ $line =~ $binding_re ]]; then
                    DX_HERDR_EXISTING_BINDINGS["${BASH_REMATCH[1]}"]=1
                elif [ "$current_table" = keys ] && [[ $line =~ $binding_literal_re ]]; then
                    DX_HERDR_EXISTING_BINDINGS["${BASH_REMATCH[1]}"]=1
                fi
                ;;
        esac
    done < "$config_file"
}

dx_herdr_emit_missing_scalars() {
    local table="$1" scalar_id scalar_line binding=""
    local binding_re='^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*(#.*)?$'
    [ -z "${DX_HERDR_EMITTED_TABLES[$table]:-}" ] || return 0
    for scalar_id in "${DX_HERDR_SCALAR_ORDER[@]}"; do
        case "$scalar_id" in
            "$table|"*)
                if [ -z "${DX_HERDR_EXISTING_SCALARS[$scalar_id]:-}" ]; then
                    scalar_line="${DX_HERDR_SCALAR_LINES[$scalar_id]}"
                    binding=""
                    if [ "$table" = keys ] && [[ $scalar_line =~ $binding_re ]]; then
                        binding="${BASH_REMATCH[1]}"
                    fi
                    if [ -n "$binding" ] \
                        && { [ -n "${DX_HERDR_EXISTING_BINDINGS[$binding]:-}" ] \
                            || [ -n "${DX_HERDR_EXISTING_COMMANDS[$binding]:-}" ]; }; then
                        continue
                    fi
                    printf '%s\n' "$scalar_line"
                    if [ -n "$binding" ]; then DX_HERDR_EXISTING_BINDINGS["$binding"]=1; fi
                fi
                ;;
        esac
    done
    DX_HERDR_EMITTED_TABLES["$table"]=1
}

dx_herdr_merge_existing() {
    local config_file="$1" output="$2"
    local scalar_header_re='^[[:space:]]*\[([A-Za-z0-9_.-]+)\][[:space:]]*(#.*)?$'
    local array_header_re='^[[:space:]]*\[\[([A-Za-z0-9_.-]+)\]\][[:space:]]*(#.*)?$'
    local line current_table="" next_table table command_key

    while IFS= read -r line || [ -n "$line" ]; do
        next_table=""
        if [[ $line =~ $array_header_re ]]; then
            next_table="${BASH_REMATCH[1]}"
            if [ "$next_table" = keys.command ] && [ -z "${DX_HERDR_EXISTING_TABLES[keys]:-}" ] \
                && [ -z "${DX_HERDR_EMITTED_TABLES[keys]:-}" ]; then
                printf '%s\n' '[keys]' >> "$output"
                dx_herdr_emit_missing_scalars keys >> "$output"
                printf '\n' >> "$output"
            fi
        elif [[ $line =~ $scalar_header_re ]]; then
            next_table="${BASH_REMATCH[1]}"
        fi

        case "$current_table" in keys|ui|ui.sidebar.agents|experimental|advanced)
            if [ -n "$next_table" ]; then dx_herdr_emit_missing_scalars "$current_table" >> "$output"; fi
            ;;
        esac
        printf '%s\n' "$line" >> "$output"
        if [ -n "$next_table" ]; then current_table="$next_table"; fi
    done < "$config_file"

    case "$current_table" in keys|ui|ui.sidebar.agents|experimental|advanced) dx_herdr_emit_missing_scalars "$current_table" >> "$output" ;; esac

    for table in keys ui ui.sidebar.agents experimental advanced; do
        if [ -z "${DX_HERDR_EXISTING_TABLES[$table]:-}" ] && [ -z "${DX_HERDR_EMITTED_TABLES[$table]:-}" ]; then
            printf '\n[%s]\n' "$table" >> "$output"
            dx_herdr_emit_missing_scalars "$table" >> "$output"
        fi
    done

    for command_key in "${DX_HERDR_COMMAND_ORDER[@]}"; do
        if [ -z "${DX_HERDR_EXISTING_COMMANDS[$command_key]:-}" ] \
            && [ -z "${DX_HERDR_EXISTING_BINDINGS[$command_key]:-}" ]; then
            printf '\n%s\n' "${DX_HERDR_COMMAND_BLOCKS[$command_key]}" >> "$output"
        fi
    done
}

dx_herdr_validate_candidate() {
    local candidate="$1" checker="${DX_HERDR_CONFIG_CHECK_BIN:-}"
    if [ -z "$checker" ]; then checker="$(command -v herdr 2>/dev/null || true)"; fi
    [ -n "$checker" ] || return 0
    HERDR_CONFIG_PATH="$candidate" "$checker" config check >/dev/null
}

dx_herdr_seed_config() {
    local template="$1" config_file="$2"
    local config_dir temp_file existing_hash candidate_hash

    DX_HERDR_SCALAR_ORDER=()
    DX_HERDR_COMMAND_ORDER=()
    DX_HERDR_SCALAR_LINES=()
    DX_HERDR_COMMAND_BLOCKS=()
    DX_HERDR_EXISTING_TABLES=()
    DX_HERDR_EXISTING_SCALARS=()
    DX_HERDR_EXISTING_COMMANDS=()
    DX_HERDR_EXISTING_BINDINGS=()
    DX_HERDR_EMITTED_TABLES=()

    [ -f "$template" ] && [ ! -L "$template" ] || {
        echo "Error: Herdr config template is not a regular file: $template" >&2
        return 1
    }
    [ ! -L "$config_file" ] || {
        echo "Error: refusing to replace symlinked Herdr config: $config_file" >&2
        return 1
    }
    config_dir="$(dirname "$config_file")"
    [ ! -L "$config_dir" ] || {
        echo "Error: refusing to seed Herdr config through symlinked directory: $config_dir" >&2
        return 1
    }
    mkdir -p "$config_dir"
    temp_file="$(mktemp "$config_dir/.dxe-herdr-config.XXXXXX")"
    trap 'rm -f "${temp_file:-}"' RETURN

    dx_herdr_read_template "$template"
    if [ ! -s "$config_file" ]; then
        cp "$template" "$temp_file"
    else
        dx_herdr_read_existing "$config_file"
        : > "$temp_file"
        dx_herdr_merge_existing "$config_file" "$temp_file"
    fi
    chmod 0600 "$temp_file"
    if ! dx_herdr_validate_candidate "$temp_file"; then
        echo "Error: merged Herdr configuration failed validation; original left untouched." >&2
        return 1
    fi
    if [ -f "$config_file" ]; then
        existing_hash="$(sha256sum "$config_file")"
        candidate_hash="$(sha256sum "$temp_file")"
        if [ "${existing_hash%% *}" = "${candidate_hash%% *}" ]; then return 0; fi
    fi
    mv -f "$temp_file" "$config_file"
    temp_file=""
    trap - RETURN
}

dx_herdr_config_main() {
    case "${1:-}" in
        seed)
            [ "$#" -eq 3 ] || {
                echo "Usage: dx-herdr-config seed TEMPLATE CONFIG" >&2
                return 64
            }
            dx_herdr_seed_config "$2" "$3"
            ;;
        *)
            echo "Usage: dx-herdr-config seed TEMPLATE CONFIG" >&2
            return 64
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then dx_herdr_config_main "$@"; fi
