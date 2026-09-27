#!/usr/bin/env bash
# Guest native-system detection and resolution. Safe to source.
#
# Branch 11 / Phase 4 (qnap-dxe-plan.md DQ7, docs/refactor/
# arch-neutral-guest.md section 4): shared between bootstrap.sh and
# scripts/dx-ai.sh so both select the same per-system flake attributes
# (homeConfigurations."dx-<system>", the agy pin) the same way, instead of
# each guessing independently.

# Maps this guest's own `uname -m` to the Nix system string the flake uses.
# Guest-side; this script only ever runs inside the Linux guest (never the
# macOS host), so only the Linux uname -m spellings are recognized. An
# architecture DQ7 does not support (e.g. 32-bit ARM) refuses rather than
# guessing.
dx_guest_native_system() {
    case "$(uname -m)" in
        aarch64) printf '%s\n' aarch64-linux ;;
        x86_64)  printf '%s\n' x86_64-linux ;;
        *) echo "Error: unsupported guest architecture: $(uname -m)" >&2; return 1 ;;
    esac
}

# Resolves the system to use: this guest's own native system, cross-checked
# against DX_GUEST_SYSTEM when the host provided it (bin/dx-create-container's
# third env token). A mismatch refuses rather than silently using either
# value -- a wrong host profile must never make a guest quietly run as the
# wrong architecture. DX_GUEST_SYSTEM absent (Apple's guest, today) means
# nothing to cross-check; the native system is used as-is.
dx_guest_resolve_system() {
    local native
    native="$(dx_guest_native_system)" || return 1
    if [ -n "${DX_GUEST_SYSTEM:-}" ] && [ "$DX_GUEST_SYSTEM" != "$native" ]; then
        echo "Error: host profile says DX_GUEST_SYSTEM=$DX_GUEST_SYSTEM, but this guest is $native." >&2
        return 1
    fi
    printf '%s\n' "$native"
}
