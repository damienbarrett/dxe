#!/bin/bash
# Section 5: Pin Nix Inputs
# Tests for: flake.lock exists, inputs pinned

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "Section 5: Pin Nix Inputs"

# Test: flake.lock exists
assert_file_exists "$FLAKE_LOCK" "flake.lock exists"

# Test: flake.lock is not ignored by git
if git -C "$BASE_DIR" check-ignore "$FLAKE_LOCK" >/dev/null 2>&1; then
    test_fail "flake.lock is ignored by git"
else
    test_pass "flake.lock is not ignored by git"
fi

# Test: nixpkgs is pinned to exact revision in flake.lock
if [ -f "$FLAKE_LOCK" ]; then
    assert_file_contains "$FLAKE_LOCK" '"nixpkgs"' "nixpkgs entry in flake.lock"
    assert_file_contains "$FLAKE_LOCK" '"rev"' "nixpkgs has revision pinned"
else
    test_skip "flake.lock not found, skipping rev check"
fi

# Test: nixvim is pinned to exact revision in flake.lock
if [ -f "$FLAKE_LOCK" ]; then
    assert_file_contains "$FLAKE_LOCK" '"nixvim"' "nixvim entry in flake.lock"
else
    test_skip "flake.lock not found, skipping nixvim check"
fi

# Test: flake.nix references the expected NixOS branch
assert_file_contains "$FLAKE_NIX" "$DX_EXPECTED_NIXOS_BRANCH" "flake.nix uses $DX_EXPECTED_NIXOS_BRANCH"

# Test: bash syntax check for flake.nix (if nix is available)
if command -v nix >/dev/null 2>&1; then
    if nix flake check --no-build --no-write-lock-file --all-systems "$CONTAINER_DIR" 2>/dev/null; then
        test_pass "nix flake evaluation passes"
    else
        test_fail "nix flake evaluation passes"
    fi

    # WP2.1 (docs/reviews/2026-09-29-fable.md finding C1, Astra F11): Home
    # Manager activation and the AI-tools closure are exposed as flake
    # `checks` per system, which is exactly what CI's own
    # `nix flake check --all-systems` gate exercises -- so this loop proves
    # the same thing CI enforces, not a one-off attribute path. No `|| true`
    # anywhere below: a genuine evaluation error fails the case loudly, with
    # its own stderr in the message, instead of being swallowed and
    # misreported downstream as "not the same derivation".
    for system in aarch64-linux x86_64-linux; do
        # WP7.3/WP7.4 (docs/reviews/2026-09-29-fable.md findings C3, C4):
        # inventory / inventory-list are the reverse-direction package <->
        # command contract (guest-tools.nix, scripts/dx-verify-inventory.sh);
        # bash-integration / fish-integration / nushell-integration prove the
        # typed programs.starship/direnv/yazi options actually wire up in
        # each shell (home/shell.nix) -- the same eval-only, zero-warnings
        # proof the three checks above already get.
        for check_name in home-activation ai-tools bootstrap-essentials \
            inventory inventory-list \
            bash-integration fish-integration nushell-integration; do
            if check_output="$(nix eval --raw --no-write-lock-file "$CONTAINER_DIR#checks.$system.$check_name.drvPath" 2>&1)"; then
                test_pass "checks.$system.$check_name evaluates"
            else
                test_fail "checks.$system.$check_name evaluates (${check_output})"
            fi

            # WP2.2 (docs/reviews/2026-09-29-fable.md finding C2): an
            # evaluation warning here is a guest-boot-time landmine --
            # bootstrap/activation.sh runs this same Home Manager evaluation
            # on first boot -- that a CI eval gate checking only the exit
            # code would never catch. Only the line that actually starts a
            # warning counts; a wrapped continuation line (e.g. the
            # `nixpkgs.source`/`follows` message's second/third lines) is
            # not itself a new, unhandled warning.
            warning_lines="$(printf '%s\n' "$check_output" | grep -E '^(trace: warning|evaluation warning)' || true)"
            if [ -z "$warning_lines" ]; then
                test_pass "checks.$system.$check_name prints zero evaluation warnings"
            else
                test_fail "checks.$system.$check_name prints zero evaluation warnings (${warning_lines})"
            fi
        done

        # alias-is-identity's entire body is an `assert`; forcing its
        # drvPath is what actually proves homeConfigurations.dx is the SAME
        # derivation as homeConfigurations.dx-aarch64-linux -- a failing
        # assert is an evaluation error, not a silently-false value the way
        # comparing two possibly-empty strings (the old outPath diff) was.
        if alias_output="$(nix eval --raw --no-write-lock-file "$CONTAINER_DIR#checks.$system.alias-is-identity.drvPath" 2>&1)"; then
            test_pass "checks.$system.alias-is-identity evaluates (homeConfigurations.dx is a real alias)"
        else
            test_fail "checks.$system.alias-is-identity evaluates (homeConfigurations.dx is a real alias) (${alias_output})"
        fi
    done
else
    test_skip "nix not available, skipping flake check"
    for system in aarch64-linux x86_64-linux; do
        test_skip "nix not available, skipping checks.$system.home-activation evaluation"
        test_skip "nix not available, skipping checks.$system.home-activation warnings check"
        test_skip "nix not available, skipping checks.$system.ai-tools evaluation"
        test_skip "nix not available, skipping checks.$system.ai-tools warnings check"
        test_skip "nix not available, skipping checks.$system.bootstrap-essentials evaluation"
        test_skip "nix not available, skipping checks.$system.bootstrap-essentials warnings check"
        test_skip "nix not available, skipping checks.$system.inventory evaluation"
        test_skip "nix not available, skipping checks.$system.inventory warnings check"
        test_skip "nix not available, skipping checks.$system.inventory-list evaluation"
        test_skip "nix not available, skipping checks.$system.inventory-list warnings check"
        test_skip "nix not available, skipping checks.$system.bash-integration evaluation"
        test_skip "nix not available, skipping checks.$system.bash-integration warnings check"
        test_skip "nix not available, skipping checks.$system.fish-integration evaluation"
        test_skip "nix not available, skipping checks.$system.fish-integration warnings check"
        test_skip "nix not available, skipping checks.$system.nushell-integration evaluation"
        test_skip "nix not available, skipping checks.$system.nushell-integration warnings check"
        test_skip "nix not available, skipping checks.$system.alias-is-identity evaluation"
    done
fi

# Static/cheap companion to the nix-eval checks above -- exercised even on a
# host with no nix installed (this repo's own dev loop), unlike the checks
# above. Not the authoritative proof (nix eval is); catches an accidental
# revert of the multi-system declaration itself.
assert_file_contains_literal "$FLAKE_NIX" 'supportedSystems = [ "aarch64-linux" "x86_64-linux" ]' "flake.nix declares both supported systems"
assert_file_contains_literal "$FLAKE_NIX" 'dx-${system}' "flake.nix names homeConfigurations per system as dx-<system>"

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "Nix release identity live checks skipped by --skip-integration"
elif ! requires_container; then
    :
elif ! wait_for_ssh 60; then
    test_fail "SSH not reachable on localhost:$DX_SSH_PORT"
else
    if guest_bash "grep -q '^VERSION_ID=\"$DX_EXPECTED_NIXOS_RELEASE\"' /etc/os-release"; then
        test_pass "live guest publishes NixOS $DX_EXPECTED_NIXOS_RELEASE as its release identity in /etc/os-release"
    else
        test_fail "live guest publishes NixOS $DX_EXPECTED_NIXOS_RELEASE as its release identity in /etc/os-release"
    fi

    # Secondary/static: proves the branch string appears somewhere in the
    # lock file, but any transitive input could satisfy that -- it is not the
    # release oracle (see below) and is kept only as a cheap static check.
    if guest_bash "grep -q '$DX_EXPECTED_NIXOS_BRANCH' /guest-bootstrap/flake.lock"; then
        test_pass "secondary/static: live guest bootstrap flake.lock contains the string $DX_EXPECTED_NIXOS_BRANCH"
    else
        test_fail "secondary/static: live guest bootstrap flake.lock contains the string $DX_EXPECTED_NIXOS_BRANCH"
    fi

    # Mandatory release oracle: resolve the guest's own
    # locked flake inputs and assert the release they resolve to, rather than
    # trusting a file the base image may not even provide.
    # --no-update-lock-file so this check can never mutate the guest's lock.
    DX_RELEASE_ORACLE_RAW="$(guest_bash "nix eval --raw --no-update-lock-file --inputs-from /guest-bootstrap/current nixpkgs#lib.version" 2>/dev/null || true)"
    DX_RELEASE_ORACLE_OUTPUT="$(printf '%s\n' "$DX_RELEASE_ORACLE_RAW" | tail -1)"
    case "$DX_RELEASE_ORACLE_OUTPUT" in
        "$DX_EXPECTED_NIXOS_RELEASE"*)
            test_pass "live guest's locked flake inputs resolve nixpkgs#lib.version starting with $DX_EXPECTED_NIXOS_RELEASE"
            ;;
        *)
            test_fail "live guest's locked flake inputs resolve nixpkgs#lib.version starting with $DX_EXPECTED_NIXOS_RELEASE (got '$DX_RELEASE_ORACLE_OUTPUT')"
            ;;
    esac
fi

# The image-store import enumerates the image's registered Nix paths and copies
# them onto the /nix volume before the remount replaces /nix wholesale. That
# enumeration must include what install_essentials registered *this boot*. A
# read-only local-store view cannot checkpoint the store database's SQLite
# write-ahead log, so it reports only the paths committed when the image was
# built; importing that stale set is a no-op against a volume that already
# holds them, the essentials never reach the volume, and the first command
# after the remount has no binary to exec.
#
# This runs the real bootstrap function against real Nix in a throwaway
# container from the DX image, which is the only context that reproduces it:
# the running guest's /nix is the ext4 volume, where a fresh registration is
# visible to both spellings. No volumes are attached, so it never contends with
# a running guest for a named volume. Verified to discriminate -- restoring the
# read-only spelling turns this red.
DX_IMAGE="${DX_IMAGE:-dx-nixos-26.05}"
if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "Nix store enumeration behaviour skipped by --skip-integration"
elif ! command -v container >/dev/null 2>&1; then
    test_skip "Apple container CLI unavailable for the Nix enumeration probe"
elif ! container image list 2>/dev/null | awk -v w="$DX_IMAGE" 'NR > 1 && $1 == w { f = 1 } END { exit !f }'; then
    test_skip "image $DX_IMAGE is not built; skipping the Nix enumeration probe"
else
    enum_probe_body='
export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
# A batch large enough to leave the store database'"'"'s write-ahead log dirty,
# which is what install_essentials does on a real boot.
nix profile install nixpkgs#shadow nixpkgs#openssh --extra-experimental-features "nix-command flakes" >/dev/null 2>&1 || true
profile="$(readlink -f /nix/var/nix/profiles/per-user/root/profile 2>/dev/null || readlink -f /root/.nix-profile 2>/dev/null || true)"
if [ -n "$profile" ] && nix_image_registered_paths | grep -q -F "$(basename "$profile")"; then
    echo RESULT=SEES_THIS_SESSION_REGISTRATIONS
else
    echo RESULT=MISSES_THIS_SESSION_REGISTRATIONS
fi
'
    enum_script="$(cat "$CONTAINER_DIR/bootstrap/common.sh" "$CONTAINER_DIR/bootstrap/base-and-storage.sh"; printf '%s\n' "$enum_probe_body")"
    enum_output="$(container run --rm --name "dxe-enum-check-$$" --entrypoint bash "$DX_IMAGE:latest" -c "$enum_script" 2>&1 || true)"
    case "$enum_output" in
        *SEES_THIS_SESSION_REGISTRATIONS*)
            test_pass "the image store enumeration includes paths registered during this boot"
            ;;
        *)
            # Report the probe's own verdict rather than the runtime's
            # progress chatter, which is what tailing the raw output yields.
            enum_verdict="$(printf '%s
' "$enum_output" | grep -e 'RESULT=' -e 'error' | tail -2)"
            test_fail "the image store enumeration includes paths registered during this boot (${enum_verdict:-no probe verdict: $(printf '%s' "$enum_output" | tail -1)})"
            ;;
    esac
fi

print_summary
exit_with_code
