#!/bin/bash
# Prints the "### Generated defaults reference" markdown table in
# docs/configuration.md from bin/lib/dx-config.sh's own
# DXE_CONFIG_REGISTRY -- the single source of truth for each field's
# default (Fable A5's refactor, Muse C2). Run it and paste its output over
# the committed table whenever the registry changes;
# tests/test_section10_docs.sh asserts the two stay byte-identical.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../bin/lib/dx-config.sh
source "$SCRIPT_DIR/../bin/lib/dx-config.sh"

# Renders a registry default-expression symbolically (never resolved
# against a real DX_PROJECT_ROOT/HOME, so this script needs neither) --
# the same symbolic style docs/configuration.md's own prose already uses
# for path defaults (e.g. "$DX_PROJECT_ROOT/dx_key").
dx_gen_config_table_render_default() {
    case "$1" in
        '=') printf '(empty)' ;;
        '='*) printf '`%s`' "${1#=}" ;;
        '@root:'*) printf '`$DX_PROJECT_ROOT/%s`' "${1#@root:}" ;;
        '@home:'*) printf '`$HOME/%s`' "${1#@home:}" ;;
        '@field:'*) printf '`$%s`' "${1#@field:}" ;;
    esac
}

printf '| Variable | Default |\n'
printf '| --- | --- |\n'
while IFS= read -r dxe_gen_line; do
    [ -n "$dxe_gen_line" ] || continue
    dxe_gen_name=${dxe_gen_line%%$'\t'*}
    dxe_gen_rest=${dxe_gen_line#*$'\t'}
    dxe_gen_default=${dxe_gen_rest#*$'\t'}
    printf '| `%s` | %s |\n' "$dxe_gen_name" "$(dx_gen_config_table_render_default "$dxe_gen_default")"
done <<<"$DXE_CONFIG_REGISTRY"
