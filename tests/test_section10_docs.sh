#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
README="$BASE_DIR/README.md"
CONFIG_DOC="$BASE_DIR/docs/configuration.md"
test_section "Section 10: Documentation Contracts"

assert_file_exists "$README" "README exists"
if [ "$(wc -l < "$README")" -lt 250 ]; then test_pass "README is a focused quick start and index"; else test_fail "README is a focused quick start and index"; fi
for doc in lifecycle configuration guest troubleshooting release-maintenance; do
    assert_file_exists "$BASE_DIR/docs/$doc.md" "focused $doc documentation exists"
    assert_file_contains_literal "$README" "docs/$doc.md" "README links $doc documentation"
done

broken_links=""
while IFS= read -r markdown_file; do
    while IFS= read -r reference; do
        target=${reference#']('}; target=${target%%#*}
        case "$target" in ''|http:*|https:*|mailto:*) continue ;; esac
        if [ ! -e "$(dirname "$markdown_file")/$target" ]; then broken_links="$broken_links$markdown_file -> $target
"; fi
    done < <(grep -oE '\]\([^)]+' "$markdown_file" || true)
done < <(find "$BASE_DIR" -maxdepth 4 -type f -name '*.md' -not -path '*/.git/*' | sort)
if [ -z "$broken_links" ]; then test_pass "local Markdown links resolve"; else test_fail "local Markdown links resolve:$broken_links"; fi

all_docs="$README $BASE_DIR/docs/lifecycle.md $CONFIG_DOC $BASE_DIR/docs/guest.md $BASE_DIR/docs/troubleshooting.md $BASE_DIR/docs/release-maintenance.md"
for command in "$BASE_DIR"/bin/dx*; do
    [ -f "$command" ] || continue
    name="$(basename "$command")"
    [ "$name" = dx-lib.sh ] && continue
    if grep -Fq -- "$name" $all_docs; then test_pass "$name is discoverable"; else test_fail "$name is discoverable"; fi
done

source "$BASE_DIR/bin/lib/dx-config.sh"
for name in $DXE_CONFIG_FIELDS; do
    if grep -Fq -- "$name" "$CONFIG_DOC"; then test_pass "$name is generated/validated from the config registry"; else test_fail "$name is generated/validated from the config registry"; fi
done
for pair in 'DX_CONTAINER_NAME|dx-host' 'DX_IMAGE|dx-nixos-26.05' 'DX_SSH_PORT|2222' 'DX_NIX_VOLUME|dx-nix' 'DX_PERSIST_VOLUME|dx-persist' 'DX_BOOTSTRAP_VOLUME|dx-bootstrap' 'DX_CONTAINER_MEMORY|12G' 'DX_CONTAINER_CPUS|4'; do
    name=${pair%%|*}; value=${pair#*|}
    if grep -F -- "$name" "$CONFIG_DOC" | grep -Fq -- "$value"; then test_pass "$name documented default matches registry"; else test_fail "$name documented default matches registry"; fi
done

assert_file_contains_literal "$CONFIG_DOC" 'Root `.env` and profiles are data files' "configuration trust boundary is explicit"
assert_file_contains_literal "$CONFIG_DOC" 'Do not source a profile' "profiles are not advertised as sourceable code"
assert_file_contains_literal "$CONFIG_DOC" '${DX_PROJECT_ROOT}' "the sole data expansion is documented"
assert_file_contains "$CONFIG_DOC" 'partial, stale, wrong-root' "snapshot failure modes are documented"
assert_file_contains "$BASE_DIR/docs/lifecycle.md" 'refus' "destructive refusal behavior remains documented"
assert_file_contains "$BASE_DIR/docs/release-maintenance.md" 'Base Image Changeover' "temporary guard procedure remains discoverable"

print_summary
exit_with_code
