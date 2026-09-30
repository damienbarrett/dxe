#!/usr/bin/env bash
# dx-keyring: explicit control over the guest's D-Bus session bus +
# gnome-keyring Secret Service (used only by agy, installed by dx-ai).
# Bootstrap keeps no keyring knowledge; this command and dx-ai's own
# dx_ai_ensure_keyring are the only owners, both thin wrappers over
# scripts/lib/dx-keyring.sh. No automatic start-on-agy wrapper by design
# (explicit over magic) -- see docs/guest.md for why, and for the deferred
# dbus-run-session-per-invocation alternative.

# dx-keyring's own bootstrap: get the shared three-candidate library loader
# (scripts/lib/dx-ai-loader.sh's dx_ai_load_library) into scope. This is the
# one copy of the candidate loop that cannot itself go through
# dx_ai_load_library -- a script cannot use a shared loader to load the
# loader (Fable B7; scripts/dx-ai.sh keeps the analogous
# dx_ai_bootstrap_load for the same reason -- dx-keyring is its own,
# separate entry point/process, so it cannot simply reuse dx-ai's copy).
dx_keyring_bootstrap_load() {
    declare -F dx_ai_load_library >/dev/null && return 0
    local script_directory candidate
    script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    for candidate in \
        "$script_directory/lib/dx-ai-loader.sh" \
        "$HOME/.local/lib/dx/dx-ai-loader.sh" \
        "${DX_KEYRING_BOOTSTRAP_ROOT:-/guest-bootstrap}/scripts/lib/dx-ai-loader.sh"; do
        [ -r "$candidate" ] || continue
        # shellcheck source=lib/dx-ai-loader.sh
        source "$candidate" || return 1
        declare -F dx_ai_load_library >/dev/null && return 0
    done
    echo "Error: dx-keyring library loader is unavailable." >&2
    return 1
}

# dx-keyring is packaged both as a Home Manager `home.file` (normal guest
# use) and loadable straight off the bootstrap volume (so it still works
# before any AI generation is published); dx_ai_load_library's own candidate
# order handles both cases, using dx-keyring's own, separate
# DX_KEYRING_BOOTSTRAP_ROOT override (unlike dx-ai's DX_AI_BOOTSTRAP_ROOT).
dx_keyring_load_library() {
    dx_keyring_bootstrap_load || return 1
    dx_ai_load_library dx_keyring_start dx-keyring.sh DX_KEYRING_BOOTSTRAP_ROOT
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
