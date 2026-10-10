#!/bin/sh
# The /persist directory marker format (plan D-3, spec R16): the file
# .dxe-persist-dir at the root of a guest's persistent directory, in the
# key=value style of .dxe-owner-v1:
#
#   schema=1
#   guest=<name>
#   state=copying|ready|retired
#   source-volume=<volume>   (only when set)
#   created-at=<UTC>         (only when set)
#   migrated-at=<UTC>        (only when set)
#   retired-at=<UTC>         (only when set)
#
# POSIX sh so the Bash 3.2 host (bin/lib/dx-persist-dir.sh sources this file)
# and the guest's Bash 5 share one definition. Safe to source: functions and
# one constant, no output and no shell options at import time.
#
# The write helper puts the text in a temporary file in the marker's own
# directory and then runs `mv` onto the final name, so a reader sees either
# the previous marker or the whole new one, never a partial file.

# shellcheck disable=SC2034 # result variables are read by the sourcing caller
DX_PERSIST_MARKER_NAME=.dxe-persist-dir

# A guest or volume name: [A-Za-z0-9][A-Za-z0-9_.-]*
dx_persist_marker_valid_name() {
    case "$1" in
        '' | [!A-Za-z0-9]* | *[!A-Za-z0-9_.-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# A UTC timestamp: YYYY-MM-DDTHH:MM:SSZ, month 01-12, day 01-31, hour 00-23,
# minute and second 00-59.
dx_persist_marker_valid_timestamp() {
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-5][0-9]:[0-5][0-9]Z) : ;;
        *) return 1 ;;
    esac
    _dx_pm_month="${1#*-}"
    _dx_pm_month="${_dx_pm_month%%-*}"
    _dx_pm_day="${1#*-*-}"
    _dx_pm_day="${_dx_pm_day%%T*}"
    _dx_pm_hour="${1#*T}"
    _dx_pm_hour="${_dx_pm_hour%%:*}"
    case "$_dx_pm_month" in
        0[1-9] | 1[0-2]) : ;;
        *) return 1 ;;
    esac
    case "$_dx_pm_day" in
        0[1-9] | [12][0-9] | 3[01]) : ;;
        *) return 1 ;;
    esac
    case "$_dx_pm_hour" in
        [01][0-9] | 2[0-3]) return 0 ;;
        *) return 1 ;;
    esac
}

dx_persist_marker_valid_state() {
    case "$1" in
        copying | ready | retired) return 0 ;;
        *) return 1 ;;
    esac
}

# dx_persist_marker_format GUEST STATE [SOURCE_VOLUME [CREATED_AT
#     [MIGRATED_AT [RETIRED_AT]]]]
# Prints the canonical text; invalid input prints one stderr line only.
dx_persist_marker_format() {
    dx_persist_marker_valid_name "${1-}" || {
        echo "dx-persist-marker: invalid guest" >&2
        return 1
    }
    dx_persist_marker_valid_state "${2-}" || {
        echo "dx-persist-marker: unknown state" >&2
        return 1
    }
    [ -z "${3-}" ] || dx_persist_marker_valid_name "$3" || {
        echo "dx-persist-marker: invalid source-volume" >&2
        return 1
    }
    for _dx_pm_ts in "${4-}" "${5-}" "${6-}"; do
        [ -z "$_dx_pm_ts" ] || dx_persist_marker_valid_timestamp "$_dx_pm_ts" || {
            echo "dx-persist-marker: invalid timestamp" >&2
            return 1
        }
    done
    printf 'schema=1\nguest=%s\nstate=%s\n' "$1" "$2"
    [ -z "${3-}" ] || printf 'source-volume=%s\n' "$3"
    [ -z "${4-}" ] || printf 'created-at=%s\n' "$4"
    [ -z "${5-}" ] || printf 'migrated-at=%s\n' "$5"
    [ -z "${6-}" ] || printf 'retired-at=%s\n' "$6"
    return 0
}

# Clear the result variables, print one reason line on stderr, return 1.
dx_persist_marker_fail() {
    DX_PERSIST_MARKER_GUEST=
    DX_PERSIST_MARKER_STATE=
    DX_PERSIST_MARKER_SOURCE_VOLUME=
    DX_PERSIST_MARKER_CREATED_AT=
    DX_PERSIST_MARKER_MIGRATED_AT=
    DX_PERSIST_MARKER_RETIRED_AT=
    echo "dx-persist-marker: $1" >&2
    return 1
}

# dx_persist_marker_parse < TEXT
# On success sets DX_PERSIST_MARKER_{GUEST,STATE,SOURCE_VOLUME,CREATED_AT,
# MIGRATED_AT,RETIRED_AT}; on failure leaves them empty.
dx_persist_marker_parse() {
    _dx_pm_schema=
    _dx_pm_guest=
    _dx_pm_state=
    _dx_pm_volume=
    _dx_pm_created=
    _dx_pm_migrated=
    _dx_pm_retired=
    while IFS= read -r _dx_pm_line || [ -n "$_dx_pm_line" ]; do
        [ -n "$_dx_pm_line" ] || continue
        case "$_dx_pm_line" in
            ?*=?*) : ;;
            *) dx_persist_marker_fail "malformed line"; return 1 ;;
        esac
        _dx_pm_key="${_dx_pm_line%%=*}"
        _dx_pm_val="${_dx_pm_line#*=}"
        case "$_dx_pm_key" in
            schema) _dx_pm_cur="$_dx_pm_schema" ;;
            guest) _dx_pm_cur="$_dx_pm_guest" ;;
            state) _dx_pm_cur="$_dx_pm_state" ;;
            source-volume) _dx_pm_cur="$_dx_pm_volume" ;;
            created-at) _dx_pm_cur="$_dx_pm_created" ;;
            migrated-at) _dx_pm_cur="$_dx_pm_migrated" ;;
            retired-at) _dx_pm_cur="$_dx_pm_retired" ;;
            *) dx_persist_marker_fail "unknown key"; return 1 ;;
        esac
        [ -z "$_dx_pm_cur" ] || { dx_persist_marker_fail "duplicate key"; return 1; }
        case "$_dx_pm_key" in
            schema)
                [ "$_dx_pm_val" = 1 ] || { dx_persist_marker_fail "unknown schema"; return 1; }
                _dx_pm_schema="$_dx_pm_val" ;;
            guest)
                dx_persist_marker_valid_name "$_dx_pm_val" || { dx_persist_marker_fail "invalid guest"; return 1; }
                _dx_pm_guest="$_dx_pm_val" ;;
            state)
                dx_persist_marker_valid_state "$_dx_pm_val" || { dx_persist_marker_fail "unknown state"; return 1; }
                _dx_pm_state="$_dx_pm_val" ;;
            source-volume)
                dx_persist_marker_valid_name "$_dx_pm_val" || { dx_persist_marker_fail "invalid source-volume"; return 1; }
                _dx_pm_volume="$_dx_pm_val" ;;
            *)
                dx_persist_marker_valid_timestamp "$_dx_pm_val" || { dx_persist_marker_fail "invalid timestamp"; return 1; }
                case "$_dx_pm_key" in
                    created-at) _dx_pm_created="$_dx_pm_val" ;;
                    migrated-at) _dx_pm_migrated="$_dx_pm_val" ;;
                    *) _dx_pm_retired="$_dx_pm_val" ;;
                esac ;;
        esac
    done
    [ -n "$_dx_pm_schema" ] || { dx_persist_marker_fail "missing schema"; return 1; }
    [ -n "$_dx_pm_guest" ] || { dx_persist_marker_fail "missing guest"; return 1; }
    [ -n "$_dx_pm_state" ] || { dx_persist_marker_fail "missing state"; return 1; }
    DX_PERSIST_MARKER_GUEST="$_dx_pm_guest"
    DX_PERSIST_MARKER_STATE="$_dx_pm_state"
    DX_PERSIST_MARKER_SOURCE_VOLUME="$_dx_pm_volume"
    DX_PERSIST_MARKER_CREATED_AT="$_dx_pm_created"
    DX_PERSIST_MARKER_MIGRATED_AT="$_dx_pm_migrated"
    DX_PERSIST_MARKER_RETIRED_AT="$_dx_pm_retired"
    return 0
}

# dx_persist_marker_write DIR TEXT
# Validates TEXT, writes it to a temporary file in DIR, then mv onto the
# marker name. On any failure nothing but the previous marker remains.
dx_persist_marker_write() {
    printf '%s\n' "$2" | dx_persist_marker_parse || return 1
    _dx_pm_tmp="$(mktemp "$1/$DX_PERSIST_MARKER_NAME.XXXXXX")" || return 1
    if printf '%s\n' "$2" >"$_dx_pm_tmp" && chmod 0644 "$_dx_pm_tmp" \
        && mv "$_dx_pm_tmp" "$1/$DX_PERSIST_MARKER_NAME"; then
        return 0
    fi
    rm -f "$_dx_pm_tmp"
    return 1
}
