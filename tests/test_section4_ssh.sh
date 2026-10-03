#!/bin/bash
# tier: unit
# bash32: no
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
SYSTEM="$CONTAINER_DIR/bootstrap/system.sh"
test_section "Section 4: Harden SSH While Keeping Sudo Convenient"

# Fable D7 item 6: these five directives used to be five separate literal
# greps of configure_ssh's own heredoc, three of which
# (PubkeyAuthentication/PasswordAuthentication/PermitEmptyPasswords) were
# ALSO grepped a second time from tests/test_section13_final_review.sh,
# alongside the passwordless-sudo line below -- the same setting checked
# twice, in two files, by source text. Rendered here instead: the exact
# heredoc body configure_ssh writes to /etc/ssh/sshd_config is extracted
# verbatim from system.sh (never retyped), written into a fixture file with
# a throwaway HostKey appended (sshd -T needs one to run at all, but never
# reads or trusts its content), and handed to the real, installed `sshd -T`
# parser -- proving the settings are not merely present as text but valid
# and in effect, from the real authority on what they mean, and folding
# section 13's duplicate check into this one place. Skips (rather than
# failing) on a host with no local sshd binary, the same way requires_container
# skips a live check no fixture can stand in for.
if ! command -v sshd >/dev/null 2>&1; then
    test_skip "sshd_config directive check skipped: no local sshd binary to validate against"
elif sshd_effective="$(
    sshd_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-sshd-config-test.XXXXXX")"
    trap 'rm -rf "$sshd_fixture"' EXIT
    ssh-keygen -q -t ed25519 -N '' -f "$sshd_fixture/hostkey" </dev/null
    {
        sed -n '/cat > \/etc\/ssh\/sshd_config <<EOF/,/^EOF$/p' "$SYSTEM" | sed '1d;$d'
        printf 'HostKey %s\n' "$sshd_fixture/hostkey"
    } > "$sshd_fixture/sshd_config"
    sshd -T -f "$sshd_fixture/sshd_config" 2>&1
)"; then
    if printf '%s\n' "$sshd_effective" | stdin_matches -F -x 'port 2222' \
        && printf '%s\n' "$sshd_effective" | stdin_matches -F -x 'permitrootlogin no' \
        && printf '%s\n' "$sshd_effective" | stdin_matches -F -x 'pubkeyauthentication yes' \
        && printf '%s\n' "$sshd_effective" | stdin_matches -F -x 'passwordauthentication no' \
        && printf '%s\n' "$sshd_effective" | stdin_matches -F -x 'permitemptypasswords no'; then
        test_pass "configure_ssh's rendered sshd_config takes effect under the real sshd parser (port 2222, key-only auth, no root login, no empty passwords)"
    else
        test_fail "configure_ssh's rendered sshd_config takes effect under the real sshd parser (port 2222, key-only auth, no root login, no empty passwords) (sshd -T said: $sshd_effective)"
    fi
else
    test_fail "configure_ssh's rendered sshd_config takes effect under the real sshd parser (sshd -T itself failed: $sshd_effective)"
fi
assert_file_contains_literal "$SYSTEM" 'mkdir -p /run /var/run/sshd' "bootstrap creates sshd runtime directories"
assert_file_contains_literal "$SYSTEM" 'DX_PUB_KEY' "authorized keys are configurable"
assert_file_contains_literal "$SYSTEM" 'dx ALL=(ALL) NOPASSWD:ALL' "passwordless sudo is preserved for dx"
# Branch 11 / Phase 5 (qnap-dxe-plan.md DQ5): the guest SSH publish spec
# itself carries no bind address any more -- each runtime adapter prepends
# its own (Apple a fixed 127.0.0.1 literal, so host forwarding really is
# still loopback-only there; docker-ssh the NAS's own discovered Tailscale
# address, so it is emphatically NOT loopback-only for that runtime, which
# is the entire point of this phase). The Apple-side byte-for-byte proof
# lives in tests/test_runtime_boundary_characterisation.sh; this checks
# only that bin/dx-create-container itself never hardcodes a bind address
# in the --publish VALUE it passes (a prose comment nearby is allowed to
# mention 127.0.0.1 -- it names what the Apple ADAPTER does elsewhere).
assert_file_contains_literal "$BASE_DIR/bin/dx-create-container" '--publish "$DX_SSH_PORT:2222"' "guest SSH publish spec carries no bind address (each runtime adapter supplies its own)"
assert_file_contains_literal "$BASE_DIR/bin/dx-create-container" '--publish "$DX_USAGE_SERVICE_HOST_PORT:8787"' "usage-service publish spec carries no bind address either (same neutral vocabulary as SSH)"

# The guest's host identity is persisted on the dx-persist volume rather than
# regenerated onto the ephemeral rootfs each boot. Behavior for restore, the
# root-ownership trust boundary, and the symlink guards is covered by the
# section 3 bootstrap tests.
assert_file_contains_literal "$SYSTEM" '/persist/etc/ssh' "SSH host keys are persisted across rebuilds"
assert_file_contains_literal "$SYSTEM" 'dx_persist_host_keys' "configure_ssh restores or persists the host identity"

if ! live_tail_enabled; then test_skip "SSH live behavior skipped by --skip-integration"; else
    # requires_container already records its own SKIP and returns 1 when no
    # guest is running; short-circuiting `requires_container && dx-ssh` into
    # the same pass/fail branch as a real command failure turned that skip
    # into skip-plus-spurious-FAIL. Branch on requires_container first so the
    # no-guest case is exactly one SKIP and nothing else.
    if ! requires_container; then
        :
    elif "$BASE_DIR/bin/dx-ssh" true; then
        test_pass "key-only SSH live probe succeeds"
        # Hostname parity, runtime-neutral and behavioural: the guest must
        # call itself by the name the host knows it by, whichever runtime
        # (Apple container, docker-ssh) created it. The fake-daemon argv test
        # of the --hostname flag stays as the unit-level guard; only a real
        # guest can answer this.
        guest_etc_hostname="$("$BASE_DIR/bin/dx-ssh" cat /etc/hostname 2>/dev/null || true)"
        if [ "$guest_etc_hostname" = "$DX_CONTAINER_NAME" ]; then
            test_pass "guest /etc/hostname equals DX_CONTAINER_NAME"
        else
            test_fail "guest /etc/hostname equals DX_CONTAINER_NAME (guest said '$guest_etc_hostname', expected '$DX_CONTAINER_NAME')"
        fi
        guest_uname_n="$("$BASE_DIR/bin/dx-ssh" uname -n 2>/dev/null || true)"
        if [ "$guest_uname_n" = "$DX_CONTAINER_NAME" ]; then
            test_pass "guest uname -n equals DX_CONTAINER_NAME"
        else
            test_fail "guest uname -n equals DX_CONTAINER_NAME (guest said '$guest_uname_n', expected '$DX_CONTAINER_NAME')"
        fi
    else
        test_fail "key-only SSH live probe succeeds"
    fi
fi
print_summary
exit_with_code
