#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
# WP8.4b (Fable D7): a reviewed home for source-text ("boundary-audit-style")
# contracts that were previously scattered across the suite. D7 counted 388
# assert_file_contains-family calls out of ~1,801 assertions (21.5%) and
# split them: roughly half target .nix/docs/Containerfile (legitimate
# contracts that stay where they are) and half target executable shell.
# This file gathers the latter half that survive review as genuine
# architectural audits -- a fixed pattern that must (or must not) appear in
# a specific production file, with no behavioural drive path available at
# unit tier -- so a source-text assertion is a deliberate, catalogued
# decision instead of incidental parsing. tests/test_runtime_boundary_
# audit.sh is NOT gathered here: it already proves its own detector
# red/green on fixtures before it scans, which is its own self-contained
# contract, not a plain grep-shaped assertion.
#
# Every assertion below already existed elsewhere, under this exact label
# (or, for the two clusters ported from test_refactor_contracts.sh's
# `check`/`reject` idiom, this exact command line). Moving it here changed
# nothing about what it tests -- only where it lives -- and each block below
# names its origin file so the move is traceable. `# coverage: no`: these
# are audits of already-covered production text, not new exercise of it, so
# tests/run-coverage-contracts.sh's `# tier: unit` + `# coverage: yes` sweep
# does not need to run this file under kcov.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Source-Text Contracts (Fable D7)"

# check/reject -- a thin bridge that keeps test_refactor_contracts.sh's own
# `check CMD ARGS...` invocation shape (so the two clusters ported from that
# file below are byte-for-byte the same call), while recording through this
# file's own shared harness (test_pass/test_fail, and so print_summary/
# exit_with_code and tests/lib/harness.sh's results file) instead of
# reviving that file's separate, disconnected `failures` counter. The label
# is "$*" with embedded newlines collapsed to spaces -- a couple of the
# ported calls pass a multi-line variable (e.g. the whole bootstrapEssentials
# list) as an argument, and every other label in this file is one line.
check() {
    local label="$*"
    label="${label//$'\n'/ }"
    if "$@"; then test_pass "$label"; else test_fail "$label"; fi
}
reject() { ! "$@"; }

# ===========================================================================
# From tests/test_section0_lint.sh (Fable D7 "keep": CI-literal checks).
# Asserts the CI workflow text directly, so the contract holds even on a
# developer host with no ShellCheck installed -- exactly the host that
# cannot otherwise notice a broken lint gate.
# ===========================================================================
WORKFLOW="$BASE_DIR/.github/workflows/ci.yml"
assert_file_exists "$WORKFLOW" "CI workflow exists"

# ShellCheck must stay pinned. 0.11.0 aborts with "Non-exhaustive patterns in
# checkCmd" on x="$(source f)", the construct test_refactor_contracts.sh uses
# to prove libraries are import-pure, so taking whatever the runner image
# ships turns a mandatory gate into a version lottery.
assert_file_not_contains "$WORKFLOW" 'apt-get install -y shellcheck' "CI does not take ShellCheck from the runner image"
assert_file_contains_literal "$WORKFLOW" 'nixpkgs/${NIXPKGS_PIN}#shellcheck' "CI runs a pinned ShellCheck"
assert_file_contains "$WORKFLOW" 'NIXPKGS_PIN: nixos-' "CI records the ShellCheck pin"

# Every gate the validation matrix calls CI-required must be present. A
# dropped step would otherwise leave CI green while enforcing less than it
# claims.
for required in \
    'bash -n' \
    'tests/run_all_tests.sh --skip-integration' \
    'tests/run-coverage-linux.sh' \
    'nix flake check --no-build --no-write-lock-file --all-systems' \
    'tests/run-bash32-tests.sh'
do
    assert_file_contains_literal "$WORKFLOW" "$required" "CI enforces: $required"
done

# ===========================================================================
# From tests/test_section2_containerfile.sh (Fable D7 "keep": the
# single-FROM-line contract).
# ===========================================================================

# Test: Containerfile is only the base image selection
if [ "$(grep -cve '^[[:space:]]*$' "$CONTAINERFILE")" -eq 1 ]; then
    test_pass "Containerfile only selects the base image"
else
    test_fail "Containerfile only selects the base image"
fi

# Test: Containerfile's single non-blank line is EXACTLY the adopted
# official base reference. This is a fixed-
# string, full-line equality check, not a pattern through
# assert_file_contains (that helper runs plain `grep -q`, i.e. BASIC
# regular expressions - an ERE like `+`/`{64}` could never match a
# sha256 digest through it). One string comparison is sufficient to
# catch every corruption mode: a wrong tag, a changed digest, a
# digest-only reference (no tag), `latest`, an extra instruction line,
# and an extra non-blank line all produce a captured value that differs
# from the expected line below (the extra-line case also already fails
# the one-non-blank-line check above, and is captured here as well
# since `$(...)` would embed a newline that cannot equal the single-line
# expectation).
DX_EXPECTED_CONTAINERFILE_LINE="FROM nixos/nix:2.34.7@sha256:bf1d938835ab96312f098fa6c2e9cab367728e0aad0646ee3e02a787c80d8fb8"
actual_containerfile_line="$(grep -ve '^[[:space:]]*$' "$CONTAINERFILE")"
if [ "$actual_containerfile_line" = "$DX_EXPECTED_CONTAINERFILE_LINE" ]; then
    test_pass "Containerfile's non-blank line exactly matches the adopted official base reference"
else
    test_fail "Containerfile's non-blank line exactly matches the adopted official base reference (got: '$actual_containerfile_line')"
fi

# ===========================================================================
# From tests/test_section9_host_scripts.sh and
# tests/test_section18_mount_git.sh (Fable D7 "keep": the "no production
# test seam" checks -- production entrypoints must never grow a
# DX_*_TEST_MODE branch that only a test would ever set).
# ===========================================================================
MOUNT="$BASE_DIR/bin/dx-mount"
assert_file_not_contains "$BASE_DIR/bin/dx-forward" 'DX_FORWARD_TEST_MODE' "forward has no production test seam"
assert_file_not_contains "$BASE_DIR/bin/dx-reverse" 'DX_REVERSE_TEST_MODE' "reverse has no production test seam"
assert_file_not_contains "$MOUNT" 'DX_MOUNT_TEST_MODE' "dx-mount has no production test seam"

# ===========================================================================
# From tests/test_refactor_contracts.sh (Fable D7 "keep": the
# bootstrapEssentials/DX_AI_TOOLS/aiPackages ties). ROOT/container_dir are
# that file's own names for $BASE_DIR/$CONTAINER_DIR, kept as-is so the two
# clusters below are otherwise byte-for-byte what they were.
# ===========================================================================
ROOT="$BASE_DIR"
container_dir="$CONTAINER_DIR"

# --- F13 contract: DX_AI_TOOLS is no longer just an inventory to keep tidy,
# it is load-bearing. dx_ai_validate_generation requires an executable of that
# name in every published generation's profile, and dx_ai_verify runs
# `command -v` over the same list, so a name added there without a matching
# package in flake.nix's aiPackages makes *every* generation fail validation
# and every dx-ai run fail at verification. That is a worse failure mode than
# the cosmetic duplication F13 described, and nothing tied the two together.
#
# The two lists cannot be compared verbatim -- these are binary names, not Nix
# attribute names (`claude` ships in `claude-code`; gemini-cli was the same
# kind of mismatch before findings.md's 2026-09-30 user decision dropped it).
# The contract asserted is the one that catches the real mistake: every tool
# dx-ai will demand has *some* package whose attribute name starts with it.
declared_tools="$(sed -n 's/^DX_AI_TOOLS="\(.*\)"$/\1/p' "$container_dir/scripts/dx-ai.sh")"
check test -n "$declared_tools"
ai_packages="$(sed -n '/aiPackages = /,/^[[:space:]]*\];$/p' "$container_dir/flake.nix" | sed -n 's/^[[:space:]]*\([A-Za-z][A-Za-z0-9_.-]*\)$/\1/p')"
has_package_for() {
    local tool="$1" package
    for package in $ai_packages; do
        case "${package#pkgs.}" in "$tool"|"$tool"-*) return 0 ;; esac
    done
    return 1
}
for tool in $declared_tools; do
    check has_package_for "$tool"
done

# The user-facing install message in bin/dx-herdr names the bundle's contents.
# It is the one copy of the inventory a user actually reads before waiting
# ~2 minutes for an install, so it must not drift from what is installed.
herdr_message_tools="$(sed -n 's/.*Installing optional AI tools bundle (\([^)]*\)).*/\1/p' "$ROOT/bin/dx-herdr" | tr -d ',')"
check test "$herdr_message_tools" = "$declared_tools"

# --- The bootstrap essentials closure is the guest's entire pre-sshd
# dependency set, and since it moved out of the bootstrap scripts into
# flake.nix's `bootstrapEssentials` it is declared in exactly one place.
# A tidy-up of that list ("coreutils surely provides tar") has nothing else
# standing between it and a guest that dies before sshd -- the failure class
# this whole change exists to prevent.
#
# The binary -> nixpkgs attribute mapping is the part that is easy to get
# wrong: tar is gnutar, useradd is shadow, mkfs.btrfs is btrfs-progs. Assert
# it in both directions -- the providing package is still declared, and the
# binary is still genuinely invoked by bootstrap -- so a stale entry here gets
# reported rather than left silently guarding nothing.
#
# Packages in the list that bootstrap never invokes (gzip, procps, which,
# sudo) are deliberately not asserted: they serve the dx user's shell after
# boot rather than bootstrap itself.
bootstrap_essentials="$(sed -n '/bootstrapEssentials = /,/^[[:space:]]*\];$/p' "$container_dir/flake.nix" | sed -n 's/^[[:space:]]*\([A-Za-z][A-Za-z0-9_.-]*\)$/\1/p')"
check test -n "$bootstrap_essentials"
bootstrap_sources=("$container_dir/bootstrap.sh" "$container_dir"/bootstrap/*.sh)
# Full-line comments are stripped so a binary named only in prose cannot stand
# in for a real invocation. `-Fw` rather than an anchored ERE: word-matching a
# fixed string is exactly the intent, and it avoids the `(^|[^[:alnum:]...])`
# construct that some grep builds (ugrep) silently fail to match.
#
# The stripped text is materialized once and matched from a herestring rather
# than piped: `grep -q` exits at the first match, and under `set -o pipefail`
# the resulting EPIPE in the upstream `sed` would fail every *successful*
# lookup -- the same SIGPIPE-under-pipefail defect
# tests/test_refactor_contracts.sh's own scan_leaking_overrides comment
# describes (encountered independently while developing that detector).
bootstrap_source_text="$(sed 's/^[[:space:]]*#.*//' "${bootstrap_sources[@]}")"
bootstrap_invokes() { grep -Fqw "$1" <<<"$bootstrap_source_text"; }
bootstrap_declares() {
    local declared
    for declared in $bootstrap_essentials; do
        [ "$declared" = "$1" ] && return 0
    done
    return 1
}
for pair in useradd:shadow groupadd:shadow usermod:shadow ssh-keygen:openssh \
    sshd:openssh tar:gnutar mount:util-linux sed:gnused grep:gnugrep \
    chown:coreutils mktemp:coreutils stat:coreutils mkfs.btrfs:btrfs-progs \
    mkfs.ext4:e2fsprogs bash:bashInteractive; do
    check bootstrap_declares "${pair##*:}"
    check bootstrap_invokes "${pair%%:*}"
done

# --- Branch 16: bootstrap keeps no keyring knowledge at all. The guest
# keyring (D-Bus session bus + gnome-keyring Secret Service, used only by
# agy) is owned entirely by dx-ai and the explicit dx-keyring command
# (scripts/lib/dx-keyring.sh, scripts/dx-ai.sh, scripts/dx-keyring.sh).
# A plain substring grep, not bootstrap_invokes's `-Fw` word-matching: the
# retired identifiers (dx_resolve_keyring_bin, setup_keyring_service) embed
# "keyring"/"dbus" inside one underscore-joined token, which word-boundary
# matching would not catch as a substring.
check test -z "$(grep -i 'keyring\|dbus' <<<"$bootstrap_source_text")"

# ===========================================================================
# From tests/test_section3_bootstrap.sh: boundary-audit-style checks over
# bootstrap.sh/bootstrap/*.sh that pin the orchestrator's own structure and
# a set of "must never recur" safety regressions (an old-base guard, a raw
# recursive chown, a production test-mode branch). None has a fake in that
# file driving the ORCHESTRATOR itself (as opposed to the individual guest
# functions the six "Bootstrap phase: ... completed in Ns" cases already
# drive behaviourally, right beside where these used to sit) -- verifying
# "sources X", "the last line execs sshd", or "never calls chown -R
# dx:dx <path> outside dx_ensure_tree_owner" would mean running
# bootstrap_main (or configure_guest/setup_persist/create_user) fully,
# end to end, which is a materially larger fixture than this move.
# ===========================================================================
BOOTSTRAP_DIR="$CONTAINER_DIR/bootstrap"
assert_file_contains_literal "$BOOTSTRAP" 'source "$DX_BOOTSTRAP_ROOT/scripts/lib/dx-guest-system.sh"' "bootstrap sources the shared guest-system helper"
assert_file_not_contains "$BOOTSTRAP_DIR/system.sh" 'guard_old_base' "guest bootstrap no longer defines the old-base guard (removed once every guest moved off the old base -- docs/refactor/migration-gates.md#old-base-guards)"
assert_file_not_contains "$BOOTSTRAP" 'guard_old_base' "bootstrap orchestrator no longer calls the old-base guard"
assert_file_contains_literal "$BOOTSTRAP" 'if [ "${BASH_SOURCE[0]}" = "$0" ]' "bootstrap main runs only when executed"
assert_file_not_contains "$BOOTSTRAP" 'DX_BOOTSTRAP_TEST_MODE' "bootstrap has no production test-mode branch"
assert_file_not_contains "$BOOTSTRAP_DIR/activation.sh" 'chown -R dx:dx /guest-bootstrap' "bootstrap never hands published payload ownership to dx"
assert_file_not_contains "$BOOTSTRAP_DIR/activation.sh" 'chown -R dx:dx /home/dx' "normal activation does not recursively re-own the home tree"
assert_file_not_contains "$BOOTSTRAP_DIR/activation.sh" 'chown -R dx:dx /persist/home/dx' "normal activation does not recursively re-own persisted AI state"
assert_file_not_contains "$BOOTSTRAP_DIR/activation.sh" 'chown -R dx:dx /nix' "normal activation does not recursively re-own a validated Nix volume"
assert_file_not_contains "$BOOTSTRAP_DIR/system.sh" 'chown -R dx:dx /home/dx/.ssh' "SSH setup does not recursively re-own existing user SSH contents"
assert_file_not_contains "$BOOTSTRAP_DIR/persistence.sh" 'chown -R dx:dx /persist/home/dx' "persistence setup does not recursively re-own persisted home on every boot"
assert_file_contains_literal "$BOOTSTRAP_DIR/persistence.sh" 'dx_ensure_tree_owner' "persisted-tree ownership uses a marker-guarded migration helper"
assert_file_contains_literal "$BOOTSTRAP_DIR/activation.sh" 'dx_ensure_tree_owner' "activation uses bounded ownership checks for mutable roots"
assert_file_contains_literal "$BOOTSTRAP_DIR/activation.sh" 'dx_activate_herdr || echo "Warning: Herdr activation failed; continuing bootstrap without it." >&2' "Herdr persistence and config seeding are non-fatal bootstrap activation steps"
assert_file_contains_literal "$BOOTSTRAP" 'configure_guest true' "validated Nix imports pass content validation only from bootstrap into guest setup"
assert_file_not_contains "$BOOTSTRAP" 'DX_NIX_VOLUME_PHASE' "bootstrap uses explicit Nix volume lifecycle seams"
assert_file_not_contains "$BOOTSTRAP" 'DX_NIX_OWNERSHIP_CONTENT_VALIDATED' "bootstrap does not export ownership steering state"
assert_file_contains_literal "$BOOTSTRAP_DIR/common.sh" '"$bootstrap_root#bootstrap-essentials" --no-update-lock-file' "essentials install uses the checked-in locked bootstrap output"
assert_file_not_contains "$BOOTSTRAP_DIR/common.sh" 'nixpkgs#' "essentials install does not resolve the global flake registry"
assert_file_contains_literal "$BOOTSTRAP" 'exec "$(command -v sshd)" -D -e -p 2222' "foreground sshd remains the final bootstrap action"

# ===========================================================================
# From tests/test_section6_tools.sh: two "must never recur" safety checks on
# the guest dx-ai entrypoint (which, per Fable A4/B7, executes unconditionally
# on source and so has no in-file seam to drive it as a function), and two
# checks that a specific bootstrap file prepares a specific persisted
# directory -- also entrypoint/orchestrator text with no local fake in that
# file (setup_tmux_persistence/configure_guest are not sourced there).
# ===========================================================================
DX_AI_SCRIPT="$CONTAINER_DIR/scripts/dx-ai.sh"
assert_file_contains "$CONTAINER_DIR/bootstrap/persistence.sh" "/persist/home/dx/.local/share/tmux/resurrect" "bootstrap creates the persisted resurrect directory"
assert_file_not_contains "$DX_AI_SCRIPT" "sed -i" "guest dx-ai does not rewrite Nix source ranges"
assert_file_not_contains "$DX_AI_SCRIPT" "touch /persist/home/dx/.claude.json" "guest dx-ai does not create empty Claude JSON config"
assert_file_contains "$CONTAINER_DIR/bootstrap/activation.sh" "/persist/home/dx/.gemini/antigravity-cli" "bootstrap prepares persisted agy state directory"

# ===========================================================================
# Fable D8: tests/test_sourceable_coverage.sh runs on `|| true`-guarded
# lines that execute production code (for kcov's percentage) while
# discarding the outcome -- constitution.md's "line coverage proves a line
# ran, not that it ran correctly". Not every `|| true` there is that
# problem: some guard a coreutils/builtin (chmod, kill, wait, unset), a
# local helper the file defines for itself (run_gh_case, run_herdr_case),
# or a command substitution assigned to a variable the file goes on to
# inspect. The ones actually worth ratcheting down are calls to a SCOPE
# function (bin/lib, bootstrap, scripts/lib) whose own outcome is thrown
# away. WP8.4 migrated the config-parser/registry/snapshot cluster of
# these into tests/test_refactor_state_machines.sh with an asserted
# outcome for each (129 -> 117 scope-function `|| true` guards); this
# ratchet keeps that count from silently climbing back up as new probes
# are added, the same "ceiling, not a floor" shape Fable D3 recommends for
# the coverage metric.
#
# The scope-function name set is derived fresh each run, never hand-
# maintained: every column-0 `name() {` definition across the three
# scopes. `^[a-z_]+\(\)` intentionally excludes a name with a digit
# (dx_mount_base64_decode, mkfs.btrfs's own helpers) -- a narrower,
# cheaper net that still catches the large majority and needs no upkeep
# as the scope grows.
dx_wp84_scope_functions() {
    grep -hoE '^[a-z_]+\(\)' \
        "$BASE_DIR"/bin/lib/*.sh \
        "$CONTAINER_DIR"/bootstrap/*.sh \
        "$CONTAINER_DIR"/scripts/lib/*.sh 2>/dev/null \
        | sed 's/()$//' | sort -u
}

# dx_wp84_scope_or_true_count FILE SCOPE_LIST_FILE -- the count of `|| true`
# lines in FILE whose immediate left-hand command (the last ';'-separated
# segment before the trailing `|| true`, stripped of a leading `(`/`{` and
# any `VAR=value` environment-prefix assignments) names a function listed
# in SCOPE_LIST_FILE.
dx_wp84_scope_or_true_count() {
    awk -v scope_file="$2" '
        BEGIN {
            while ((getline fname < scope_file) > 0) { if (fname != "") scope[fname] = 1 }
            close(scope_file)
            matches = 0
        }
        /\|\| true/ {
            line = $0
            tmp = line
            lastidx = 0
            while ((p = index(tmp, "|| true")) > 0) { lastidx += p; tmp = substr(tmp, p + 7) }
            left = substr(line, 1, lastidx - 1)
            n = split(left, segs, ";")
            last = segs[n]
            sub(/^[ \t]+/, "", last)
            while (last ~ /^[({]/) { sub(/^[({]/, "", last); sub(/^[ \t]+/, "", last) }
            while (last ~ /^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/) {
                sub(/^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/, "", last)
            }
            tok = last
            sub(/[ \t(].*$/, "", tok)
            if (tok in scope) matches++
        }
        END { print matches }
    ' "$1"
}

dx_wp84_scope_list="$(mktemp "${TMPDIR:-/tmp}/dxe-wp84-scope.XXXXXX")"
dx_wp84_scope_functions > "$dx_wp84_scope_list"
DX_WP84_SOURCEABLE_COVERAGE="$BASE_DIR/tests/test_sourceable_coverage.sh"
dx_wp84_scope_or_true_ceiling=117
dx_wp84_scope_or_true_actual="$(dx_wp84_scope_or_true_count "$DX_WP84_SOURCEABLE_COVERAGE" "$dx_wp84_scope_list")"
rm -f "$dx_wp84_scope_list"
if [ "$dx_wp84_scope_or_true_actual" -le "$dx_wp84_scope_or_true_ceiling" ]; then
    test_pass "test_sourceable_coverage.sh's scope-function \`|| true\` count ($dx_wp84_scope_or_true_actual) is at or below the ceiling ($dx_wp84_scope_or_true_ceiling)"
else
    test_fail "test_sourceable_coverage.sh's scope-function \`|| true\` count ($dx_wp84_scope_or_true_actual) exceeds the ceiling ($dx_wp84_scope_or_true_ceiling) -- migrate the new probe(s) to a behavioural suite with an asserted outcome instead of raising this number"
fi

print_summary
exit_with_code
