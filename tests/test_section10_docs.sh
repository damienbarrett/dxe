#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
README="$BASE_DIR/README.md"
CONFIG_DOC="$BASE_DIR/docs/configuration.md"
test_section "Section 10: Documentation Contracts"

assert_file_exists "$README" "README exists"
if [ "$(wc -l < "$README")" -lt 250 ]; then test_pass "README is a focused quick start and index"; else test_fail "README is a focused quick start and index"; fi
for doc in lifecycle configuration guest troubleshooting release-maintenance qnap-runbook; do
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

# --- no tracked file names the old, renamed guest directory (WP9.4, Muse
# B5) ---
#
# The guest tree used to live at
# container/aarch64-darwin-apple-container-dx-nixos-26.05/ even though the
# flake is architecture-neutral (`supportedSystems = [ "aarch64-linux"
# "x86_64-linux" ]`) and the QNAP guest that boots it is x86_64 -- the old
# name actively misled. It is now container/dx-nixos-26.05/, with a
# git-tracked symlink left at the old path for one release so an external
# profile that still sets DX_CONTEXT_DIR/DX_BOOTSTRAP_SOURCE to the old
# name keeps working (dx_config_validate_cross_fields warns on stderr when
# it sees one, section 21). A symlink's own tracked path name is not file
# CONTENT, so it needs no exemption from this content scan. docs/evidence/
# and docs/reviews/ are historical records of what the repository looked
# like on the day they were written -- exempted so their prose can keep
# naming the directory that existed then; every other tracked file must
# not. Scoped to `git ls-files` (tracked files only, current tree) rather
# than a raw filesystem walk, so this never reads git HISTORY -- a past
# commit's diff naming the old directory is not this file's concern.
OLD_GUEST_DIR_NAME="aarch64-darwin-apple-container-dx-nixos-26.05"
stale_old_name_hits=""
while IFS= read -r tracked_rel; do
    [ -n "$tracked_rel" ] || continue
    case "$tracked_rel" in
        docs/evidence/*|docs/reviews/*) continue ;;
        # This file's own OLD_GUEST_DIR_NAME literal, above, is the pattern
        # being searched for, not a stale reference to fix. bin/lib/
        # dx-config.sh's dx_config_validate_cross_fields deliberately keeps
        # the same literal, permanently, as the pattern its section 21
        # deprecation warning matches against; test_refactor_state_machines.sh
        # deliberately sets a DX_CONTEXT_DIR fixture value naming the old
        # directory to exercise that same warning. docs/configuration.md and
        # docs/release-maintenance.md name the old directory in their own
        # deprecation notices (WP9.4) -- intentional documentation of the
        # alias, due to be removed together with the symlink shim at the
        # next base changeover, not a stale reference to fix now.
        tests/test_section10_docs.sh|bin/lib/dx-config.sh|tests/test_refactor_state_machines.sh|docs/configuration.md|docs/release-maintenance.md) continue ;;
    esac
    tracked_file="$BASE_DIR/$tracked_rel"
    [ -f "$tracked_file" ] || continue
    if grep -qF -- "$OLD_GUEST_DIR_NAME" "$tracked_file" 2>/dev/null; then
        stale_old_name_hits="$stale_old_name_hits$tracked_rel
"
    fi
done < <(cd "$BASE_DIR" && git ls-files)
if [ -z "$stale_old_name_hits" ]; then
    test_pass "no tracked file outside docs/evidence/ and docs/reviews/ names the old guest directory"
else
    test_fail "no tracked file outside docs/evidence/ and docs/reviews/ names the old guest directory:
$stale_old_name_hits"
fi

# --- plans.md indexes every root plan document under exactly one status ---
#
# plans.md is prose: a plan document can be added, removed, or reassigned
# between statuses without anything noticing. Enumerate every root plan
# document -- every *.md at the repository root except this index itself,
# the top-level README, and the constitution -- and assert it is listed in
# plans.md under exactly one status section, and that every entry plans.md
# links to resolves to a file that exists. The status vocabulary (Partially
# complete, Open, Historical) is defined in plans.md itself.
PLANS_INDEX="$BASE_DIR/plans.md"
PLAN_STATUS_HITS="$(mktemp)"
PLAN_ALL_LINKS="$(mktemp)"

in_status_section=0
while IFS= read -r plans_line; do
    case "$plans_line" in
        '## Partially complete'*|'## Open'*|'## Historical'*) in_status_section=1; continue ;;
        '## '*) in_status_section=0; continue ;;
    esac
    while IFS= read -r reference; do
        [ -n "$reference" ] || continue
        target=${reference#']('}; target=${target%%#*}
        case "$target" in ''|http:*|https:*|mailto:*) continue ;; esac
        printf '%s\n' "$target" >>"$PLAN_ALL_LINKS"
        if [ "$in_status_section" -eq 1 ]; then printf '%s\n' "$target" >>"$PLAN_STATUS_HITS"; fi
    done < <(printf '%s\n' "$plans_line" | grep -oE '\]\([^)]+' || true)
done <"$PLANS_INDEX"

while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    case "$doc" in
        README.md|constitution.md|plans.md) continue ;;
    esac
    hit_count=$(grep -Fxc -- "$doc" "$PLAN_STATUS_HITS" || true)
    if [ "$hit_count" -eq 1 ]; then
        test_pass "plans.md lists $doc under exactly one status"
    else
        test_fail "plans.md lists $doc under exactly one status (found $hit_count)"
    fi
done < <(find "$BASE_DIR" -maxdepth 1 -type f -name '*.md' -exec basename {} \; | sort)

while IFS= read -r plan_target; do
    [ -n "$plan_target" ] || continue
    if [ -e "$BASE_DIR/$plan_target" ]; then
        test_pass "plans.md entry '$plan_target' resolves to a file"
    else
        test_fail "plans.md entry '$plan_target' resolves to a file"
    fi
done <"$PLAN_ALL_LINKS"

rm -f "$PLAN_STATUS_HITS" "$PLAN_ALL_LINKS"

# --- every document listed under "## Open plans" states a revisit trigger ---
#
# The status vocabulary above requires an Open entry to name a Revisit
# trigger: an Open plan with none is a document nobody has a reason to ever
# look at again. Walk plans.md a second time, this time scoped to just the
# "## Open plans" section, and assert each linked document contains the line.
OPEN_PLAN_LINKS="$(mktemp)"
in_open_section=0
while IFS= read -r plans_line; do
    case "$plans_line" in
        '## Open plans'*) in_open_section=1; continue ;;
        '## '*) in_open_section=0; continue ;;
    esac
    [ "$in_open_section" -eq 1 ] || continue
    while IFS= read -r reference; do
        [ -n "$reference" ] || continue
        target=${reference#']('}; target=${target%%#*}
        case "$target" in ''|http:*|https:*|mailto:*) continue ;; esac
        printf '%s\n' "$target" >>"$OPEN_PLAN_LINKS"
    done < <(printf '%s\n' "$plans_line" | grep -oE '\]\([^)]+' || true)
done <"$PLANS_INDEX"

while IFS= read -r open_target; do
    [ -n "$open_target" ] || continue
    if [ -e "$BASE_DIR/$open_target" ] && grep -q 'Revisit trigger:' "$BASE_DIR/$open_target"; then
        test_pass "$open_target states a Revisit trigger"
    else
        test_fail "$open_target states a Revisit trigger"
    fi
done <"$OPEN_PLAN_LINKS"

rm -f "$OPEN_PLAN_LINKS"

# --- reviews live under docs/reviews/, indexed there (findings.md D-2) ---
#
# D-2 reserves the repository root for plans that plans.md indexes; reviews
# are evidence, not plans, and move under docs/reviews/ instead, indexed by
# docs/reviews/README.md. Assert the move happened and stays complete: no
# findings-*.md left at the root, and every review file under docs/reviews/
# (other than its own README) is linked from that README. Same
# `](target` link-extraction idiom as above, matched on basename since the
# index links with a relative path.
findings_at_root="$(find "$BASE_DIR" -maxdepth 1 -type f -name 'findings-*.md')"
if [ -z "$findings_at_root" ]; then
    test_pass "no findings-*.md remains at the repository root"
else
    test_fail "no findings-*.md remains at the repository root: $findings_at_root"
fi

REVIEWS_DIR="$BASE_DIR/docs/reviews"
REVIEWS_README="$REVIEWS_DIR/README.md"
assert_file_exists "$REVIEWS_README" "docs/reviews/README.md exists"

REVIEWS_README_LINKS="$(mktemp)"
if [ -f "$REVIEWS_README" ]; then
    while IFS= read -r reference; do
        [ -n "$reference" ] || continue
        target=${reference#']('}; target=${target%%#*}
        basename "$target" >>"$REVIEWS_README_LINKS"
    done < <(grep -oE '\]\([^)]+' "$REVIEWS_README" || true)
fi

while IFS= read -r review_file; do
    [ -n "$review_file" ] || continue
    review_name="$(basename "$review_file")"
    if grep -Fxq -- "$review_name" "$REVIEWS_README_LINKS" 2>/dev/null; then
        test_pass "docs/reviews/README.md links $review_name"
    else
        test_fail "docs/reviews/README.md links $review_name"
    fi
done < <(find "$REVIEWS_DIR" -maxdepth 1 -type f -name '*.md' -not -name 'README.md' 2>/dev/null | sort)

rm -f "$REVIEWS_README_LINKS"

# --- docs/README.md maps entry points -> operating docs -> decisions ->
# evidence -> reviews (WP9.2, Muse F2). Assert it exists and links every
# operating doc that lives directly under docs/ (maxdepth 1 *.md, excluding
# itself) -- otherwise a newcomer following the map can land on it and still
# not find the doc they need. Matched on basename, the same tolerant idiom
# docs/reviews/README.md's check above uses, so the link may be written
# relative ("lifecycle.md") or repo-rooted ("docs/lifecycle.md").
DOCS_README="$BASE_DIR/docs/README.md"
assert_file_exists "$DOCS_README" "docs/README.md map exists"
while IFS= read -r docs_readme_target; do
    [ -n "$docs_readme_target" ] || continue
    doc_name="$(basename "$docs_readme_target")"
    [ "$doc_name" = "README.md" ] && continue
    if [ -f "$DOCS_README" ] && grep -Fq -- "$doc_name" "$DOCS_README"; then
        test_pass "docs/README.md links $doc_name"
    else
        test_fail "docs/README.md links $doc_name"
    fi
done < <(find "$BASE_DIR/docs" -maxdepth 1 -type f -name '*.md' | sort)

all_docs="$README $BASE_DIR/docs/lifecycle.md $CONFIG_DOC $BASE_DIR/docs/guest.md $BASE_DIR/docs/troubleshooting.md $BASE_DIR/docs/release-maintenance.md $BASE_DIR/docs/qnap-runbook.md"
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
for pair in 'DX_CONTAINER_NAME|dx-host' 'DX_IMAGE|dx-nixos-26.05' 'DX_SSH_PORT|2222' 'DX_NIX_VOLUME|dx-nix' 'DX_NIX_DISK_SIZE|64G' 'DX_PERSIST_VOLUME|dx-persist' 'DX_BOOTSTRAP_VOLUME|dx-bootstrap' 'DX_CONTAINER_MEMORY|12G' 'DX_CONTAINER_CPUS|4'; do
    name=${pair%%|*}; value=${pair#*|}
    if grep -F -- "$name" "$CONFIG_DOC" | stdin_matches -F -- "$value"; then test_pass "$name documented default matches registry"; else test_fail "$name documented default matches registry"; fi
done

# Fable A5's refactor / Muse C2: docs/gen-config-table.sh prints the
# defaults table straight from bin/lib/dx-config.sh's own
# DXE_CONFIG_REGISTRY, so the two can never drift apart. Extract the
# committed "### Generated defaults reference" table the same way the
# plans.md/reviews sections above walk this file line by line, and assert
# it is byte-identical to the generator's current output.
GENERATED_CONFIG_TABLE="$(bash "$BASE_DIR/docs/gen-config-table.sh")"
committed_config_table=""
in_generated_config_table=0
while IFS= read -r config_doc_line; do
    case "$config_doc_line" in
        '### Generated defaults reference') in_generated_config_table=1; continue ;;
        '### '*) in_generated_config_table=0 ;;
    esac
    [ "$in_generated_config_table" -eq 1 ] || continue
    case "$config_doc_line" in
        '|'*) committed_config_table="$committed_config_table$config_doc_line
" ;;
    esac
done < "$CONFIG_DOC"
committed_config_table=${committed_config_table%$'\n'}
if [ "$committed_config_table" = "$GENERATED_CONFIG_TABLE" ]; then
    test_pass "docs/configuration.md's generated defaults table matches docs/gen-config-table.sh"
else
    test_fail "docs/configuration.md's generated defaults table matches docs/gen-config-table.sh"
fi

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
# Branch 7 (test/herdr-acceptance) live-verified this exact claim on dx-test:
# a pane's shell PID (from `herdr pane process-info`) answers `kill -0`
# before `herdr server stop` and fails ("No such process") immediately after.
# Pin the precise wording so it cannot drift into overclaiming that a cold
# stop "preserves" or "migrates" pane processes -- it does neither.
assert_file_contains_literal "$GUEST_DOC" 'anything running in an attached pane is terminated, not preserved or migrated' "history cleanup's cold-stop claim matches its live-verified effect on pane processes exactly (Branch 7)"
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
# the host and it has to name the volume boundary. Resetting dx-nix costs a
# store rebuild; reaching for dx-factory-reset instead destroys /persist and
# with it the home directory. Pin both, the way the Base Image Changeover
# procedure above is pinned. Branch 12 (store-trust-plan.md) replaced the raw
# "container volume delete dx-nix" instruction with the safe, runtime-neutral
# ./bin/dx-reset-nix-volume (label-checked under docker-ssh, refuses while a
# container still exists or the runtime reports the volume in use) -- pin
# that command name instead of the raw one it superseded.
TROUBLESHOOTING="$BASE_DIR/docs/troubleshooting.md"
assert_file_contains_literal "$TROUBLESHOOTING" 'dx-bootstrap-essentials' "troubleshooting docs identify the missing-toolchain boot failure"
assert_file_contains_literal "$TROUBLESHOOTING" 'dx-reset-nix-volume' "troubleshooting docs give the store-only recovery command"
assert_file_contains "$TROUBLESHOOTING" 'dx-factory-reset' "troubleshooting docs warn which reset also destroys /persist"
assert_file_contains "$TROUBLESHOOTING" 'dx-wait-ssh' "troubleshooting docs cover a healthy boot reported as a failure"
assert_file_contains_literal "$TROUBLESHOOTING" 'banner exchange' "troubleshooting docs cover a host too loaded to complete the SSH banner exchange"
assert_file_contains_literal "$TROUBLESHOOTING" 'tmutil addexclusion' "troubleshooting docs give the backup-exclusion fix for the container volumes"

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
