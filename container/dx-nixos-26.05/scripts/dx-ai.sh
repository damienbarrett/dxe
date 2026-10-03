#!/usr/bin/env bash

# Consumed by scripts/lib/dx-ai-generation.sh, dx-ai-pin.sh and
# dx-ai-cache-policy.sh (Fable B7's split), not by this file directly, so a
# single-file ShellCheck pass over dx-ai.sh alone cannot see the use.
# shellcheck disable=SC2034
NIX_FLAGS=(--extra-experimental-features "nix-command flakes" --accept-flake-config)
# Single source of truth for the optional AI tools bundle. Keep the Nix
# declaration (flake.nix's aiPackages), bin/dx-herdr, and docs/guest.md in sync
# with this list by hand; they are outside this module's ownership.
DX_AI_TOOLS="codex claude agy herdr opencode"
# A generation published before OpenCode support has no .tools-manifest (see
# dx_ai_generation_tools); its real, complete inventory was this five-tool
# set (gemini-cli was still installed at that point -- see findings.md's
# 2026-09-30 user decision to drop it), and validating or recovering it must
# use that instead of the current DX_AI_TOOLS, which would demand an
# opencode executable that generation was never asked to build.
# Consumed by scripts/lib/dx-ai-generation.sh -- see the NIX_FLAGS comment
# above.
# shellcheck disable=SC2034
DX_AI_LEGACY_TOOLS="codex gemini claude agy herdr"
# The intersection of the agents dx-ai publishes and the integrations Herdr
# ships. Herdr has no target for agy, so it is absent by design. Consumed by
# scripts/lib/dx-ai-post-install.sh -- see the NIX_FLAGS comment above.
# shellcheck disable=SC2034
DX_AI_HERDR_INTEGRATIONS=(claude codex opencode)

# dx-ai's own bootstrap: get the shared three-candidate library loader
# (scripts/lib/dx-ai-loader.sh's dx_ai_load_library) into scope. This is the
# one copy of the candidate loop that cannot itself go through
# dx_ai_load_library -- a script cannot use a shared loader to load the
# loader (Fable B7; dx-keyring.sh keeps the analogous
# dx_keyring_bootstrap_load for the same reason).
dx_ai_bootstrap_load() {
    declare -F dx_ai_load_library >/dev/null && return 0
    local script_directory candidate
    script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    for candidate in \
        "$script_directory/lib/dx-ai-loader.sh" \
        "$HOME/.local/lib/dx/dx-ai-loader.sh" \
        "${DX_AI_BOOTSTRAP_ROOT:-/guest-bootstrap}/scripts/lib/dx-ai-loader.sh"; do
        [ -r "$candidate" ] || continue
        # shellcheck source=lib/dx-ai-loader.sh
        source "$candidate" || return 1
        declare -F dx_ai_load_library >/dev/null && return 0
    done
    echo "Error: dx-ai library loader is unavailable." >&2
    return 1
}
dx_ai_bootstrap_load \
    || { echo "Error: dx-ai could not bootstrap its own library loader." >&2; return 1 2>/dev/null || exit 1; }

# The generation lifecycle, agy pin, cache-miss policy, and post-install
# (credentials/keyring/Herdr) libraries are all always needed -- unlike the
# opencode-persistence/keyring libraries dx-ai-post-install.sh loads lazily,
# on first actual use -- so they are loaded here, eagerly, every time this
# file itself is sourced (force=1: see dx_ai_load_library's own comment for
# why a probe-gated fast path is wrong for these four specifically), right
# after the loader itself (Fable B7: this is also how each now sits under
# scripts/lib, in kcov's coverage scope, unlike this file -- see
# tests/coverage/exclusions.txt).
dx_ai_load_library dx_ai_stage_generation dx-ai-generation.sh DX_AI_BOOTSTRAP_ROOT 1 \
    || { echo "Error: dx-ai's generation library is unavailable." >&2; return 1 2>/dev/null || exit 1; }
dx_ai_load_library dx_ai_refresh_pin dx-ai-pin.sh DX_AI_BOOTSTRAP_ROOT 1 \
    || { echo "Error: dx-ai's agy pin library is unavailable." >&2; return 1 2>/dev/null || exit 1; }
dx_ai_load_library dx_ai_check_cached dx-ai-cache-policy.sh DX_AI_BOOTSTRAP_ROOT 1 \
    || { echo "Error: dx-ai's cache-policy library is unavailable." >&2; return 1 2>/dev/null || exit 1; }
dx_ai_load_library dx_ai_setup_credentials dx-ai-post-install.sh DX_AI_BOOTSTRAP_ROOT 1 \
    || { echo "Error: dx-ai's post-install library is unavailable." >&2; return 1 2>/dev/null || exit 1; }
# Fable B9: the shared persist-relocate primitive dx_ai_setup_credentials
# (above) now uses for its AI-credential symlinks.
dx_ai_load_library dx_persist_relocate_dir dx-persist-relocate.sh DX_AI_BOOTSTRAP_ROOT 1 \
    || { echo "Error: dx-ai's persist-relocate library is unavailable." >&2; return 1 2>/dev/null || exit 1; }

dx_ai_usage() {
    cat <<'EOF'
Usage: dx-ai [--recover] [--supports <tool>]

Install or update Codex, Claude, Antigravity, Herdr, and OpenCode from an
immutable working generation under /persist. The published bootstrap is never modified.
Use --recover to repoint current to its retained predecessor generation.
Use --supports <tool> to check if a tool is known to this dx-ai generation.

If a nixpkgs-unstable refresh would build a non-trivial package from source
(a binary-cache miss), dx-ai falls back to the previous generation's lock; if
that also misses, or none exists, it refuses to install and exits non-zero.
Set DX_AI_ALLOW_SOURCE_BUILDS=1 to build from source anyway.
EOF
}

dx_ai_published_root() {
    local root="${DX_AI_BOOTSTRAP_ROOT:-/guest-bootstrap}"
    if [ -L "$root/current" ] && [ -f "$root/current/flake.nix" ]; then readlink -f "$root/current"; else printf '%s\n' "$root"; fi
}

# Fable B4: a uniform "Error: <msg>" stderr line for the staging/publish
# paths that used to fail with a bare `return 1` and nothing printed. A
# plain function call cannot exit its caller, so every call site still
# writes its own `return 1` right alongside this.
dx_ai_fail() {
    printf 'Error: %s\n' "$1" >&2
    return 1
}

# dx-ai's own publication lock (scripts/lib/dx-ai-lock.sh) is loaded lazily,
# only when a run actually needs to acquire it (dx_ai_run_locked, below) --
# unlike the eager loads above, which every action needs regardless. Defined
# here rather than alongside its callers so that dx_ai_load_library's own
# candidate 1 (the calling script's own colocated lib/ directory) names
# dx-ai.sh's directory, not scripts/lib/ itself (see dx-ai-post-install.sh's
# header comment for why that distinction matters).
dx_ai_load_lock() {
    dx_ai_load_library dx_ai_lock_acquire dx-ai-lock.sh
}

# Shared guest-system detection (scripts/lib/dx-guest-system.sh, also used by
# bootstrap.sh) is likewise loaded lazily, only by dx_ai_main, once, right
# before it is needed.
dx_ai_load_guest_system() {
    dx_ai_load_library dx_guest_resolve_system dx-guest-system.sh
}

# dx_ai_setup_credentials/dx_ai_ensure_keyring (scripts/lib/
# dx-ai-post-install.sh) call these lazily, on first actual use -- unlike the
# eager loads above, which every action needs regardless of whether it ever
# touches credentials or the keyring.
dx_ai_load_opencode_persistence() {
    dx_ai_load_library dx_ai_opencode_persistence dx-opencode-persistence.sh
}

dx_ai_load_keyring() {
    dx_ai_load_library dx_keyring_start dx-keyring.sh
}

# Fable B4/B7: acquire $1's lock, run $2 (with any further args) under it,
# and release it exactly once -- on a normal return AND on HUP/INT/TERM/exit
# -- replacing what used to be a release-and-clear-trap epilogue copied at
# every early-return site in dx_ai_main. $stage is script-global (not local
# to any one function): whichever function is running when a signal fires
# still has it in scope, so an in-flight AI generation stage is always
# discarded on the same trap that releases the lock, and a killed run never
# leaves an orphan pinned under /nix/var/nix/gcroots/auto.
dx_ai_run_locked() {
    local lock="$1" result
    shift
    dx_ai_load_lock || return 1
    dx_ai_lock_acquire "$lock" || return 1
    trap 'rm -rf "${stage:-}"; dx_ai_lock_release "${lock:-}" 2>/dev/null || true' EXIT HUP INT TERM
    "$@"
    result=$?
    dx_ai_lock_release "$lock"
    trap - EXIT HUP INT TERM
    return "$result"
}

# The critical section of a normal (non-recover) dx-ai run, run under
# dx_ai_run_locked's lock: stage a fresh generation from the published
# bootstrap, refresh its lock file, refuse a binary-cache miss, build the AI
# tools profile, and publish it. $stage is intentionally not `local` here --
# see dx_ai_run_locked above -- and is always cleared before returning,
# whether this succeeds or fails.
dx_ai_main_update() {
    local published="$1" state="$2" id="$3" system="$4" result=0
    stage="$(dx_ai_stage_generation "$published" "$state" "$id")" || return 1
    dx_ai_update_flake "$stage" "$system" || result=$?
    [ "$result" -ne 0 ] || dx_ai_ensure_cached "$stage" "$state" "$system" || result=$?
    [ "$result" -ne 0 ] || dx_ai_install_profile "$stage" || result=$?
    [ "$result" -ne 0 ] || dx_ai_publish_generation "$state" "$id" "$stage" || result=$?
    if [ "$result" -ne 0 ]; then
        rm -rf "$stage"
        stage=""
        return "$result"
    fi
    stage=""
    return 0
}

dx_ai_main() {
    local action=update published state id lock system result
    stage=""
    case "${1:-}" in
        -h|--help) dx_ai_usage; return ;;
        --recover) action=recover; shift ;;
        --supports)
            local tool="${2:-}"
            [ "$#" -eq 2 ] || { dx_ai_usage >&2; return 64; }
            dx_ai_tool_known "$tool"
            return
            ;;
    esac
    [ "$#" -eq 0 ] || { dx_ai_usage >&2; return 64; }
    [ "$(id -u)" -ne 0 ] || { dx_ai_fail "run dx-ai as the dx user, not root."; return 1; }
    state="${DX_AI_STATE_ROOT:-/persist/home/dx/.local/state/dx-ai}"; lock="$state/.lock"; id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    export SSL_CERT_FILE="${SSL_CERT_FILE:-$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt}"
    export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-$SSL_CERT_FILE}"

    if [ "$action" = recover ]; then
        dx_ai_run_locked "$lock" dx_ai_recover_generation "$state"
        result=$?
        [ "$result" -eq 0 ] || return "$result"
        export PATH="$state/current/profile/bin:$PATH"
        dx_ai_verify "$state/current"
        return
    fi

    published="$(dx_ai_published_root)"
    [ -f "$published/flake.nix" ] || { dx_ai_fail "published bootstrap flake is missing: $published/flake.nix"; return 1; }
    # Branch 11 / Phase 4 (docs/refactor/arch-neutral-guest.md section 4):
    # resolve this guest's own system once, via the shared helper (also used
    # by bootstrap.sh), and adjust DX_AI_TOOLS (a global the staging/
    # validation/verify functions below already read) BEFORE staging, so a
    # system with no native agy artifact stages, publishes, and verifies a
    # generation that never claims agy. Neither of these touches $state, so
    # they run before the lock is even acquired.
    dx_ai_load_guest_system || return 1
    system="$(dx_guest_resolve_system)" || return 1
    DX_AI_TOOLS="$(dx_ai_tools_for_system "$published" "$system" | tr '\n' ' ')"; DX_AI_TOOLS="${DX_AI_TOOLS% }"

    dx_ai_run_locked "$lock" dx_ai_main_update "$published" "$state" "$id" "$system"
    result=$?
    [ "$result" -eq 0 ] || return "$result"

    export PATH="$state/current/profile/bin:$PATH"
    dx_ai_setup_credentials /persist/home/dx "$HOME" || return
    dx_ai_ensure_keyring || return
    # Herdr is optional, so a missing or unhappy integration is reported but
    # never fails an otherwise successful AI update.
    dx_ai_install_herdr_integrations
    dx_ai_verify "$state/current" || return
    dx_ai_usage_service_hook "$state"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; dx_ai_main "$@"; fi
