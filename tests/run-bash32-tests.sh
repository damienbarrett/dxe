#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="$(/bin/bash --version | head -1)"
case "$version" in *'version 3.2.'*) ;; *) echo "Error: /bin/bash is not Bash 3.2: $version" >&2; exit 1 ;; esac

/bin/bash -n "$SCRIPT_DIR"/../bin/dx* "$SCRIPT_DIR"/../bin/lib/*.sh "$SCRIPT_DIR"/qnap/phase0-*.sh "$SCRIPT_DIR"/qnap/lib/*.sh
/bin/bash "$SCRIPT_DIR/test_refactor_contracts.sh"
/bin/bash "$SCRIPT_DIR/test_harness.sh"
/bin/bash "$SCRIPT_DIR/test_coverage_metric.sh"
/bin/bash "$SCRIPT_DIR/test_host_util.sh"
/bin/bash "$SCRIPT_DIR/test_section9_host_scripts.sh"
/bin/bash "$SCRIPT_DIR/test_section18_mount_git.sh"
/bin/bash "$SCRIPT_DIR/test_refactor_state_machines.sh"
/bin/bash "$SCRIPT_DIR/test_persist_backup_select.sh"
/bin/bash "$SCRIPT_DIR/test_dx_backup.sh"
/bin/bash "$SCRIPT_DIR/test_dx_restore.sh"
/bin/bash "$SCRIPT_DIR/test_docker_runtime_adapter.sh"
# tests/qnap/phase0-*.sh run on this Mac's default Bash 3.2, exactly like
# bin/dx*, so this is their Bash 3.2 regression net.
/bin/bash "$SCRIPT_DIR/test_section27_qnap_scripts.sh"
