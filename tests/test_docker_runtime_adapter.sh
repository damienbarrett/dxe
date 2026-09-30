#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# Section 33: Docker-ssh runtime adapter (Branch 11 / Phase 2, qnap-dxe-plan.md
# Phase 2) -- bin/lib/dx-runtime-docker.sh, developed and tested entirely
# against a fake `ssh` (tests/lib/fake-tools.sh's fake_qnap_ssh_write) and fake
# `docker` executables. The real NAS is production and off-limits; nothing
# here ever contacts it. See docs/refactor/docker-adapter-mapping.md for the
# command-by-command design this section characterises.
#
# Fable D6 step 1 (2026-09-30): this file used to hold all ~3,900 lines and
# 208 cases directly. It is now the aggregate entry point for five parts,
# split along its own original `# ---` section headers:
#   test_docker_adapter_transport.sh  -- ssh transport, quoting, dispatch
#   test_docker_adapter_identity.sh   -- daemon/host/image identity, DQ6
#   test_docker_adapter_lifecycle.sh  -- container/image/volume lifecycle
#   test_docker_adapter_lock.sh       -- the remote per-profile lifecycle lock
#   test_docker_adapter_health.sh     -- capability/diagnostics/coverage cases
# Each part carries its own full copy of the shared fixture prelude (fake
# tool sourcing, the isolated HOME, new_tool_dir, link_coreutils_into,
# tailnet_fixture_addr, ...) and is independently runnable on its own, e.g.
# `bash tests/test_docker_adapter_transport.sh`. This file remains the ONE
# entry tests/run_all_tests.sh dispatches (section 33); sourcing all five
# parts, in order, in the SAME process means their test_pass/test_fail
# calls all land in the one results file this process's print_summary/
# exit_with_code read below (tests/lib/harness.sh keys that file by PID, not
# by which sourced file recorded a case), so section 33 still reports a
# single combined Results line for all 208 cases -- no change needed in any
# runner or in tests/test_refactor_contracts.sh's B2 dispatch contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
test_section "Docker-ssh runtime adapter (Branch 11 / Phase 2)"

source "$SCRIPT_DIR/test_docker_adapter_transport.sh"
source "$SCRIPT_DIR/test_docker_adapter_identity.sh"
source "$SCRIPT_DIR/test_docker_adapter_lifecycle.sh"
source "$SCRIPT_DIR/test_docker_adapter_lock.sh"
source "$SCRIPT_DIR/test_docker_adapter_health.sh"

print_summary
exit_with_code
