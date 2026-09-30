#!/usr/bin/env bash
# Shared body of the three-candidate library loader (Fable B7): the
# candidate order is always the calling script's own colocated lib/
# directory first, then the Home-Manager-installed copy under
# ~/.local/lib/dx, then a bootstrap-volume fallback -- the same shape
# dx-ai.sh and dx-keyring.sh each repeated once per library they load,
# before this consolidation. Safe to source (import-only: defines a
# function, produces no output, and does not change caller control state).
#
# Getting dx-ai.sh and dx-keyring.sh to this file in the first place still
# needs one small colocated loader per entry point (see dx-ai.sh's
# dx_ai_bootstrap_load and dx-keyring.sh's dx_keyring_bootstrap_load): a
# script cannot use a shared library to load the mechanism that finds shared
# libraries. Everything loaded *through* this function, though -- the
# publication lock, generation lifecycle, agy pin, cache policy, post-install
# steps, OpenCode persistence, and the keyring library itself -- goes through
# this one copy instead of repeating the loop.
#
# $1: probe function name. Already defined means already loaded: return 0
#     immediately without touching the filesystem -- UNLESS $4 (force) is
#     set, in which case the file is always re-resolved and re-sourced.
#     dx-ai.sh's own eager loads (generation/pin/cache-policy/post-install:
#     every action needs them, every time dx-ai.sh itself is sourced) pass
#     force=1 for exactly this reason: sourcing dx-ai.sh is how this test
#     suite resets a function it deliberately stubbed back to its real body
#     between cases, a guarantee the original monolithic file gave for free
#     and that a probe-gated fast path would otherwise silently break. The
#     lazy, on-first-use loaders (the publication lock, guest-system
#     detection, OpenCode persistence, the keyring library) leave force
#     unset: those are meant to load at most once per process, exactly as
#     before this consolidation.
# $2: basename to look for under lib/, ~/.local/lib/dx/, and the bootstrap
#     volume's scripts/lib/.
# $3: optional bootstrap-root override variable name (default
#     DX_AI_BOOTSTRAP_ROOT). dx-keyring.sh's own loader passes
#     DX_KEYRING_BOOTSTRAP_ROOT, its own pre-existing, separate override.
# $4: optional force flag (default unset/0).
#
# BASH_SOURCE[1] -- the frame that called this function, not this file's own
# frame (BASH_SOURCE[0]) -- is what makes "the script's own directory" mean
# the CALLING script's directory, exactly as when each loader carried this
# loop inline.
dx_ai_load_library() {
    local probe_fn="$1" basename="$2" bootstrap_root_var="${3:-DX_AI_BOOTSTRAP_ROOT}" force="${4:-0}"
    local script_directory candidate bootstrap_root
    [ "$force" = 1 ] || { declare -F "$probe_fn" >/dev/null && return 0; }
    script_directory="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)" || return 1
    bootstrap_root="${!bootstrap_root_var:-/guest-bootstrap}"
    for candidate in \
        "$script_directory/lib/$basename" \
        "$HOME/.local/lib/dx/$basename" \
        "$bootstrap_root/scripts/lib/$basename"; do
        [ -r "$candidate" ] || continue
        # shellcheck source=/dev/null
        source "$candidate" || return 1
        declare -F "$probe_fn" >/dev/null && return 0
    done
    echo "Error: $basename is unavailable." >&2
    return 1
}
