#!/usr/bin/env bash
# dx-keyring: explicit control over the guest's D-Bus session bus +
# gnome-keyring Secret Service (used only by agy, installed by dx-ai).
# Bootstrap keeps no keyring knowledge; this command and dx-ai's own
# dx_ai_ensure_keyring are the only owners, both thin wrappers over
# scripts/lib/dx-keyring.sh. No automatic start-on-agy wrapper by design
# (explicit over magic) -- see docs/guest.md for why, and for the deferred
# dbus-run-session-per-invocation alternative.

# dx-keyring is packaged both as a Home Manager `home.file` (normal guest
# use) and loadable straight off the bootstrap volume (so it still works
# before any AI generation is published). Same three-candidate shape as
# scripts/dx-ai.sh's dx_ai_load_opencode_persistence/dx_ai_load_keyring.
dx_keyring_load_library() {
    local script_directory candidate
    declare -F dx_keyring_start >/dev/null && return 0
    script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    for candidate in \
        "$script_directory/lib/dx-keyring.sh" \
        "$HOME/.local/lib/dx/dx-keyring.sh" \
        "${DX_KEYRING_BOOTSTRAP_ROOT:-/guest-bootstrap}/scripts/lib/dx-keyring.sh"; do
        [ -r "$candidate" ] || continue
        # shellcheck source=lib/dx-keyring.sh
        source "$candidate" || return 1
        declare -F dx_keyring_start >/dev/null && return 0
    done
    echo "Error: keyring library is unavailable." >&2
    return 1
}

dx_keyring_usage() {
    cat <<'EOF'
Usage: dx-keyring <start|status> | --help

  start   Start (or reuse) the D-Bus session bus and gnome-keyring Secret
          Service used by agy. Idempotent: a live bus with the Secret
          Service already running starts nothing new.
  status  Print the recorded bus address's state (live/stale/absent) and,
          when live, the dbus-daemon/gnome-keyring-daemon pids.

Run this after a container restart (dx-stop-container/dx-start-container)
and before an agy login, or run any dx-ai (it calls the same start logic at
the end of every run). Bootstrap never starts the keyring service itself.
EOF
}

dx_keyring_main() {
    local address_file="${DX_KEYRING_ADDRESS_FILE:-/persist/home/dx/.local/state/dx/keyring-address}"
    case "${1:-}" in
        -h|--help)
            dx_keyring_usage
            ;;
        start)
            [ "$#" -eq 1 ] || { dx_keyring_usage >&2; return 64; }
            dx_keyring_load_library || return 1
            dx_keyring_start "$address_file"
            ;;
        status)
            [ "$#" -eq 1 ] || { dx_keyring_usage >&2; return 64; }
            dx_keyring_load_library || return 1
            dx_keyring_status "$address_file"
            ;;
        *)
            dx_keyring_usage >&2
            return 64
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; dx_keyring_main "$@"; fi
