#!/bin/bash
# shellcheck disable=SC2034
# Additional isolated behavior probes for the D1 sourceable coverage scope.
# This script may create guest-shaped paths and therefore runs only inside the
# disposable pinned coverage environment.
set -euo pipefail

[ "${DXE_COVERAGE_ISOLATED:-}" = 1 ] || { echo "Error: sourceable coverage probes require the isolated coverage environment." >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST="$ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05"
fixture="$(mktemp -d /tmp/dxe-sourceable-coverage.XXXXXX)"
cleanup() {
    chmod -R u+w "$fixture" 2>/dev/null || true
    rm -rf "$fixture" /var/lib/dx-nix-raw /mnt/tmp-nix /persist/home/dx /home/dx
    rm -f /nix/.dx-owner-set
}
trap cleanup EXIT

source "$ROOT/bin/lib/dx-config.sh"
source "$ROOT/bin/lib/dx-host-util.sh"
source "$ROOT/bin/lib/dx-container.sh"
source "$ROOT/bin/lib/dx-ssh-common.sh"
source "$ROOT/bin/lib/dx-mount-plan.sh"
source "$ROOT/bin/lib/dx-tunnel.sh"
source "$GUEST/scripts/lib/dx-keyring.sh"
source "$GUEST/bootstrap/common.sh"
source "$GUEST/bootstrap/base-and-storage.sh"
source "$GUEST/bootstrap/system.sh"
source "$GUEST/bootstrap/persistence.sh"
source "$GUEST/bootstrap/activation.sh"

# Configuration registry, validators, diagnostics, and snapshot failures.
DX_PROJECT_ROOT="$fixture/project"; mkdir -p "$DX_PROJECT_ROOT"
for field in $DXE_CONFIG_FIELDS; do dx_config_default "$field" >/dev/null; done
dx_config_default UNKNOWN >/dev/null 2>&1 || true
for pair in \
    'DX_CONTAINER_NAME:' 'DX_IMAGE:.bad' 'DX_SSH_PORT:0' 'DX_SSH_PORT:65536' \
    'DX_SSH_CONNECT_TIMEOUT:0' 'DX_NIX_DISK_SIZE:0G' 'DX_BOOTSTRAP_PATH:relative' \
    'DX_SSH_KEY:relative' 'DX_GIT_MOUNT_SOURCE:relative'; do
    dx_config_validate_value "${pair%%:*}" "${pair#*:}" >/dev/null 2>&1 || true
done
dx_config_validate_value DX_NIX_DISK_SIZE 12
dx_config_parse_error fixture 7 expected >/dev/null 2>&1 || true
printf '%s\n' bad-line > "$fixture/bad.env"; dx_parse_config_file "$fixture/bad.env" >/dev/null 2>&1 || true
printf '%s\n' 'DX_SSH_KEY=${DX_PROJECT_ROOT}' > "$fixture/root-only.env"; dx_parse_config_file "$fixture/root-only.env"
(
    unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION
    for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
    dx_init_config "$DX_PROJECT_ROOT"
    DXE_CONFIG_SNAPSHOT_VERSION=99; dx_validate_config_snapshot "$DX_PROJECT_ROOT" >/dev/null 2>&1 || true
)
(
    legacy_base="$(printf 'DX_\127\117\122\113\123\120\101\103\105_')"
    legacy_volume="${legacy_base}VOLUME" legacy_path="${legacy_base}PATH"
    unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION "$legacy_volume" "$legacy_path"
    for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
    cd "$DX_PROJECT_ROOT"
    dx_init_config
    DXE_CONFIG_ORIGIN_DX_IMAGE=invalid
    dx_validate_config_snapshot "$DX_PROJECT_ROOT" >/dev/null 2>&1 || true
)
(
    DXE_CONFIG_RESOLVED='' DXE_CONFIG_SNAPSHOT_VERSION=1
    dx_init_config "$DX_PROJECT_ROOT" >/dev/null 2>&1 || true
)
(
    unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION
    for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
    dx_init_config "$DX_PROJECT_ROOT"
    DX_PROJECT_ROOT=/wrong; dx_validate_config_snapshot /expected >/dev/null 2>&1 || true
)
(
    DXE_CONFIG_RESOLVED=1; unset DXE_CONFIG_SNAPSHOT_VERSION
    dx_init_config "$DX_PROJECT_ROOT" >/dev/null 2>&1 || true
)
(
    unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION
    legacy_volume="$(printf 'DX_\127\117\122\113\123\120\101\103\105_VOLUME')"
    printf -v "$legacy_volume" '%s' old
    dx_init_config "$DX_PROJECT_ROOT" >/dev/null 2>&1 || true
)
dx_config_set_resolved UNKNOWN value default >/dev/null 2>&1 || true
dx_config_set_resolved DX_SSH_PORT bad default >/dev/null 2>&1 || true

# Pure host helpers and lock error paths.
dx_require_non_reserved_container_name dx-host >/dev/null 2>&1 || true
dx_require_container_safe_name .bad >/dev/null 2>&1 || true
dx_slugify '---' fallback 4 >/dev/null
(
    command() { if [ "${1:-}" = -v ] && [ "${2:-}" = shasum ]; then return 1; fi; builtin command "$@"; }
    sha256sum() { printf '%064d  -\n' 0; }
    dx_short_hash fallback >/dev/null
)
dx_derived_name side- identity 'Display Name' >/dev/null
dx_derived_port identity >/dev/null
dx_require_positive_integer COUNT 0 >/dev/null 2>&1 || true
DX_GUEST_ACTIVATION_TIMEOUT=1 DX_GUEST_ACTIVATION_ATTEMPTS=2 DX_GUEST_ACTIVATION_RETRY_DELAY=1 dx_default_ssh_wait_timeout >/dev/null
dx_path_uid "$fixture" >/dev/null; dx_path_mode "$fixture" >/dev/null
(
    stat() { if [ "${1:-}" = -c ]; then return 1; fi; printf '%s\n' 501; }
    dx_path_uid "$fixture" >/dev/null; dx_path_mode "$fixture" >/dev/null
)
dx_process_start_identity $$ >/dev/null
dx_process_start_identity 999999 >/dev/null 2>&1 || true
(
    uname() { printf '%s\n' Darwin; }
    dx_process_start_identity $$ >/dev/null
)
bad_lock="$fixture/bad.lock"; mkdir "$bad_lock"; printf '%s\t%s\n' "$$" wrong > "$bad_lock/owner"
dx_lock_acquire "$bad_lock" 0 >/dev/null 2>&1 || true
rm -rf "$bad_lock"; ln -s nowhere "$bad_lock"; dx_lock_acquire "$bad_lock" 0 >/dev/null 2>&1 || true; rm -f "$bad_lock"
mkdir "$bad_lock"; printf '%s\t%s\n' 999999 stale > "$bad_lock/owner"; dx_lock_acquire "$bad_lock" 1; dx_lock_release "$bad_lock"
mkdir "$bad_lock"; printf '%s\t%s\n' 1 other > "$bad_lock/owner"; dx_lock_release "$bad_lock" >/dev/null 2>&1 || true; rm -rf "$bad_lock"
run_with_timeout 2 true
(
    dx_process_start_identity() { return 1; }
    kill() { return 0; }
    run_with_timeout 1 true >/dev/null 2>&1 || true
)
dx_get_host_timezone >/dev/null

# Container adapter capability and state transitions use a bounded fake CLI.
(
    PATH=/usr/bin:/bin; unset -f container 2>/dev/null || true
    dx_require_container_cli >/dev/null 2>&1 || true
)
(
    calls=0
    container() {
        case "$*" in
            'system status') [ "$calls" -gt 0 ] ;;
            'system start') calls=$((calls + 1)) ;;
            'list -a --quiet'|'list --quiet'|'image list --quiet') return 1 ;;
            'list -a') printf 'NAME STATE\nall stopped\n' ;;
            'list') printf 'NAME STATE\nrunning running\n' ;;
            'image list') printf 'NAME\nimage\n' ;;
            'volume inspect volume') return 1 ;;
            'volume create volume') return 0 ;;
        esac
    }
    container_system_ensure_started >/dev/null
    dx_container_list_names true >/dev/null; dx_container_list_names false >/dev/null
    container_image_exists image; container_ensure_volume volume
)
(
    count=0
    container_is_running() { count=$((count + 1)); [ "$count" -lt 2 ]; }
    sleep() { :; }
    container_wait_stopped side 2 >/dev/null
    container_is_running() { return 0; }
    container_wait_stopped side 0 >/dev/null 2>&1 || true
)
(
    ps() { printf '%s\n' '12 container-runtime-linux --uuid side' '13 container-runtime-linux --uuid side-other'; }
    container_runtime_pids side >/dev/null
)
(
    container_runtime_pids() { printf '%s\n' 4242; }
    dx_process_start_identity() { printf '%s\n' stable; }
    dx_process_identity_matches() { return 0; }
    kill() { :; }
    sleep() { :; }
    DX_STOP_WAIT_TIMEOUT=0
    container_kill_runtime_process side >/dev/null 2>&1 || true
)
(
    counter="$fixture/runtime-counter"; : > "$counter"
    container_runtime_pids() {
        local count
        count="$(wc -l < "$counter")"; printf '%s\n' x >> "$counter"
        [ "$count" -ge 4 ] || printf '%s\n' 4242
    }
    dx_process_start_identity() { printf '%s\n' stable; }
    container_runtime_identity_matches() { return 0; }
    kill() { :; }; sleep() { :; }; DX_STOP_WAIT_TIMEOUT=2
    container_kill_runtime_process side
)
(
    container_exists() { return 1; }; container_stop_bounded absent >/dev/null
    container_exists() { return 0; }; container_is_running() { return 1; }; container_stop_bounded stopped >/dev/null
    container_is_running() { return 0; }; container_wait_stopped() { return 1; }
    run_with_timeout() { return 1; }; container_kill_runtime_process() { return 1; }
    DX_STOP_COMMAND_TIMEOUT=1 DX_STOP_GRACE_SECONDS=1 DX_STOP_WAIT_TIMEOUT=1
    container_stop_bounded stuck >/dev/null 2>&1 || true
)

# SSH assembly and generated launcher are data-producing helpers.
DX_SSH_PORT=2222; dx_ssh_endpoint >/dev/null; dx_ssh_append_common_options >/dev/null; dx_bootstrap_launch_command >/dev/null

# Remaining mount codec error and escape paths.
for encoded in "\$'a\\ab'" "\$'a\\bb'" "\$'a\\nb'" "\$'a\\rb'" "\$'a\\tb'" "\$'a\\eb'" "\$'a\\Eb'" "\$'a\\fb'" "\$'a\\vb'" "\$'a\\\\b'" "\$'a\\\"b'" "\$'a\\'b'"; do dx_mount_legacy_decode_value "$encoded" >/dev/null; done
(
    real_base64="$(command -v base64)"
    base64() { if [ "${1:-}" = --decode ]; then return 1; elif [ "${1:-}" = -D ]; then shift; "$real_base64" -d "$@"; else "$real_base64" "$@"; fi; }
    dx_mount_base64_decode Zm9v >/dev/null
)
dx_mount_base64_decode invalid- >/dev/null 2>&1 || true
dx_mount_base64_decode AAAAA >/dev/null 2>&1 || true
dx_mount_manifest_set UNKNOWN value >/dev/null 2>&1 || true
dx_mount_manifest_validate_field UNKNOWN value >/dev/null 2>&1 || true
dx_mount_manifest_clear; DX_RECORDED_CONTAINER_NAME=bad/name; dx_mount_manifest_finalize >/dev/null 2>&1 || true
printf '%s\n' DX_MOUNT_MANIFEST_V2 > "$fixture/short-v2"; dx_mount_manifest_read "$fixture/short-v2" >/dev/null 2>&1 || true
printf '%s\n' bad > "$fixture/bad-legacy"; dx_mount_manifest_read "$fixture/bad-legacy" >/dev/null 2>&1 || true
dx_mount_manifest_read "$fixture/missing" >/dev/null 2>&1 || true
ln -s missing "$fixture/manifest-link"; dx_mount_manifest_secure_read "$fixture/manifest-link" >/dev/null 2>&1 || true
ln -s missing "$fixture/identity-link"; dx_mount_prepare_identity_dir "$fixture/identity-link" >/dev/null 2>&1 || true

# Keyring exact readers, failed publication cleanup, and config discovery.
printf 'unix:path=/tmp/socket\n\n' > "$fixture/address"; dx_keyring_read_address "$fixture/address" >/dev/null 2>&1 || true
printf "export DBUS_SESSION_BUS_ADDRESS='unix:path=/tmp/socket'\n\n" > "$fixture/legacy"; dx_keyring_read_legacy_env "$fixture/legacy" >/dev/null 2>&1 || true
(
    mv() { return 1; }
    dx_keyring_write_address "$fixture/keyring/address" unix:path=/tmp/socket >/dev/null 2>&1 || true
)
mkdir -p "$fixture/dbus/bin" "$fixture/dbus/share/dbus-1"; : > "$fixture/dbus/bin/dbus-daemon"; : > "$fixture/dbus/share/dbus-1/session.conf"
dx_keyring_session_config "$fixture/dbus/bin/dbus-daemon" >/dev/null
rm "$fixture/dbus/share/dbus-1/session.conf"; mkdir -p "$fixture/dbus/etc/dbus-1"; : > "$fixture/dbus/etc/dbus-1/session.conf"
dx_keyring_session_config "$fixture/dbus/bin/dbus-daemon" >/dev/null
rm "$fixture/dbus/etc/dbus-1/session.conf"; dx_keyring_session_config "$fixture/dbus/bin/dbus-daemon" >/dev/null 2>&1 || true

# Tunnel metadata/discovery/list/stop branches not reached by the state suite.
DX_CONTAINER_NAME=coverage-side DX_SSH_PORT=2222 DX_SSH_KEY="$fixture/key" DX_SSH_CONNECT_TIMEOUT=1 DX_TUNNEL_LOCK_TIMEOUT=1
: > "$DX_SSH_KEY"; DX_TUNNEL_STATE_DIR="$fixture/tunnels"; export DX_TUNNEL_STATE_DIR DX_CONTAINER_NAME DX_SSH_PORT DX_SSH_KEY DX_SSH_CONNECT_TIMEOUT DX_TUNNEL_LOCK_TIMEOUT
dx_tunnel_prepare_state
dx_tunnel_metadata_write forward 5000 5001
dx_tunnel_peer_for_socket forward 5000 "$(dx_tunnel_socket_path forward 5000)" >/dev/null
TMPDIR="$fixture" dx_tunnel_discover forward >/dev/null
printf '%s\n' broken > "$fixture/tunnels/bad.meta"; dx_tunnel_metadata_read "$fixture/tunnels/bad.meta" >/dev/null 2>&1 || true
printf '%s\n' direction=forward direction=forward container=coverage-side key_port=5000 peer_port=5001 > "$fixture/tunnels/duplicate.meta"; dx_tunnel_metadata_read "$fixture/tunnels/duplicate.meta" >/dev/null 2>&1 || true
(
    mv() { return 1; }
    dx_tunnel_metadata_write forward 5000 5001 >/dev/null 2>&1 || true
)
legacy_socket="$fixture/dx-forward-$DX_CONTAINER_NAME-5000.sock"; : > "$legacy_socket"; printf '%s\n' guest_port=5001 > "$legacy_socket.meta"
TMPDIR="$fixture" dx_tunnel_legacy_peer forward "$legacy_socket" >/dev/null
printf '%s\n' host_port=5002 > "$legacy_socket.meta"; TMPDIR="$fixture" dx_tunnel_legacy_peer reverse "$legacy_socket" >/dev/null
TMPDIR="$fixture" dx_tunnel_peer_for_socket forward 5000 "$legacy_socket" >/dev/null
dx_tunnel_print_active reverse 5000 5001 >/dev/null
(
    dx_require_container_cli() { return 0; }; container_system_ensure_started() { return 0; }
    container_exists() { return 0; }; container_is_running() { return 0; }
    wait_ok() { return 0; }; dx_tunnel_require_prerequisites wait_ok
    rm -f "$DX_SSH_KEY"; dx_tunnel_require_prerequisites wait_ok >/dev/null 2>&1 || true
)
(
    dx_tunnel_discover() { :; }
    dx_tunnel_list forward >/dev/null; dx_tunnel_list reverse >/dev/null
    dx_tunnel_stop_all forward >/dev/null; dx_tunnel_stop_all reverse >/dev/null
)
dx_tunnel_stop forward 6500 >/dev/null
(
    dx_tunnel_discover() { printf '%s\t%s\n' 6000 "$fixture/orphan.sock"; }
    dx_tunnel_control_active() { return 1; }
    dx_tunnel_list forward >/dev/null
    dx_tunnel_stop() { return 1; }
    dx_tunnel_stop_all forward >/dev/null 2>&1 || true
)

# Guest common helpers are safe with command fakes.
(
    setpriv() { :; }; timeout() { :; }
    run_as_dx true; run_as_dx_with_timeout 1 true
    validate_positive_integer VALUE 0 >/dev/null 2>&1 || true
)

# Bootstrap base/storage branches run with external mutation commands replaced.
(
    essentials_profile_path() { printf '%s\n' "$fixture/essentials/bin"; }
    nix() { :; }
    command() { [ "${1:-}" = -v ] && [ "${2:-}" = useradd ] && return 1; builtin command "$@"; }
    install_essentials
)
install_essentials
DX_LINK_ROOT="$fixture/link-root" link_system_bash
setup_nix_volume
(
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() { printf '%s\n' '/nix btrfs'; }
    setup_nix_volume
)
mkdir -p /var/lib/dx-nix-raw /nix
(
    grep() {
        if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 1; fi
        if [ "$*" = '-q /nix ext4 /etc/fstab' ]; then return 1; fi
        command grep "$@"
    }
    findmnt() { return 1; }
    truncate() { : > "${3:?}"; }
    mkfs.ext4() { :; }
    mount() { :; }
    umount() { :; }
    cp() { :; }
    blkid() { return 1; }
    setup_nix_volume
    mkdir -p /mnt/tmp-nix/store
    setup_nix_volume
)
rm -f /var/lib/dx-nix-raw/nix-store.btrfs
(
    grep() {
        if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi
        if [ "$*" = '-q /nix btrfs /etc/fstab' ]; then return 1; fi
        command grep "$@"
    }
    findmnt() { return 1; }
    truncate() { : > "${3:?}"; }
    mkfs.btrfs() { :; }
    mount() { :; }
    umount() { :; }
    cp() { :; }
    blkid() { return 0; }
    setup_nix_volume
)
# The block-device path is driven by shadowing is_block_device rather than by
# creating a real device node. mknod for a block device needs CAP_MKNOD, which a
# rootless container runner does not have, so the previous `if mknod ...` form
# silently skipped these three probes and dropped this file to 85% -- the gate's
# result depended on whether docker or podman happened to run it.
fake_block="$fixture/fake-block"
: > "$fake_block"
(
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() { case "$*" in *SOURCE*) printf '%s\n' "$fake_block" ;; *) return 1 ;; esac; }
    is_block_device() { return 0; }
    blkid() { return 1; }
    umount() { return 0; }
    mkfs.btrfs() { :; }
    mount() { :; }
    cp() { :; }
    setup_nix_volume
)
(
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 1; fi; command grep "$@"; }
    findmnt() { case "$*" in *SOURCE*) printf '%s\n' "$fake_block" ;; *) return 1 ;; esac; }
    is_block_device() { return 0; }
    blkid() { return 1; }
    umount() { return 0; }
    mkfs.ext4() { :; }
    mount() { :; }
    cp() { :; }
    setup_nix_volume
)
(
    grep() { if [ "$*" = '-q btrfs /proc/filesystems' ]; then return 0; fi; command grep "$@"; }
    findmnt() { case "$*" in *SOURCE*) printf '%s\n' "$fake_block" ;; *) return 1 ;; esac; }
    is_block_device() { return 0; }
    blkid() { return 1; }
    umount() { return 1; }
    setup_nix_volume
) >/dev/null 2>&1 || true

# is_block_device itself must still be exercised for real, both ways.
is_block_device /dev/null && exit 1
is_block_device "$fake_block" && exit 1
if [ -b /dev/loop0 ]; then is_block_device /dev/loop0 || exit 1; fi
configure_nix_daemon

# System phase data resolution and root-mutating paths are safe in this runner.
mkdir -p "$fixture/release-valid" "$fixture/release-invalid"
printf '%s\n' '  nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";' > "$fixture/release-valid/flake.nix"
printf '%s\n' 'nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";' > "$fixture/release-invalid/flake.nix"
DX_BOOTSTRAP_ROOT="$fixture/release-valid" configure_release_identity
DX_BOOTSTRAP_ROOT="$fixture/release-invalid" configure_release_identity >/dev/null 2>&1 || true
mkdir -p /home/dx/.nix-profile/share/zoneinfo/Test "$fixture/tzdir/Test"
: > /home/dx/.nix-profile/share/zoneinfo/Test/Profile
: > "$fixture/tzdir/Test/Env"
mkdir -p /nix/store/dxe-coverage/share/zoneinfo/Test
: > /nix/store/dxe-coverage/share/zoneinfo/Test/Store
resolve_timezone_file Test/Store >/dev/null
resolve_timezone_file Test/Profile >/dev/null
(
    run_as_dx() { printf '%s\n' "$fixture/tzdir"; }
    resolve_timezone_file Test/Env >/dev/null
)
resolve_timezone_file Test/Missing >/dev/null 2>&1 || true
HOST_TZ=Test/Profile configure_timezone
HOST_TZ=Test/Missing configure_timezone
HOST_TZ='' configure_timezone
mkdir -p "$fixture/auth/etc"; ln -s missing "$fixture/auth/etc/passwd"
DX_AUTH_ROOT="$fixture/auth" materialize_auth_files >/dev/null 2>&1 || true
rm -f "$fixture/auth/etc/passwd"
printf '%s\n' secret > "$fixture/auth-shadow-source"; ln -s "$fixture/auth-shadow-source" "$fixture/auth/etc/shadow"
DX_AUTH_ROOT="$fixture/auth" materialize_auth_files
(
    saved_sudoers=false saved_dx=false
    [ ! -e /etc/sudoers ] || { mv /etc/sudoers "$fixture/sudoers.saved"; saved_sudoers=true; }
    [ ! -e /etc/sudoers.d/dx ] || { mv /etc/sudoers.d/dx "$fixture/sudoers-dx.saved"; saved_dx=true; }
    id() { return 1; }; groupadd() { :; }; useradd() { :; }; usermod() { :; }
    create_user
    [ "$saved_sudoers" = false ] || mv "$fixture/sudoers.saved" /etc/sudoers
    [ "$saved_dx" = false ] || mv "$fixture/sudoers-dx.saved" /etc/sudoers.d/dx
)
(
    saved_config=false saved_host_key=false
    [ ! -e /etc/ssh/sshd_config ] || { mv /etc/ssh/sshd_config "$fixture/sshd-config.saved"; saved_config=true; }
    [ ! -e /etc/ssh/ssh_host_rsa_key ] || { mv /etc/ssh/ssh_host_rsa_key "$fixture/ssh-host-key.saved"; saved_host_key=true; }
    id() { return 1; }; useradd() { :; }; ssh-keygen() { :; }; chown() { :; }
    DX_BOOTSTRAP_ROOT="$fixture/release-valid" DX_PUB_KEY='ssh-ed25519 coverage' configure_ssh
    rm -f /home/dx/.ssh/authorized_keys
    printf '%s\n' 'ssh-ed25519 fallback' > "$fixture/release-valid/dx_key.pub"
    DX_BOOTSTRAP_ROOT="$fixture/release-valid" DX_PUB_KEY='' configure_ssh
    [ "$saved_config" = false ] || mv "$fixture/sshd-config.saved" /etc/ssh/sshd_config
    [ "$saved_host_key" = false ] || mv "$fixture/ssh-host-key.saved" /etc/ssh/ssh_host_rsa_key
)

# Persistence transitions cover each recoverable GitHub CLI state shape.
mkdir -p /persist
(
    chown() { :; }; install() { local last="${!#}"; mkdir -p "$last"; }
    setup_persist
    setup_tmux_persistence
)
run_gh_case() (
    chown() { :; }; run_as_dx() { :; }
    setup_gh_persistence
)
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /home/dx/.config
: > /persist/home/dx/.config/gh; run_gh_case
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /home/dx/.config
ln -s nowhere /home/dx/.config/gh; run_gh_case
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /home/dx/.config/gh
: > /home/dx/.config/gh/config.yml; run_gh_case
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config/gh /home/dx/.config/gh
: > /home/dx/.config/gh/config.yml; run_gh_case
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config/gh /home/dx/.config/gh
: > /persist/home/dx/.config/gh/hosts.yml; : > /home/dx/.config/gh/config.yml; run_gh_case

rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx /home/dx "$fixture/dbus/bin" "$fixture/dbus/share/dbus-1"
: > "$fixture/dbus/bin/dbus-daemon"; : > "$fixture/dbus/share/dbus-1/session.conf"
(
    chown() { :; }
    run_as_dx() { case "$1" in *'command -v dbus-daemon'*) printf '%s\n' "$fixture/dbus/bin/dbus-daemon" ;; esac; }
    setpriv() { case "$*" in *--print-address*) printf '%s\n' unix:path=/tmp/dxe-coverage-bus ;; esac; }
    setup_keyring_service
    dx_keyring_address_is_live() { return 0; }
    setup_keyring_service
)
rm -f /persist/home/dx/.local/state/dx/keyring-address
printf '%s\n' "export DBUS_SESSION_BUS_ADDRESS='unix:path=/tmp/dxe-coverage-bus'" > /home/dx/.dx-keyring-env
(
    chown() { :; }; run_as_dx() { :; }; setpriv() { :; }; dx_keyring_address_is_live() { return 0; }
    setup_keyring_service
)
printf '%s\n' malicious > /home/dx/.dx-keyring-env
rm -f /persist/home/dx/.local/state/dx/keyring-address
(
    chown() { :; }; run_as_dx() { :; }; setpriv() { :; }
    setup_keyring_service >/dev/null 2>&1 || true
)

# Activation retries, ownership states, orchestration, and verification.
(
    DX_BOOTSTRAP_ROOT="$fixture/release-valid" DX_GUEST_ACTIVATION_TIMEOUT=1 DX_GUEST_ACTIVATION_ATTEMPTS=1 DX_GUEST_ACTIVATION_RETRY_DELAY=1
    run_as_dx_with_timeout() { return 0; }
    run_home_manager_activation
)
(
    DX_BOOTSTRAP_ROOT="$fixture/release-valid" DX_GUEST_ACTIVATION_TIMEOUT=1 DX_GUEST_ACTIVATION_ATTEMPTS=2 DX_GUEST_ACTIVATION_RETRY_DELAY=1
    activation_call=0
    run_as_dx_with_timeout() { activation_call=$((activation_call + 1)); [ "$activation_call" -gt 1 ] || return 124; }
    sleep() { :; }
    run_home_manager_activation
)
(
    DX_BOOTSTRAP_ROOT="$fixture/release-valid" DX_GUEST_ACTIVATION_TIMEOUT=1 DX_GUEST_ACTIVATION_ATTEMPTS=1 DX_GUEST_ACTIVATION_RETRY_DELAY=1
    run_as_dx_with_timeout() { return 9; }
    run_home_manager_activation >/dev/null 2>&1 || true
)
mkdir -p /nix/store /nix/var/nix
(
    id() { printf '%s\n' 1000; }; chown() { :; }
    rm -f /nix/.dx-owner-set; ensure_nix_ownership
    stat() { printf '%s\n' 1000:1000; }; run_as_dx() { return 0; }; ensure_nix_ownership
    run_as_dx() { return 1; }; ensure_nix_ownership
    stat() { printf '%s\n' 0:0; }; ensure_nix_ownership
)
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.local/state/dx-ai/current/profile/bin /home/dx/.nix-profile/bin
: > /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex; chmod +x /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex
: > /home/dx/.nix-profile/bin/nu
(
    ensure_nix_ownership() { :; }; chown() { :; }; run_as_dx() { :; }
    setup_gh_persistence() { :; }; setup_tmux_persistence() { :; }; setup_keyring_service() { :; }
    run_home_manager_activation() { :; }; usermod() { :; }; grep() { return 1; }
    configure_guest
)
(
    run_as_dx() { return 0; }; verify_guest_tools
    run_as_dx() { return 1; }; verify_guest_tools
) >/dev/null 2>&1 || true

echo "Isolated sourceable coverage probes passed."
