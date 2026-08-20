#!/bin/bash
# shellcheck disable=SC2034
# Additional isolated behavior probes for the D1 sourceable coverage scope.
# This script may create guest-shaped paths and therefore runs only inside the
# disposable pinned coverage environment.
set -euo pipefail

# This probe script runs standalone (it never sources tests/test_helpers.sh),
# so it carries its own copy. See the helper there for why `| grep -q` under
# `set -o pipefail` reports a successful match as a failure.
stdin_matches() { grep "$@" >/dev/null; }

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
source "$GUEST/bootstrap/herdr-config.sh"
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

# Bootstrap generation drift reporting: the launcher-lease hit and miss paths,
# and the reporter's drifted and quiet branches. Behavior for these lives in
# Section 9; these probes exist so every branch is executed under the gate.
dx_bootstrap_lease_generation 'gen-a.4242 gen-b.1' >/dev/null
dx_bootstrap_lease_generation 'gen-a.4242' >/dev/null 2>&1 || true
dx_bootstrap_report_drift old new probe 2>/dev/null
dx_bootstrap_report_drift same same probe 2>/dev/null
dx_bootstrap_report_drift '' new probe 2>/dev/null

# SSH assembly and generated launcher are data-producing helpers.
DX_SSH_PORT=2222; dx_ssh_endpoint >/dev/null; dx_bootstrap_launch_command >/dev/null

# Shared SSH boundary (dx-ssh-common.sh, F10): guest PATH/SSL data, the
# workdir snippet's set/unset branches (including the printf %q escaping
# round-trip), the env-prefix/bash-lc composition, and the non-interactive
# and interactive guest-command entry points -- missing-key guards, ssh's own
# exit status passing through unmodified (F2), and the interactive path's
# Apple Terminal OSC branch, non-Apple branch, cleanup, and never-exec
# contract (F3). `ssh` is shadowed with a plain shell function -- consistent
# with every other external-command fake in this file -- so no real
# connection is ever attempted.
(
    DX_SSH_KEY="$fixture/ssh-common-key"; : > "$DX_SSH_KEY"
    DX_SSH_PORT=2222 DX_SSH_CONNECT_TIMEOUT=1
    export DX_SSH_KEY DX_SSH_PORT DX_SSH_CONNECT_TIMEOUT

    [ "$(dx_guest_path)" = "/home/dx/.nix-profile/bin:/home/dx/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" ]
    case "$(dx_guest_ssl_env)" in *"SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"*"NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"*) ;; *) exit 1 ;; esac
    # Unset branch: no workdir means no `cd` prefix at all.
    [ -z "$(dx_guest_workdir_snippet)" ]

    # Set branch: the %q-escaped path actually cd's into a directory whose
    # name contains a space when evaluated -- proves the escaping round-trips
    # rather than just pattern-matching the generated text.
    workdir="$fixture/needs quoting"; mkdir -p "$workdir"
    result="$(cd "$fixture" && eval "$(DX_GUEST_WORKDIR="$workdir" dx_guest_workdir_snippet)pwd")"
    [ "$result" = "$(cd "$workdir" && pwd)" ]

    # dx_guest_env_prefix: HOST_TZ, PATH, the SSL trust roots, and TERM
    # actually land in the environment of whatever it feeds -- run the
    # generated prefix against real `env` and inspect the table it produces.
    actual_env="$(eval "$(dx_guest_env_prefix TestZone) env")"
    printf '%s\n' "$actual_env" | stdin_matches -xF 'HOST_TZ=TestZone'
    printf '%s\n' "$actual_env" | stdin_matches -xF "PATH=$(dx_guest_path)"
    printf '%s\n' "$actual_env" | stdin_matches -xF 'SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt'
    printf '%s\n' "$actual_env" | stdin_matches -xF 'NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt'
    printf '%s\n' "$actual_env" | stdin_matches -xF 'TERM=xterm-256color'

    # dx_guest_theme_restore_prefix guards on the restore helper being
    # executable and swallows its failure, so an unthemed guest still reaches
    # the session's real program. Run the generated prefix for real against a
    # fixture that stands in for the helper: absent, then present and failing.
    restore_probe="$fixture/theme-restore-probe"
    theme_prefix="$(dx_guest_theme_restore_prefix)"
    [ "$(eval "${theme_prefix}printf ran")" = ran ]
    printf '%s\n' '#!/bin/sh' "printf marker > '$restore_probe'" 'exit 3' > "$fixture/dx-theme-restore"
    chmod 0755 "$fixture/dx-theme-restore"
    [ "$(eval "${theme_prefix//\/home\/dx\/.local\/bin\//$fixture/}printf ran")" = ran ]
    [ "$(cat "$restore_probe")" = marker ]

    # dx_guest_bash_command composes the env prefix, workdir snippet, and the
    # bash -l -c boundary into one runnable string, with and without a workdir.
    out="$(eval "$(dx_guest_bash_command UTC 'echo hi')")"
    [ "$out" = hi ]
    workdir2="$fixture/second workdir"; mkdir -p "$workdir2"
    out2="$(cd "$fixture" && eval "$(DX_GUEST_WORKDIR="$workdir2" dx_guest_bash_command UTC pwd)")"
    [ "$out2" = "$(cd "$workdir2" && pwd)" ]

    # dx_ssh_run_guest_command: normal path reaches the shared endpoint and
    # forwards ssh's own exit status unmodified (F2), whatever it is.
    ssh() { printf '%s\n' "$*" > "$fixture/ssh-argv"; return 0; }
    dx_ssh_run_guest_command true >/dev/null
    grep -qF "$(dx_ssh_endpoint)" "$fixture/ssh-argv"
    ssh() { return 42; }
    rc=0; dx_ssh_run_guest_command true >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 42 ]

    # dx_ssh_run_guest_command: the missing-key guard is checked before
    # dialing out and reports 255 without ever invoking ssh.
    ssh() { echo "SHOULD NOT RUN" >> "$fixture/unexpected-ssh-calls"; return 0; }
    rm -f "$DX_SSH_KEY"
    rc=0; dx_ssh_run_guest_command true >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 255 ]
    [ ! -f "$fixture/unexpected-ssh-calls" ]
    : > "$DX_SSH_KEY"

    # dx_run_interactive_ssh: the same missing-key guard, reporting 1.
    rm -f "$DX_SSH_KEY"
    rc=0; dx_run_interactive_ssh true >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ]
    [ ! -f "$fixture/unexpected-ssh-calls" ]
    : > "$DX_SSH_KEY"

    # dx_run_interactive_ssh: the non-Apple-Terminal branch never emits the
    # OSC colour-reset sequence.
    ssh() { return 0; }
    osc=$'\033]110\033\\\033]111\033\\\033]104\033\\'
    err="$(unset TERM_PROGRAM; dx_run_interactive_ssh true 2>&1 >/dev/null)"
    case "$err" in *"$osc"*) exit 1 ;; esac

    # dx_run_interactive_ssh: the Apple Terminal branch emits the OSC reset on
    # stderr after the "remote" session ends (the cleanup path runs even
    # though the function never execs, F3), and a failing ssh's exit status
    # still propagates through that cleanup path unmodified.
    ssh() { return 7; }
    rc=0
    err="$(TERM_PROGRAM=Apple_Terminal dx_run_interactive_ssh true 2>&1 >/dev/null)" || rc=$?
    [ "$rc" -eq 7 ]
    case "$err" in *"$osc"*) ;; *) exit 1 ;; esac
)

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
# setup_nix_volume's mount probes intentionally replace mount with a no-op;
# keep their focus on device selection rather than attempting a real import
# from the runner's synthetic /nix tree.  Import semantics have a dedicated
# real-UID behaviour test in test_nix_store_import.sh.
nix_seed_volume() { :; }
nix_store_import_registered() { :; }
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
configure_single_user_nix

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
    mkdir -p /home/dx/.ssh
    printf '%s\n' 'existing-known-host' > /home/dx/.ssh/known_hosts
    DX_BOOTSTRAP_ROOT="$fixture/release-valid" DX_PUB_KEY='ssh-ed25519 coverage' configure_ssh
    [ "$(cat /home/dx/.ssh/known_hosts)" = 'existing-known-host' ]
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

# NOTE: the Herdr *persistence* cases live further down, beside the second
# run_herdr_case definition. The guest branch grew its own copy of them here
# against its own setup_herdr_persistence; both landed on this file, leaving
# the function defined twice with the later definition silently winning for
# every case after it. The surviving block is the one written against the
# implementation this branch kept.

# The Herdr config merger, driven directly. Behavior for these cases is
# asserted in tests/test_herdr_config_persistence.sh; what this block owes the
# gate is that every branch of the parser, the emitter, and the publication
# path actually runs -- including the ones that refuse to write.
herdr_merge_dir="$fixture/herdr-merge"
mkdir -p "$herdr_merge_dir"
herdr_template="$GUEST/bootstrap/herdr-config.toml"
herdr_merge_case() {
    local name="$1" body="$2"
    local path="$herdr_merge_dir/$name.toml"
    printf '%s' "$body" > "$path"
    DX_HERDR_CONFIG_CHECK_BIN=/bin/true dx_herdr_seed_config "$herdr_template" "$path" >/dev/null 2>&1 || true
}
# Fresh file: straight copy of the template, no merge pass at all.
DX_HERDR_CONFIG_CHECK_BIN=/bin/true dx_herdr_seed_config "$herdr_template" "$herdr_merge_dir/fresh.toml" >/dev/null 2>&1 || true
# Second run over the identical result takes the hash-equal early return.
DX_HERDR_CONFIG_CHECK_BIN=/bin/true dx_herdr_seed_config "$herdr_template" "$herdr_merge_dir/fresh.toml" >/dev/null 2>&1 || true
# Every known table already present, so each emitter finds nothing to add.
herdr_merge_case all-present "$(cat "$herdr_merge_dir/fresh.toml")"
# Known tables present but empty, plus an unrelated table and a comment: the
# per-table emit path runs and the merge preserves what it does not own.
herdr_merge_case partial '# user comment
[keys]
detach = "prefix+q"

[[keys.command]]
key = "prefix+g"
type = "popup"
command = "mine"

[ui]
sidebar_width = 31

[other]
untouched = true
'
# Single-quoted binding and command keys exercise the literal-string branches.
herdr_merge_case quoted "[keys]
goto = 'prefix+g'

[[keys.command]]
key = 'ctrl+h'
type = 'shell'
command = 'mine'
"
# A keys.command array table arriving before any [keys] scalar table forces the
# emitter to synthesise the [keys] header ahead of it.
herdr_merge_case command-first '[[keys.command]]
key = "prefix+z"
type = "shell"
command = "mine"
'
# Sub-tables and commented headers: distinct table names, no duplicates.
herdr_merge_case nested '[experimental.nested]
pane_history = false

[advanced] # trailing comment
other = 1
'
# Validator rejects the candidate: the original must survive untouched.
printf '%s' '[ui]
sidebar_width = 42
' > "$herdr_merge_dir/rejected.toml"
DX_HERDR_CONFIG_CHECK_BIN=/bin/false dx_herdr_seed_config "$herdr_template" "$herdr_merge_dir/rejected.toml" >/dev/null 2>&1 || true
# No validator resolvable at all: validation is skipped rather than fatal.
( PATH=/nonexistent DX_HERDR_CONFIG_CHECK_BIN="" dx_herdr_seed_config "$herdr_template" "$herdr_merge_dir/novalidator.toml" >/dev/null 2>&1 || true )
# Refusals: symlinked config, symlinked parent directory, absent template.
ln -sf /dev/null "$herdr_merge_dir/symlink.toml"
DX_HERDR_CONFIG_CHECK_BIN=/bin/true dx_herdr_seed_config "$herdr_template" "$herdr_merge_dir/symlink.toml" >/dev/null 2>&1 || true
mkdir -p "$herdr_merge_dir/real-dir"
ln -sfn "$herdr_merge_dir/real-dir" "$herdr_merge_dir/linkdir"
DX_HERDR_CONFIG_CHECK_BIN=/bin/true dx_herdr_seed_config "$herdr_template" "$herdr_merge_dir/linkdir/config.toml" >/dev/null 2>&1 || true
DX_HERDR_CONFIG_CHECK_BIN=/bin/true dx_herdr_seed_config "$fixture/no-such-template.toml" "$herdr_merge_dir/x.toml" >/dev/null 2>&1 || true
ln -sf "$herdr_template" "$herdr_merge_dir/template-link.toml"
DX_HERDR_CONFIG_CHECK_BIN=/bin/true dx_herdr_seed_config "$herdr_merge_dir/template-link.toml" "$herdr_merge_dir/y.toml" >/dev/null 2>&1 || true
# Malformed templates: a command block with no key, and duplicate definitions.
printf '%s' '[[keys.command]]
type = "shell"
' > "$herdr_merge_dir/tpl-nokey.toml"
DX_HERDR_CONFIG_CHECK_BIN=/bin/true dx_herdr_seed_config "$herdr_merge_dir/tpl-nokey.toml" "$herdr_merge_dir/z1.toml" >/dev/null 2>&1 || true
printf '%s' '[[keys.command]]
key = "a"
type = "shell"

[[keys.command]]
key = "a"
type = "shell"
' > "$herdr_merge_dir/tpl-dupcmd.toml"
DX_HERDR_CONFIG_CHECK_BIN=/bin/true dx_herdr_seed_config "$herdr_merge_dir/tpl-dupcmd.toml" "$herdr_merge_dir/z2.toml" >/dev/null 2>&1 || true
printf '%s' '[keys]
prefix = "a"
prefix = "b"
' > "$herdr_merge_dir/tpl-dupscalar.toml"
DX_HERDR_CONFIG_CHECK_BIN=/bin/true dx_herdr_seed_config "$herdr_merge_dir/tpl-dupscalar.toml" "$herdr_merge_dir/z3.toml" >/dev/null 2>&1 || true
# A [[keys.command]] block in the *existing* config whose key is written as a
# literal single-quoted string, so the literal-key branch of the existing-config
# reader runs as well as the double-quoted one.
herdr_merge_case literal-command "[[keys.command]]
key = 'prefix+g'
type = 'popup'
command = 'mine'
"
# A [keys] scalar whose value collides with a binding the template also wants,
# so the emitter reaches its skip-occupied-binding branch rather than writing a
# duplicate. prefix+f is the template's `goto`.
herdr_merge_case occupied-binding '[keys]
detach = "prefix+f"
'

# Herdr activation composes the persistence wrapper with the repository-owned
# merger. Exercise success and each wrapper-level failure without depending on
# an installed Herdr binary in the coverage image.
rm -rf "$fixture/herdr-activate"; mkdir -p "$fixture/herdr-activate/persist/home/dx" "$fixture/herdr-activate/home/dx"
(
    chown() { :; }
    run_as_dx() { bash -c "$1"; }
    DX_BOOTSTRAP_ROOT="$GUEST"
    DX_HERDR_CONFIG_CHECK_BIN=/bin/true
    export DX_BOOTSTRAP_ROOT DX_HERDR_CONFIG_CHECK_BIN
    dx_activate_herdr "$fixture/herdr-activate/persist/home/dx" "$fixture/herdr-activate/home/dx"
)
(
    # The wrapper's own refusal: bootstrap/herdr-config.sh was never sourced,
    # so the merge function it delegates to does not exist. A subshell keeps
    # the unset from reaching the probes that follow.
    unset -f dx_herdr_seed_config
    dx_seed_herdr_config "$fixture/missing-config.toml" "$GUEST/bootstrap/herdr-config.toml" >/dev/null 2>&1 || true
)
(
    # Default-template branch: no template argument, so the wrapper derives the
    # path from DX_BOOTSTRAP_ROOT.
    DX_BOOTSTRAP_ROOT="$GUEST" DX_HERDR_CONFIG_CHECK_BIN=/bin/true \
        dx_seed_herdr_config "$fixture/herdr-default-template.toml" >/dev/null 2>&1 || true
)
(
    # ...and with DX_BOOTSTRAP_ROOT unset, from this module's own location.
    unset DX_BOOTSTRAP_ROOT
    DX_HERDR_CONFIG_CHECK_BIN=/bin/true \
        dx_seed_herdr_config "$fixture/herdr-derived-root.toml" >/dev/null 2>&1 || true
)
(
    setup_herdr_persistence() { return 1; }
    dx_activate_herdr "$fixture/herdr-fail/persist/home/dx" "$fixture/herdr-fail/home/dx" "$GUEST/bootstrap/herdr-config.toml" >/dev/null 2>&1 || true
)
(
    setup_herdr_persistence() { :; }
    dx_seed_herdr_config() { return 1; }
    dx_activate_herdr "$fixture/herdr-fail/persist/home/dx" "$fixture/herdr-fail/home/dx" "$GUEST/bootstrap/herdr-config.toml" >/dev/null 2>&1 || true
)

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

# Herdr persistence and config seeding probes. The Herdr cases below each
# `rm -rf /persist/home/dx /home/dx` and recreate their own fixture before use,
# so they cannot clobber the keyring probes above (already run) or the
# activation/ownership probes further down (which likewise recreate their own
# /persist/home/dx and /home/dx before use).
run_herdr_case() (
    chown() { :; }; run_as_dx() { :; }
    setup_herdr_persistence
)
# Live-defect coverage: a truly fresh guest has neither ~/.config nor
# ~/.local/state yet, so setup_herdr_persistence must create and chown both
# home-side parents itself rather than relying on another tool (e.g.
# setup_gh_persistence) having already created one of them.
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /persist/home/dx/.local/state
run_herdr_case
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /persist/home/dx/.local/state /home/dx/.config /home/dx/.local/state
: > /persist/home/dx/.config/herdr; : > /persist/home/dx/.local/state/herdr; run_herdr_case
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /persist/home/dx/.local/state /home/dx/.config /home/dx/.local/state
ln -s nowhere /home/dx/.config/herdr; ln -s nowhere /home/dx/.local/state/herdr; run_herdr_case
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /persist/home/dx/.local/state /home/dx/.config/herdr /home/dx/.local/state/herdr
: > /home/dx/.config/herdr/config.toml; : > /home/dx/.local/state/herdr/announcements; run_herdr_case
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config/herdr /persist/home/dx/.local/state/herdr /home/dx/.config/herdr /home/dx/.local/state/herdr
: > /home/dx/.config/herdr/config.toml; : > /home/dx/.local/state/herdr/announcements; run_herdr_case
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config/herdr /persist/home/dx/.local/state/herdr /home/dx/.config/herdr /home/dx/.local/state/herdr
: > /persist/home/dx/.config/herdr/config.toml; : > /home/dx/.config/herdr/config.toml; run_herdr_case

# F5 regression coverage: a symlinked persistent target is rejected before
# any mutation reaches it.
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /persist/home/dx/.local/state /home/dx/.config /home/dx/.local/state
mkdir -p "$fixture/herdr-outside-target"
ln -s "$fixture/herdr-outside-target" /persist/home/dx/.config/herdr
run_herdr_case >/dev/null 2>&1 || true

# F5 regression coverage: a symlinked parent directory is rejected before any
# mutation reaches it.
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx /home/dx/.config /home/dx/.local/state
mkdir -p "$fixture/herdr-outside-parent"
ln -s "$fixture/herdr-outside-parent" /persist/home/dx/.config
run_herdr_case >/dev/null 2>&1 || true

# Readiness-marker rejection before any mutation: an existing persistent
# config directory with a symlinked marker is never safe to invalidate.
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config/herdr /persist/home/dx/.local/state /home/dx/.config /home/dx/.local/state "$fixture/herdr-marker-outside-early"
ln -s "$fixture/herdr-marker-outside-early" /persist/home/dx/.config/herdr/.dxe-persistence-ready
run_herdr_case >/dev/null 2>&1 || true

# A marker can arrive through migration when persistent_config did not exist
# during the first marker check. The post-migration check must reject it too.
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /persist/home/dx/.local/state /home/dx/.config/herdr /home/dx/.local/state "$fixture/herdr-marker-outside-migrated"
ln -s "$fixture/herdr-marker-outside-migrated" /home/dx/.config/herdr/.dxe-persistence-ready
run_herdr_case >/dev/null 2>&1 || true

# Cover the defensive post-mkdir real-directory assertion without allowing
# its artificial symlink to be traversed by chown/chmod in this isolated
# fixture. This models a replacement between the initial check and mkdir.
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /persist/home/dx/.local/state /home/dx/.config /home/dx/.local/state "$fixture/herdr-config-replaced"
(
    target=/persist/home/dx/.config/herdr
    outside="$fixture/herdr-config-replaced"
    mkdir() {
        command mkdir "$@"
        if [ "$#" -eq 2 ] && [ "$1" = -p ] && [ "$2" = "$target" ]; then
            command rmdir "$target"
            command ln -s "$outside" "$target"
        fi
    }
    chown() { :; }; chmod() { :; }; run_as_dx() { :; }
    setup_herdr_persistence >/dev/null 2>&1 || true
)

# F5 regression coverage: the state-side ephemeral-backup path (a non-empty
# home state dir colliding with a non-empty persistent state dir) is
# reachable too, not just the config-side one exercised above.
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config/herdr /persist/home/dx/.local/state/herdr /home/dx/.config/herdr /home/dx/.local/state/herdr
: > /persist/home/dx/.local/state/herdr/announcements; : > /home/dx/.local/state/herdr/announcements; run_herdr_case

# Leave a clean, non-adversarial layout so the config-seeding and
# dx_activate_herdr probes below start from real (non-symlinked) directories,
# not whatever the rejection probes above left behind.
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /persist/home/dx/.local/state /home/dx/.config /home/dx/.local/state
run_herdr_case

# Herdr config seeding probes
herdr_test_cfg="$fixture/herdr-test-config.toml"
rm -f "$herdr_test_cfg"
dx_seed_herdr_config "$herdr_test_cfg"
grep -q 'pane_history = true' "$herdr_test_cfg"
grep -q 'scrollback_limit_bytes = 10000000' "$herdr_test_cfg"

cat > "$herdr_test_cfg" <<'EOF'
[experimental]
other = 123

[advanced]
other = 456
EOF
dx_seed_herdr_config "$herdr_test_cfg"
grep -q 'pane_history = true' "$herdr_test_cfg"
grep -q 'scrollback_limit_bytes = 10000000' "$herdr_test_cfg"

cat > "$herdr_test_cfg" <<'EOF'
[experimental]
pane_history = false

[advanced]
scrollback_limit_bytes = 5000000
EOF
dx_seed_herdr_config "$herdr_test_cfg"
grep -q 'pane_history = false' "$herdr_test_cfg"
grep -q 'scrollback_limit_bytes = 5000000' "$herdr_test_cfg"

# F7 regression coverage: a key name present only under an unrelated table
# must not suppress seeding the real [experimental]/[advanced] tables.
cat > "$herdr_test_cfg" <<'EOF'
[other]
pane_history = false
scrollback_limit_bytes = 1
EOF
dx_seed_herdr_config "$herdr_test_cfg"
grep -q '^\[experimental\]$' "$herdr_test_cfg"
grep -q '^pane_history = true$' "$herdr_test_cfg"
grep -q '^\[advanced\]$' "$herdr_test_cfg"

# F7 regression coverage: a header with a trailing comment is recognized as
# that table, never appended as a second, duplicate table.
cat > "$herdr_test_cfg" <<'EOF'
[experimental] # mine
foo = 1
EOF
dx_seed_herdr_config "$herdr_test_cfg"
[ "$(grep -c '\[experimental\]' "$herdr_test_cfg")" -eq 1 ]

# F7 regression coverage: a same-named sub-table is a distinct table and must
# not suppress seeding the top-level table.
cat > "$herdr_test_cfg" <<'EOF'
[experimental.nested]
pane_history = false
EOF
dx_seed_herdr_config "$herdr_test_cfg"
grep -q '^\[experimental\.nested\]$' "$herdr_test_cfg"
grep -q '^\[experimental\]$' "$herdr_test_cfg"

# F7 regression coverage: idempotent re-run over already-seeded content.
dx_seed_herdr_config "$herdr_test_cfg"

# F7 regression coverage: TOML this seeder cannot update safely (a top-level
# dotted key) fails closed rather than partially rewriting the file.
printf '%s\n' 'experimental.pane_history = true' > "$herdr_test_cfg"
dx_seed_herdr_config "$herdr_test_cfg" >/dev/null 2>&1 || true

# F7 regression coverage: a mktemp failure is reported and leaves nothing
# behind, on both the fresh-file and existing-file publication paths.
(
    mktemp() { return 1; }
    rm -f "$herdr_test_cfg"
    dx_seed_herdr_config "$herdr_test_cfg" >/dev/null 2>&1 || true
    printf '%s\n' '[experimental]' > "$herdr_test_cfg"
    dx_seed_herdr_config "$herdr_test_cfg" >/dev/null 2>&1 || true
)

# F7 regression coverage: a chmod failure on the temp file is reported and
# leaves nothing behind, on both publication paths.
(
    chmod() { return 1; }
    rm -f "$herdr_test_cfg"
    dx_seed_herdr_config "$herdr_test_cfg" >/dev/null 2>&1 || true
    printf '%s\n' '[experimental]' > "$herdr_test_cfg"
    dx_seed_herdr_config "$herdr_test_cfg" >/dev/null 2>&1 || true
)

(
    # Exercise the complete activation/readiness publication path. A no-op
    # privilege stub used to be enough here, but readiness now deliberately
    # verifies the two links before writing its marker.
    chown() { :; }; run_as_dx() { bash -c "$1"; }
    dx_activate_herdr
)

# The readiness marker is only published after its ownership/mode setup. A
# failed marker chown must remove the temporary file and return failure.
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /persist/home/dx/.local/state /home/dx/.config /home/dx/.local/state
(
    chown() {
        case "${!#}" in
            */.dxe-persistence-ready.*) return 1 ;;
            *) : ;;
        esac
    }
    run_as_dx() { bash -c "$1"; }
    dx_activate_herdr >/dev/null 2>&1 || true
)

# dx_activate_herdr must fail loudly, not mask, when a sub-step fails (F7/F5).
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /persist/home/dx/.local/state /home/dx/.config /home/dx/.local/state
mkdir -p "$fixture/herdr-outside-activate"
ln -s "$fixture/herdr-outside-activate" /persist/home/dx/.config/herdr
(
    chown() { :; }; run_as_dx() { :; }
    dx_activate_herdr >/dev/null 2>&1 || true
)
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config/herdr /persist/home/dx/.local/state/herdr /home/dx/.config /home/dx/.local/state
printf '%s\n' 'experimental.pane_history = true' > /persist/home/dx/.config/herdr/config.toml
(
    chown() { :; }; run_as_dx() { :; }
    dx_activate_herdr >/dev/null 2>&1 || true
)
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /persist/home/dx/.local/state /home/dx/.config /home/dx/.local/state
(
    chown() {
        case "$*" in
            *"/persist/home/dx/.config/herdr /persist/home/dx/.local/state/herdr") return 1 ;;
            *) return 0 ;;
        esac
    }
    run_as_dx() { :; }
    dx_activate_herdr >/dev/null 2>&1 || true
)
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.config /persist/home/dx/.local/state /home/dx/.config /home/dx/.local/state
(
    chown() {
        case "$*" in
            */persist/home/dx/.config/herdr/config.toml) return 1 ;;
            *) return 0 ;;
        esac
    }
    run_as_dx() { bash -c "$1"; }
    dx_activate_herdr >/dev/null 2>&1 || true
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

# Home Manager's input validation failures are timed as well as returned.
(
    DX_BOOTSTRAP_ROOT="$fixture/release-valid" DX_GUEST_ACTIVATION_TIMEOUT=bad DX_GUEST_ACTIVATION_ATTEMPTS=1 DX_GUEST_ACTIVATION_RETRY_DELAY=1
    run_home_manager_activation >/dev/null 2>&1 || true
)
(
    DX_BOOTSTRAP_ROOT="$fixture/release-valid" DX_GUEST_ACTIVATION_TIMEOUT=1 DX_GUEST_ACTIVATION_ATTEMPTS=bad DX_GUEST_ACTIVATION_RETRY_DELAY=1
    run_home_manager_activation >/dev/null 2>&1 || true
)
(
    DX_BOOTSTRAP_ROOT="$fixture/release-valid" DX_GUEST_ACTIVATION_TIMEOUT=1 DX_GUEST_ACTIVATION_ATTEMPTS=1 DX_GUEST_ACTIVATION_RETRY_DELAY=bad
    run_home_manager_activation >/dev/null 2>&1 || true
)

# Keep ownership coverage on a disposable tree. The real `run_as_dx` invokes
# setpriv and cannot be used by sourceable coverage's rootless fixture; each
# branch below supplies the privilege/content result it is meant to exercise.
ownership_fixture="$fixture/nix-ownership"
mkdir -p "$ownership_fixture/store" "$ownership_fixture/var/nix"
(
    ownership_stat=0:0
    id() { printf '%s\n' 1000; }
    stat() { printf '%s\n' "$ownership_stat"; }
    chown() { :; }
    run_as_dx() { return 0; }
    essentials_store_valid() { return 0; }

    rm -f "$ownership_fixture/.dx-owner-set" "$ownership_fixture/.dx-owner-layout-v1"
    DX_NIX_OWNERSHIP_ROOT="$ownership_fixture" ensure_nix_ownership

    ownership_stat=1000:1000
    DX_NIX_OWNERSHIP_ROOT="$ownership_fixture" ensure_nix_ownership
    rm -f "$ownership_fixture/.dx-owner-set"
    DX_NIX_OWNERSHIP_ROOT="$ownership_fixture" ensure_nix_ownership

    rm -f "$ownership_fixture/.dx-owner-layout-v1"
    DX_NIX_OWNERSHIP_ROOT="$ownership_fixture" ensure_nix_ownership

    run_as_dx() { return 1; }
    ownership_status=0
    DX_NIX_OWNERSHIP_ROOT="$ownership_fixture" ensure_nix_ownership || ownership_status=$?
    [ "$ownership_status" -ne 0 ]

    run_as_dx() { return 0; }
    ownership_stat=0:0
    DX_NIX_OWNERSHIP_ROOT="$ownership_fixture" ensure_nix_ownership

    # Direct marker publication refusals and both atomic publication failure
    # points are covered independently from ensure_nix_ownership's wrapper.
    rm -f "$ownership_fixture/.dx-owner-layout-v1"
    ln -s "$ownership_fixture/store" "$ownership_fixture/.dx-owner-layout-v1.symlink-target"
    ln -s "$ownership_fixture/.dx-owner-layout-v1.symlink-target" "$ownership_fixture/.dx-owner-layout-v1"
    DX_NIX_OWNERSHIP_ROOT="$ownership_fixture" publish_nix_ownership_marker >/dev/null 2>&1 || true
    rm -f "$ownership_fixture/.dx-owner-layout-v1"
    run_as_dx() { return 1; }
    DX_NIX_OWNERSHIP_ROOT="$ownership_fixture" publish_nix_ownership_marker >/dev/null 2>&1 || true
    run_as_dx() { return 0; }
    ownership_stat=0:0
    rm -f "$ownership_fixture/.dx-owner-set"
    mv_count=0
    mv() { mv_count=$((mv_count + 1)); [ "$mv_count" -eq 1 ] && return 1; command mv "$@"; }
    DX_NIX_OWNERSHIP_ROOT="$ownership_fixture" publish_nix_ownership_marker >/dev/null 2>&1 || true
    unset -f mv
    mv_count=0
    mv() { mv_count=$((mv_count + 1)); [ "$mv_count" -eq 2 ] && return 1; command mv "$@"; }
    DX_NIX_OWNERSHIP_ROOT="$ownership_fixture" publish_nix_ownership_marker >/dev/null 2>&1 || true
    unset -f mv

    rm -f "$ownership_fixture/.dx-owner-set" "$ownership_fixture/.dx-owner-layout-v1"
    ownership_stat=1000:1000
    DX_NIX_OWNERSHIP_ROOT="$ownership_fixture" ensure_nix_ownership true

    # A completed versioned marker with a stale compatibility sentinel only
    # needs the sentinel's ownership repaired; it must not recurse through the
    # durable Nix tree again.
    printf 'durable-identity=1\nowner=dx:dx\n' > "$ownership_fixture/.dx-durable-identity-v1"
    : > "$ownership_fixture/.dx-owner-set"
    chown_calls=0
    chown() { chown_calls=$((chown_calls + 1)); }
    stat() {
        case "$3" in
            *'.dx-owner-set') printf '0:0\n' ;;
            *) printf '1000:1000\n' ;;
        esac
    }
    DX_NIX_IDENTITY_MIGRATION_REQUIRED=true migrate_durable_nix_identity_if_needed "$ownership_fixture"
    [ "$chown_calls" -gt 0 ]
)

# Persisted-tree migration refusals and directory-creation failures are kept
# in a disposable tree so the probes never depend on guest paths or accounts.
persist_edge="$fixture/persist-edge"
mkdir -p "$persist_edge"
printf '%s\n' file > "$persist_edge/not-a-directory"
(
    dx_ensure_tree_owner "$persist_edge/not-a-directory" "$persist_edge/file-marker" "non-directory" >/dev/null 2>&1 || true
    ln -s "$persist_edge/not-a-directory" "$persist_edge/marker-target"
    dx_ensure_tree_owner "$persist_edge" "$persist_edge/marker-target" "symlink-marker" >/dev/null 2>&1 || true
    id() { return 0; }
    install() { return 1; }
    dx_ensure_tree_owner "$persist_edge/install-failure" "$persist_edge/install-failure.marker" "install-failure" >/dev/null 2>&1 || true
    install() { :; }
    dx_ensure_tree_owner "$persist_edge/mkdir-failure" "$persist_edge/mkdir-failure.marker" "mkdir-failure" >/dev/null 2>&1 || true
    id() { return 1; }
    mkdir() { :; }
    dx_ensure_tree_owner "$persist_edge/no-guest" "$persist_edge/no-guest.marker" "no-guest" >/dev/null 2>&1 || true
    ln -s "$persist_edge" "$persist_edge/owned-directory-symlink"
    dx_prepare_owned_directory "$persist_edge/owned-directory-symlink" 0700 >/dev/null 2>&1 || true
)

rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.local/state/dx-ai/current/profile/bin /home/dx/.nix-profile/bin
: > /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex; chmod +x /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex
: > /home/dx/.nix-profile/bin/nu
(
    ensure_nix_ownership() { :; }; chown() { :; }; run_as_dx() { :; }
    setup_gh_persistence() { :; }; setup_tmux_persistence() { :; }; dx_activate_herdr() { :; }; setup_keyring_service() { :; }
    run_home_manager_activation() { :; }; usermod() { :; }; grep() { return 1; }
    configure_guest
)

# ai_tools_enabled=false branch: setup_keyring_service must never be called
# when the AI-tools guard is false (the flag has to stay false all the way to
# the moved call site after run_home_manager_activation).
rm -rf /persist/home/dx /home/dx; mkdir -p /home/dx/.nix-profile/bin
: > /home/dx/.nix-profile/bin/nu
(
    ensure_nix_ownership() { :; }; chown() { :; }; run_as_dx() { :; }
    setup_gh_persistence() { :; }; setup_tmux_persistence() { :; }
    keyring_called=0
    setup_keyring_service() { keyring_called=1; }
    run_home_manager_activation() { :; }; usermod() { :; }; grep() { return 1; }
    configure_guest
    [ "$keyring_called" -eq 0 ]
)

# Bootstrap ordering defect: configure_guest must not start the D-Bus keyring
# service until Home Manager activation has installed dbus-daemon into dx's
# profile. On a fresh dx-recreate /home/dx is ephemeral, so
# setup_keyring_service's `dbus_bin="$(run_as_dx 'command -v dbus-daemon')"`
# lookup only succeeds once Home Manager activation has run. The custom
# run_as_dx below prints a PROBE line recording whether Home Manager's stub
# has already run at the moment the lookup is attempted -- that is the direct
# signal for the *ordering*, since there is still no error string tied to the
# old defect itself (a bare failed command substitution under
# `set -euo pipefail` used to kill the whole bootstrap in total silence), so
# the assertions below are on outcome and ordering, never on error text.
#
# This has to run as a genuinely separate bash process (not sourced/stubbed
# in-place in this already-running script): bash's `errexit` does not
# reliably propagate out of a failing bare-assignment command substitution
# that occurs inside a function which is itself being captured by another
# `$(...)` in the same interpreter -- verified empirically, execution quietly
# continues past the failure instead of aborting, which would mask exactly
# the defect this test exists to catch. The real bootstrap runs
# `configure_guest` as the top-level script of its own bash process, so a
# fresh `bash` subprocess is what actually reproduces the silent-death
# signature.
rm -rf /persist/home/dx /home/dx
mkdir -p /persist/home/dx/.local/state/dx-ai/current/profile/bin
: > /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex
chmod +x /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex
mkdir -p "$fixture/dbus-order/bin" "$fixture/dbus-order/share/dbus-1"
: > "$fixture/dbus-order/bin/dbus-daemon"
: > "$fixture/dbus-order/share/dbus-1/session.conf"
order_script="$(mktemp "$fixture/dxe-configure-guest-order.XXXXXX")"
cat > "$order_script" <<'INNER'
set -euo pipefail
source "$DXE_TEST_GUEST/scripts/lib/dx-keyring.sh"
source "$DXE_TEST_GUEST/bootstrap/common.sh"
source "$DXE_TEST_GUEST/bootstrap/base-and-storage.sh"
source "$DXE_TEST_GUEST/bootstrap/system.sh"
source "$DXE_TEST_GUEST/bootstrap/persistence.sh"
source "$DXE_TEST_GUEST/bootstrap/activation.sh"
ensure_nix_ownership() { :; }
chown() { :; }
setup_gh_persistence() { :; }
setup_tmux_persistence() { :; }
usermod() { :; }
hm_ran=0
run_as_dx() {
    case "$1" in
        (*'command -v dbus-daemon'*)
            # Deliberately >&2: this call's stdout is captured into the
            # `dbus_bin="$(run_as_dx ...)"` assignment in setup_keyring_service,
            # so anything printed on stdout here would vanish into that
            # variable rather than reach this test's output -- which is
            # exactly the mechanism that makes the underlying defect silent.
            echo "PROBE: dbus-daemon lookup attempted with hm_ran=$hm_ran" >&2
            [ "$hm_ran" -eq 1 ] || return 1
            printf '%s\n' "$DXE_TEST_DBUS_BIN"
            ;;
        (*) return 0 ;;
    esac
}
run_home_manager_activation() { hm_ran=1; echo "STUB: Home Manager activation ran"; }
setpriv() { case "$*" in (*--print-address*) printf '%s\n' unix:path=/tmp/dxe-coverage-order-bus ;; (*) return 0 ;; esac; }
configure_guest
echo "STUB: configure_guest returned normally"
INNER
rc=0
output="$(DXE_TEST_GUEST="$GUEST" DXE_TEST_DBUS_BIN="$fixture/dbus-order/bin/dbus-daemon" bash "$order_script" 2>&1)" || rc=$?
rm -f "$order_script"
if [ "$rc" -ne 0 ]; then
    echo "Error: configure_guest did not complete (rc=$rc). Output:" >&2
    printf '%s\n' "$output" >&2
    exit 1
fi
if ! printf '%s\n' "$output" | stdin_matches -F 'PROBE: dbus-daemon lookup attempted with hm_ran=1'; then
    echo "Error: dbus-daemon was never looked up after Home Manager activation ran. Output:" >&2
    printf '%s\n' "$output" >&2
    exit 1
fi
if printf '%s\n' "$output" | stdin_matches -F 'hm_ran=0'; then
    echo "Error: setup_keyring_service looked up dbus-daemon before Home Manager activation ran. Output:" >&2
    printf '%s\n' "$output" >&2
    exit 1
fi
if ! printf '%s\n' "$output" | stdin_matches -F 'STUB: configure_guest returned normally'; then
    echo "Error: configure_guest did not return normally after the keyring service ran. Output:" >&2
    printf '%s\n' "$output" >&2
    exit 1
fi

rm -rf /persist/home/dx /home/dx

# Core Nix bootstrap negative/recovery branches.  These are sourceable-only
# fakes: every path is under the disposable fixture and no guest service is
# contacted.
# Earlier volume-selection probes intentionally replace the import functions.
# Re-source the production implementation before exercising its failure and
# recovery boundaries below.
source "$GUEST/bootstrap/base-and-storage.sh"
(
    command() { [ "$1" = -v ] && [ "$2" = useradd ] && return 1; builtin command "$@"; }
    essentials_profile_path() { :; }
    install_essential_packages() { return 7; }
    install_essentials >/dev/null 2>&1 || true

    essentials_profile_store_path() { printf '%s\n' /nix/store/profile; }
    essentials_store_valid() { return 0; }
    ensure_essentials_valid >/dev/null
    essentials_store_valid() { return 1; }
    repair_store_closure() { :; }
    ensure_essentials_valid >/dev/null 2>&1 || true
)
(
    root="$fixture/core-nix-branches"
    mkdir -p "$root/store" "$root/var/nix"
    chown() { :; }
    DX_NIX_PENDING_IMAGE_STORE_IDENTITY=bad
    nix_install_image_essentials_root "$root" 1000 1000 >/dev/null 2>&1 || true
    DX_NIX_PENDING_IMAGE_STORE_IDENTITY=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/root; }
    ln() { return 1; }
    nix_install_image_essentials_root "$root" 1000 1000 >/dev/null 2>&1 || true
    unset -f ln
    nix_install_image_essentials_root "$root" 1000 1000

    # A failed root enumeration must remove the private stage before returning
    # so a later bootstrap cannot mistake it for a published root set.
    rm -rf "$root/var/nix/gcroots"/dx-image-roots-*
    nix_image_bootstrap_store_paths() { return 1; }
    nix_install_image_essentials_root "$root" 1000 1000 >/dev/null 2>&1 || true

    seed="$root/seed"; target="$root/target"
    mkdir -p "$seed/store/a" "$target"
    printf x > "$seed/store/a/file"
    mv() { case "$1" in *'/contents/'*) return 1;; *) command mv "$@";; esac; }
    nix_seed_volume "$seed" "$target" 1000 1000 >/dev/null 2>&1 || true
    unset -f mv

    mkdir -p "$root/unsafe-persist"
    chown 0:0 "$root/unsafe-persist"
    DX_PERSIST_HOME="$root/unsafe-persist" record_durable_nix_identity "$root"

    id() { case "$1:$2" in -u:dx|-g:dx) printf '%s\n' 1000;; *) builtin id "$@";; esac; }
    chown() { :; }
    : > "$root/.dx-durable-identity-v1"
    printf 'durable-identity=1\nowner=dx:dx\n' > "$root/.dx-durable-identity-v1"
    stat() { printf '1000:1000\n'; }
    DX_NIX_IDENTITY_MIGRATION_REQUIRED=true migrate_durable_nix_identity_if_needed "$root"
    rm -f "$root/.dx-owner-set"
    DX_NIX_IDENTITY_MIGRATION_REQUIRED=true migrate_durable_nix_identity_if_needed "$root"
    mv() { return 1; }
    DX_NIX_IDENTITY_MIGRATION_REQUIRED=true migrate_durable_nix_identity_if_needed "$root" >/dev/null 2>&1 || true
    unset -f mv
    : > "$root/.dx-owner-set"
    stat() { case "$1" in *'.dx-owner-set') printf '1:1\n';; *) printf '1000:1000\n';; esac; }
    DX_NIX_IDENTITY_MIGRATION_REQUIRED=true migrate_durable_nix_identity_if_needed "$root"

    nix() { return 1; }
    nix_image_registered_paths >/dev/null 2>&1 || true
    unset -f nix

    mkdir -p "$root/gate"; printf '%s\n' identity > "$root/gate/.dx-image-store-identity"
    nix_image_store_identity() { printf '%s\n' identity; }
    nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/root; }
    run_as_dx() { return 0; }
    nix_image_store_import_required /nix "$root/gate" >/dev/null 2>&1 || true
    chown() { :; }
    DX_NIX_PENDING_IMAGE_STORE_IDENTITY=identity
    publish_nix_image_store_identity "$root/gate"

    # A directory at the image identity marker is not an absent marker: the
    # gate must retain the computed identity for a retry rather than silently
    # treating the directory as a valid publication.
    mkdir -p "$root/gate-directory/.dx-image-store-identity"
    unset DX_NIX_PENDING_IMAGE_STORE_IDENTITY
    nix_image_store_import_required /nix "$root/gate-directory"
    [ "${DX_NIX_PENDING_IMAGE_STORE_IDENTITY:-}" = identity ]

    # Exercise the portable sourceable fallback used on Darwin. It still
    # replaces a validated marker atomically and leaves no temporary file.
    fallback_marker="$root/fallback-marker"
    fallback_temporary="$root/fallback-marker.tmp"
    printf '%s\n' fallback > "$fallback_temporary"
    uname() { printf '%s\n' Darwin; }
    dx_publish_atomic_marker "$fallback_temporary" "$fallback_marker" "coverage fallback marker"
    unset -f uname
    [ -f "$fallback_marker" ] && [ "$(cat "$fallback_marker")" = fallback ] && [ ! -e "$fallback_temporary" ]

    DX_NIX_VOLUME_ALREADY_MOUNTED=true DX_NIX_VOLUME_ROOT="$root" populate_prepared_nix_volume
    populate_prepared_nix_volume() { :; }
    setup_nix_volume_impl
)
(
    # Exercise every refusal branch of the retained image-default profile
    # helper against a disposable tree.  The Linux behavior test proves the
    # successful GC/recovery flow; these probes keep its defensive boundaries
    # observable without ever touching a mounted guest Nix store.
    root="$fixture/default-profile-branches"
    profiles="$root/var/nix/profiles"
    target="$root/store/default-profile"
    mkdir -p "$target/bin" "$target/etc/ssl/certs" "$profiles"
    : > "$target/bin/sh"; : > "$target/bin/nix"; : > "$target/etc/ssl/certs/ca-bundle.crt"
    chmod 0755 "$target/bin/sh" "$target/bin/nix"

    ln -s /tmp "$profiles/default"
    ! nix_image_default_profile_store_path "$root" >/dev/null 2>&1 || exit 1
    rm "$profiles/default"
    ln -s "$target" "$profiles/default"
    rm "$target/etc/ssl/certs/ca-bundle.crt"
    ! nix_image_default_profile_store_path "$root" >/dev/null 2>&1 || exit 1
    : > "$target/etc/ssl/certs/ca-bundle.crt"

    unset DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET
    ! DX_NIX_ROOT="$root" nix_restore_image_default_profile >/dev/null 2>&1 || exit 1
    ln -s unavailable "$root/store/unavailable"
    DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET="$root/store/unavailable"
    ! DX_NIX_ROOT="$root" nix_restore_image_default_profile >/dev/null 2>&1 || exit 1
    DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET=/tmp
    ! DX_NIX_ROOT="$root" nix_restore_image_default_profile >/dev/null 2>&1 || exit 1
    DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET="$target"
    rm "$target/etc/ssl/certs/ca-bundle.crt"
    ! DX_NIX_ROOT="$root" nix_restore_image_default_profile >/dev/null 2>&1 || exit 1
    : > "$target/etc/ssl/certs/ca-bundle.crt"

    rm -rf "$root/var/nix"
    ln -s /tmp "$root/var/nix"
    ! DX_NIX_ROOT="$root" nix_restore_image_default_profile >/dev/null 2>&1 || exit 1
    rm "$root/var/nix"
    mkdir -p "$profiles"
    : > "$profiles/default"
    ! DX_NIX_ROOT="$root" nix_restore_image_default_profile >/dev/null 2>&1 || exit 1
    rm "$profiles/default"

    chown() { return 1; }
    ! DX_NIX_ROOT="$root" nix_restore_image_default_profile >/dev/null 2>&1 || exit 1
    ! find "$profiles" -name '.default.dx.*' -print -quit | grep -q . || exit 1
    unset -f chown
    chown() { :; }
    readlink() {
        if [ "${1:-}" = "$profiles/default" ]; then printf '%s\n' wrong-target; else command readlink "$@"; fi
    }
    ! DX_NIX_ROOT="$root" nix_restore_image_default_profile >/dev/null 2>&1 || exit 1
)
(
    auth_root="$fixture/core-auth"
    mkdir -p "$auth_root/etc"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' > "$auth_root/etc/passwd"
    printf '%s\n' 'root:x:0:' > "$auth_root/etc/group"
    id() { [ "$1" = -u ] && [ "$2" = dx ] && return 1; builtin id "$@"; }
    groupadd() { :; }; useradd() { :; }; usermod() { :; }
    DX_AUTH_ROOT="$auth_root" DX_NIX_DURABLE_UID=42420 DX_NIX_DURABLE_GID=42420 create_user
    ! DX_AUTH_ROOT="$fixture/core-auth-missing" auth_entries_with_numeric_id passwd 42420 >/dev/null 2>&1 || exit 1
)
(
    root="$fixture/core-nix-final"
    mkdir -p "$root/store" "$root/var/nix"
    id() { case "$1:$2" in -u:dx|-g:dx) printf '%s\n' 1000;; *) builtin id "$@";; esac; }
    stat() { printf '1000:1000\n'; }
    chown() { :; }
    run_as_dx() { :; }
    essentials_store_valid() { :; }
    : > "$root/.dx-durable-identity-v1"
    printf 'durable-identity=1\nowner=dx:dx\n' > "$root/.dx-durable-identity-v1"
    rm -f "$root/.dx-owner-set"
    mv() { return 1; }
    DX_NIX_IDENTITY_MIGRATION_REQUIRED=true migrate_durable_nix_identity_if_needed "$root" >/dev/null 2>&1 || true
    unset -f mv
    rm -f "$root/.dx-durable-identity-v1" "$root/.dx-owner-set"
    mv() { return 1; }
    DX_NIX_IDENTITY_MIGRATION_REQUIRED=true migrate_durable_nix_identity_if_needed "$root" >/dev/null 2>&1 || true
    unset -f mv

    DX_NIX_VOLUME_ALREADY_MOUNTED=false DX_NIX_VOLUME_ROOT="$root" DX_NIX_VOLUME_FS_TYPE=fake DX_NIX_VOLUME_MOUNT_OPTS=none DX_NIX_VOLUME_DEVICE=fake
    migrate_durable_nix_identity_if_needed() { :; }
    nix_image_store_import_required() { return 1; }
    nix_install_image_essentials_root() { :; }
    umount() { :; }; mount() { :; }; grep() { return 0; }
    populate_prepared_nix_volume
)
(
    root="$fixture/activation-marker-failure"
    mkdir -p "$root/store" "$root/var/nix"
    id() { printf '%s\n' 1000; }
    run_as_dx() { :; }; essentials_store_valid() { :; }; chown() { :; }; stat() { printf '1000:1000\n'; }
    : > "$root/.dx-owner-set"
    mv() { return 1; }
    DX_NIX_OWNERSHIP_ROOT="$root" publish_nix_ownership_marker >/dev/null 2>&1 || true
)
(
    # Explicit lifecycle seams report both outcomes independently from the
    # compatibility wrapper.
    prepare_nix_volume_impl() { return 0; }
    prepare_nix_volume >/dev/null
    prepare_nix_volume_impl() { return 9; }
    prepare_nix_volume >/dev/null 2>&1 || true
)
(
    # The host-wide Nix-volume claim is a lifecycle boundary, not mounted
    # store state. Exercise acquisition, contention, stale takeover, and
    # owner-only release with disposable host state.
    HOME="$fixture/claim-home" DXE_SELF_PROCESS_IDENTITY="coverage-$$" DX_TUNNEL_LOCK_TIMEOUT=1
    existing=first
    container_exists() { [ "$existing" = "$1" ]; }
    dx_nix_volume_claim_acquire coverage-nix first
    ! dx_nix_volume_claim_acquire coverage-nix second
    existing=""
    dx_nix_volume_claim_acquire coverage-nix second
    existing=second
    dx_nix_volume_claim_acquire coverage-nix second
    existing=""
    ! dx_nix_volume_claim_acquire ../unsafe second
    printf 'malformed\n' > "$HOME/.dx-cache/nix-volume-claims/malformed-nix"
    ! dx_nix_volume_claim_acquire malformed-nix second
    printf 'stale\t999999\tdead-process\nsecond\t999998\tdead-process\n' > "$HOME/.dx-cache/nix-volume-claims/multiline-nix"
    ! dx_nix_volume_claim_acquire multiline-nix second
    printf 'creating\t444\tlive-start\n' > "$HOME/.dx-cache/nix-volume-claims/reserved-nix"
    dx_process_identity_matches() { return 0; }
    ! dx_nix_volume_claim_acquire reserved-nix second
    dx_nix_volume_claim_release coverage-nix first
    dx_nix_volume_claim_release coverage-nix second
)
(
    # A validated caller may bypass the duplicate content check, but still
    # must prove dx can write both Nix roots before publication.
    root="$fixture/validated-ownership"
    mkdir -p "$root/store" "$root/var/nix"
    id() { printf '%s\n' 1000; }
    stat() { printf '%s\n' 1000:1000; }
    run_as_dx() { return 0; }
    chown() { :; }
    DX_NIX_OWNERSHIP_ROOT="$root" ensure_nix_ownership true
)
(
    run_as_dx() { return 0; }; verify_guest_tools
    run_as_dx() { return 1; }; verify_guest_tools
) >/dev/null 2>&1 || true

echo "Isolated sourceable coverage probes passed."
