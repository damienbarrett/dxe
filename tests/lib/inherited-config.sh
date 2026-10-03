#!/bin/bash
# tier: unit
# bash32: yes
# Import-only (functions; no output, no shell-option or trap changes).
#
# Hermetic by default: an operator's `dx-profile <profile> run_all_tests.sh
# --live` exports the resolved configuration snapshot (DX_RUNTIME, DX_REMOTE_HOST,
# the names, DXE_CONFIG_*, the DXE_RUNTIME_* discovery caches) to every suite.
# Cases built on fake Apple `container` binaries then dispatched to the real
# docker adapter and, with no fake ssh, the real management host. So at source
# time the inherited snapshot is saved (shell-quoted, in an UNEXPORTED variable)
# and unset, and every hermetic case sees registry defaults, as in CI.
# live_tail_enabled restores it for the live tails. The field list comes from
# the registry (tests/lib/registry-defaults.sh), never a copy.
DXE_LIVE_PROFILE_ENV="${DXE_LIVE_PROFILE_ENV-}"
DXE_LIVE_PROFILE_NAMES="${DXE_LIVE_PROFILE_NAMES-}"
# dxe_restore_profile -- put the saved snapshot back for a live tail. All or
# nothing, because the snapshot is only valid as a whole (a docker-ssh runtime
# with an apple-image storage mode is rejected): if the suite has declared any
# configuration field of its own (a DX_* the snapshot also holds, other than
# the helper's own two defaults below), it is running against its own fake
# setup and the snapshot is left unrestored. Idempotent.
dxe_restore_profile() {
    [ -n "$DXE_LIVE_PROFILE_NAMES" ] || return 0
    local name
    for name in $DXE_LIVE_PROFILE_NAMES; do
        case "$name" in DX_*) ;; *) continue ;; esac
        [ "${!name+x}" = x ] || continue
        case "$name=${!name}" in
            DX_CONTAINER_NAME=dx-host|DX_SSH_PORT=2222) ;;
            *) return 0 ;;
        esac
    done
    eval "$DXE_LIVE_PROFILE_ENV"
}
dxe_scrub_inherited_config() {
    [ "${DXE_CONFIG_RESOLVED:-}" = 1 ] || return 0
    # shellcheck source=registry-defaults.sh
    source "$(dirname "${BASH_SOURCE[0]}")/registry-defaults.sh"
    local name saved="" names=""
    for name in $(registry_fields) $(compgen -v DXE_CONFIG_) $(compgen -v DXE_RUNTIME_) $(compgen -v DXE_PARSED_); do
        [ "${!name+x}" = x ] || continue
        saved="$saved$(printf 'export %s=%q' "$name" "${!name}")"$'\n'
        names="$names $name"
        unset "$name"
    done
    DXE_LIVE_PROFILE_ENV="$saved"
    DXE_LIVE_PROFILE_NAMES="$names"
}
# dxe_unset_profile_vars -- undo dxe_restore_profile: unset every variable the
# snapshot held, so hermetic cases that follow a live-tail gate (the gate
# restores the snapshot in the suite's own shell) see registry defaults again.
# No-op when no snapshot was inherited.
dxe_unset_profile_vars() {
    local name
    for name in $DXE_LIVE_PROFILE_NAMES; do unset "$name"; done
}
