#!/bin/bash
# Pure host helpers and bounded process-control primitives. Safe to source.

dx_require_non_reserved_container_name() {
    if [ "$1" = dx-host ]; then
        echo "Error: dx-host is reserved for the default durable guest." >&2
        return 1
    fi
}

dx_require_container_safe_name() {
    local name="$1"
    case "$name" in
        ''|[.-]*|*[!A-Za-z0-9_.-]*)
            echo "Error: --container name '$name' is not valid." >&2
            echo "Names must match ^[A-Za-z0-9][A-Za-z0-9_.-]*\$ (no '/', no leading '-' or '.', not empty)." >&2
            return 1
            ;;
    esac
}

dx_slugify() {
    local value="$1" fallback="${2:-item}" max_len="${3:-32}" slug
    slug="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
    [ -n "$slug" ] || slug="$fallback"
    printf '%s' "${slug:0:$max_len}" | sed -E 's/-+$//'
}

dx_short_hash() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 10)}'
    else
        printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 10)}'
    fi
}

dx_derived_name() {
    local prefix="$1" identity="$2" display="${3:-$2}" slug hash name
    slug="$(dx_slugify "$(basename "$display")" item 32)"
    hash="$(dx_short_hash "$identity")"
    name="${prefix}${slug}-${hash}"
    dx_require_non_reserved_container_name "$name"
    printf '%s\n' "$name"
}

dx_derived_port() {
    local hash_int
    hash_int="$((0x$(dx_short_hash "$1" | cut -c1-6)))"
    printf '%s\n' "$((2300 + (hash_int % 17000)))"
}

dx_port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

dx_require_positive_integer() {
    case "$2" in
        ''|*[!0-9]*|0) echo "Error: $1 must be a positive integer, got '$2'." >&2; return 1 ;;
    esac
}

dx_path_uid() {
    local value
    if value="$(stat -c '%u' "$1" 2>/dev/null)"; then printf '%s\n' "$value"; return; fi
    stat -f '%u' "$1" 2>/dev/null
}

dx_path_mode() {
    local value
    if value="$(stat -c '%a' "$1" 2>/dev/null)"; then printf '%s\n' "$value"; return; fi
    stat -f '%Lp' "$1" 2>/dev/null
}

dx_default_ssh_wait_timeout() {
    local bootstrap_grace=1800 wait_timeout
    dx_require_positive_integer DX_GUEST_ACTIVATION_TIMEOUT "$DX_GUEST_ACTIVATION_TIMEOUT"
    dx_require_positive_integer DX_GUEST_ACTIVATION_ATTEMPTS "$DX_GUEST_ACTIVATION_ATTEMPTS"
    dx_require_positive_integer DX_GUEST_ACTIVATION_RETRY_DELAY "$DX_GUEST_ACTIVATION_RETRY_DELAY"
    wait_timeout=$((DX_GUEST_ACTIVATION_ATTEMPTS * (DX_GUEST_ACTIVATION_TIMEOUT + 30) + (DX_GUEST_ACTIVATION_ATTEMPTS - 1) * DX_GUEST_ACTIVATION_RETRY_DELAY + bootstrap_grace))
    printf '%s\n' "$wait_timeout"
}

dx_process_start_identity() {
    local value boot
    if [ "$(uname -s 2>/dev/null || true)" = Linux ] && [ -r "/proc/$1/stat" ] && [ -r /proc/sys/kernel/random/boot_id ]; then
        boot="$(sed -n '1p' /proc/sys/kernel/random/boot_id)"
        value="$(awk '{print $22}' "/proc/$1/stat" 2>/dev/null || true)"
        [ -n "$boot" ] && [ -n "$value" ] || return 1
        printf '%s:%s\n' "$boot" "$value"
        return
    fi
    if [ -x /bin/ps ]; then value="$(/bin/ps -p "$1" -o lstart= 2>/dev/null || true)"; else value="$(ps -p "$1" -o lstart= 2>/dev/null || true)"; fi
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

dx_process_identity_matches() {
    local current
    current="$(dx_process_start_identity "$1" || true)"
    [ -n "$current" ] && [ "$current" = "$2" ]
}

dx_lock_acquire() {
    local lock_dir="$1" timeout="${2:-5}" elapsed=0 owner pid start current
    owner="$lock_dir/owner"
    if [ -z "${DXE_SELF_PROCESS_IDENTITY:-}" ]; then
        DXE_SELF_PROCESS_IDENTITY="$(dx_process_start_identity "$$" || true)"
    fi
    while :; do
        if mkdir "$lock_dir" 2>/dev/null; then
            chmod 0700 "$lock_dir"
            start="$DXE_SELF_PROCESS_IDENTITY"
            [ -n "$start" ] || { rmdir "$lock_dir" 2>/dev/null || true; echo "Error: cannot identify lock owner process." >&2; return 1; }
            printf '%s\t%s\n' "$$" "$start" > "$owner"
            chmod 0600 "$owner"
            DXE_HELD_LOCK="$lock_dir"
            return 0
        fi
        [ ! -L "$lock_dir" ] || { echo "Error: refusing symlinked lock path $lock_dir." >&2; return 1; }
        if [ -f "$owner" ]; then
            IFS="$(printf '\t')" read -r pid start < "$owner" || true
            current="$(dx_process_start_identity "${pid:-0}" || true)"
            if [ -n "${pid:-}" ] && [ -n "${start:-}" ] && [ -n "$current" ] && [ "$current" != "$start" ]; then
                rm -f "$owner"
                rmdir "$lock_dir" 2>/dev/null || true
                continue
            fi
            if [ -n "${pid:-}" ] && [ -n "${start:-}" ] && [ -z "$current" ] && ! kill -0 "$pid" 2>/dev/null; then
                rm -f "$owner"
                rmdir "$lock_dir" 2>/dev/null || true
                continue
            fi
        fi
        [ "$elapsed" -lt "$timeout" ] || { echo "Error: timed out waiting for lock $lock_dir." >&2; return 1; }
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

dx_lock_release() {
    local lock_dir="$1" owner="$1/owner" pid start current
    [ -f "$owner" ] || return 1
    IFS="$(printf '\t')" read -r pid start < "$owner" || return 1
    current="${DXE_SELF_PROCESS_IDENTITY:-}"
    [ "$pid" = "$$" ] && [ -n "$current" ] && [ "$current" = "$start" ] || {
        echo "Error: refusing to release a lock owned by another process: $lock_dir." >&2
        return 1
    }
    rm -f "$owner"
    rmdir "$lock_dir"
    [ "${DXE_HELD_LOCK:-}" = "$lock_dir" ] && unset DXE_HELD_LOCK
}

dx_timeout_cleanup() {
    if [ -n "${watchdog_pid:-}" ]; then kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true; fi
    if [ -n "${pid:-}" ] && [ -n "${start_id:-}" ] && dx_process_identity_matches "$pid" "$start_id"; then kill "$pid" 2>/dev/null || true; fi
    if [ -n "${marker:-}" ]; then rm -f "$marker"; fi
    if [ -n "${tmpdir:-}" ]; then rmdir "$tmpdir" 2>/dev/null || true; fi
}

dx_timeout_watchdog() {
    local timeout="$1" pid="$2" start_id="$3" marker="$4" display="$5"
    sleep "$timeout"
    if dx_process_identity_matches "$pid" "$start_id"; then
        echo "Command timed out after ${timeout}s: $display" >&2
        : > "$marker"
        kill "$pid" 2>/dev/null || true
        if dx_process_identity_matches "$pid" "$start_id"; then kill -KILL "$pid" 2>/dev/null || true; fi
    fi
}

run_with_timeout() {
    local timeout="$1"
    shift
    ( local pid="" start_id="" watchdog_pid="" status=0 marker tmpdir
        tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-timeout.XXXXXX")" || exit 1
        chmod 0700 "$tmpdir"
        marker="$tmpdir/timed-out"
        trap 'dx_timeout_cleanup' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        "$@" & pid=$!
        start_id="$(dx_process_start_identity "$pid" || true)"
        if [ -z "$start_id" ]; then
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null || status=$?
                pid=""
                exit "$status"
            fi
            echo "Error: cannot identify command process for bounded execution." >&2
            exit 1
        fi
        dx_timeout_watchdog "$timeout" "$pid" "$start_id" "$marker" "$*" & watchdog_pid=$!
        wait "$pid" 2>/dev/null || status=$?
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
        watchdog_pid=""; pid=""; start_id=""
        if [ -f "$marker" ]; then status=124; fi
        exit "$status"
    )
}

dx_get_host_timezone() {
    local tz="" target=""
    if [ -L /etc/localtime ]; then
        target="$(readlink /etc/localtime || true)"
        case "$target" in */zoneinfo/*) tz=${target#*/zoneinfo/} ;; esac
    fi
    if [ -z "$tz" ] && [ -f /etc/timezone ]; then tz="$(sed -n '1{s/[[:space:]]*$//;p;}' /etc/timezone)"; fi
    if [ -z "$tz" ] && command -v systemsetup >/dev/null 2>&1; then tz="$(systemsetup -gettimezone 2>/dev/null | sed -n 's/^Time Zone: //p' || true)"; fi
    if [ -z "$tz" ]; then echo "Warning: could not detect host timezone; defaulting guest timezone to UTC." >&2; tz=UTC; fi
    printf '%s\n' "$tz"
}
