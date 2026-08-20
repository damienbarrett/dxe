#!/usr/bin/env bash

bootstrap_main() {
    export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}"
    export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}"
    DX_GUEST_ACTIVATION_TIMEOUT="${DX_GUEST_ACTIVATION_TIMEOUT:-1800}"
    DX_GUEST_ACTIVATION_ATTEMPTS="${DX_GUEST_ACTIVATION_ATTEMPTS:-2}"
    DX_GUEST_ACTIVATION_RETRY_DELAY="${DX_GUEST_ACTIVATION_RETRY_DELAY:-5}"

    guard_old_base
    configure_single_user_nix
    install_essentials
    link_system_bash
    capture_nix_image_default_profile
    prepare_nix_volume
    materialize_auth_files
    create_user
    populate_prepared_nix_volume
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

    echo "Guest bootstrap complete. Starting sshd in foreground..."
    exec "$(command -v sshd)" -D -e -p 2222
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    self="$(readlink -f "${BASH_SOURCE[0]}")"
    DX_BOOTSTRAP_ROOT="$(cd "$(dirname "$self")" && pwd)"
    export DX_BOOTSTRAP_ROOT
    source "$DX_BOOTSTRAP_ROOT/scripts/lib/dx-keyring.sh"
    source "$DX_BOOTSTRAP_ROOT/bootstrap/common.sh"
    source "$DX_BOOTSTRAP_ROOT/bootstrap/base-and-storage.sh"
    source "$DX_BOOTSTRAP_ROOT/bootstrap/system.sh"
    source "$DX_BOOTSTRAP_ROOT/bootstrap/persistence.sh"
    source "$DX_BOOTSTRAP_ROOT/bootstrap/herdr-config.sh"
    source "$DX_BOOTSTRAP_ROOT/bootstrap/activation.sh"
    bootstrap_main "$@"
fi
