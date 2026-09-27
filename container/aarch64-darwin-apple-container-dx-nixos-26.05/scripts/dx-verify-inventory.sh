#!/usr/bin/env bash
# dx-verify-inventory: prints present/missing for the guest's required CLI
# inventory after bootstrap, on either supported architecture
# (qnap-dxe-plan.md Phase 4 item 4, docs/refactor/arch-neutral-guest.md
# section 5). The coordinating session runs this via `dx_runtime_exec` on
# the disposable QNAP guest at the exit gate (SSH into the QNAP guest is
# Phase 5's job, so the gate uses exec, not dx-ssh).
#
# An explicit, checked-in list of BINARY names, not a derivation from
# flake.nix's dxPackages Nix attribute names: several packages' attribute
# name differs from the command it provides (ripgrep -> rg, findutils ->
# find/xargs, go-task -> task, gnused -> sed, e2fsprogs ->
# mkfs.ext4/fsck.ext4, ...), and several packages provide no standalone
# command at all (cacert, tzdata, bash-completion, nix-direnv). Deriving
# the list automatically would mean guessing at that mapping instead of
# stating it; this is the same "explicit, hand-maintained inventory"
# pattern scripts/dx-ai.sh's DX_AI_TOOLS and flake.nix's bootstrapEssentials
# already use, applied to the interactive, user-facing subset of
# dxPackages -- keep this list in sync with flake.nix's dxPackages and
# NixVim's nvim by hand.
DX_REQUIRED_INVENTORY="git gh nix ssh tmux rg fd curl jq direnv just task lazygit yazi btop fastfetch nvim tinty less file which"

dx_verify_inventory_main() {
    if [ "${1:-}" = --print-inventory ]; then
        printf '%s\n' $DX_REQUIRED_INVENTORY
        return 0
    fi
    local tool missing=0
    for tool in $DX_REQUIRED_INVENTORY; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf 'present: %s\n' "$tool"
        else
            printf 'missing: %s\n' "$tool"
            missing=$((missing + 1))
        fi
    done
    [ "$missing" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then dx_verify_inventory_main "$@"; fi
