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
# Usage: audit-flake-lock.sh <base-lock-file> <candidate-lock-file> <expected-changed-nodes>
#
# <expected-changed-nodes> is a whitespace-separated list of the flake input
# node names this refresh is claimed to touch (e.g. "nixpkgs home-manager
# nixvim flake-parts"). It is a required argument, not a default, so the
# helper stays reusable for a future refresh with a different node set. The
# changed-node set actually found in the two documents must equal this list
# exactly, not merely be a subset of it (assertion 9) -- a no-op or partial
# refresh must fail rather than pass as if it delivered the full claim.

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $(basename "$0") <base-lock-file> <candidate-lock-file> <expected-changed-nodes>" >&2
    exit 2
fi

BASE="$1"
CANDIDATE="$2"
# The nodes this refresh is claimed to touch. Doubles as the allowlist for
# assertion 6 (nothing outside this set may change) and the requirement for
# assertion 9 (everything in this set must have changed) -- one caller-
# supplied list drives both directions of the check.
ALLOWED_CHANGE_NODES="$3"
[ -n "$ALLOWED_CHANGE_NODES" ] || { echo "Error: expected-changed-nodes must name at least one input node." >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }
[ -f "$BASE" ] || { echo "Error: base lock file not found: $BASE" >&2; exit 1; }
[ -f "$CANDIDATE" ] || { echo "Error: candidate lock file not found: $CANDIDATE" >&2; exit 1; }
jq -e . "$BASE" >/dev/null 2>&1 || { echo "Error: base lock file is not valid JSON: $BASE" >&2; exit 1; }
jq -e . "$CANDIDATE" >/dev/null 2>&1 || { echo "Error: candidate lock file is not valid JSON: $CANDIDATE" >&2; exit 1; }

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

# True if node $1's locked.$2 leaf is present in lock file $3 with JSON type
# $4. `has` is used rather than `// null` so a leaf whose real value happens
# to be JSON null is not mistaken for an absent leaf -- flake.lock never
# stores null there, so treating a present null as missing costs nothing and
# keeps the check honest either way.
locked_leaf_present() {
    local name="$1" field="$2" file="$3" want_type="$4"
    jq -e --arg n "$name" --arg f "$field" --arg t "$want_type" '
        (.nodes[$n].locked // {}) as $locked
        | ($locked | has($f)) and (($locked[$f] | type) == $t)
    ' "$file" >/dev/null
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

    # Prove the three allowed leaves are actually present, with the
    # expected JSON type, on both sides before normalizing them away.
    # Normalizing a leaf that was *deleted* rather than moved would
    # otherwise silently manufacture equality with the base value -- the
    # normalization step would paper over the very deletion it exists to
    # tolerate a legitimate move around.
    leaf_violations=""
    for field_spec in lastModified:number rev:string narHash:string; do
        field="${field_spec%%:*}"
        want_type="${field_spec##*:}"
        locked_leaf_present "$name" "$field" "$BASE" "$want_type" || leaf_violations="$leaf_violations base.locked.$field"
        locked_leaf_present "$name" "$field" "$CANDIDATE" "$want_type" || leaf_violations="$leaf_violations candidate.locked.$field"
    done
    if [ -n "$leaf_violations" ]; then
        FIELD_SCOPE_VIOLATIONS="$FIELD_SCOPE_VIOLATIONS $name(missing:$leaf_violations)"
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

# --- assertion 8: top-level document key set identical -------------------

# None of the assertions above look past `.nodes`, `.root`, and `.version`
# individually -- a wholesale added or removed top-level key (a smuggled
# override block, a stripped field) would pass every one of them untouched.
BASE_TOP_KEYS="$(jq -r 'keys[]' "$BASE" | sort)"
CANDIDATE_TOP_KEYS="$(jq -r 'keys[]' "$CANDIDATE" | sort)"
if [ "$BASE_TOP_KEYS" = "$CANDIDATE_TOP_KEYS" ]; then
    report_pass "8. top-level document key set identical ($(echo "$BASE_TOP_KEYS" | wc -l | tr -d ' ') keys)"
else
    ADDED_TOP="$(comm -13 <(printf '%s\n' "$BASE_TOP_KEYS") <(printf '%s\n' "$CANDIDATE_TOP_KEYS") | tr '\n' ' ')"
    REMOVED_TOP="$(comm -23 <(printf '%s\n' "$BASE_TOP_KEYS") <(printf '%s\n' "$CANDIDATE_TOP_KEYS") | tr '\n' ' ')"
    report_fail "8. top-level document key set identical" "added=[$ADDED_TOP] removed=[$REMOVED_TOP]"
fi

# --- assertion 9: every expected node actually changed --------------------

# Assertion 6 proves the converse of this: every *actual* node change is
# confined to an allowlisted node's locked.{lastModified,narHash,rev}.
# Neither that nor any assertion above requires the changed set to be
# non-empty or complete, so a no-op diff (nothing changed) or a partial
# refresh (only some of the claimed nodes moved) reports the same "no
# violation found" result as a complete, on-claim refresh. This closes that
# gap: every node named in the caller's expected-changed-nodes argument must
# be among the nodes that actually changed.
MISSING_EXPECTED_CHANGES=""
for name in $ALLOWED_CHANGE_NODES; do
    list_contains "$name" "$CHANGED_ALLOWED_NODES" || MISSING_EXPECTED_CHANGES="$MISSING_EXPECTED_CHANGES $name"
done
if [ -z "$MISSING_EXPECTED_CHANGES" ]; then
    report_pass "9. every expected node ({$ALLOWED_CHANGE_NODES}) actually changed"
else
    report_fail "9. every expected node actually changed" "expected but unchanged:$MISSING_EXPECTED_CHANGES"
fi

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
