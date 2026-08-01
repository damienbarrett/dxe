#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="$(/bin/bash --version | head -1)"
case "$version" in *'version 3.2.'*) ;; *) echo "Error: /bin/bash is not Bash 3.2: $version" >&2; exit 1 ;; esac

/bin/bash -n "$SCRIPT_DIR"/../bin/dx* "$SCRIPT_DIR"/../bin/lib/*.sh
/bin/bash "$SCRIPT_DIR/test_refactor_contracts.sh"
/bin/bash "$SCRIPT_DIR/test_section9_host_scripts.sh"
/bin/bash "$SCRIPT_DIR/test_section18_mount_git.sh"
/bin/bash "$SCRIPT_DIR/test_refactor_state_machines.sh"
