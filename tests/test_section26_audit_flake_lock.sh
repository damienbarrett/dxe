#!/bin/bash
# Section 26: flake.lock refresh audit (tests/lib/audit-flake-lock.sh)
#
# audit-flake-lock.sh proves a flake.lock diff is confined to a "stable
# inputs refresh" rather than trusting that claim as prose. It landed in
# 59b0494 with only ad hoc manual tampering as its evidence and no durable
# test -- this is that test.
#
# Four fail-opens were found by hand-tampering the real fixtures below and
# are reproduced here as the driving cases: an unchanged pair passes as a
# valid refresh, a partial refresh (only some of the claimed nodes actually
# moved) passes as if it were complete, deleting an allowed leaf from a
# changed node is masked by the very normalization step meant to neutralize
# it, and an added top-level document field is never checked at all.
#
# A fifth claim investigated alongside these four -- that node equality is
# merely structural and ignores key reordering -- did not hold up under
# verification: assertion 6's `jq -S` comparison already treats a reordered
# node as changed (it would fail case 1 below, which requires byte-identical
# input to pass), and assertion 7 is deliberately order-sensitive by design
# (see its own comment). That behavior is exercised implicitly throughout
# and is not touched by the fix below.
#
# Fixtures are the real lock files either side of the pin refresh this
# helper was built to audit -- main's flake.lock (base) and
# bump/lock-refresh's (candidate) -- tampered per case with jq, exactly as
# done by hand during the original investigation. Real fixtures over
# synthetic ones catch anything a hand-built JSON blob would accidentally
# simplify away.
#
# They are checked in under tests/fixtures/audit-flake-lock/ rather than
# read via `git show <sha>:<path>` at run time. The candidate side's commit
# (once 8ff05d8) was a pre-rebase tip: after later rebases it stopped being
# reachable from any ref and survived only in one machine's reflog, so a
# fresh clone, CI, or a `git gc --prune` would have failed this suite with
# no code change at fault. Committing the two files removes the history
# dependency entirely; their SHA-256 is checked below so silent corruption
# of the checked-in bytes still fails loudly. Do not reintroduce the
# `git show` form.
#
# The fix for the first two holes added a required third CLI argument (the
# expected-changed-nodes list) so the audit can require the changed set to
# equal the claim exactly rather than merely be a subset of an allowlist.
# Every call below passes it -- this is a call-site update to the new
# required interface, not a loosening of what each case asserts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 26: flake.lock refresh audit"

AUDIT="$SCRIPT_DIR/lib/audit-flake-lock.sh"
EXPECTED_NODES="nixpkgs home-manager nixvim flake-parts"

FIXTURE_SRC_DIR="$SCRIPT_DIR/fixtures/audit-flake-lock"
FIXTURE_BASE_SRC="$FIXTURE_SRC_DIR/base.lock"
FIXTURE_CAND_SRC="$FIXTURE_SRC_DIR/candidate.lock"
# Verified once when these files were checked in; see the header comment
# for why they are not read via `git show` instead.
FIXTURE_BASE_SHA256="34f29312a2da3447515d68c3c470fda7c63e9a2497c9fc3d1769c4f5f92b8b9b"
FIXTURE_CAND_SHA256="ee4d64dcb658b5e01b1e916965fcc3900a33b3dfaa20da30a0b8995fd4a4b6f9"

# sha256 of a file, on either host: macOS ships shasum, Linux CI ships
# sha256sum, and neither guarantees the other (see bin/lib/dx-container.sh
# for the same fallback pattern used against the store digest).
fixture_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-audit-flake-lock.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

fixture_ok=1
if [ ! -f "$FIXTURE_BASE_SRC" ] || [ ! -f "$FIXTURE_CAND_SRC" ]; then
    fixture_ok=0
else
    base_got_sha256="$(fixture_sha256 "$FIXTURE_BASE_SRC")"
    cand_got_sha256="$(fixture_sha256 "$FIXTURE_CAND_SRC")"
    if [ "$base_got_sha256" != "$FIXTURE_BASE_SHA256" ] || [ "$cand_got_sha256" != "$FIXTURE_CAND_SHA256" ]; then
        fixture_ok=0
    fi
fi

if [ "$fixture_ok" -ne 1 ]; then
    test_fail "checked-in fixtures at $FIXTURE_SRC_DIR exist and match their recorded SHA-256"
    print_summary
    exit_with_code
fi

cp "$FIXTURE_BASE_SRC" "$fixture/base.lock"
cp "$FIXTURE_CAND_SRC" "$fixture/cand.lock"

# Captures both exit status and emitted text: several cases below need to
# know *which* assertion failed, not merely that the run failed.
audit_out=""
audit_status=0
run_audit() {
    audit_out="$("$AUDIT" "$@" 2>&1)"
    audit_status=$?
}

# --- Red case 1: an unmodified pair (no-op refresh) must not pass --------
#
# Reproduces the brief's exact repro: `audit-flake-lock.sh base base`. An
# empty diff is not evidence of *any* refresh, let alone the claimed one.
run_audit "$fixture/base.lock" "$fixture/base.lock" "$EXPECTED_NODES"
if [ "$audit_status" -ne 0 ]; then
    test_pass "an unmodified pair (no-op refresh) is rejected"
else
    test_fail "an unmodified pair (no-op refresh) is rejected (exit 0: $audit_out)"
fi

# --- Red case 2: a partial refresh (3 of 4 claimed nodes reverted) -------
#
# Three of the four genuinely-refreshed nodes are reverted back to their
# base values, leaving only nixpkgs changed. The claim under audit is that
# all four moved; a refresh that actually only touched one of them must not
# pass as if it delivered the claim.
partial="$fixture/partial.lock"
jq --slurpfile b "$fixture/base.lock" '
    .nodes["home-manager"] = $b[0].nodes["home-manager"]
    | .nodes.nixvim         = $b[0].nodes.nixvim
    | .nodes["flake-parts"] = $b[0].nodes["flake-parts"]
' "$fixture/cand.lock" > "$partial"
run_audit "$fixture/base.lock" "$partial" "$EXPECTED_NODES"
if [ "$audit_status" -ne 0 ]; then
    test_pass "a partial refresh (3 of 4 claimed nodes left unchanged) is rejected"
else
    test_fail "a partial refresh (3 of 4 claimed nodes left unchanged) is rejected (exit 0: $audit_out)"
fi

# --- Red case 3: deleting an allowed leaf from a changed node is masked --
#
# nixpkgs.locked.rev is deleted outright on the candidate side (not moved to
# a new value -- removed). The normalization step that neutralizes
# locked.{lastModified,narHash,rev} for comparison must not silently
# manufacture the missing key back from the base value.
delrev="$fixture/delrev.lock"
jq 'del(.nodes.nixpkgs.locked.rev)' "$fixture/cand.lock" > "$delrev"
run_audit "$fixture/base.lock" "$delrev" "$EXPECTED_NODES"
if [ "$audit_status" -ne 0 ]; then
    test_pass "deleting an allowed leaf (nixpkgs.locked.rev) from a changed node is rejected"
else
    test_fail "deleting an allowed leaf (nixpkgs.locked.rev) from a changed node is rejected (exit 0: $audit_out)"
fi

# --- Red case 4: an added top-level document field is unchecked ----------
#
# Nothing in the per-node assertions looks at the document's own key set, so
# a wholesale added field (a real attack shape: e.g. a smuggled override
# block) sails through untouched.
sneaky="$fixture/sneaky.lock"
jq '.sneaky = "payload"' "$fixture/cand.lock" > "$sneaky"
run_audit "$fixture/base.lock" "$sneaky" "$EXPECTED_NODES"
if [ "$audit_status" -ne 0 ]; then
    test_pass "an added top-level document field ('.sneaky') is rejected"
else
    test_fail "an added top-level document field ('.sneaky') is rejected (exit 0: $audit_out)"
fi

# --- existing positive path: the real, complete refresh still passes -----
run_audit "$fixture/base.lock" "$fixture/cand.lock" "$EXPECTED_NODES"
if [ "$audit_status" -eq 0 ]; then
    test_pass "the real, complete four-node refresh passes"
else
    test_fail "the real, complete four-node refresh passes (exit $audit_status: $audit_out)"
fi

# The evidence record must name every claimed node and carry the exact
# base->candidate transition for each of rev, narHash, and lastModified --
# not merely a generic "changed" marker. Expected values are read from the
# fixtures themselves (not hardcoded) so this does not silently drift if the
# pinned commits ever move.
for node in $EXPECTED_NODES; do
    if printf '%s\n' "$audit_out" | stdin_matches -F "node: $node"; then
        test_pass "evidence record names changed node '$node'"
    else
        test_fail "evidence record names changed node '$node'"
    fi

    b_rev="$(jq -r --arg n "$node" '.nodes[$n].locked.rev' "$fixture/base.lock")"
    c_rev="$(jq -r --arg n "$node" '.nodes[$n].locked.rev' "$fixture/cand.lock")"
    if printf '%s\n' "$audit_out" | stdin_matches -F "$b_rev -> $c_rev"; then
        test_pass "evidence record for '$node' carries the full rev transition"
    else
        test_fail "evidence record for '$node' carries the full rev transition"
    fi

    b_hash="$(jq -r --arg n "$node" '.nodes[$n].locked.narHash' "$fixture/base.lock")"
    c_hash="$(jq -r --arg n "$node" '.nodes[$n].locked.narHash' "$fixture/cand.lock")"
    if printf '%s\n' "$audit_out" | stdin_matches -F "$b_hash -> $c_hash"; then
        test_pass "evidence record for '$node' carries the full narHash transition"
    else
        test_fail "evidence record for '$node' carries the full narHash transition"
    fi

    b_mod="$(jq -r --arg n "$node" '.nodes[$n].locked.lastModified' "$fixture/base.lock")"
    c_mod="$(jq -r --arg n "$node" '.nodes[$n].locked.lastModified' "$fixture/cand.lock")"
    if printf '%s\n' "$audit_out" | stdin_matches -F "$b_mod -> $c_mod"; then
        test_pass "evidence record for '$node' carries the full lastModified transition"
    else
        test_fail "evidence record for '$node' carries the full lastModified transition"
    fi
done

print_summary
exit_with_code
