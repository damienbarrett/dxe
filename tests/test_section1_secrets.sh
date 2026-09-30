#!/bin/bash
# tier: unit
# bash32: no
# Section 1: Protect Local Secrets And Generated Files
# Tests for: .gitignore setup, secret exclusion, DS_Store handling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

test_section "Section 1: Protect Local Secrets And Generated Files"

# Test: .gitignore exists
assert_file_exists "$BASE_DIR/.gitignore" ".gitignore exists"

# Test: dx_key in .gitignore
assert_file_contains "$BASE_DIR/.gitignore" "dx_key" "dx_key is in .gitignore"

# Test: dx_key.pub in .gitignore
assert_file_contains "$BASE_DIR/.gitignore" "dx_key.pub" "dx_key.pub is in .gitignore"

# Test: .DS_Store in .gitignore
assert_file_contains "$BASE_DIR/.gitignore" "\.DS_Store" ".DS_Store is in .gitignore"

# Test: *.swp in .gitignore
assert_file_contains "$BASE_DIR/.gitignore" "\*\.swp" "*.swp is in .gitignore"

# Test: dx-host-export*.tar in .gitignore
assert_file_contains "$BASE_DIR/.gitignore" "dx-host-export.*\.tar" "dx-host-export*.tar is in .gitignore"

# Test: dx_key not tracked by git
assert_git_not_tracked "$BASE_DIR/dx_key" "dx_key is not tracked by git"

# Test: dx_key.pub not tracked by git
assert_git_not_tracked "$BASE_DIR/dx_key.pub" "dx_key.pub is not tracked by git"

# Test: No .DS_Store files in working tree
if find "$BASE_DIR" -name ".DS_Store" 2>/dev/null | stdin_matches .; then
    test_fail "No .DS_Store files in working tree"
else
    test_pass "No .DS_Store files in working tree"
fi

# Test: git status does not show dx_key, dx_key.pub, or .DS_Store
GIT_STATUS=$(git -C "$BASE_DIR" status --short 2>/dev/null || echo "")
if echo "$GIT_STATUS" | stdin_matches "dx_key"; then
    test_fail "git status does not show dx_key"
else
    test_pass "git status does not show dx_key"
fi
if echo "$GIT_STATUS" | stdin_matches "dx_key.pub"; then
    test_fail "git status does not show dx_key.pub"
else
    test_pass "git status does not show dx_key.pub"
fi
if echo "$GIT_STATUS" | stdin_matches "\.DS_Store"; then
    test_fail "git status does not show .DS_Store"
else
    test_pass "git status does not show .DS_Store"
fi

# --- NAS-identifying / key-material leak scan --------------------------
#
# qnap-dxe-plan.md's Phase 0 talks to a real, production QNAP NAS from this
# PUBLIC repository. Only the ssh_config alias (DXE_QNAP_HOST, e.g.
# "qnap-dxe") may ever appear in a tracked file -- never its Tailscale
# MagicDNS name, tailnet address, storage-pool/dataset name, or any key
# material. These are generic shape detectors (not specific to this one
# NAS), so they also catch the equivalent leak for any future host this
# repository talks to the same way.
#
# Every pattern below is written as an ordinary, correctly escaped regex
# (real "\." dot-escapes, "(...)" groups, "[...]" classes, "{n}" quantifiers).
# That is not merely idiomatic: it is also why none of these pattern
# *definitions* trips its own check when this file itself is scanned below
# -- the regex metacharacters are literal "noise" (an unescaped "(", "[",
# or bare quantifier syntax) sitting exactly where the real trigger shape
# would need contiguous plain text, so the pattern's own source text can
# never satisfy itself. Verified by running this section after writing it,
# not merely by this argument.
TAILNET_IP_PATTERN='100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'
TAILSCALE_DOMAIN_PATTERN='\.ts\.net'
QNAP_POOL_PATH_PATTERN='/share/[A-Za-z0-9]+_DATA'
SSH_PUBKEY_PATTERN='ssh-(ed25519|rsa) AAAA[A-Za-z0-9+/=]+'
SSH_FINGERPRINT_PATTERN='SHA256:[A-Za-z0-9+/]{43}'
PRIVATE_KEY_PATTERN='BEGIN[A-Z ]*PRIVATE KEY'

# Scans tracked files only (git ls-files: honours .gitignore, so
# tests/coverage/out/ is excluded the same way it already is everywhere
# else, and .git/ internals are never files git tracks in the first place).
check_no_leak() {
    local pattern="$1" description="$2" hits
    hits="$(git -C "$BASE_DIR" ls-files -z | (cd "$BASE_DIR" && xargs -0 grep -lE -- "$pattern") 2>/dev/null || true)"
    if [ -z "$hits" ]; then
        test_pass "no tracked file leaks $description"
    else
        test_fail "no tracked file leaks $description (found in: $hits)"
    fi
}

check_no_leak "$TAILNET_IP_PATTERN" "a Tailscale tailnet IP (the CGNAT /10 block Tailscale assigns from)"
check_no_leak "$TAILSCALE_DOMAIN_PATTERN" "a Tailscale MagicDNS domain suffix"
check_no_leak "$QNAP_POOL_PATH_PATTERN" "a QNAP storage-pool dataset path"
check_no_leak "$SSH_PUBKEY_PATTERN" "an SSH public key blob"
check_no_leak "$SSH_FINGERPRINT_PATTERN" "an SSH key fingerprint"
check_no_leak "$PRIVATE_KEY_PATTERN" "a PEM private key header"

# Red/green proof that each pattern actually catches the shape it claims to,
# using the identical grep -lE mechanism check_no_leak uses above -- a
# vacuous "no hits" is worthless without also proving a real hit would have
# been caught. Runs against a throwaway fixture file outside the repository
# (never git-added, never touches this repository's own tracked state), one
# case per pattern.
#
# Every planted example is assembled at runtime from pieces that do not
# individually contain the trigger shape, for the same self-reference reason
# documented above: written as one contiguous literal, any one of them would
# itself become a tracked-file leak the moment this test file was committed,
# defeating the very check it exists to prove.
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dxe-secrets-fixture.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

planted_ip="$(printf '%s.%s.%s.%s' 100 64 12 34)"
planted_domain="$(printf '%s%s%s' "myhost.example." "ts" ".net")"
planted_pool_path="$(printf '%s%s%s' "/share/" "CACHEDEV1" "_DATA/x")"
planted_pubkey="$(printf '%s %s%s' "ssh-ed25519" "AAAA" "C3NzaC1lZDI1NTE5AAAAIGZ1eGFrZQ==")"
planted_fingerprint="$(printf '%s%s' "SHA256:" "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNO12")"
planted_private_key="$(printf '%s%s' "-----BEGIN OPENSSH" " PRIVATE KEY-----")"

fixture_cases="$(printf '%s\t%s\t%s\n' \
    "$TAILNET_IP_PATTERN" "$planted_ip" "a Tailscale tailnet IP" \
    "$TAILSCALE_DOMAIN_PATTERN" "$planted_domain" "a Tailscale MagicDNS domain suffix" \
    "$QNAP_POOL_PATH_PATTERN" "$planted_pool_path" "a QNAP storage-pool dataset path" \
    "$SSH_PUBKEY_PATTERN" "$planted_pubkey" "an SSH public key blob" \
    "$SSH_FINGERPRINT_PATTERN" "$planted_fingerprint" "an SSH key fingerprint" \
    "$PRIVATE_KEY_PATTERN" "$planted_private_key" "a PEM private key header" \
)"

while IFS="$(printf '\t')" read -r case_pattern case_planted case_description; do
    [ -n "$case_pattern" ] || continue
    fixture_file="$FIXTURE_DIR/planted.md"
    printf '%s\n' "$case_planted" > "$fixture_file"
    if grep -lE -- "$case_pattern" "$fixture_file" >/dev/null 2>&1; then
        test_pass "the $case_description pattern catches a planted example (red/green proof)"
    else
        test_fail "the $case_description pattern catches a planted example (red/green proof)"
    fi
    rm -f "$fixture_file"
done <<<"$fixture_cases"

rm -rf "$FIXTURE_DIR"
trap - EXIT

print_summary
exit_with_code
