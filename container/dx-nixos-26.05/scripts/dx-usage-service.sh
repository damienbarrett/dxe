#!/usr/bin/env bash
# Thin dispatcher over scripts/lib/dx-usage-service.sh: `serve` (as dx) or
# `watchdog` (as root), started by the s6 services bootstrap builds.
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "$script_directory/lib/dx-keyring.sh" && source "$script_directory/lib/dx-usage-service.sh" || exit 1
if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; dx_usage_service_main "$@"; fi
