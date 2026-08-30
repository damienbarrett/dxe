#!/bin/bash
# Mechanical audit of a flake.lock diff against a strict allowlist.
#
# A "stable inputs refresh only" claim about a flake.lock change is not
# trustworthy as prose -- it must be proven against the two JSON documents.
# This script proves it: it fails closed on any change outside the exact
# shape a pin-only refresh produces (locked.lastModified/narHash/rev moving
# on a fixed set of input nodes, nothing else) and prints every violation it
# finds rather than stopping at the first.
#
# Usage: audit-flake-lock.sh <base-lock-file> <candidate-lock-file>

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $(basename "$0") <base-lock-file> <candidate-lock-file>" >&2
    exit 2
fi

BASE="$1"
CANDIDATE="$2"

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }
[ -f "$BASE" ] || { echo "Error: base lock file not found: $BASE" >&2; exit 1; }
[ -f "$CANDIDATE" ] || { echo "Error: candidate lock file not found: $CANDIDATE" >&2; exit 1; }
jq -e . "$BASE" >/dev/null 2>&1 || { echo "Error: base lock file is not valid JSON: $BASE" >&2; exit 1; }
jq -e . "$CANDIDATE" >/dev/null 2>&1 || { echo "Error: candidate lock file is not valid JSON: $CANDIDATE" >&2; exit 1; }

# The four input names a stable pin refresh is allowed to move. Node keys are
# derived from the actual files below rather than assumed to equal this list
# -- a real key that does not match one of these bare names (e.g. a
# collision-suffixed "nixpkgs_2") is reported explicitly instead of silently
# skipped.
ALLOWED_CHANGE_NODES="nixpkgs home-manager nixvim flake-parts"

OVERALL_STATUS=0

# $1: assertion label. $2: detail (may be empty).
report_pass() { printf '[PASS] %s\n' "$1"; }
report_fail() {
    printf '[FAIL] %s\n' "$1"
    [ -z "${2:-}" ] || printf '       %s\n' "$2"
    OVERALL_STATUS=1
}

# True if $1 is a member of the whitespace-separated list in $2. A plain for
# loop is used rather than a `case " $2 "` scan because callers pass both
# space-separated lists (e.g. ALLOWED_CHANGE_NODES) and newline-separated
# ones (e.g. BASE_NODE_KEYS, kept newline-separated so `comm` can consume
# them directly for assertion 2) -- word splitting treats both alike.
list_contains() {
    local needle="$1" item
    for item in $2; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# --- gather shared facts -----------------------------------------------

BASE_VERSION="$(jq -r '.version' "$BASE")"
CANDIDATE_VERSION="$(jq -r '.version' "$CANDIDATE")"

BASE_NODE_KEYS="$(jq -r '.nodes | keys[]' "$BASE" | sort)"
CANDIDATE_NODE_KEYS="$(jq -r '.nodes | keys[]' "$CANDIDATE" | sort)"
ALL_NODE_KEYS="$(printf '%s\n%s\n' "$BASE_NODE_KEYS" "$CANDIDATE_NODE_KEYS" | sort -u)"

BASE_ROOT_NAME="$(jq -r '.root' "$BASE")"
CANDIDATE_ROOT_NAME="$(jq -r '.root' "$CANDIDATE")"

# --- assertion 1: top-level version field ------------------------------

if [ "$BASE_VERSION" = "$CANDIDATE_VERSION" ]; then
    report_pass "1. top-level version unchanged ($BASE_VERSION)"
else
    report_fail "1. top-level version unchanged" "base=$BASE_VERSION candidate=$CANDIDATE_VERSION"
fi

# --- assertion 2: node name set identical -------------------------------

if [ "$BASE_NODE_KEYS" = "$CANDIDATE_NODE_KEYS" ]; then
    report_pass "2. node name set identical ($(echo "$BASE_NODE_KEYS" | wc -l | tr -d ' ') nodes)"
else
    ADDED="$(comm -13 <(printf '%s\n' "$BASE_NODE_KEYS") <(printf '%s\n' "$CANDIDATE_NODE_KEYS") | tr '\n' ' ')"
    REMOVED="$(comm -23 <(printf '%s\n' "$BASE_NODE_KEYS") <(printf '%s\n' "$CANDIDATE_NODE_KEYS") | tr '\n' ' ')"
    report_fail "2. node name set identical" "added=[$ADDED] removed=[$REMOVED]"
fi

# --- assertion 3: root node unchanged in its entirety -------------------

if [ "$BASE_ROOT_NAME" != "$CANDIDATE_ROOT_NAME" ]; then
    report_fail "3. root node unchanged" "root pointer changed: base=$BASE_ROOT_NAME candidate=$CANDIDATE_ROOT_NAME"
else
    BASE_ROOT_JSON="$(jq -S --arg n "$BASE_ROOT_NAME" '.nodes[$n] // null' "$BASE")"
    CANDIDATE_ROOT_JSON="$(jq -S --arg n "$CANDIDATE_ROOT_NAME" '.nodes[$n] // null' "$CANDIDATE")"
    if [ "$BASE_ROOT_JSON" = "$CANDIDATE_ROOT_JSON" ]; then
        report_pass "3. root node ('$BASE_ROOT_NAME') unchanged in its entirety"
    else
        report_fail "3. root node unchanged in its entirety" "nodes[\"$BASE_ROOT_NAME\"] differs between base and candidate"
    fi
fi

# --- assertions 4 & 5: per-node inputs and original objects -------------

INPUTS_VIOLATIONS=""
ORIGINAL_VIOLATIONS=""
for name in $ALL_NODE_KEYS; do
    b_inputs="$(jq -S --arg n "$name" '.nodes[$n].inputs // null' "$BASE")"
    c_inputs="$(jq -S --arg n "$name" '.nodes[$n].inputs // null' "$CANDIDATE")"
    [ "$b_inputs" = "$c_inputs" ] || INPUTS_VIOLATIONS="$INPUTS_VIOLATIONS $name"

    b_original="$(jq -S --arg n "$name" '.nodes[$n].original // null' "$BASE")"
    c_original="$(jq -S --arg n "$name" '.nodes[$n].original // null' "$CANDIDATE")"
    [ "$b_original" = "$c_original" ] || ORIGINAL_VIOLATIONS="$ORIGINAL_VIOLATIONS $name"
done

if [ -z "$INPUTS_VIOLATIONS" ]; then
    report_pass "4. inputs edges (incl. follows) unchanged on every node"
else
    report_fail "4. inputs edges (incl. follows) unchanged on every node" "changed on:$INPUTS_VIOLATIONS"
fi

if [ -z "$ORIGINAL_VIOLATIONS" ]; then
    report_pass "5. original object unchanged on every node"
else
    report_fail "5. original object unchanged on every node" "changed on:$ORIGINAL_VIOLATIONS"
fi

# --- assertion 6: locked.{lastModified,narHash,rev} only, allowlisted only

# Surface a canonical name that is not an actual key in this lock -- that is
# a sign the allowlist above no longer matches the flake's real input names
# (e.g. a collision-suffixed node), and the allowlist would then be silently
# failing to cover the node it was meant to describe.
for name in $ALLOWED_CHANGE_NODES; do
    if ! list_contains "$name" "$BASE_NODE_KEYS"; then
        echo "NOTICE: allowlisted node name '$name' is not an actual node key in this lock; real keys are: $BASE_NODE_KEYS"
    fi
done

UNEXPECTED_NODE_CHANGES=""
FIELD_SCOPE_VIOLATIONS=""
CHANGED_ALLOWED_NODES=""
for name in $ALL_NODE_KEYS; do
    b_node="$(jq -S --arg n "$name" '.nodes[$n] // null' "$BASE")"
    c_node="$(jq -S --arg n "$name" '.nodes[$n] // null' "$CANDIDATE")"
    [ "$b_node" = "$c_node" ] && continue

    if ! list_contains "$name" "$ALLOWED_CHANGE_NODES"; then
        UNEXPECTED_NODE_CHANGES="$UNEXPECTED_NODE_CHANGES $name"
        continue
    fi

    # Neutralize the three fields a pin refresh is allowed to move on the
    # candidate side, then require the result to equal the base node
    # exactly. Anything left different -- another locked.* field (type,
    # owner, repo, ...), inputs, or original -- fails this node.
    normalized_candidate="$(jq -S --arg n "$name" --argjson b "$b_node" '
        .nodes[$n]
        | .locked.lastModified = $b.locked.lastModified
        | .locked.narHash      = $b.locked.narHash
        | .locked.rev          = $b.locked.rev
    ' "$CANDIDATE")"

    if [ "$normalized_candidate" = "$b_node" ]; then
        CHANGED_ALLOWED_NODES="$CHANGED_ALLOWED_NODES $name"
    else
        FIELD_SCOPE_VIOLATIONS="$FIELD_SCOPE_VIOLATIONS $name"
    fi
done

if [ -z "$UNEXPECTED_NODE_CHANGES" ] && [ -z "$FIELD_SCOPE_VIOLATIONS" ]; then
    if [ -z "$CHANGED_ALLOWED_NODES" ]; then
        report_pass "6. no node changed outside {locked.lastModified,locked.narHash,locked.rev} on {$ALLOWED_CHANGE_NODES} (no nodes changed at all)"
    else
        report_pass "6. only locked.{lastModified,narHash,rev} changed, only on:$CHANGED_ALLOWED_NODES"
    fi
else
    detail=""
    [ -z "$UNEXPECTED_NODE_CHANGES" ] || detail="node(s) outside the allowlist changed:$UNEXPECTED_NODE_CHANGES"
    if [ -n "$FIELD_SCOPE_VIOLATIONS" ]; then
        [ -z "$detail" ] || detail="$detail; "
        detail="${detail}allowlisted node(s) changed outside locked.{lastModified,narHash,rev}:$FIELD_SCOPE_VIOLATIONS"
    fi
    report_fail "6. only locked.{lastModified,narHash,rev} changed, only on allowlisted nodes" "$detail"
fi

# --- assertion 7: nixpkgs-unstable and systems byte-for-byte identical --

for name in nixpkgs-unstable systems; do
    if ! list_contains "$name" "$BASE_NODE_KEYS"; then
        report_fail "7. node '$name' byte-for-byte identical" "node '$name' is not present in the base lock"
        continue
    fi
    # -c (compact) with jq's default key order preserves the source's own
    # field ordering rather than imposing one, so equal output here means
    # equal content, not merely equal after reformatting.
    b_bytes="$(jq -c --arg n "$name" '.nodes[$n]' "$BASE")"
    c_bytes="$(jq -c --arg n "$name" '.nodes[$n]' "$CANDIDATE")"
    if [ "$b_bytes" = "$c_bytes" ]; then
        report_pass "7. node '$name' byte-for-byte identical"
    else
        report_fail "7. node '$name' byte-for-byte identical" "nodes[\"$name\"] differs between base and candidate"
    fi
done

# --- evidence: full rev/narHash/lastModified for each changed node ------

if [ "$OVERALL_STATUS" -eq 0 ]; then
    echo ""
    echo "=== Audit record: locked pin changes ==="
    for name in $ALLOWED_CHANGE_NODES; do
        list_contains "$name" "$CHANGED_ALLOWED_NODES" || continue
        b_rev="$(jq -r --arg n "$name" '.nodes[$n].locked.rev' "$BASE")"
        c_rev="$(jq -r --arg n "$name" '.nodes[$n].locked.rev' "$CANDIDATE")"
        b_hash="$(jq -r --arg n "$name" '.nodes[$n].locked.narHash' "$BASE")"
        c_hash="$(jq -r --arg n "$name" '.nodes[$n].locked.narHash' "$CANDIDATE")"
        b_modified="$(jq -r --arg n "$name" '.nodes[$n].locked.lastModified' "$BASE")"
        c_modified="$(jq -r --arg n "$name" '.nodes[$n].locked.lastModified' "$CANDIDATE")"
        echo ""
        echo "node: $name"
        echo "  rev:          $b_rev -> $c_rev"
        echo "  narHash:      $b_hash -> $c_hash"
        echo "  lastModified: $b_modified -> $c_modified"
    done
fi

echo ""
if [ "$OVERALL_STATUS" -eq 0 ]; then
    echo "AUDIT: PASS -- flake.lock change is confined to a stable inputs refresh."
else
    echo "AUDIT: FAIL -- flake.lock change is not confined to a stable inputs refresh."
fi

exit "$OVERALL_STATUS"
