#!/bin/bash
# shellcheck disable=SC2034
# Additional isolated behavior probes for the D1 sourceable coverage scope.
# This script may create guest-shaped paths and therefore runs only inside the
# disposable pinned coverage environment.
set -Eeuo pipefail

# This file is a long, output-free probe: on success it prints nothing until
# its final line, so an unexpected failure anywhere in it used to be
# indistinguishable from CI silently killing the step -- a bare `set -e`
# abort prints no diagnostic of its own. Report exactly what broke instead.
# `cmd || true`/`cmd || { ...; }`-guarded *expected* failures never reach
# this: bash does not run ERR for the command before the final `||` in a
# list, only for a genuinely unhandled one (`-E` carries that into functions
# and command substitutions too, not just this top-level script).
trap 'echo "test_sourceable_coverage.sh:${LINENO}: unexpected failure (exit $?): ${BASH_COMMAND}" >&2' ERR

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
source "$ROOT/bin/lib/dx-runtime.sh"
source "$ROOT/bin/lib/dx-container.sh"
source "$ROOT/bin/lib/dx-ssh-common.sh"
source "$ROOT/bin/lib/dx-mount-plan.sh"
source "$ROOT/bin/lib/dx-tunnel.sh"
source "$GUEST/scripts/lib/dx-keyring.sh"
source "$GUEST/scripts/lib/dx-opencode-persistence.sh"
source "$GUEST/scripts/lib/dx-guest-system.sh"
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
    # dx_runtime_apple_volume_usage (Branch 11 / Phase 3): today's host
    # sparse-image sizing, both the missing-image and found-image branches.
    vu_root="$fixture/apple-volume-usage"
    mkdir -p "$vu_root/dxe-vu-missing"
    DX_CONTAINER_VOLUME_DIR="$vu_root"
    [ "$(dx_runtime_apple_volume_usage dxe-vu-missing)" = missing ]
    mkdir -p "$vu_root/dxe-vu-present"
    printf 'x' > "$vu_root/dxe-vu-present/volume.img"
    dx_runtime_apple_volume_usage dxe-vu-present >/dev/null
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

# Runtime contract and Apple adapter (Branch 11 / Phase 1, qnap-dxe-plan.md
# DQ2): dispatch success/rejection for every DX_RUNTIME value, every
# dx_runtime_apple_* function and its primary/fallback branches, and the two
# explicit preservation proofs the coordinating session required 2026-09-27:
# dx_runtime_exec's stdin passthrough (piped and file-redirected, with no
# intermediate subshell or `cat`, exit status unchanged under `set -o
# pipefail`) and verbatim argv passthrough, via a fake `container` shell
# function recording both. Behavior for the operations these dispatch to
# lives in bin/lib/dx-container.sh's own probes above (unchanged) and in
# tests/test_section16_persist_storage.sh (dx-migrate-persist's runtime-
# client-race retry, end to end through dx-runtime-apple.sh's
# dx_runtime_apple_run_ephemeral); these probes exist so every branch is
# also executed under this 100%-line-coverage gate, which does not run
# either of those test files.
(
    PATH=/usr/bin:/bin; unset -f container 2>/dev/null || true
    dx_runtime_apple_available >/dev/null 2>&1 || true
    dx_runtime_available >/dev/null 2>&1 || true
)
(
    DX_RUNTIME=bogus
    dx_runtime_dispatch_ok >/dev/null 2>&1 || true
    DX_RUNTIME=docker
    dx_runtime_available >/dev/null 2>&1 || true
)
(
    DX_RUNTIME=apple
    container() {
        case "$*" in
            'system status') return 0 ;;
            'system start') return 0 ;;
            'list -a --quiet') printf '%s\n' side ;;
            'list --quiet') printf '%s\n' side ;;
            'list -a') printf 'NAME STATE\nside stopped\n' ;;
            'list') printf 'NAME STATE\nside running\n' ;;
            'image list --quiet') printf '%s\n' img ;;
            'image list') printf 'NAME\nimg\n' ;;
            'build img /ctx') return 0 ;;
            'image rm img') return 0 ;;
            'volume inspect vol') return 0 ;;
            'volume create vol') return 0 ;;
            'volume rm vol') return 0 ;;
            'create --name side --entrypoint sh --cap-add CAP_SYS_ADMIN --volume nixvol:/var/lib/dx-nix-raw:rw --volume persistvol:/persist:rw --volume bootvol:/guest-bootstrap:rw -e FOO=bar -m 1G -c 2 -p 127.0.0.1:2222:2222 img -c echo hi -- /guest-bootstrap') return 0 ;;
            'start side') return 0 ;;
            'stop side') return 0 ;;
            'kill side') return 0 ;;
            'delete side') return 0 ;;
            'exec side echo hi') printf 'hi\n' ;;
            'logs side') return 0 ;;
            'export side') printf 'bytes' ;;
        esac
    }
    dx_runtime_available >/dev/null
    dx_runtime_system_running >/dev/null
    dx_runtime_system_start >/dev/null
    dx_runtime_container_exists side >/dev/null
    dx_runtime_container_running side >/dev/null
    dx_runtime_container_list -a >/dev/null
    dx_runtime_image_exists img >/dev/null
    dx_runtime_image_list >/dev/null
    dx_runtime_image_build img /ctx >/dev/null
    dx_runtime_image_delete img >/dev/null
    dx_runtime_volume_exists vol >/dev/null
    dx_runtime_volume_create vol >/dev/null
    dx_runtime_volume_delete vol >/dev/null
    # --health-cmd/--health-interval/--health-retries (Branch 11 / Phase 6
    # item 4): Apple discards all three (dx_runtime_apple_container_create's
    # own parse loop does a bare "shift 2" for each), so the fake's expected
    # rendered argv above is unaffected byte for byte -- these three flags
    # exist here purely to execute that discard path under this 100%-line-
    # coverage gate, which does not run tests/test_docker_runtime_adapter.sh
    # (Section 33), where the same three lines are otherwise unreached.
    dx_runtime_container_create --name side --image img \
        --volume nix:nixvol:rw --volume persist:persistvol:/persist:rw --volume bootstrap:bootvol:/guest-bootstrap:rw \
        --env FOO=bar --memory 1G --cpus 2 --publish 2222:2222 --restart-policy no \
        --health-cmd 'ls /guest-bootstrap/.locks/leases/*' --health-interval 10s --health-retries 3 \
        --entrypoint-cmd 'echo hi' --entrypoint-arg /guest-bootstrap >/dev/null
    dx_runtime_container_start side >/dev/null
    dx_runtime_container_stop side >/dev/null
    dx_runtime_container_kill side >/dev/null
    dx_runtime_container_delete side >/dev/null
    dx_runtime_exec side echo hi >/dev/null
    dx_runtime_logs side >/dev/null
    dx_runtime_export side >/dev/null
    dx_runtime_host_identity >/dev/null
    dx_runtime_guest_ssh_address >/dev/null
    dx_runtime_capability direct_named_volume_mounts
    dx_runtime_capability bind_mounts
    dx_runtime_capability restart_policy || true
    dx_runtime_capability host_filesystem_reclamation
    dx_runtime_capability bogus >/dev/null 2>&1 || true
)
(
    DX_RUNTIME=apple
    container() {
        case "$*" in
            *--quiet*) return 1 ;;
            'list -a') printf 'NAME STATE\nside stopped\n' ;;
            'list') printf 'NAME STATE\nside running\n' ;;
            'image list') printf 'NAME\nimg\n' ;;
        esac
    }
    dx_runtime_container_exists side >/dev/null
    dx_runtime_container_running side >/dev/null
    dx_runtime_image_exists img >/dev/null
)
(
    DX_RUNTIME=apple
    container() { [ "$1" = run ] && { printf 'ok\n'; return 0; }; return 1; }
    DX_MIGRATE_RUN_MAX_ATTEMPTS=2 DX_MIGRATE_RUN_RETRY_DELAY=0 dx_runtime_run_ephemeral --rm x >/dev/null
)
(
    DX_RUNTIME=apple
    run_count=0
    container() {
        if [ "$1" = run ]; then
            run_count=$((run_count + 1))
            if [ "$run_count" -eq 1 ]; then echo "Error: no runtime client exists: container is stopped" >&2; return 1; fi
            printf 'ok\n'; return 0
        fi
        return 1
    }
    DX_MIGRATE_RUN_MAX_ATTEMPTS=3 DX_MIGRATE_RUN_RETRY_DELAY=0 dx_runtime_run_ephemeral --rm x >/dev/null
)
(
    DX_RUNTIME=apple
    container() { [ "$1" = run ] && { echo "Error: no runtime client exists: container is stopped" >&2; return 1; }; return 1; }
    DX_MIGRATE_RUN_MAX_ATTEMPTS=2 DX_MIGRATE_RUN_RETRY_DELAY=0 dx_runtime_run_ephemeral --rm x >/dev/null 2>&1 || true
)
(
    DX_RUNTIME=apple
    container() { [ "$1" = run ] && { echo "Error: distinct failure" >&2; return 1; }; return 1; }
    DX_MIGRATE_RUN_MAX_ATTEMPTS=2 DX_MIGRATE_RUN_RETRY_DELAY=0 dx_runtime_run_ephemeral --rm x >/dev/null 2>&1 || true
)
(
    DX_RUNTIME=apple
    argv_log="$fixture/runtime-exec-argv.log"
    stdin_log="$fixture/runtime-exec-stdin.log"
    container() {
        printf '%s\n' "$@" > "$argv_log"
        if [ "${1:-}" = exec ]; then
            shift
            [ "${1:-}" = -i ] && { shift; cat > "$stdin_log"; }
        fi
        return 7
    }
    rc_piped=0
    printf 'piped payload' | dx_runtime_exec -i side sh -c 'cat' -- "an arg with spaces" || rc_piped=$?
    [ "$(cat "$stdin_log")" = "piped payload" ] || { echo "Error: dx_runtime_exec lost piped stdin." >&2; exit 1; }
    [ "$rc_piped" -eq 7 ] || { echo "Error: dx_runtime_exec did not preserve the piped-stdin exit status ($rc_piped)." >&2; exit 1; }
    grep -F -x -q -- "an arg with spaces" "$argv_log" || { echo "Error: dx_runtime_exec did not pass argv verbatim." >&2; exit 1; }

    printf 'file payload' > "$fixture/runtime-exec-source"
    rc_file=0
    dx_runtime_exec -i side cat < "$fixture/runtime-exec-source" || rc_file=$?
    [ "$(cat "$stdin_log")" = "file payload" ] || { echo "Error: dx_runtime_exec lost redirected stdin." >&2; exit 1; }
    [ "$rc_file" -eq 7 ] || { echo "Error: dx_runtime_exec did not preserve the redirected-stdin exit status ($rc_file)." >&2; exit 1; }
)

# Bootstrap generation drift reporting: the launcher-lease hit and miss paths,
# and the reporter's drifted and quiet branches. Behavior for these lives in
# Section 9; these probes exist so every branch is executed under the gate.
dx_bootstrap_lease_generation 'gen-a.4242 gen-b.1' >/dev/null
dx_bootstrap_lease_generation 'gen-a.4242' >/dev/null 2>&1 || true
dx_bootstrap_report_drift old new probe 2>/dev/null
dx_bootstrap_report_drift same same probe 2>/dev/null
dx_bootstrap_report_drift '' new probe 2>/dev/null

# Bootstrap payload digest: the success path, the not-a-directory rejection, and
# both halves of the SHA-256 tool pick. Behavior lives in Section 9; these
# probes exist so every branch is executed under the gate. Reaching the shasum
# fallback needs a PATH with no sha256sum anywhere on it, so the probe builds a
# minimal one rather than assuming the runner lacks coreutils.
digest_fixture="$fixture/bootstrap-digest"
mkdir -p "$digest_fixture"
printf 'payload\n' > "$digest_fixture/bootstrap.sh"
dx_bootstrap_content_digest "$digest_fixture" >/dev/null
dx_bootstrap_content_digest "$digest_fixture/bootstrap.sh" >/dev/null 2>&1 || true
(
    digest_bin="$fixture/digest-bin"
    mkdir -p "$digest_bin"
    for digest_tool in find sort cat; do
        digest_tool_path="$(command -v "$digest_tool")" || continue
        ln -sf "$digest_tool_path" "$digest_bin/$digest_tool"
    done
    # This fake shasum is invoked twice in the fallback pipeline (once per
    # file via `find -exec`, once more reading `sort`'s output): it must
    # drain its stdin before printing, or the upstream `sort` can still be
    # writing when this exits, earning a SIGPIPE that `pipefail` turns into
    # a failing pipeline status though every stage's own logic succeeded.
    # `cat` is already symlinked into $digest_bin above.
    printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s  -\\n" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' > "$digest_bin/shasum"
    chmod 0755 "$digest_bin/shasum"
    PATH="$digest_bin" dx_bootstrap_content_digest "$digest_fixture" </dev/null >/dev/null
)

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

# dx_ssh_probe_login_shell (Branch 11 / Phase 6, qnap-dxe-plan.md Phase 6
# item 5): the shared one-shot readiness probe bin/dx-wait-ssh's poll loop
# and bin/dx-status's SSH section both call now, instead of each building
# its own option array. `ssh` shadowed with a plain shell function,
# consistent with every other external-command fake in this file -- no
# real connection is ever attempted. Proves the probe's own stderr lands
# in the caller-supplied file (not swallowed, not printed to the probe's
# own stdout/stderr) and that ssh's exit status passes through unmodified.
(
    DX_SSH_KEY="$fixture/ssh-probe-key"; : > "$DX_SSH_KEY"
    DX_SSH_PORT=2222 DX_SSH_CONNECT_TIMEOUT=1
    export DX_SSH_KEY DX_SSH_PORT DX_SSH_CONNECT_TIMEOUT
    ssh() { echo "probe stderr line" >&2; return 0; }
    stderr_file="$fixture/probe-stderr"
    dx_ssh_probe_login_shell "$stderr_file" >/dev/null
    grep -qF "probe stderr line" "$stderr_file"
    ssh() { echo "probe failed" >&2; return 5; }
    rc=0; dx_ssh_probe_login_shell "$stderr_file" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 5 ]
    grep -qF "probe failed" "$stderr_file"
)

# Known-hosts pinning for docker-ssh (Branch 11 / Phase 5, item 8):
# dx_ssh_common_options's docker-ssh branch, and the three pin-directory
# helpers it calls (dx_ssh_known_hosts_dir/_path/_prepare), which nothing
# above exercises -- that whole block runs under DX_RUNTIME=apple.
# DXE_RUNTIME_DOCKER_DAEMON_ID is pre-seeded so dx_runtime_host_identity
# resolves without any real ssh round trip. HOME is isolated to a fixture
# below before dx_ssh_common_options ever runs; the snapshot, taken with
# this script's own ambient, unisolated HOME (this file never overrides
# HOME at top level), proves that isolation held rather than just trusting
# it -- this script requires the disposable coverage environment
# (DXE_COVERAGE_ISOLATED=1, checked above) but the check costs nothing and
# catches a regression here the same way it does in the unit-test files.
# An absent real state directory (the normal state in a fresh coverage
# container) is a legitimate empty snapshot, not an error -- `find` on a
# nonexistent path exits 1, which this script's own `set -Eeuo pipefail`
# would otherwise turn into an aborting ERR trap, so both snapshots below
# are guarded on the directory's existence rather than calling find blind.
known_hosts_coverage_real_dir="${XDG_STATE_HOME:-$HOME/.local/state}/dxe"
if [ -d "$known_hosts_coverage_real_dir" ]; then
    known_hosts_coverage_real_state_before="$(find "$known_hosts_coverage_real_dir" -mindepth 1 2>/dev/null | sort)"
else
    known_hosts_coverage_real_state_before=""
fi
(
    home_dir="$fixture/known-hosts-home"
    mkdir -p "$home_dir"
    HOME="$home_dir"
    unset XDG_STATE_HOME
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dxe-coverage
    DXE_RUNTIME_DOCKER_DAEMON_ID=coveragefixture
    DX_SSH_KEY="$fixture/ssh-common-key2"; : > "$DX_SSH_KEY"
    DX_SSH_PORT=2222 DX_SSH_CONNECT_TIMEOUT=1
    out="$(dx_ssh_common_options)"
    printf '%s\n' "$out" | stdin_matches -xF 'StrictHostKeyChecking=accept-new'
    printf '%s\n' "$out" | stdin_matches -F -- '/known_hosts'
    ! printf '%s\n' "$out" | stdin_matches -xF 'UserKnownHostsFile=/dev/null'
    [ -d "$(dx_ssh_known_hosts_dir)" ]
    [ "$(dx_path_mode "$(dx_ssh_known_hosts_dir)")" = 700 ]
)
if [ -d "$known_hosts_coverage_real_dir" ]; then
    known_hosts_coverage_real_state_after="$(find "$known_hosts_coverage_real_dir" -mindepth 1 2>/dev/null | sort)"
else
    known_hosts_coverage_real_state_after=""
fi
[ "$known_hosts_coverage_real_state_before" = "$known_hosts_coverage_real_state_after" ]

# dx_runtime_docker_destructive_plan_and_verify (Branch 11 / Phase 6, item
# 7): two branches nothing above reaches -- a CONTAINER-kind resource that
# does not exist (distinct from the volume-kind "does not exist" case
# tests/test_docker_runtime_adapter.sh, Section 33, already covers) and an
# unrecognised kind, which returns before any docker/ssh call is even
# attempted. DXE_RUNTIME_DOCKER_BIN is pre-seeded (same idiom the
# known-hosts block above uses via DXE_RUNTIME_DOCKER_DAEMON_ID) so
# dx_runtime_docker_require_bin resolves without any real ssh round trip;
# `ssh` is shadowed with a plain shell function for the one call the
# container-kind branch does make, consistent with every other
# external-command fake in this file -- no real connection is attempted.
(
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=qnap-dxe DX_CONTAINER_NAME=dxe-coverage
    DXE_RUNTIME_DOCKER_BIN=docker
    ssh() { case "$*" in *"container inspect"*) return 1 ;; *) return 0 ;; esac; }
    out="$(dx_runtime_docker_destructive_plan_and_verify container:dxe-coverage-missing:container 2>&1)"
    printf '%s\n' "$out" | stdin_matches -F -- 'does not exist'
    rc=0
    out2="$(dx_runtime_docker_destructive_plan_and_verify bogus:name:role 2>&1)" || rc=$?
    [ "$rc" -eq 1 ]
    printf '%s\n' "$out2" | stdin_matches -F -- 'unknown kind'
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
fake_block="$fixture/fake-block"
: > "$fake_block"

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
    # create_user's own trailing identity capture (Contract 5) calls
    # `id -u dx`/`id -g dx` again after the stubbed useradd "creates" dx, so
    # the stub must track that transition rather than fail every call: a
    # blanket `return 1` makes that capture's command substitutions fail
    # too, which is a bug in the probe, not in create_user.
    _dx_created=false
    id() {
        if { [ "$1" = -u ] || [ "$1" = -g ]; } && [ "$2" = dx ]; then
            [ "$_dx_created" = true ] || return 1
            printf '%s\n' 1000
            return 0
        fi
        return 1
    }
    groupadd() { :; }; useradd() { _dx_created=true; }; usermod() { :; }
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

# --- Branch 16: dx_keyring_probe/_clear_stale/_secrets_registered/
# _pids_matching/_start/_status (scripts/lib/dx-keyring.sh). Real dbus/
# gnome-keyring are never installed in this container, so dbus-daemon,
# dbus-send, and gnome-keyring-daemon are faked under fixture/keyring-fakebin
# (a bin/ subdirectory, matching dx_keyring_session_config's
# `${real%/bin/dbus-daemon}` prefix stripping) and prepended to PATH only for
# this block. `[ -S ... ]` still needs a REAL socket-typed filesystem entry
# (python3 -- available in this image for kcov's own build -- is the only
# portable way to create one without a real dbus-daemon; the live diagnosis
# in dx_keyring_probe's own comment already proved dbus-send's actual
# connect/reply behavior against the pinned dbus package in a real guest, so
# faking the client here only needs to reproduce its exit-code contract).
keyring_fixture="$fixture/keyring"
mkdir -p "$keyring_fixture/keyring-fakebin/bin" "$keyring_fixture/keyring-fakebin/share/dbus-1" "$keyring_fixture/nokeyringbin/bin"
: > "$keyring_fixture/keyring-fakebin/share/dbus-1/session.conf"
fake_log="$keyring_fixture/fake-invocations.log"
fake_dbus_daemon_fail="$keyring_fixture/.fake-dbus-daemon-fail"
fake_dbus_daemon_addr_file="$keyring_fixture/.fake-dbus-daemon-addr"
fake_dbus_send_fail="$keyring_fixture/.fake-dbus-send-fail"
fake_dbus_send_nosecrets="$keyring_fixture/.fake-dbus-send-nosecrets"
fake_socket="$keyring_fixture/fake.sock"
python3 - "$fake_socket" <<'PY'
import os, socket, sys
path = sys.argv[1]
if os.path.exists(path):
    os.remove(path)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.close()
PY
printf 'unix:path=%s,guid=deadbeefdeadbeefdeadbeefdeadbeef\n' "$fake_socket" > "$fake_dbus_daemon_addr_file"
# Captured once as a plain variable (not repeatedly re-`cat`, an external
# command) so the PATH=/dev/null probes below -- which deliberately break
# external-command resolution to test "the binary is nowhere on PATH" --
# don't also break reading this fixture's own address.
fake_address="$(cat "$fake_dbus_daemon_addr_file")"

cat > "$keyring_fixture/keyring-fakebin/bin/dbus-daemon" <<FAKE
#!/bin/sh
printf '%s\n' "dbus-daemon \$*" >> "$fake_log"
[ ! -f "$fake_dbus_daemon_fail" ] || exit 1
cat "$fake_dbus_daemon_addr_file"
FAKE
cat > "$keyring_fixture/keyring-fakebin/bin/gnome-keyring-daemon" <<FAKE
#!/bin/sh
printf '%s\n' "gnome-keyring-daemon \$*" >> "$fake_log"
exit 0
FAKE
cat > "$keyring_fixture/keyring-fakebin/bin/dbus-send" <<FAKE
#!/bin/sh
printf '%s\n' "dbus-send \$*" >> "$fake_log"
[ ! -f "$fake_dbus_send_fail" ] || exit 1
if [ -f "$fake_dbus_send_nosecrets" ]; then
    printf '   array [\n      string "org.freedesktop.DBus"\n   ]\n'
else
    printf '   array [\n      string "org.freedesktop.DBus"\n      string "org.freedesktop.secrets"\n   ]\n'
fi
FAKE
chmod +x "$keyring_fixture/keyring-fakebin/bin/dbus-daemon" "$keyring_fixture/keyring-fakebin/bin/gnome-keyring-daemon" "$keyring_fixture/keyring-fakebin/bin/dbus-send"
# A second fakebin with dbus-daemon/dbus-send but no gnome-keyring-daemon, for
# the "secrets binary unresolvable, bus still starts" branch.
cp "$keyring_fixture/keyring-fakebin/bin/dbus-daemon" "$keyring_fixture/nokeyringbin/bin/dbus-daemon"
cp "$keyring_fixture/keyring-fakebin/bin/dbus-send" "$keyring_fixture/nokeyringbin/bin/dbus-send"
chmod +x "$keyring_fixture/nokeyringbin/bin/dbus-daemon" "$keyring_fixture/nokeyringbin/bin/dbus-send"
mkdir -p "$keyring_fixture/nokeyringbin/share/dbus-1"
: > "$keyring_fixture/nokeyringbin/share/dbus-1/session.conf"

# dx_keyring_socket_from_address/_address_valid/_address_is_live already have
# dedicated probes above; exercise the new real-liveness primitives directly.
dx_keyring_probe not-an-address >/dev/null 2>&1 || true
dx_keyring_probe "unix:path=$keyring_fixture/no-such-socket" >/dev/null 2>&1 || true
(
    PATH="$keyring_fixture/keyring-fakebin/bin:$PATH"
    rm -f "$fake_dbus_send_fail"
    dx_keyring_probe "$fake_address" >/dev/null 2>&1
)
(
    PATH="$keyring_fixture/keyring-fakebin/bin:$PATH"
    : > "$fake_dbus_send_fail"
    dx_keyring_probe "$fake_address" >/dev/null 2>&1 || true
    rm -f "$fake_dbus_send_fail"
)
(
    # dbus-send entirely unresolvable: deliberately break command lookup,
    # a subshell-scoped probe of dx_keyring_probe's own fail-closed path.
    # shellcheck disable=SC2123
    PATH=/dev/null
    dx_keyring_probe "$fake_address" >/dev/null 2>&1 || true
)

(
    PATH="$keyring_fixture/keyring-fakebin/bin:$PATH"
    dx_keyring_secrets_registered "$fake_address" >/dev/null 2>&1
    : > "$fake_dbus_send_nosecrets"
    dx_keyring_secrets_registered "$fake_address" >/dev/null 2>&1 || true
    rm -f "$fake_dbus_send_nosecrets"
    : > "$fake_dbus_send_fail"
    dx_keyring_secrets_registered "$fake_address" >/dev/null 2>&1 || true
    rm -f "$fake_dbus_send_fail"
    # dbus-send entirely unresolvable, subshell-scoped.
    # shellcheck disable=SC2123
    PATH=/dev/null
    dx_keyring_secrets_registered "$fake_address" >/dev/null 2>&1 || true
)

# dx_keyring_clear_stale: absent (no-op), live (no-op, files survive), stale
# (removes both the address file and the socket it names).
clear_stale_address_file="$keyring_fixture/clear-stale-address"
dx_keyring_clear_stale "$clear_stale_address_file" >/dev/null 2>&1
(
    PATH="$keyring_fixture/keyring-fakebin/bin:$PATH"
    rm -f "$fake_dbus_send_fail"
    dx_keyring_write_address "$clear_stale_address_file" "$fake_address"
    dx_keyring_clear_stale "$clear_stale_address_file"
)
if [ -f "$clear_stale_address_file" ]; then :; else echo "Error: dx_keyring_clear_stale removed a live address file." >&2; exit 1; fi
(
    PATH="$keyring_fixture/keyring-fakebin/bin:$PATH"
    : > "$fake_dbus_send_fail"
    dx_keyring_clear_stale "$clear_stale_address_file"
    rm -f "$fake_dbus_send_fail"
)
if [ ! -f "$clear_stale_address_file" ]; then :; else echo "Error: dx_keyring_clear_stale kept a stale address file." >&2; exit 1; fi
if [ ! -S "$fake_socket" ]; then :; else echo "Error: dx_keyring_clear_stale kept a stale socket." >&2; exit 1; fi
# Recreate the fake socket for the dx_keyring_start probes below.
python3 - "$fake_socket" <<'PY'
import os, socket, sys
path = sys.argv[1]
if os.path.exists(path):
    os.remove(path)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.close()
PY

# dx_keyring_pids_matching: a real match (this shell's own dummy background
# marker process) and the ordinary no-match sweep over the rest of /proc.
bash -c 'exec -a dxe-coverage-keyring-marker sleep 60' &
marker_pid=$!
sleep 1
matched_pids="$(dx_keyring_pids_matching dxe-coverage-keyring-marker)"
kill "$marker_pid" 2>/dev/null || true
wait "$marker_pid" 2>/dev/null || true
case "$matched_pids" in
    *"$marker_pid"*) ;;
    *) echo "Error: dx_keyring_pids_matching did not find its own marker process." >&2; exit 1 ;;
esac
dx_keyring_pids_matching dxe-coverage-keyring-pattern-that-matches-nothing >/dev/null

# dx_keyring_start: fresh start (no address recorded), idempotent second call
# (no new invocations of either fake daemon), stale recovery (a third call
# after the recorded bus goes dead), dbus-daemon wholly unresolvable
# (fail-closed), an invalid bus address from dbus-daemon, and
# gnome-keyring-daemon unresolvable while dbus-daemon still starts.
start_address_file="$keyring_fixture/start-address"
rm -f "$fake_log"
(
    PATH="$keyring_fixture/keyring-fakebin/bin:$PATH"
    rm -f "$fake_dbus_send_fail"; : > "$fake_dbus_send_nosecrets"
    dx_keyring_start "$start_address_file" >/dev/null 2>&1
)
first_dbus_calls="$(grep -c '^dbus-daemon ' "$fake_log" 2>/dev/null || true)"
first_keyring_calls="$(grep -c '^gnome-keyring-daemon ' "$fake_log" 2>/dev/null || true)"
if [ "${first_dbus_calls:-0}" -eq 1 ]; then :; else echo "Error: dx_keyring_start's fresh start did not invoke dbus-daemon exactly once (got ${first_dbus_calls:-0})." >&2; exit 1; fi
if [ "${first_keyring_calls:-0}" -eq 1 ]; then :; else echo "Error: dx_keyring_start's fresh start did not invoke gnome-keyring-daemon exactly once (got ${first_keyring_calls:-0})." >&2; exit 1; fi
(
    PATH="$keyring_fixture/keyring-fakebin/bin:$PATH"
    rm -f "$fake_dbus_send_fail" "$fake_dbus_send_nosecrets"
    dx_keyring_start "$start_address_file" >/dev/null 2>&1
)
second_dbus_calls="$(grep -c '^dbus-daemon ' "$fake_log" 2>/dev/null || true)"
second_keyring_calls="$(grep -c '^gnome-keyring-daemon ' "$fake_log" 2>/dev/null || true)"
if [ "$second_dbus_calls" -eq "$first_dbus_calls" ]; then :; else echo "Error: dx_keyring_start's idempotent second call started a new dbus-daemon." >&2; exit 1; fi
if [ "$second_keyring_calls" -eq "$first_keyring_calls" ]; then :; else echo "Error: dx_keyring_start's idempotent second call started a new gnome-keyring-daemon." >&2; exit 1; fi
(
    PATH="$keyring_fixture/keyring-fakebin/bin:$PATH"
    : > "$fake_dbus_send_fail"; : > "$fake_dbus_send_nosecrets"
    dx_keyring_start "$start_address_file" >/dev/null 2>&1
    rm -f "$fake_dbus_send_fail" "$fake_dbus_send_nosecrets"
)
third_dbus_calls="$(grep -c '^dbus-daemon ' "$fake_log" 2>/dev/null || true)"
third_keyring_calls="$(grep -c '^gnome-keyring-daemon ' "$fake_log" 2>/dev/null || true)"
if [ "$third_dbus_calls" -eq 2 ]; then :; else echo "Error: dx_keyring_start's stale recovery did not start exactly one new dbus-daemon (total ${third_dbus_calls})." >&2; exit 1; fi
if [ "$third_keyring_calls" -eq 2 ]; then :; else echo "Error: dx_keyring_start's stale recovery did not start exactly one new gnome-keyring-daemon (total ${third_keyring_calls})." >&2; exit 1; fi
rm -f "$keyring_fixture/unresolvable-address"
(
    # rm runs before PATH is broken: it is an external command too, and this
    # subshell's whole point is to make dbus-daemon (and everything else)
    # unresolvable.
    # shellcheck disable=SC2123
    PATH=/dev/null
    dx_keyring_start "$keyring_fixture/unresolvable-address" >/dev/null 2>&1 || true
)
if [ ! -f "$keyring_fixture/unresolvable-address" ]; then :; else echo "Error: dx_keyring_start recorded an address despite dbus-daemon being unresolvable." >&2; exit 1; fi
(
    PATH="$keyring_fixture/keyring-fakebin/bin:$PATH"
    printf 'not-a-valid-address\n' > "$fake_dbus_daemon_addr_file"
    rm -f "$keyring_fixture/invalid-address"
    dx_keyring_start "$keyring_fixture/invalid-address" >/dev/null 2>&1 || true
    printf 'unix:path=%s,guid=deadbeefdeadbeefdeadbeefdeadbeef\n' "$fake_socket" > "$fake_dbus_daemon_addr_file"
)
if [ ! -f "$keyring_fixture/invalid-address" ]; then :; else echo "Error: dx_keyring_start recorded an invalid bus address." >&2; exit 1; fi
(
    PATH="$keyring_fixture/keyring-fakebin/bin:$PATH"
    : > "$fake_dbus_daemon_fail"
    rm -f "$keyring_fixture/daemon-fail-address"
    dx_keyring_start "$keyring_fixture/daemon-fail-address" >/dev/null 2>&1 || true
    rm -f "$fake_dbus_daemon_fail"
)
if [ ! -f "$keyring_fixture/daemon-fail-address" ]; then :; else echo "Error: dx_keyring_start recorded an address despite dbus-daemon itself failing." >&2; exit 1; fi
(
    PATH="$keyring_fixture/nokeyringbin/bin:$PATH"
    : > "$fake_dbus_send_nosecrets"
    rm -f "$keyring_fixture/nokeyring-address"
    dx_keyring_start "$keyring_fixture/nokeyring-address" >/dev/null 2>&1 || true
    rm -f "$fake_dbus_send_nosecrets"
)
if [ -f "$keyring_fixture/nokeyring-address" ]; then :; else echo "Error: dx_keyring_start did not persist the bus address when gnome-keyring-daemon was unresolvable." >&2; exit 1; fi

# The stale-recovery dx_keyring_start call above (fake_dbus_send_fail set)
# went through dx_keyring_clear_stale internally, which removed fake_socket
# for real -- recreate it so the "live" status probe below has a genuine
# socket-typed file to find again.
python3 - "$fake_socket" <<'PY'
import os, socket, sys
path = sys.argv[1]
if os.path.exists(path):
    os.remove(path)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.close()
PY

# dx_keyring_status: absent (no file), absent (unparseable content), live,
# and stale.
dx_keyring_status "$keyring_fixture/status-absent" >/dev/null
printf 'unix:path=/tmp/x\n\nextra\n' > "$keyring_fixture/status-garbled"
dx_keyring_status "$keyring_fixture/status-garbled" >/dev/null
(
    PATH="$keyring_fixture/keyring-fakebin/bin:$PATH"
    rm -f "$fake_dbus_send_fail"
    dx_keyring_write_address "$keyring_fixture/status-live" "$fake_address"
    dx_keyring_status "$keyring_fixture/status-live" >/dev/null
)
(
    PATH="$keyring_fixture/keyring-fakebin/bin:$PATH"
    : > "$fake_dbus_send_fail"
    dx_keyring_write_address "$keyring_fixture/status-stale" "$fake_address"
    dx_keyring_status "$keyring_fixture/status-stale" >/dev/null
    rm -f "$fake_dbus_send_fail"
)
rm -f "$fake_log" "$fake_dbus_send_fail" "$fake_dbus_send_nosecrets" "$fake_dbus_daemon_fail"
rm -f "$fake_socket"

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

# OpenCode persistence exercises both the dx-ai and activation ownership
# boundaries: normal migration, idempotent repeat, conflict preservation,
# symlinked-ancestor refusal, non-directory-component refusal, and a
# partial-failure leaving no dangling symlink.
opencode_fixture="$fixture/opencode-persistence"
mkdir -p "$opencode_fixture/persist/home/dx" "$opencode_fixture/home/dx"
chmod 0755 "$fixture" "$opencode_fixture" "$opencode_fixture/persist" "$opencode_fixture/persist/home" "$opencode_fixture/persist/home/dx" "$opencode_fixture/home" "$opencode_fixture/home/dx"
mkdir -p "$opencode_fixture/persist/home/dx/.config" "$opencode_fixture/persist/home/dx/.local/share"
dx_ai_opencode_prepare_activation_ancestors "$opencode_fixture/persist/home/dx"
if id -u dx >/dev/null 2>&1 && id -g dx >/dev/null 2>&1; then
    [ "$(stat -c '%U:%G' "$opencode_fixture/persist/home/dx/.config")" = dx:dx ]
    [ "$(stat -c '%U:%G' "$opencode_fixture/persist/home/dx/.local")" = dx:dx ]
    [ "$(stat -c '%U:%G' "$opencode_fixture/persist/home/dx/.local/share")" = dx:dx ]
fi
# Normal migration: pre-existing real content in both live paths, nothing yet
# under persist.
mkdir -p "$opencode_fixture/home/dx/.config/opencode" "$opencode_fixture/home/dx/.local/share/opencode"
printf '%s\n' live-config > "$opencode_fixture/home/dx/.config/opencode/config.json"
printf '%s\n' live-data > "$opencode_fixture/home/dx/.local/share/opencode/session.db"
dx_ai_opencode_persistence "$opencode_fixture/persist/home/dx" "$opencode_fixture/home/dx"
[ "$(stat -c '%a' "$opencode_fixture/persist/home/dx/.config/opencode")" = 700 ]
[ "$(cat "$opencode_fixture/persist/home/dx/.config/opencode/config.json")" = live-config ]
[ "$(cat "$opencode_fixture/persist/home/dx/.local/share/opencode/session.db")" = live-data ]
[ -L "$opencode_fixture/home/dx/.config/opencode" ]
[ -L "$opencode_fixture/home/dx/.local/share/opencode" ]
if id -u dx >/dev/null 2>&1 && id -g dx >/dev/null 2>&1; then
    [ "$(stat -c '%U:%G' "$opencode_fixture/persist/home/dx/.config/opencode")" = dx:dx ]
    run_as_dx "touch '$opencode_fixture/home/dx/.config/opencode/dx-write'"
else
    touch "$opencode_fixture/home/dx/.config/opencode/dx-write"
fi
[ -f "$opencode_fixture/persist/home/dx/.config/opencode/dx-write" ]
if id -u dx >/dev/null 2>&1 && id -g dx >/dev/null 2>&1; then
    run_as_dx "touch '$opencode_fixture/home/dx/.local/share/opencode/dx-write'"
else
    touch "$opencode_fixture/home/dx/.local/share/opencode/dx-write"
fi
[ -f "$opencode_fixture/persist/home/dx/.local/share/opencode/dx-write" ]
# Idempotent repeat: already-migrated (both live paths are already the
# correct symlinks) leaves everything unchanged.
before_config_link="$(readlink "$opencode_fixture/home/dx/.config/opencode")"
before_data_link="$(readlink "$opencode_fixture/home/dx/.local/share/opencode")"
dx_ai_opencode_persistence "$opencode_fixture/persist/home/dx" "$opencode_fixture/home/dx"
[ "$(readlink "$opencode_fixture/home/dx/.config/opencode")" = "$before_config_link" ]
[ "$(readlink "$opencode_fixture/home/dx/.local/share/opencode")" = "$before_data_link" ]
[ "$(cat "$opencode_fixture/persist/home/dx/.config/opencode/config.json")" = live-config ]

dx_opencode_validate_directory_path relative relative >/dev/null 2>&1 || true
dx_opencode_validate_directory_path "$opencode_fixture/../not-normal" normalized >/dev/null 2>&1 || true
printf '%s\n' file > "$opencode_fixture/non-directory"
dx_opencode_validate_directory_path "$opencode_fixture/non-directory/child" non-directory >/dev/null 2>&1 || true

# Symlinked ancestor refused: a symlinked persist root must never be
# traversed, migrated through, or have its ownership repaired.
symlinked_ancestor_fixture="$fixture/opencode-symlinked-ancestor"
mkdir -p "$symlinked_ancestor_fixture/outside" "$symlinked_ancestor_fixture/home/dx/.config" "$symlinked_ancestor_fixture/home/dx/.local/share"
ln -s "$symlinked_ancestor_fixture/outside" "$symlinked_ancestor_fixture/persist"
if dx_ai_opencode_persistence "$symlinked_ancestor_fixture/persist/home/dx" "$symlinked_ancestor_fixture/home/dx" >/dev/null 2>&1; then
    echo "Error: dx_ai_opencode_persistence traversed a symlinked persist ancestor" >&2
    exit 1
fi
[ ! -e "$symlinked_ancestor_fixture/outside/home" ]
if dx_ai_opencode_prepare_activation_ancestors "$symlinked_ancestor_fixture/persist/home/dx" >/dev/null 2>&1; then
    echo "Error: dx_ai_opencode_prepare_activation_ancestors traversed a symlinked persist ancestor" >&2
    exit 1
fi
[ ! -e "$symlinked_ancestor_fixture/outside/home" ]

# Non-directory component refused: a persisted path that is a plain file
# rather than a directory must never be traversed into.
non_directory_fixture="$fixture/opencode-non-directory"
mkdir -p "$non_directory_fixture/persist/home/dx" "$non_directory_fixture/home/dx/.config" "$non_directory_fixture/home/dx/.local/share"
printf '%s\n' file > "$non_directory_fixture/persist/home/dx/.config"
if dx_ai_opencode_persistence "$non_directory_fixture/persist/home/dx" "$non_directory_fixture/home/dx" >/dev/null 2>&1; then
    echo "Error: dx_ai_opencode_persistence traversed a non-directory persist component" >&2
    exit 1
fi
[ -f "$non_directory_fixture/persist/home/dx/.config" ]
[ ! -L "$non_directory_fixture/home/dx/.config/opencode" ]

wrong_link_fixture="$fixture/opencode-wrong-link"
mkdir -p "$wrong_link_fixture/persist/home/dx" "$wrong_link_fixture/home/dx/.config" "$wrong_link_fixture/home/dx/.local/share" "$wrong_link_fixture/outside"
ln -s "$wrong_link_fixture/outside" "$wrong_link_fixture/home/dx/.config/opencode"
dx_ai_opencode_persistence "$wrong_link_fixture/persist/home/dx" "$wrong_link_fixture/home/dx" >/dev/null 2>&1 || true

# Conflicting content: both the live path and the persistent target already
# have a same-named file. Neither is discarded; the live copy is kept
# alongside as a `.dxe-conflict-…` file.
regular_live_fixture="$fixture/opencode-regular-live"
mkdir -p "$regular_live_fixture/persist/home/dx/.config/opencode" "$regular_live_fixture/home/dx/.config" "$regular_live_fixture/home/dx/.local/share"
printf '%s\n' persisted > "$regular_live_fixture/persist/home/dx/.config/opencode/config.json"
mkdir -p "$regular_live_fixture/home/dx/.config/opencode"
printf '%s\n' live-conflict > "$regular_live_fixture/home/dx/.config/opencode/config.json"
dx_ai_opencode_persistence "$regular_live_fixture/persist/home/dx" "$regular_live_fixture/home/dx"
[ "$(cat "$regular_live_fixture/persist/home/dx/.config/opencode/config.json")" = persisted ]
live_conflict_backup=""
for conflict_backup in "$regular_live_fixture/persist/home/dx/.config/opencode"/.dxe-conflict-config.json.*; do
    [ -f "$conflict_backup" ] || continue
    [ "$(cat "$conflict_backup")" = live-conflict ] && live_conflict_backup="$conflict_backup"
done
[ -n "$live_conflict_backup" ]

# A live path that is itself a plain file (not a directory) is preserved
# wholesale as a `.dxe-conflict-live-opencode.…` backup rather than merged
# item by item.
live_file_fixture="$fixture/opencode-live-file"
mkdir -p "$live_file_fixture/persist/home/dx" "$live_file_fixture/home/dx/.config" "$live_file_fixture/home/dx/.local/share"
printf '%s\n' preserved > "$live_file_fixture/home/dx/.config/opencode"
dx_ai_opencode_persistence "$live_file_fixture/persist/home/dx" "$live_file_fixture/home/dx"
grep -q preserved "$live_file_fixture/persist/home/dx/.config/opencode"/.dxe-conflict-live-opencode.*
[ -L "$live_file_fixture/home/dx/.config/opencode" ]

# dx_opencode_unused_path must keep searching past an already-taken
# candidate rather than reuse it.
unused_path_fixture="$fixture/opencode-unused-path"
mkdir -p "$unused_path_fixture"
: > "$unused_path_fixture/marker.$$"
if [ "$(dx_opencode_unused_path "$unused_path_fixture/marker")" != "$unused_path_fixture/marker.$$.1" ]; then
    echo "Error: dx_opencode_unused_path did not skip past an already-taken candidate" >&2
    exit 1
fi

# Partial-failure leaves no dangling symlink: a failed rename of the
# temporary link must never leave a stray `.dxe-link.*` behind.
publish_failure="$fixture/opencode-publish-failure"
mkdir -p "$publish_failure"
[ "$(mv() { return 1; }; dx_opencode_publish_link "$publish_failure/target" "$publish_failure/live" >/dev/null 2>&1 || true; find "$publish_failure" -name '*.dxe-link.*' -print -quit)" = "" ]
[ ! -e "$publish_failure/live" ]
dx_opencode_validate_directory_path "$opencode_fixture" valid-directory
dx_opencode_validate_directory_path /tmp root-directory
dx_opencode_prepare_directory "$opencode_fixture/persist/home/dx/.config" 0700
( unset -f dx_prepare_owned_directory; dx_ai_opencode_prepare_activation_ancestors "$opencode_fixture/persist/home/dx" >/dev/null 2>&1 || true )
( unset -f dx_prepare_owned_directory; dx_opencode_prepare_directory "$fixture/opencode-no-helper" 0755; [ -d "$fixture/opencode-no-helper" ] )

rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.local/state/dx-ai/current/profile/bin /home/dx/.nix-profile/bin
: > /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex; chmod +x /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex
: > /home/dx/.nix-profile/bin/nu
(
    ensure_nix_ownership() { :; }; chown() { :; }; run_as_dx() { :; }
    setup_gh_persistence() { :; }; setup_tmux_persistence() { :; }; dx_activate_herdr() { :; }
    run_home_manager_activation() { :; }; usermod() { :; }; grep() { return 1; }
    configure_guest
)

# Branch 16: configure_guest no longer calls any keyring function at all
# (with the AI-tools guard true or false) -- the two probes this used to
# need (an "ai_tools_enabled=false must never call setup_keyring_service"
# guard, and a dedicated recreate-time-resolution/ordering regression test
# run as a separate bash process) no longer apply to anything configure_guest
# itself does. See tests/test_sourceable_coverage.sh's own dx_keyring_start/
# dx_keyring_status probes above, and tests/test_section17_dx_ai_runtime.sh's
# live dx-keyring checks, for the equivalent behavioral coverage now that
# ownership moved to dx-ai/dx-keyring.
#
# The removed test also incidentally exercised configure_guest's *unrelated*
# OpenCode-persistence-library fallback load (source
# "$opencode_persistence_library", the branch taken only when
# dx_ai_opencode_persistence was not already sourced by the caller) --
# nothing else in this file unsets that function before calling
# configure_guest, so losing that whole block silently dropped its coverage
# too. Keep it covered directly, with a real (not missing) bootstrap root so
# this exercises the successful source, not the fail-closed error message
# the very next probe below already covers.
rm -rf /persist/home/dx /home/dx; mkdir -p /persist/home/dx/.local/state/dx-ai/current/profile/bin /home/dx/.nix-profile/bin
: > /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex; chmod +x /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex
: > /home/dx/.nix-profile/bin/nu
(
    unset -f dx_ai_opencode_persistence dx_ai_opencode_prepare_activation_ancestors
    ensure_nix_ownership() { :; }; chown() { :; }; run_as_dx() { :; }
    setup_gh_persistence() { :; }; setup_tmux_persistence() { :; }; dx_activate_herdr() { :; }
    run_home_manager_activation() { :; }; usermod() { :; }; grep() { return 1; }
    DX_BOOTSTRAP_ROOT="$GUEST" configure_guest
)
rm -rf /persist/home/dx /home/dx

# Exercise configure_guest's fail-closed fallback when the helper was not
# preloaded and the configured bootstrap root does not contain it. Needs its
# own ai_tools_opted_in fixture (the preceding probe cleans up
# /persist/home/dx afterward, and this one stubs run_as_dx to a silent
# no-op, so ai_tools_opted_in's own fallback -- `run_as_dx "nix profile
# list" | grep ...` -- would otherwise never see the AI-tools guard as true
# and this whole branch would go unreached).
mkdir -p /persist/home/dx/.local/state/dx-ai/current/profile/bin
: > /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex
chmod +x /persist/home/dx/.local/state/dx-ai/current/profile/bin/codex
(
    unset -f dx_ai_opencode_persistence dx_ai_opencode_prepare_activation_ancestors
    ensure_nix_ownership() { :; }; chown() { :; }; run_as_dx() { :; }
    setup_gh_persistence() { :; }; setup_tmux_persistence() { :; }; dx_activate_herdr() { :; }
    run_home_manager_activation() { :; }; usermod() { :; }; grep() { return 1; }
    DX_BOOTSTRAP_ROOT="$fixture/missing-bootstrap" configure_guest >/dev/null 2>&1 || true
)
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
    # Contract 1 (refactor-v2-final.md, Fable B6 item 4): the image identity
    # is a required fourth positional argument now, never
    # DX_NIX_PENDING_IMAGE_STORE_IDENTITY.
    identity_valid=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    nix_install_image_essentials_root "$root" 1000 1000 bad >/dev/null 2>&1 || true
    nix_image_bootstrap_store_paths() { printf '%s\n' /nix/store/root; }
    ln() { return 1; }
    nix_install_image_essentials_root "$root" 1000 1000 "$identity_valid" >/dev/null 2>&1 || true
    unset -f ln
    nix_install_image_essentials_root "$root" 1000 1000 "$identity_valid"

    # A failed root enumeration must remove the private stage before returning
    # so a later bootstrap cannot mistake it for a published root set.
    rm -rf "$root/var/nix/gcroots"/dx-image-roots-*
    nix_image_bootstrap_store_paths() { return 1; }
    nix_install_image_essentials_root "$root" 1000 1000 "$identity_valid" >/dev/null 2>&1 || true

    seed="$root/seed"; target="$root/target"
    mkdir -p "$seed/store/a" "$target"
    printf x > "$seed/store/a/file"
    mv() { case "$1" in *'/contents/'*) return 1;; *) command mv "$@";; esac; }
    nix_seed_volume "$seed" "$target" 1000 1000 >/dev/null 2>&1 || true
    unset -f mv

    mkdir -p "$root/unsafe-persist"
    chown 0:0 "$root/unsafe-persist"
    DX_PERSIST_HOME="$root/unsafe-persist" record_durable_nix_identity "$root" >/dev/null

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
    # Contract 1: identity/publication-decision threading now goes through
    # dx_write_pending_image_identity's own non-sourced pending record, never
    # DX_NIX_PENDING_IMAGE_STORE_IDENTITY. A verified-match skip (this
    # fixture's marker content already agrees with the stubbed identity)
    # writes no pending record at all -- exercised for real here -- so the
    # publish path below is exercised separately, by writing one directly.
    nix_image_store_import_required /nix "$root/gate" >/dev/null 2>&1 || true
    chown() { :; }
    dx_write_pending_image_identity "$root/gate" cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    publish_nix_image_store_identity "$root/gate"

    # A directory at the image identity marker is not an absent marker: the
    # gate must retain the computed identity for a retry rather than silently
    # treating the directory as a valid publication -- now via the pending
    # record file, surfaced to the caller as this function's own stdout.
    mkdir -p "$root/gate-directory/.dx-image-store-identity"
    gate_directory_identity="$(nix_image_store_import_required /nix "$root/gate-directory")"
    [ "$gate_directory_identity" = identity ]
    [ "$(cat "$root/gate-directory/.dx-image-store-identity.pending" 2>/dev/null)" = identity ]

    # Exercise the portable sourceable fallback used on Darwin. It still
    # replaces a validated marker atomically and leaves no temporary file.
    fallback_marker="$root/fallback-marker"
    fallback_temporary="$root/fallback-marker.tmp"
    printf '%s\n' fallback > "$fallback_temporary"
    uname() { printf '%s\n' Darwin; }
    dx_publish_atomic_marker "$fallback_temporary" "$fallback_marker" "coverage fallback marker"
    unset -f uname
    [ -f "$fallback_marker" ] && [ "$(cat "$fallback_marker")" = fallback ] && [ ! -e "$fallback_temporary" ]

    # Contract 3 (refactor-v2-final.md, Fable B6 item 3): the mode-tagged
    # Nix-volume record replaces DX_NIX_VOLUME_ALREADY_MOUNTED/ROOT.
    DX_BOOTSTRAP_SCRATCH_DIR="$root/scratch" dx_write_nix_volume_record already-mounted "$root"
    DX_BOOTSTRAP_SCRATCH_DIR="$root/scratch" populate_prepared_nix_volume 0 0

    # Branch 11 / Phase 3: publish_nix_volume_image_identity's chown/
    # publish failure branch (never reached by the Section 3 happy-path
    # test, which stubs chown to succeed).
    unset -f chown
    marker_fail_root="$root/image-identity-fail"
    mkdir -p "$marker_fail_root"
    chown() { return 1; }
    publish_nix_volume_image_identity "$marker_fail_root" "sha256:coverage-probe" >/dev/null 2>&1 || true
    unset -f chown
)
(
    # Exercise every refusal branch of the retained image-default profile
    # helper against a disposable tree.  The Linux behavior test proves the
    # successful GC/recovery flow; these probes keep its defensive boundaries
    # observable without ever touching a mounted guest Nix store.
    root="$fixture/default-profile-branches"
    export DX_BOOTSTRAP_SCRATCH_DIR="$root/scratch"
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

    # Contract 2 (refactor-v2-final.md): the retained target is now bridged
    # via dx_persist_image_default_profile_target, never the exported
    # DX_NIX_IMAGE_DEFAULT_PROFILE_TARGET.
    rm -f "$DX_BOOTSTRAP_SCRATCH_DIR/image-default-profile-target"
    ! DX_NIX_ROOT="$root" nix_restore_image_default_profile >/dev/null 2>&1 || exit 1
    ln -s unavailable "$root/store/unavailable"
    dx_persist_image_default_profile_target "$root/store/unavailable"
    ! DX_NIX_ROOT="$root" nix_restore_image_default_profile >/dev/null 2>&1 || exit 1
    dx_persist_image_default_profile_target /tmp
    ! DX_NIX_ROOT="$root" nix_restore_image_default_profile >/dev/null 2>&1 || exit 1
    dx_persist_image_default_profile_target "$target"
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
    # create_user's own trailing identity capture (Contract 5) calls
    # `id -u dx`/`id -g dx` again after the stubbed useradd "creates" dx, so
    # the stub must track that transition rather than fail every `-u dx`
    # call: a blanket failure makes that capture's command substitutions
    # fail too, which is a bug in the probe, not in create_user.
    _dx_created=false
    id() {
        if { [ "$1" = -u ] || [ "$1" = -g ]; } && [ "$2" = dx ]; then
            [ "$_dx_created" = true ] || return 1
            printf '%s\n' 42420
            return 0
        fi
        builtin id "$@"
    }
    groupadd() { :; }; useradd() { _dx_created=true; }; usermod() { :; }
    # Contract 5 (refactor-v2-final.md, Fable B6 item 5): the durable
    # identity candidate is now a positional record, never
    # DX_NIX_DURABLE_UID/DX_NIX_DURABLE_GID.
    DX_AUTH_ROOT="$auth_root" create_user "$(printf 'identity=42420:42420\nmigrate=false')" >/dev/null
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

    # Contract 3 (refactor-v2-final.md, Fable B6 item 3): the mode-tagged
    # Nix-volume record replaces the DX_NIX_VOLUME_* globals.
    export DX_BOOTSTRAP_SCRATCH_DIR="$root/scratch"
    dx_write_nix_volume_record prepared "$root" fake fake none
    migrate_durable_nix_identity_if_needed() { :; }
    nix_image_store_import_required() { return 1; }
    nix_install_image_essentials_root() { :; }
    umount() { :; }; mount() { :; }; grep() { return 0; }
    populate_prepared_nix_volume 0 0
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

(
    # Host-key persistence trust boundary, exercised with real filesystem
    # ownership. /persist is handed to dx, so the store holding host *private*
    # keys is trusted only while it is genuinely root-owned. Stubbing stat and
    # chown here would defeat the probe: a wrong real uid is exactly the defect
    # it guards against.
    hk="$fixture/hostkeys"
    mkdir -p "$hk/persist/etc" "$hk/etc/ssh"

    install -d -o root -g root -m 0700 "$hk/persist/etc/ssh"
    printf 'persisted-private\n' > "$hk/persist/etc/ssh/ssh_host_ed25519_key"
    printf 'persisted-public\n' > "$hk/persist/etc/ssh/ssh_host_ed25519_key.pub"
    generate_host_keys() { echo "unexpected host-key generation" >&2; return 1; }
    dx_persist_host_keys "$hk/etc/ssh" "$hk/persist/etc/ssh"
    [ "$(cat "$hk/etc/ssh/ssh_host_ed25519_key")" = persisted-private ]
    [ "$(stat -c '%a' "$hk/etc/ssh/ssh_host_ed25519_key")" = 600 ]
    [ "$(stat -c '%a' "$hk/etc/ssh/ssh_host_ed25519_key.pub")" = 644 ]

    # The same store owned by an unprivileged uid is refused: the guest
    # regenerates rather than adopting an identity dx could have planted, and
    # the fresh private key is not written into a dx-readable directory.
    rm -rf "$hk/etc/ssh"
    mkdir -p "$hk/etc/ssh"
    chown 1000:1000 "$hk/persist/etc/ssh"
    generate_host_keys() { printf 'regenerated\n' > "$hk/etc/ssh/ssh_host_ed25519_key"; }
    dx_persist_host_keys "$hk/etc/ssh" "$hk/persist/etc/ssh"
    [ "$(cat "$hk/etc/ssh/ssh_host_ed25519_key")" = regenerated ]
    [ "$(cat "$hk/persist/etc/ssh/ssh_host_ed25519_key")" = persisted-private ]
) 2>/dev/null
echo "Isolated sourceable coverage probes passed."
