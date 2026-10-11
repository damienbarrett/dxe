#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP5.1: in-process coverage for the destroy/reset helpers in
# bin/lib/dx-container.sh. tests/test_persist_destroy_reset.sh drives the
# commands from `env -i`, which kcov cannot trace; this suite calls the
# functions here with the runtime operations replaced by recording fakes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"
source "$BASE_DIR/bin/lib/dx-persist-dir.sh"
source "$BASE_DIR/bin/lib/dx-runtime-docker-identity.sh"

test_section "WP5.1: destroy and reset helpers (in-process)"

DX_CONTAINER_NAME=dx-u DX_NIX_VOLUME=u-nix DX_PERSIST_VOLUME=u-persist DX_BOOTSTRAP_VOLUME=u-boot
DX_PERSIST_HOST_ROOT=/root-x
DX_REMOTE_HOST=host.invalid
PLAN_SPECS=''
dx_destructive_plan_and_verify() { PLAN_SPECS="$*"; }
PROBE_OUT=''; PROBE_RC=0; EXISTING=' u-persist u-old '
dx_runtime_host_dir_probe() { printf '%s' "$PROBE_OUT"; return "$PROBE_RC"; }
dx_runtime_volume_exists() { case "$EXISTING" in *" $1 "*) return 0 ;; esac; return 1; }

check() { # label expected actual
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (want '$2' got '$3')"; fi
}

DX_PERSIST_STORAGE=volume
dx_destroy_plan_and_verify
check "volume mode plan: nix, persist, bootstrap" "volume:u-nix:nix volume:u-persist:persist volume:u-boot:bootstrap" "$PLAN_SPECS"
dx_destroy_plan_and_verify container
check "volume mode plan with the container first" "container:dx-u:container volume:u-nix:nix volume:u-persist:persist volume:u-boot:bootstrap" "$PLAN_SPECS"
check "volume mode: no kept volumes" "" "$(dx_persist_kept_volumes)"
check "volume mode: no kept report" "" "$(dx_persist_kept_report)"
check "volume mode: no kept status lines" "" "$(dx_persist_status_kept_lines)"
check "volume mode: reset lists the persist volume as irreversible" \
    "  - Volume u-nix (Nix store — re-download takes hours)
  - Volume u-persist (Your work in /persist — IRREVERSIBLE)
  - Volume u-boot (Bootstrap payload — auto-rebuilt)" "$(dx_factory_reset_volume_lines)"
check "describe: nix" "  u-nix  (Nix store — re-download takes hours)" "$(dx_destroy_volume_describe u-nix)"
check "describe: persist" "  u-persist  (Your work in /persist — IRREVERSIBLE)" "$(dx_destroy_volume_describe u-persist)"
check "describe: bootstrap" "  u-boot  (Bootstrap payload — auto-rebuilt on next start)" "$(dx_destroy_volume_describe u-boot)"
check "describe: other" "  other" "$(dx_destroy_volume_describe other)"

DX_PERSIST_STORAGE=host-path
dx_destroy_plan_and_verify
check "host-path plan: nix and bootstrap only" "volume:u-nix:nix volume:u-boot:bootstrap" "$PLAN_SPECS"
dx_destroy_plan_and_verify container
check "host-path plan with the container" "container:dx-u:container volume:u-nix:nix volume:u-boot:bootstrap" "$PLAN_SPECS"
check "host-path: the destroy list never holds a persist volume" "u-nix u-boot" "${DX_DESTROY_VOLUMES[*]}"
check "host-path: the reset prompt keeps the persist data" \
    "  - Volume u-nix (Nix store — re-download takes hours)
  (kept: the /persist directory on the NAS and every persist volume)
  - Volume u-boot (Bootstrap payload — auto-rebuilt)" "$(dx_factory_reset_volume_lines)"

PROBE_OUT='root=/root-x
mounted=unknown
state=nonempty
marker=present
version=1
source-volume=u-old'
check "kept volumes: configured first, then the marker's source" "u-persist
u-old" "$(dx_persist_kept_volumes)"
PROBE_OUT='marker=present
source-volume=u-persist'
check "kept volumes: the same volume is listed once" "u-persist" "$(dx_persist_kept_volumes)"
PROBE_OUT='marker=present
source-volume=bad name;rm'
check "kept volumes: an invalid source-volume is ignored" "u-persist" "$(dx_persist_kept_volumes)"
PROBE_OUT='marker=present
source-volume=u-gone'
check "kept volumes: a source volume that does not exist is skipped" "u-persist" "$(dx_persist_kept_volumes)"
PROBE_OUT='source-volume=u-old'; PROBE_RC=1
check "kept volumes: a failed probe contributes no source volume" "u-persist" "$(dx_persist_kept_volumes)"
PROBE_RC=0 PROBE_OUT='marker=absent'
EXISTING=' '
check "kept volumes: none exist" "" "$(dx_persist_kept_volumes)"

EXISTING=' u-persist u-old '
PROBE_OUT='marker=present
source-volume=u-old'
want="Kept /persist host directory: /root-x/dxe/dx-u/persist
  manual removal 1: with the guest stopped, remove /root-x/dxe/dx-u on the NAS
  manual removal 2: delete the record file /state-x/dxe/persist-dirs/host.invalid__dx-u
Kept persist volume: u-persist
  delete with: docker volume rm u-persist
Kept persist volume: u-old
  delete with: docker volume rm u-old"
XDG_STATE_HOME=/state-x
check "kept report: directory, removal steps, each volume" "$want" "$(dx_persist_kept_report)"
unset XDG_STATE_HOME
HOME=/home-x
check "record path basename is the adapter's profile id" "$(dx_runtime_docker_profile_id)" "$(basename "$(dx_persist_dir_record_path)")"
check "record path falls back to \$HOME/.local/state" "/home-x/.local/state/dxe/persist-dirs/host.invalid__dx-u" "$(dx_persist_dir_record_path)"
got="$(HOME="" dx_persist_kept_report | grep -F "manual removal 2")"
check "kept report names a placeholder when the record path cannot be formed" "  manual removal 2: delete the record file <XDG_STATE_HOME>/dxe/persist-dirs/<DX_REMOTE_HOST>__<DX_CONTAINER_NAME>" "$got"
check "status lines: one per kept volume" "kept volume: u-persist
kept volume: u-old" "$(dx_persist_status_kept_lines)"

print_summary
exit_with_code
