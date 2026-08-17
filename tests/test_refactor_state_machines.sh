#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"
source "$BASE_DIR/bin/lib/dx-mount-plan.sh"
source "$BASE_DIR/bin/lib/dx-tunnel.sh"
test_section "Refactor State-Machine Contracts"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-refactor-state.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

expect_ok() { local label="$1"; shift; if "$@"; then test_pass "$label"; else test_fail "$label"; fi; }
expect_reject() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then test_fail "$label"; else test_pass "$label"; fi; }

# D2 data grammar, precedence, origins, and complete snapshot validation.
config_root="$fixture/config"
mkdir -p "$config_root"
printf '%s\n' 'DX_CONTAINER_NAME=root-name' 'DX_IMAGE=root-image' > "$config_root/.env"
(
    for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
    unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION
    DX_IMAGE=environment-image
    dx_init_config "$config_root"
    [ "$DX_CONTAINER_NAME:$DXE_CONFIG_ORIGIN_DX_CONTAINER_NAME" = root-name:root:.env ]
    [ "$DX_IMAGE:$DXE_CONFIG_ORIGIN_DX_IMAGE" = environment-image:environment ]
    [ "$DX_SSH_PORT:$DXE_CONFIG_ORIGIN_DX_SSH_PORT" = 2222:default ]
    dx_validate_config_snapshot "$config_root"
) && test_pass "config precedence records root, environment, and default origins" || test_fail "config precedence records root, environment, and default origins"

for hostile in \
    'DX_CONTAINER_NAME=one\nDX_CONTAINER_NAME=two' \
    'DX_CONTAINER_NAME=~name' \
    'DX_CONTAINER_NAME=$(id)' \
    'DX_CONTAINER_NAME=`id`' \
    'DX_CONTAINER_NAME=one;id' \
    'DX_CONTAINER_NAME="quoted"' \
    'DX_CONTAINER_NAME=one\\two' \
    'DX_CONTAINER_NAME=$HOME' \
    'DX_CONTAINER_NAME=one && id' \
    'DX_CONTAINER_NAME=one || id' \
    'DX_SSH_KEY=/tmp/key&touch' \
    'DX_SSH_KEY=/tmp/key|touch' \
    'DX_SSH_KEY=/tmp/key>file' \
    'DX_SSH_KEY=/tmp/key<file' \
    'UNKNOWN=value'; do
    printf '%b\n' "$hostile" > "$config_root/hostile.env"
    expect_reject "data parser rejects unsupported syntax: $hostile" dx_parse_config_file "$config_root/hostile.env"
done
printf '%s\n' 'DX_CONTAINER_NAME=one' 'DX_CONTAINER_NAME=two' > "$config_root/duplicate.env"
expect_reject "data parser rejects duplicate fields" dx_parse_config_file "$config_root/duplicate.env"
printf '%s\n' 'DX_CONTAINER_NAME=${DX_PROJECT_ROOT}' > "$config_root/placeholder.env"
expect_reject "project-root placeholder is restricted to path fields" dx_parse_config_file "$config_root/placeholder.env"
printf '%s\n' 'export DX_SSH_KEY=${DX_PROJECT_ROOT}/key' > "$config_root/export.env"
export DX_PROJECT_ROOT=$config_root
expect_ok "migration export prefix and project-root path placeholder are accepted" dx_parse_config_file "$config_root/export.env"
[ "$DXE_PARSED_DX_SSH_KEY" = "$config_root/key" ] && test_pass "project-root placeholder resolves as data" || test_fail "project-root placeholder resolves as data"
dx_parse_config_file "$config_root/absent.env"
[ "${DXE_PARSED_DX_SSH_KEY+x}" != x ] && test_pass "an absent data file clears prior parser output" || test_fail "an absent data file clears prior parser output"

# Process identity and lock reclamation use PID plus process start, never PID alone.
lock="$fixture/live.lock"
dx_lock_acquire "$lock" 1
IFS="$(printf '\t')" read -r lock_pid lock_start < "$lock/owner"
expect_ok "lock owner metadata matches the live process identity" dx_process_identity_matches "$lock_pid" "$lock_start"
dx_lock_release "$lock"
mkdir "$lock"; printf '%s\t%s\n' 999999 stale > "$lock/owner"
expect_ok "dead lock owner is reclaimed" dx_lock_acquire "$lock" 1
dx_lock_release "$lock"

kill_log="$fixture/kill.log"; identity_marker="$fixture/identity.marker"
container_runtime_pids() { printf '%s\n' 424242; }
dx_process_start_identity() { if [ ! -e "$identity_marker" ]; then : > "$identity_marker"; printf '%s\n' original; else printf '%s\n' reused; fi; }
kill() { printf '%s\n' "$*" >> "$kill_log"; }
export DX_STOP_WAIT_TIMEOUT=0
container_kill_runtime_process side >/dev/null 2>&1 || true
[ ! -e "$kill_log" ] && test_pass "PID reuse prevents TERM and KILL" || test_fail "PID reuse prevents TERM and KILL"
unset -f container_runtime_pids dx_process_start_identity kill
unset DX_STOP_WAIT_TIMEOUT
timeout_tmp="$fixture/timeouts"; mkdir -p "$timeout_tmp"
dx_process_start_identity() { printf 'stable-%s\n' "$1"; }
timeout_status=0
TMPDIR="$timeout_tmp" run_with_timeout 1 sleep 5 >/dev/null 2>&1 || timeout_status=$?
if [ "$timeout_status" -eq 124 ] && [ -z "$(find "$timeout_tmp" -mindepth 1 -print -quit)" ]; then
    test_pass "bounded command timeout returns 124 and removes private bookkeeping"
else
    test_fail "bounded command timeout returns 124 and removes private bookkeeping"
fi
source "$BASE_DIR/bin/lib/dx-host-util.sh"

# D4 codecs and no-replace publication.
legacy_cases=("''" '/tmp/a\ b' "\$'/tmp/a\\nb'" "quote\\'and\\\\slash" "\$'octal-\\101'" "\$'utf8-\\303\\251'")
legacy_expected=('' '/tmp/a b' $'/tmp/a\nb' "quote'and\\slash" 'octal-A' 'utf8-é')
for index in 0 1 2 3 4 5; do
    actual="$(dx_mount_legacy_decode_value "${legacy_cases[$index]}")"
    [ "$actual" = "${legacy_expected[$index]}" ] && test_pass "legacy %q fixture $index decodes" || test_fail "legacy %q fixture $index decodes"
done
for hostile in '\$(id)' '$HOME' 'value;id' 'value>file' "\$'bad\\x41'" 'value extra'; do
    expect_reject "legacy decoder rejects token: $hostile" dx_mount_legacy_decode_value "$hostile"
done

manifest="$fixture/identity/side.env"
export DX_CONTAINER_NAME=side DX_GIT_MOUNT_SOURCE=/tmp/source DX_GIT_MOUNT_TARGET=/src DX_IMAGE=dx-nixos-26.05
export DX_NIX_VOLUME=side-nix DX_PERSIST_VOLUME=side-persist DX_BOOTSTRAP_VOLUME=side-bootstrap
export DX_SSH_KEY=/tmp/key DX_SSH_KEY_PUB=/tmp/key.pub DX_SSH_PORT=2301
dx_mount_manifest_load_plan_values
(dx_mount_manifest_publish_new "$manifest") & first=$!
(dx_mount_manifest_publish_new "$manifest") & second=$!
first_status=0; second_status=0; wait "$first" || first_status=$?; wait "$second" || second_status=$?
if { [ "$first_status" -eq 0 ] && [ "$second_status" -ne 0 ]; } || { [ "$second_status" -eq 0 ] && [ "$first_status" -ne 0 ]; }; then
    test_pass "concurrent first publication has exactly one winner"
else
    test_fail "concurrent first publication has exactly one winner"
fi
expect_ok "concurrent publication leaves one complete v2 manifest" dx_mount_manifest_secure_read "$manifest"

# Complete legacy manifests convert explicitly; incomplete ones are unchanged.
migrate_repo="$fixture/migrate-repo"; migrate_state="$fixture/migrate-state"; mkdir -p "$migrate_repo" "$migrate_state"
git -C "$migrate_repo" init -q
mount_clean() {
    env -u DX_CONTAINER_NAME -u DX_IMAGE -u DX_SSH_PORT -u DX_SSH_KEY -u DX_SSH_KEY_PUB \
        -u DX_NIX_VOLUME -u DX_PERSIST_VOLUME -u DX_BOOTSTRAP_VOLUME \
        -u DX_GIT_MOUNT_SOURCE -u DX_GIT_MOUNT_TARGET -u DXE_CONFIG_RESOLVED -u DXE_CONFIG_SNAPSHOT_VERSION \
        DX_MOUNT_IDENTITY_DIR="$migrate_state" "$BASE_DIR/bin/dx-mount" "$@"
}
plan_output="$(mount_clean "$migrate_repo" --container migrate-side --print-env)"
plan_value() { printf '%s\n' "$plan_output" | sed -n "s/^export $1=//p"; }
legacy_manifest="$migrate_state/migrate-side.env"
{
    printf 'DX_MARKER_VERSION=1\n'
    for field in $DX_MOUNT_MANIFEST_FIELDS; do printf 'DX_RECORDED_%s=%q\n' "$field" "$(plan_value "DX_$field")"; done
} > "$legacy_manifest"
legacy_hash="$(shasum -a 256 "$legacy_manifest")"
dry_run="$(mount_clean "$migrate_repo" --container migrate-side --migrate-manifests)"
if printf '%s\n' "$dry_run" | stdin_matches 'migration-eligible=true' && [ "$legacy_hash" = "$(shasum -a 256 "$legacy_manifest")" ]; then
    test_pass "legacy migration dry run is report-only"
else
    test_fail "legacy migration dry run is report-only"
fi
mount_clean "$migrate_repo" --container migrate-side --migrate-manifests --apply >/dev/null
if dx_mount_manifest_read "$legacy_manifest" && [ "$DX_MOUNT_MANIFEST_FORMAT" = 2 ]; then test_pass "complete matching legacy manifest converts atomically"; else test_fail "complete matching legacy manifest converts atomically"; fi
printf '%s\n' 'DX_RECORDED_CONTAINER_NAME=incomplete-side' > "$migrate_state/incomplete-side.env"
incomplete_hash="$(shasum -a 256 "$migrate_state/incomplete-side.env")"
expect_reject "incomplete legacy manifest refuses migration" mount_clean "$migrate_repo" --container incomplete-side --migrate-manifests --apply
[ "$incomplete_hash" = "$(shasum -a 256 "$migrate_state/incomplete-side.env")" ] && test_pass "refused migration preserves incomplete authoritative file" || test_fail "refused migration preserves incomplete authoritative file"

# Phase 2 partial-failure behavior through one fake SSH implementation.
fake_dir="$(fake_tool_dir_create "$fixture")"; ssh_log="$fixture/ssh.log"
fake_ssh_write "$fake_dir" '
socket=""
previous=""
for arg in "$@"; do [ "$previous" = -S ] && socket=$arg; previous=$arg; done
printf "%s\n" "$*" >> "$DXE_FAKE_SSH_LOG"
case " $* " in
  *" -O check "*) [ -e "$socket" ] ;;
  *" -O exit "*) [ "${DXE_FAKE_SSH_STOP_FAIL:-0}" != 1 ] || exit 1; rm -f "$socket" ;;
  *) [ -z "${DXE_FAKE_SSH_START_DELAY:-}" ] || sleep "$DXE_FAKE_SSH_START_DELAY"; : > "$socket" ;;
esac
'
export PATH="$fake_dir:$PATH" DXE_FAKE_SSH_LOG="$ssh_log"
export DX_TUNNEL_STATE_DIR="$fixture/tunnels" DX_CONTAINER_NAME=side DX_SSH_PORT=2222 DX_SSH_KEY="$fixture/key" DX_SSH_CONNECT_TIMEOUT=1 DX_TUNNEL_LOCK_TIMEOUT=3
: > "$DX_SSH_KEY"
dx_port_in_use() { return 1; }
expect_ok "shared tunnel engine starts a forward" dx_tunnel_start forward 15173 5173
metadata="$(dx_tunnel_metadata_path forward 15173)"; socket="$(dx_tunnel_socket_path forward 15173)"
expect_ok "published tunnel metadata is allowlisted and complete" dx_tunnel_metadata_read "$metadata"
[ "$DX_TUNNEL_META_PEER" = 5173 ] && test_pass "tunnel metadata records the active peer" || test_fail "tunnel metadata records the active peer"
export DXE_FAKE_SSH_STOP_FAIL=1
expect_reject "failed SSH master stop returns failure" dx_tunnel_stop forward 15173
[ -e "$socket" ] && [ -f "$metadata" ] && test_pass "failed stop retains authoritative state" || test_fail "failed stop retains authoritative state"
unset DXE_FAKE_SSH_STOP_FAIL
expect_ok "successful stop removes retained state" dx_tunnel_stop forward 15173

# Separate processes race on one key; the per-key lock permits one master.
: > "$ssh_log"; export DXE_FAKE_SSH_START_DELAY=1
tunnel_child='source "$1"; source "$2"; dx_port_in_use() { return 1; }; dx_tunnel_start forward 16000 6000'
/bin/bash -c "$tunnel_child" _ "$BASE_DIR/bin/lib/dx-host-util.sh" "$BASE_DIR/bin/lib/dx-tunnel.sh" >/dev/null & tunnel_first=$!
/bin/bash -c "$tunnel_child" _ "$BASE_DIR/bin/lib/dx-host-util.sh" "$BASE_DIR/bin/lib/dx-tunnel.sh" >/dev/null & tunnel_second=$!
tunnel_first_status=0; tunnel_second_status=0
wait "$tunnel_first" || tunnel_first_status=$?; wait "$tunnel_second" || tunnel_second_status=$?
start_count="$(grep -c -- '-f -N -M' "$ssh_log" || true)"
if [ "$tunnel_first_status" -eq 0 ] && [ "$tunnel_second_status" -eq 0 ] && [ "$start_count" -eq 1 ]; then
    test_pass "concurrent tunnel starts linearize to one SSH master"
else
    test_fail "concurrent tunnel starts linearize to one SSH master"
fi
unset DXE_FAKE_SSH_START_DELAY
expect_ok "concurrently-created tunnel remains stoppable" dx_tunnel_stop forward 16000

export DXE_FAKE_SSH_START_DELAY=1
tunnel_race_start='source "$1"; source "$2"; dx_port_in_use() { return 1; }; dx_tunnel_start reverse 18000 8000'
tunnel_race_stop='source "$1"; source "$2"; dx_tunnel_stop reverse 18000'
/bin/bash -c "$tunnel_race_start" _ "$BASE_DIR/bin/lib/dx-host-util.sh" "$BASE_DIR/bin/lib/dx-tunnel.sh" >/dev/null & race_start=$!
sleep 0.2
/bin/bash -c "$tunnel_race_stop" _ "$BASE_DIR/bin/lib/dx-host-util.sh" "$BASE_DIR/bin/lib/dx-tunnel.sh" >/dev/null & race_stop=$!
race_start_status=0; race_stop_status=0; wait "$race_start" || race_start_status=$?; wait "$race_stop" || race_stop_status=$?
race_socket="$(dx_tunnel_socket_path reverse 18000)"; race_metadata="$(dx_tunnel_metadata_path reverse 18000)"
if [ "$race_start_status" -eq 0 ] && [ "$race_stop_status" -eq 0 ] && [ ! -e "$race_socket" ] && [ ! -e "$race_metadata" ]; then
    test_pass "concurrent tunnel start/stop serializes to a complete stopped state"
else
    test_fail "concurrent tunnel start/stop serializes to a complete stopped state"
fi
unset DXE_FAKE_SSH_START_DELAY

# Metadata reaped from under a live SSH master. macOS deletes files under /tmp
# that have gone untouched for three days, but the master holds its socket open
# indefinitely -- so the tunnel outlives the file that describes it, and the
# port used to be unusable until someone stopped it by hand. The master's own
# -L/-R mapping is the authority, so the peer is recovered from there.
: > "$ssh_log"
dx_tunnel_process_list >/dev/null 2>&1 || true   # cover the real ps probe once
expect_ok "reaped-metadata fixture starts a forward" dx_tunnel_start forward 15200 5200
reaped_metadata="$(dx_tunnel_metadata_path forward 15200)"; reaped_socket="$(dx_tunnel_socket_path forward 15200)"
# The fake ssh logs "$*" verbatim, so the log *is* the argv the master would
# show in ps; prefixing the binary name is the only thing ps adds.
dx_tunnel_process_list() { sed 's/^/ssh /' "$ssh_log"; }

rm -f "$reaped_metadata"
expect_ok "reaped metadata self-heals from the live SSH master" dx_tunnel_start forward 15200 5200
if dx_tunnel_metadata_read "$reaped_metadata" && [ "$DX_TUNNEL_META_PEER" = 5200 ]; then
    test_pass "recovery republishes the peer the master is actually forwarding"
else
    test_fail "recovery republishes the peer the master is actually forwarding"
fi

# Recovery must not become a way to silently repoint a live tunnel.
rm -f "$reaped_metadata"
expect_reject "recovered peer still refuses a conflicting mapping" dx_tunnel_start forward 15200 9200

rm -f "$reaped_metadata"
if [ "$(dx_tunnel_peer_for_socket forward 15200 "$reaped_socket")" = 5200 ]; then
    test_pass "listing reports the recovered peer instead of unknown"
else
    test_fail "listing reports the recovered peer instead of unknown"
fi

# Refreshing on every confirmed-active start keeps the reaper from reaching a
# tunnel that is still in daily use at all.
touch -t 200001010000 "$reaped_metadata"
refresh_marker="$fixture/refresh-marker"; touch -t 200001020000 "$refresh_marker"
dx_tunnel_start forward 15200 5200 >/dev/null
if [ -n "$(find "$reaped_metadata" -newer "$refresh_marker" 2>/dev/null)" ]; then
    test_pass "confirming an active tunnel restamps its metadata against the reaper"
else
    test_fail "confirming an active tunnel restamps its metadata against the reaper"
fi

rm -f "$reaped_metadata"
if ( dx_tunnel_metadata_write() { return 1; }; dx_tunnel_recover_peer forward 15200 "$reaped_socket" ) >/dev/null 2>&1; then
    test_fail "recovery that cannot republish metadata fails loudly"
else
    test_pass "recovery that cannot republish metadata fails loudly"
fi

# A master that claims an impossible peer is not evidence of anything.
dx_tunnel_process_list() { printf 'ssh -f -N -M -S %s -L 127.0.0.1:15200:127.0.0.1:99999999 -i k\n' "$reaped_socket"; }
expect_reject "an out-of-range peer in the master argv is not trusted" dx_tunnel_start forward 15200 5200

# Nothing left to recover from: the error must name the command that clears it.
dx_tunnel_process_list() { :; }
recover_error="$(dx_tunnel_start forward 15200 5200 2>&1 >/dev/null || true)"
if printf '%s\n' "$recover_error" | stdin_matches -F 'dx-forward --stop 15200'; then
    test_pass "unrecoverable state names the command that clears it"
else
    test_fail "unrecoverable state names the command that clears it"
fi
expect_ok "recovered tunnel remains stoppable" dx_tunnel_stop forward 15200

# Reverse tunnels bind the same way through -R, and legacy sockets predate the
# metadata layout entirely, so recovery must not publish canonical state for one.
dx_tunnel_process_list() { sed 's/^/ssh /' "$ssh_log"; }
expect_ok "reverse fixture starts a reverse forward" dx_tunnel_start reverse 18200 8200
rm -f "$(dx_tunnel_metadata_path reverse 18200)"
expect_ok "reverse recovery reads the -R mapping" dx_tunnel_start reverse 18200 8200
dx_tunnel_stop reverse 18200 >/dev/null

legacy_recover="$fixture/dx-forward-side-15300.sock"; : > "$legacy_recover"
dx_tunnel_process_list() { printf 'ssh -f -N -M -S %s -L 127.0.0.1:15300:127.0.0.1:5300 -i k\n' "$legacy_recover"; }
if [ "$(dx_tunnel_peer_for_socket forward 15300 "$legacy_recover")" = 5300 ] &&
    [ ! -f "$(dx_tunnel_metadata_path forward 15300)" ]; then
    test_pass "legacy socket recovery reports the peer without publishing new-layout state"
else
    test_fail "legacy socket recovery reports the peer without publishing new-layout state"
fi
rm -f "$legacy_recover"

legacy_unknown="$fixture/dx-forward-side-15500.sock"; : > "$legacy_unknown"
dx_tunnel_process_list() { :; }
legacy_unknown_status=0
legacy_unknown_out="$(dx_tunnel_peer_for_socket forward 15500 "$legacy_unknown")" || legacy_unknown_status=$?
if [ "$legacy_unknown_status" -eq 0 ] && [ -z "$legacy_unknown_out" ]; then
    test_pass "an unknown legacy peer reports nothing rather than failing its set -e caller"
else
    test_fail "an unknown legacy peer reports nothing rather than failing its set -e caller"
fi
rm -f "$legacy_unknown"

# Discovery is keyed by the metadata file, so reaping it also hid the socket:
# --list reported nothing while a master still held the port, and --stop-all
# walked straight past it. The key port is in the master's argv as well, and
# re-deriving the socket path from it proves the key belongs to this direction
# and container rather than trusting the argv on its face.
: > "$ssh_log"
dx_tunnel_process_list() { sed 's/^/ssh /' "$ssh_log"; }
expect_ok "orphan-discovery fixture starts a forward" dx_tunnel_start forward 15400 5400
if [ "$(dx_tunnel_discover forward | grep -c -F 15400)" = 1 ]; then
    test_pass "a socket with intact metadata is discovered exactly once"
else
    test_fail "a socket with intact metadata is discovered exactly once"
fi
if [ "$(dx_tunnel_list forward 2>/dev/null | grep -c -F 'Active http://127.0.0.1:15400')" = 1 ]; then
    test_pass "listing a healthy tunnel prints one entry"
else
    test_fail "listing a healthy tunnel prints one entry"
fi
rm -f "$(dx_tunnel_metadata_path forward 15400)"
if dx_tunnel_discover forward | stdin_matches -F '15400'; then
    test_pass "discovery finds a live socket whose metadata was reaped"
else
    test_fail "discovery finds a live socket whose metadata was reaped"
fi
if dx_tunnel_list forward 2>/dev/null | stdin_matches -F 'Active http://127.0.0.1:15400 -> side:5400'; then
    test_pass "listing an orphaned socket reports its real peer"
else
    test_fail "listing an orphaned socket reports its real peer"
fi
if dx_tunnel_discover reverse | stdin_matches -F '15400'; then
    test_fail "a forward socket is never discovered as a reverse forward"
else
    test_pass "a forward socket is never discovered as a reverse forward"
fi
expect_reject "a key port outside the valid range is not trusted" \
    eval 'dx_tunnel_process_list() { printf "ssh -S %s -L 127.0.0.1:99999999:127.0.0.1:5400\n" "$(dx_tunnel_socket_path forward 15400)"; }; dx_tunnel_recover_key forward "$(dx_tunnel_socket_path forward 15400)"'
expect_reject "a key whose socket path does not round-trip is not trusted" \
    eval 'dx_tunnel_process_list() { printf "ssh -S %s -L 127.0.0.1:15300:127.0.0.1:5300\n" "$fixture/dx-forward-side-15300.sock"; }; dx_tunnel_recover_key forward "$fixture/dx-forward-side-15300.sock"'
dx_tunnel_process_list() { sed 's/^/ssh /' "$ssh_log"; }
expect_ok "stop-all reclaims a socket that only the process table knew about" dx_tunnel_stop_all forward
[ ! -e "$(dx_tunnel_socket_path forward 15400)" ] &&
    test_pass "reclaimed orphan leaves no socket behind" || test_fail "reclaimed orphan leaves no socket behind"

dx_tunnel_process_list() { :; }

dx_tunnel_metadata_write() { return 1; }
expect_reject "metadata publication failure fails the start" dx_tunnel_start reverse 15432 5432
socket="$(dx_tunnel_socket_path reverse 15432)"
[ ! -e "$socket" ] && test_pass "metadata failure cleans up the started master" || test_fail "metadata failure cleans up the started master"

profile_dir="$fixture/profiles"; mkdir -p "$profile_dir"
printf '%s\n' 'DX_CONTAINER_NAME=profile-side' > "$profile_dir/profile-side.env"
: > "$fixture/dx-forward-profile-side-17000.sock"
tunnel_audit="$(env -u DXE_CONFIG_RESOLVED -u DXE_CONFIG_SNAPSHOT_VERSION \
    DX_PROFILES_DIR="$profile_dir" TMPDIR="$fixture" "$BASE_DIR/bin/dx-status" --tunnel-state)"
if printf '%s\n' "$tunnel_audit" | stdin_matches 'container=profile-side port=17000 layout=legacy'; then
    test_pass "tunnel-state audit sweeps safely parsed named profiles"
else
    test_fail "tunnel-state audit sweeps safely parsed named profiles"
fi

print_summary
exit_with_code
