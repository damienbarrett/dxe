#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
test_section "Section 9: Host Library And Command Contracts"

for script in "$BASE_DIR"/bin/dx*; do
    [ -f "$script" ] || continue
    case "$script" in */dx-lib.sh) continue ;; esac
    if grep -q '^set -euo pipefail$' "$script"; then test_pass "$(basename "$script") owns strict mode"; else test_fail "$(basename "$script") owns strict mode"; fi
    if bash -n "$script"; then :; else test_fail "$(basename "$script") passes bash syntax"; fi
done

for library in "$BASE_DIR"/bin/lib/*.sh; do
    if grep -q '^set -.*pipefail' "$library"; then test_fail "$(basename "$library") does not set caller shell options"; else test_pass "$(basename "$library") does not set caller shell options"; fi
    before_flags=$-; before_ifs=$IFS; before_pwd=$PWD; before_umask="$(umask)"; before_traps="$(trap -p)"
    # shellcheck source=/dev/null
    output="$(source "$library")"
    if [ -z "$output" ] && [ "$before_flags" = "$-" ] && [ "$before_ifs" = "$IFS" ] && [ "$before_pwd" = "$PWD" ] && [ "$before_umask" = "$(umask)" ] && [ "$before_traps" = "$(trap -p)" ]; then
        test_pass "$(basename "$library") is import-only"
    else test_fail "$(basename "$library") is import-only"; fi
done

source "$BASE_DIR/bin/lib/dx-config.sh"
config_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-host-config.XXXXXX")"
trap 'rm -rf "$config_fixture"' EXIT
printf '%s\n' 'DX_CONTAINER_NAME=from-data' 'DX_SSH_KEY=${DX_PROJECT_ROOT}/fixture-key' > "$config_fixture/good.env"
DX_PROJECT_ROOT=$config_fixture
if dx_parse_config_file "$config_fixture/good.env" && [ "$DXE_PARSED_DX_CONTAINER_NAME" = from-data ] && [ "$DXE_PARSED_DX_SSH_KEY" = "$config_fixture/fixture-key" ]; then test_pass "root/profile grammar is parsed as bounded data"; else test_fail "root/profile grammar is parsed as bounded data"; fi
for hostile in 'DX_CONTAINER_NAME=$(id)' 'DX_CONTAINER_NAME=$HOME' 'DX_CONTAINER_NAME="quoted"' 'UNKNOWN=value'; do
    printf '%s\n' "$hostile" > "$config_fixture/hostile.env"
    if dx_parse_config_file "$config_fixture/hostile.env" >/dev/null 2>&1; then test_fail "config rejects $hostile"; else test_pass "config rejects $hostile"; fi
done

(
    unset DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION
    HOME="$config_fixture"; dx_init_config "$BASE_DIR"
    dx_validate_config_snapshot "$BASE_DIR"
) && test_pass "complete versioned configuration snapshot validates" || test_fail "complete versioned configuration snapshot validates"
(
    DXE_CONFIG_RESOLVED=1 DXE_CONFIG_SNAPSHOT_VERSION=1 DX_PROJECT_ROOT="$BASE_DIR"
    export DXE_CONFIG_RESOLVED DXE_CONFIG_SNAPSHOT_VERSION DX_PROJECT_ROOT
    for field in $DXE_CONFIG_FIELDS; do unset "$field" "DXE_CONFIG_ORIGIN_$field"; done
    dx_validate_config_snapshot "$BASE_DIR"
) >/dev/null 2>&1 && test_fail "partial snapshot fails closed" || test_pass "partial snapshot fails closed"

source "$BASE_DIR/bin/lib/dx-container.sh"
ps() { printf '%s\n' '101 container-runtime-linux start --uuid dx-host-other' '102 container-runtime-linux start --uuid dx-host' 'bad malformed'; }
if [ "$(container_runtime_pids dx-host)" = 102 ]; then test_pass "runtime discovery matches exact --uuid argument/value pairs"; else test_fail "runtime discovery matches exact --uuid argument/value pairs"; fi
unset -f ps

source "$BASE_DIR/bin/dx-forward"
if [ "$(parse_all_forwards 5173 8000:8001)" = $'5173:5173\n8001:8000' ]; then test_pass "forward wrapper parses direction-specific mappings"; else test_fail "forward wrapper parses direction-specific mappings"; fi
if parse_all_forwards 80 >/dev/null 2>&1; then test_fail "forward wrapper rejects privileged host ports"; else test_pass "forward wrapper rejects privileged host ports"; fi
source "$BASE_DIR/bin/dx-reverse"
if [ "$(parse_all_reverses 5432 3000:13000)" = $'5432:5432\n13000:3000' ]; then test_pass "reverse wrapper parses direction-specific mappings"; else test_fail "reverse wrapper parses direction-specific mappings"; fi

assert_file_not_contains "$BASE_DIR/bin/dx-forward" 'DX_FORWARD_TEST_MODE' "forward has no production test seam"
assert_file_not_contains "$BASE_DIR/bin/dx-reverse" 'DX_REVERSE_TEST_MODE' "reverse has no production test seam"
assert_file_contains_literal "$BASE_DIR/bin/dx-create-container" '-- "$DX_BOOTSTRAP_PATH"' "bootstrap path crosses the launcher boundary positionally"
assert_file_contains_literal "$BASE_DIR/bin/dx-migrate-persist" "-- \"\$legacy_volume\" \"\$sentinel\"" "migration values cross fixed command boundaries positionally"

print_summary
exit_with_code
