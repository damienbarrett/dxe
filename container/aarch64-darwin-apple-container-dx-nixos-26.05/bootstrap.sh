#!/usr/bin/env bash

# The documented guest bootstrap phase order (Fable review B8). Split out of
# bootstrap_main so it can be sourced and driven directly -- calling
# bootstrap_main itself would still run every real phase and end in `exec
# sshd`, which a test cannot safely invoke. tests/test_section3_bootstrap.sh
# shadows each phase function and calls this to prove the order
# behaviourally, instead of comparing grep line numbers in this file's
# source text.
bootstrap_phases() {
    local owner_uid owner_gid
    configure_single_user_nix
    install_essentials
    link_system_bash
    capture_nix_image_default_profile
    prepare_nix_volume
    materialize_auth_files
    create_user
    # Contract 1 (refactor-v2-final.md, Fable B6 item 6): the owner uid/gid
    # is resolved exactly once, here, after create_user has run -- never
    # re-derived inside populate_prepared_nix_volume or its in-place
    # counterpart. The 2>/dev/null fallback stays (moved to this single call
    # site) so sourceable probes that shadow these phase functions without
    # materialising a real dx account keep working.
    owner_uid="$(id -u dx 2>/dev/null || printf '%s' 0)"
    owner_gid="$(id -g dx 2>/dev/null || printf '%s' 0)"
    populate_prepared_nix_volume "$owner_uid" "$owner_gid"
    verify_remount_prerequisites
    nix_restore_image_default_profile
    ensure_essentials_valid
    # The remounted essentials closure is content-verified before ownership
    # markers are published. This lets activation avoid a redundant recursive
    # chown on a freshly owner-mapped import.
    publish_nix_image_store_identity
    configure_release_identity
    setup_persist
    configure_ssh
    configure_guest true
    verify_guest_tools
    configure_timezone
}

bootstrap_main() {
    # $2/$3/$4: the generation/boot-id/start-time triple the launcher (bin/
    # lib/dx-ssh-common.sh's dx_bootstrap_launch_command) recorded in this
    # exact process's own lease just before it exec'd here ($1 is the
    # vestigial "serve" mode token). Empty on the unsignalled-fallback boot,
    # where no lease was ever written either -- see
    # dx_bootstrap_publish_ready_marker's own no-op case below.
    local dx_lease_generation="${2:-}" dx_lease_boot_id="${3:-}" dx_lease_start="${4:-}"

    export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}"
    export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}"
    DX_GUEST_ACTIVATION_TIMEOUT="${DX_GUEST_ACTIVATION_TIMEOUT:-1800}"
    DX_GUEST_ACTIVATION_ATTEMPTS="${DX_GUEST_ACTIVATION_ATTEMPTS:-2}"
    DX_GUEST_ACTIVATION_RETRY_DELAY="${DX_GUEST_ACTIVATION_RETRY_DELAY:-5}"

    bootstrap_phases

    # Astra F7: the host healthcheck probe treats a lease alone as ownership,
    # not readiness. Publish the completion marker it also requires only
    # now, after every phase above has actually succeeded.
    dx_bootstrap_publish_ready_marker "$dx_lease_generation" "$dx_lease_boot_id" "$dx_lease_start" "$$" \
        || echo "Warning: could not publish the bootstrap readiness marker; the container healthcheck will report unhealthy despite sshd starting." >&2

    echo "Guest bootstrap complete. Starting sshd in foreground..."
    exec "$(command -v sshd)" -D -e -p 2222
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    self="$(readlink -f "${BASH_SOURCE[0]}")"
    DX_BOOTSTRAP_ROOT="$(cd "$(dirname "$self")" && pwd)"
    export DX_BOOTSTRAP_ROOT
    source "$DX_BOOTSTRAP_ROOT/bootstrap/common.sh"
    source "$DX_BOOTSTRAP_ROOT/scripts/lib/dx-guest-system.sh"
    source "$DX_BOOTSTRAP_ROOT/bootstrap/base-and-storage.sh"
    source "$DX_BOOTSTRAP_ROOT/bootstrap/system.sh"
    source "$DX_BOOTSTRAP_ROOT/bootstrap/persistence.sh"
    source "$DX_BOOTSTRAP_ROOT/bootstrap/herdr-config.sh"
    source "$DX_BOOTSTRAP_ROOT/bootstrap/activation.sh"
    bootstrap_main "$@"
fi
