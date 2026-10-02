#!/bin/bash
# Sourceable DXE configuration registry and data-file parser.
# This file intentionally does not set shell options or initialize configuration.

DXE_CONFIG_SNAPSHOT_VERSION_CURRENT=1

# Fable A5's refactor: one table, one line per field, `NAME<TAB>kind<TAB>
# default`. DXE_CONFIG_FIELDS, dx_config_path_field, dx_config_default and
# dx_config_validate_value are all lookups over this table (plus one
# validator per kind) instead of four hand-synced per-field lists that had
# to agree by construction (and didn't: dx_config_validate_value had no
# default arm, and DX_BOOTSTRAP_SOURCE's default depended on field order --
# see the two commits before this one). Bash 3.2-clean: a multi-line
# string and `case`, no associative arrays (no `declare -A`/namerefs/
# `mapfile`/`local x=$(...)` in this file, matching every other bin/
# library).
#
# kind is one of, chosen to reproduce dx_config_validate_value's original
# per-field arms exactly (see the WP4.3 refactor commit message for the
# full NAME -> kind mapping):
#   enum:a,b   -- exact match against one comma-joined literal list
#   name       -- DX_CONTAINER_NAME's non-empty identifier class
#   optname    -- the same class, but empty is also accepted (DX_REMOTE_HOST)
#   image      -- DX_IMAGE's class (adds `.`/`/`/`:` for image refs)
#   port       -- 1-65535
#   posint     -- a positive (non-zero) integer
#   size       -- a positive integer with an optional K/M/G/T/P(k/m/g/p/t) suffix
#   abspath    -- a non-empty value starting with `/`
#   optpath    -- the same, but empty is also accepted
#
# default is one of:
#   =literal    -- the literal value verbatim (`=` alone means empty)
#   @root:suffix -- "$DX_PROJECT_ROOT/suffix"
#   @home:suffix -- "$HOME/suffix" (HOME must be set, as today)
#   @field:NAME  -- NAME's own default (DX_BOOTSTRAP_SOURCE's default is
#                   exactly DX_CONTEXT_DIR's, independent of field order --
#                   see dx_config_default)
# A heredoc body, unlike a multi-line `$'...'` assignment, is never traced
# by kcov's bash line instrumentation past its opening line -- see the
# `cat <<'EOF'` launcher in dx_bootstrap_launch_command (bin/lib/
# dx-ssh-common.sh), which kcov reports at 100% for the same reason. `read
# -d ''` reads until a NUL byte, which this heredoc never contains, so it
# always hits EOF and returns 1 -- entrypoints source dx-lib.sh under
# `set -e`, so the `|| true` is required here. `read` with a single
# variable name strips only leading/trailing IFS whitespace from the whole
# record (verified against this shell's own read builtin); every embedded
# tab and newline in the table below, including the final field's trailing
# newline before the closing delimiter, survives untouched -- confirmed
# byte-for-byte identical to the previous `$'...\t...'` form via `printf
# '%s' "$DXE_CONFIG_REGISTRY" | od -c`, and behaviourally pinned by section
# 21's registry-defaults fixture case (tests/fixtures/
# config-registry-defaults.txt).
read -r -d '' DXE_CONFIG_REGISTRY <<'DXE_REGISTRY' || true
DX_RUNTIME	enum:apple,docker-ssh	=apple
DX_REMOTE_HOST	optname	=
DX_GUEST_SYSTEM	enum:aarch64-linux,x86_64-linux	=aarch64-linux
DX_NIX_STORAGE_MODE	enum:apple-image,direct-volume	=apple-image
DX_CONTAINER_RESTART_POLICY	enum:no,unless-stopped	=no
DX_CONTAINER_NAME	name	=dx-host
DX_IMAGE	image	=dx-nixos-26.05
DX_SSH_PORT	port	=2222
DX_SSH_KEY	abspath	@root:dx_key
DX_SSH_KEY_PUB	abspath	@root:dx_key.pub
DX_SSH_CONNECT_TIMEOUT	posint	=15
DX_SYSTEM_WAIT_TIMEOUT	posint	=30
DX_CONTEXT_DIR	abspath	@root:container/dx-nixos-26.05
DX_BOOTSTRAP_SOURCE	abspath	@field:DX_CONTEXT_DIR
DX_BOOTSTRAP_VOLUME	name	=dx-bootstrap
DX_BOOTSTRAP_PATH	abspath	=/guest-bootstrap
DX_BOOTSTRAP_WAIT_TIMEOUT	posint	=30
DX_BOOTSTRAP_CONFIRM_TIMEOUT	posint	=5
DX_GUEST_ACTIVATION_TIMEOUT	posint	=1800
DX_GUEST_ACTIVATION_ATTEMPTS	posint	=2
DX_GUEST_ACTIVATION_RETRY_DELAY	posint	=5
DX_NIX_VOLUME	name	=dx-nix
DX_NIX_MOUNT	abspath	=/nix
DX_NIX_DISK	abspath	@home:.dx-cache/nix-store.img
DX_NIX_DISK_SIZE	size	=64G
DX_PERSIST_VOLUME	name	=dx-persist
DX_GIT_MOUNT_SOURCE	optpath	=
DX_GIT_MOUNT_TARGET	abspath	=/workspace
DX_GUEST_WORKDIR	optpath	=
DX_CONTAINER_MEMORY	size	=12G
DX_CONTAINER_CPUS	posint	=4
DX_CONTAINER_VOLUME_DIR	abspath	@home:Library/Application Support/com.apple.container/volumes
DX_STOP_GRACE_SECONDS	posint	=5
DX_STOP_COMMAND_TIMEOUT	posint	=15
DX_STOP_WAIT_TIMEOUT	posint	=5
DX_DELETE_COMMAND_TIMEOUT	posint	=15
DX_MOUNT_IDENTITY_DIR	abspath	@home:.dx-cache/mount-identities
DX_TUNNEL_LOCK_TIMEOUT	posint	=5
DX_BACKUP_DIR	abspath	@home:Backups/dxe-persist
DX_PROFILE_ROOT	optpath	=
DXE_REGISTRY

# Looks up NAME's registry row and prints "kind<TAB>default" (everything
# after the first tab); returns 1 with no output for an unregistered name.
# Every other lookup below is built on this one scan.
dx_config_registry_row() {
    local line name
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        name=${line%%$'\t'*}
        if [ "$name" = "$1" ]; then
            printf '%s' "${line#*$'\t'}"
            return 0
        fi
    done <<<"$DXE_CONFIG_REGISTRY"
    return 1
}

dx_config_kind() {
    local row
    row="$(dx_config_registry_row "$1")" || return 1
    printf '%s' "${row%%$'\t'*}"
}

DXE_CONFIG_FIELDS=""
while IFS= read -r dxe_config_registry_line; do
    [ -n "$dxe_config_registry_line" ] || continue
    DXE_CONFIG_FIELDS="$DXE_CONFIG_FIELDS ${dxe_config_registry_line%%$'\t'*}"
done <<<"$DXE_CONFIG_REGISTRY"
DXE_CONFIG_FIELDS=${DXE_CONFIG_FIELDS# }
unset dxe_config_registry_line

dx_config_is_field() {
    case " $DXE_CONFIG_FIELDS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# A path field is exactly one whose kind accepts a filesystem path (the
# only two kinds that ever do): eligible for the ${DX_PROJECT_ROOT}
# placeholder in dx_parse_config_file. This set is identical to the
# original hand-written list -- every abspath/optpath field and no other.
dx_config_path_field() {
    case "$(dx_config_kind "$1")" in
        abspath|optpath) return 0 ;;
        *) return 1 ;;
    esac
}

dx_config_default() {
    local row default_expr
    row="$(dx_config_registry_row "$1")" || return 1
    default_expr=${row#*$'\t'}
    case "$default_expr" in
        '='*) printf '%s' "${default_expr#=}" ;;
        '@field:'*) dx_config_default "${default_expr#@field:}" ;;
        '@root:'*) printf '%s/%s' "$DX_PROJECT_ROOT" "${default_expr#@root:}" ;;
        '@home:'*) printf '%s/%s' "${HOME:?}" "${default_expr#@home:}" ;;
    esac
}

dx_config_validate_value() {
    local name="$1" value="$2" kind number
    # Phase 2 (qnap-dxe-plan.md DQ2/DQ3) ships the docker-ssh adapter
    # alongside Apple's. Phase 1 used the placeholder name `docker`; that
    # bare name is never valid (the implemented value is `docker-ssh`,
    # DQ1's Docker-over-SSH control plane), and it earns its own clear
    # rejection message pointing at the real name, distinct from the
    # generic "invalid value" every other bogus value gets from the kind
    # lookup below -- checked first since it is a value-specific exception
    # to DX_RUNTIME's own enum, not a kind of its own.
    if [ "$name" = DX_RUNTIME ] && [ "$value" = docker ]; then
        echo "Error: DX_RUNTIME=docker was Phase 1's placeholder name; the implemented value is 'docker-ssh'." >&2
        return 1
    fi
    kind="$(dx_config_kind "$name")" || { echo "Error: unknown configuration field '$name'." >&2; return 1; }
    case "$kind" in
        enum:*)
            # Reject an embedded comma before the substring match below,
            # so a value cannot smuggle the whole enum list (or another
            # member plus a trailing comma) past a single-token check.
            case "$value" in *,*) return 1 ;; esac
            case ",${kind#enum:}," in
                *",$value,"*) : ;;
                *) return 1 ;;
            esac
            ;;
        name)
            case "$value" in ''|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
            ;;
        optname)
            # Same character class as `name`, but empty is also accepted --
            # DX_REMOTE_HOST is empty for DX_RUNTIME=apple
            # (dx_config_validate_cross_fields enforces which runtimes
            # require or forbid it; this per-field check only shapes the
            # value when one is given).
            case "$value" in
                '') : ;;
                [.-]*|*[!A-Za-z0-9_.-]*) return 1 ;;
                *) : ;;
            esac
            ;;
        image)
            case "$value" in ''|[.-]*|*[!A-Za-z0-9_./:-]*) return 1 ;; esac
            ;;
        port)
            case "$value" in ''|*[!0-9]*) return 1 ;; esac
            [ "$value" -ge 1 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null || return 1
            ;;
        posint)
            case "$value" in ''|*[!0-9]*|0) return 1 ;; esac
            ;;
        size)
            case "$value" in
                *[KMGTPkmgpt]) number=${value%?} ;;
                *) number=$value ;;
            esac
            case "$number" in ''|*[!0-9]*|0) return 1 ;; esac
            ;;
        abspath)
            case "$value" in /*) ;; *) return 1 ;; esac
            ;;
        optpath)
            case "$value" in ''|/*) ;; *) return 1 ;; esac
            ;;
    esac
}

# Cross-field checks that need more than one already-resolved field at once
# (qnap-dxe-plan.md DQ3: "Invalid cross-field combinations fail before
# contacting either runtime"). Called only after every field in
# DXE_CONFIG_FIELDS has its own per-field value validated and resolved (by
# dx_init_config's own loop, or by dx_validate_config_snapshot for an
# inherited child snapshot) -- never from dx_config_validate_value itself,
# which only ever sees one NAME/value pair and cannot see DX_RUNTIME while
# validating DX_REMOTE_HOST or vice versa.
dx_config_validate_cross_fields() {
    # WP9.4 (Muse B5) compatibility: the guest tree was renamed from
    # container/aarch64-darwin-apple-container-dx-nixos-26.05 to
    # container/dx-nixos-26.05 (the flake is architecture-neutral; the QNAP
    # guest that boots it is x86_64, not the darwin/apple/aarch64 name the
    # old directory carried). A git-tracked symlink at the old path keeps a
    # real profile that still sets DX_CONTEXT_DIR/DX_BOOTSTRAP_SOURCE to the
    # old name working for one release -- this is a warning, not an error,
    # because the path still resolves; it only tells a developer to update
    # their profile before the symlink is removed at the next base
    # changeover (docs/release-maintenance.md). Checked first, unconditional
    # on every other check below (including the ones that `return 1`), so it
    # always fires whenever either field still names the old directory.
    case "${DX_CONTEXT_DIR:-}:${DX_BOOTSTRAP_SOURCE:-}" in
        *aarch64-darwin-apple-container-dx-nixos-26.05*)
            echo "Warning: a configured path names the old 'aarch64-darwin-apple-container-dx-nixos-26.05' guest directory -- this is a deprecated alias for 'container/dx-nixos-26.05', kept as a compatibility symlink for one release and removed at the next base changeover." >&2
            ;;
    esac

    case "${DX_RUNTIME:-}" in
        docker-ssh)
            [ -n "${DX_REMOTE_HOST:-}" ] || {
                echo "Error: DX_REMOTE_HOST is required when DX_RUNTIME=docker-ssh (a validated OpenSSH config alias for the QNAP host)." >&2
                return 1
            }
            ;;
        *)
            [ -z "${DX_REMOTE_HOST:-}" ] || {
                echo "Error: DX_REMOTE_HOST must be empty unless DX_RUNTIME=docker-ssh." >&2
                return 1
            }
            ;;
    esac

    # Runtime <-> Nix storage-mode compatibility (Astra F10, Muse C1).
    # DX_RUNTIME and DX_NIX_STORAGE_MODE are not independent knobs: each
    # runtime's adapter mounts the Nix volume at a fixed place of its own
    # choosing (bin/dx-create-container's own "Volume roles" comment).
    # Apple always stages the volume at /var/lib/dx-nix-raw for the guest
    # to reformat and remount onto /nix -- DX_NIX_STORAGE_MODE=apple-image
    # is the only mode whose guest-side probe (base-and-storage.sh's
    # prepare_nix_volume_impl) matches that shape. The Docker adapter
    # always mounts the volume directly at /nix (docs/refactor/
    # direct-volume-storage.md) -- DX_NIX_STORAGE_MODE=direct-volume is the
    # only mode whose guest-side probe (`findmnt -n -o TARGET /nix`)
    # matches THAT shape. A DX_RUNTIME=docker-ssh profile with the
    # apple-image default (Astra F10's exact reproduction) passes this far
    # today and only fails deep inside guest bootstrap; reject it here
    # instead, before any runtime call.
    case "${DX_RUNTIME:-}:${DX_NIX_STORAGE_MODE:-}" in
        apple:apple-image) : ;;
        docker-ssh:direct-volume) : ;;
        *)
            echo "Error: DX_RUNTIME=${DX_RUNTIME:-} is not compatible with DX_NIX_STORAGE_MODE=${DX_NIX_STORAGE_MODE:-} (supported: DX_RUNTIME=apple with DX_NIX_STORAGE_MODE=apple-image, or DX_RUNTIME=docker-ssh with DX_NIX_STORAGE_MODE=direct-volume)." >&2
            return 1
            ;;
    esac

    # The three named-volume roles must never collide (Astra F10, Muse C1):
    # a shared name would let one role's guest-side traffic reach another
    # role's volume.
    if [ "${DX_NIX_VOLUME:-}" = "${DX_PERSIST_VOLUME:-}" ] \
        || [ "${DX_NIX_VOLUME:-}" = "${DX_BOOTSTRAP_VOLUME:-}" ] \
        || [ "${DX_PERSIST_VOLUME:-}" = "${DX_BOOTSTRAP_VOLUME:-}" ]; then
        echo "Error: DX_NIX_VOLUME, DX_PERSIST_VOLUME, and DX_BOOTSTRAP_VOLUME must all be distinct volume names." >&2
        return 1
    fi
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
    dx_config_validate_cross_fields
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

    dx_config_validate_cross_fields || return 1

    DXE_CONFIG_SNAPSHOT_VERSION=$DXE_CONFIG_SNAPSHOT_VERSION_CURRENT
    DXE_CONFIG_RESOLVED=1
    export DXE_CONFIG_SNAPSHOT_VERSION DXE_CONFIG_RESOLVED
}

# --- Profile helpers (bin/dx-profile and bin/qx stay thin over these) --------

# Profile names follow the registry's own name rule (DX_CONTAINER_NAME's class).
dx_profile_name_valid() {
    dx_config_validate_value DX_CONTAINER_NAME "$1" 2>/dev/null
}

# The directories searched for profiles, one per line, in precedence order:
# the explicit DX_PROFILES_DIR alone, else the user config directory and then
# the checkout's bundled tests/profiles.
dx_profile_search_dirs() {
    if [ -n "${DX_PROFILES_DIR:-}" ]; then
        printf '%s\n' "$DX_PROFILES_DIR"
    else
        printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/dxe/profiles" "$DX_PROJECT_ROOT/tests/profiles"
    fi
}

dx_profile_usage() {
    local directory file
    echo "Usage: $1 <profile> <command...>" >&2
    echo "Available profiles:" >&2
    while IFS= read -r directory; do
        [ -d "$directory" ] || continue
        for file in "$directory"/*.env; do
            [ -f "$file" ] && echo "  $(basename "$file" .env) ($directory)" >&2
        done
    done < <(dx_profile_search_dirs) # KCOV_LOOP_TERMINATOR
}

# Prints the profile file for NAME. Status 2: invalid name; 1: not found.
dx_profile_resolve_file() {
    local profile="$1" first="" second="" directory
    dx_profile_name_valid "$profile" || { echo "Error: invalid profile name '$profile'." >&2; return 2; }
    while IFS= read -r directory; do
        if [ -z "$first" ]; then first="$directory"; else second="$directory"; fi
        if [ -f "$directory/$profile.env" ]; then
            printf '%s\n' "$directory/$profile.env"
            return 0
        fi
    done < <(dx_profile_search_dirs) # KCOV_LOOP_TERMINATOR
    echo "Error: Profile not found: $first/$profile.env${second:+ (also checked $second/$profile.env)}" >&2
    return 1
}

# A profile may pin itself to one checkout (DX_PROFILE_ROOT, kept private in
# the profile): refuse unless this checkout is that one. Both sides are
# canonicalised so symlinked paths compare equal; an unresolvable pin
# canonicalises to nothing and therefore refuses. Only a pin the profile
# itself set counts; an environment-set one is not a profile pin.
dx_profile_enforce_pin() {
    local profile="$1" pin_canonical
    [ -n "${DX_PROFILE_ROOT:-}" ] && [ "${DXE_CONFIG_ORIGIN_DX_PROFILE_ROOT:-}" = "profile:$profile" ] || return 0
    pin_canonical="$(cd "$DX_PROFILE_ROOT" 2>/dev/null && pwd -P)" || pin_canonical=""
    [ -n "$pin_canonical" ] && [ "$pin_canonical" = "$(cd "$DX_PROJECT_ROOT" && pwd -P)" ] && return 0
    echo "Error: profile '$profile' is pinned to $DX_PROFILE_ROOT; run it from that checkout." >&2
    return 2
}

# Load PROFILE's data file into the exported configuration (each field with
# its profile origin), enforce the checkout pin, then resolve the snapshot.
dx_profile_apply() {
    local profile="$1" name parsed_name origin_name
    dx_parse_config_file "$2" || return 1
    for name in $DXE_CONFIG_FIELDS; do
        parsed_name="DXE_PARSED_$name"
        if [ "${!parsed_name+x}" = x ]; then
            printf -v "$name" '%s' "${!parsed_name}"
            origin_name="DXE_CONFIG_ORIGIN_$name"
            printf -v "$origin_name" '%s' "profile:$profile"
            export "${name?}" "${origin_name?}"
        fi
        unset "$parsed_name"
    done
    dx_profile_enforce_pin "$profile" || return $?
    unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION
    dx_init_config "$DX_PROJECT_ROOT"
}

# bin/qx's profile: QX_PROFILE, defaulting (also when empty) to qnap-canary.
dx_qx_profile() {
    local profile="${QX_PROFILE:-qnap-canary}"
    dx_profile_name_valid "$profile" || { echo "Error: invalid QX_PROFILE '$profile'." >&2; return 2; }
    printf '%s\n' "$profile"
}
