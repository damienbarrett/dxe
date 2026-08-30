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
    if grep -F -- "$name" "$CONFIG_DOC" | stdin_matches -F -- "$value"; then test_pass "$name documented default matches registry"; else test_fail "$name documented default matches registry"; fi
done

assert_file_contains_literal "$CONFIG_DOC" 'Root `.env` and profiles are data files' "configuration trust boundary is explicit"
assert_file_contains_literal "$CONFIG_DOC" 'Do not source a profile' "profiles are not advertised as sourceable code"
assert_file_contains_literal "$CONFIG_DOC" '${DX_PROJECT_ROOT}' "the sole data expansion is documented"
assert_file_contains "$CONFIG_DOC" 'partial, stale, wrong-root' "snapshot failure modes are documented"
assert_file_contains "$BASE_DIR/docs/lifecycle.md" 'refus' "destructive refusal behavior remains documented"
assert_file_contains "$BASE_DIR/docs/release-maintenance.md" 'Base Image Changeover' "temporary guard procedure remains discoverable"
# These are documentation literals, not shell paths to expand.
# shellcheck disable=SC2088
assert_file_contains_literal "$BASE_DIR/docs/guest.md" '~/.config/herdr' "guest docs identify the persisted Herdr config path"
# shellcheck disable=SC2088
assert_file_contains_literal "$BASE_DIR/docs/guest.md" '~/.local/state/herdr' "guest docs identify the persisted Herdr session path"
assert_file_contains_literal "$BASE_DIR/docs/guest.md" 'bootstrap/herdr-config.toml' "guest docs identify the repository-owned Herdr defaults"
assert_file_contains_literal "$BASE_DIR/docs/guest.md" 'explicit existing values win' "guest docs explain the Herdr merge policy"

GUEST_DOC="$BASE_DIR/docs/guest.md"
assert_file_contains_literal "$GUEST_DOC" 'without prompting for confirmation' "dx-herdr install-without-confirming behavior is documented accurately"
assert_file_contains_literal "$GUEST_DOC" 'session-history.json' "the sensitive pane-history file is named for the documented cleanup path"
assert_file_contains "$GUEST_DOC" 'ends its pane processes' "history cleanup warns it ends live pane processes"
assert_file_contains_literal "$GUEST_DOC" 'no live upgrade' "cold-upgrade workflow states no live upgrade exists"
assert_file_contains_literal "$GUEST_DOC" 'never refreshes an already-present bundle' "ordinary dx-herdr launches are documented as never refreshing an installed bundle"
assert_file_contains_literal "$GUEST_DOC" 'It never modifies the published' "dx-ai's immutable bootstrap/source boundary is documented accurately (R6)"
assert_file_contains_literal "$GUEST_DOC" 'verifies the persistent Herdr configuration and state links' "dx-herdr's persistence-ready preflight is documented (R3)"
assert_file_contains_literal "$GUEST_DOC" 'AGPL-3.0-or-later' "the packaged herdr license is documented"
assert_file_contains_literal "$GUEST_DOC" 'meta.license.spdxId' "the license claim cites its nixpkgs source"
assert_file_contains_literal "$GUEST_DOC" 'direct single-user mode' "guest docs explain the Nix single-user ownership model"
assert_file_contains_literal "$GUEST_DOC" 'versioned `.dxe-*-owner-v1` marker' "guest docs explain bounded ownership markers"
assert_file_contains_literal "$GUEST_DOC" 'full lifecycle, not merely while it is running' "guest documentation records the Nix-volume single-writer constraint"
assert_file_contains_literal "$GUEST_DOC" 'Destroy that container before' "guest documentation records the required claim transfer boundary"
assert_file_contains_literal "$BASE_DIR/docs/configuration.md" 'host lifecycle claim' "configuration documents the host Nix-volume claim boundary"
assert_file_contains_literal "$BASE_DIR/docs/configuration.md" 'Destroy the owning container before assigning' "configuration documents the required Nix-volume claim transfer boundary"
assert_file_contains_literal "$BASE_DIR/docs/troubleshooting.md" 'Recovering a Nix volume without resetting it' "troubleshooting documents non-destructive Nix-volume recovery"
assert_file_contains_literal "$BASE_DIR/docs/release-maintenance.md" 'bootstrap-essentials' "release maintenance documents locked bootstrap essentials provenance"
assert_file_contains_literal "$BASE_DIR/docs/troubleshooting.md" 'Migrating legacy ... ownership (one time)' "troubleshooting docs identify one-time ownership migration output"
assert_file_contains_literal "$BASE_DIR/docs/troubleshooting.md" 'written only after the recursive repair completes' "troubleshooting docs explain safe migration interruption"

# A guest that will not boot is the one situation where the reader cannot get
# into the guest to look things up, so the recovery has to be discoverable from
# the host and it has to name the volume boundary. Deleting dx-nix costs a
# store rebuild; reaching for dx-factory-reset instead destroys /persist and
# with it the home directory. Pin both, the way the Base Image Changeover
# procedure above is pinned.
TROUBLESHOOTING="$BASE_DIR/docs/troubleshooting.md"
assert_file_contains_literal "$TROUBLESHOOTING" 'dx-bootstrap-essentials' "troubleshooting docs identify the missing-toolchain boot failure"
assert_file_contains_literal "$TROUBLESHOOTING" 'container volume delete dx-nix' "troubleshooting docs give the store-only recovery command"
assert_file_contains "$TROUBLESHOOTING" 'dx-factory-reset' "troubleshooting docs warn which reset also destroys /persist"
assert_file_contains "$TROUBLESHOOTING" 'dx-wait-ssh' "troubleshooting docs cover a healthy boot reported as a failure"

# The rule that would have caught both the ownership-laundering defect and the
# read-only store defect, neither of which a stubbed boundary can observe.
assert_file_contains "$BASE_DIR/constitution.md" 'trust boundary' "the constitution states the real-boundary testing rule"

# The pin-bump prohibition is load-bearing: it is what sends a bump down the
# destructive salvage path instead of dx-recreate. Pin the observed evidence,
# so the section cannot drift back to a diagnosis that no longer reproduces.
RELEASE_DOC="$BASE_DIR/docs/release-maintenance.md"
assert_file_contains_literal "$RELEASE_DOC" 'hash mismatch importing path' "release maintenance records the observed pin-bump blocker"
# Match a phrase that line-wrapping cannot split; the bolded verdicts below it
# are broken across lines by the surrounding prose width.
assert_file_contains_literal "$RELEASE_DOC" 'have not survived testing' "release maintenance marks the superseded store-reuse diagnoses"

print_summary
exit_with_code
