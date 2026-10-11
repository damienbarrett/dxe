#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
# WP1.2 (spec requirements 7-9): the Mac access docs section for browsing
# /persist over the guest's existing SSH (VS Code Remote-SSH and an SFTP
# browser). The connection snippets are checked by BEHAVIOUR: each fenced
# sshconfig block is written to a file and resolved by the REAL ssh client in
# config-dump mode (`ssh -G -F FILE ALIAS`, which never connects), so the
# values asserted are the ones ssh would really use, not text in the docs.
#
# Interface contract:
#   - File: docs/guest.md. Section heading, exactly (a level-2 heading):
#         ## Browsing /persist from the Mac
#     The section runs to the next level-2 heading or end of file.
#   - The section holds EXACTLY two fenced ```sshconfig blocks, each
#     self-contained (the client sees only that block):
#       block 1 defines `Host dx-host`;
#       block 2 defines `Host dx-host-vscode` (all of block 1's settings plus
#       `RemoteCommand bash -l`).
#   - Resolved by ssh -G for the default profile (values read from
#     tests/profiles/default.env's DX_SSH_PORT and DX_SSH_KEY lines, never
#     hard-coded here): hostname 127.0.0.1, user dx, port DX_SSH_PORT,
#     identityfile DX_SSH_KEY (first identityfile line), identitiesonly yes,
#     hostkeyalias dx-host (BOTH aliases), stricthostkeychecking accept-new.
#     remotecommand is absent for dx-host and `bash -l` for dx-host-vscode.
#   - Prose in the section (case-insensitive fixed strings):
#       "only while the guest is running"             (requirement 8)
#       "remote.SSH.enableRemoteCommand"  and  "true"  (VS Code setting)
#       "code --remote ssh-remote+dx-host-vscode /persist"
#       "SFTP"
#       "root-only" and "etc/ssh"  (dx's permissions: root-only entries are
#                                    unreadable; intended)
#       "factory reset", "fingerprint", "dx-ssh" and the literal command
#       "ssh-keygen -R dx-host"; the first mention of "fingerprint" comes
#       BEFORE the "ssh-keygen -R dx-host" line (confirm, then remove).
#   - WP1.4 (VS Code server support in the guest; plans/do plan.md WP1.4,
#     tests/test_persist_vscode_server.sh), same section, case-insensitive
#     fixed strings:
#       "nix-ld"            (the guest runs VS Code's server through nix-ld,
#                            set up at boot with no manual step)
#       "first connection" and "download"
#                           (the first connection downloads the server, so
#                            it is slow once)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "WP1.2: Mac access docs (/persist over SSH)"

# Resolve the real client before any fake PATH could be installed.
REAL_SSH="$(command -v ssh || true)"
GUEST_DOC="$BASE_DIR/docs/guest.md"
DEFAULT_ENV="$BASE_DIR/tests/profiles/default.env"
HEADING="## Browsing /persist from the Mac"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dxe-mac-docs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The default profile's documented values, read from the profile file.
EXPECT_PORT="$(sed -n 's/^#[[:space:]]*export DX_SSH_PORT=\([0-9][0-9]*\)$/\1/p' "$DEFAULT_ENV" | head -n 1)"
EXPECT_KEY_RAW="$(sed -n 's/^#[[:space:]]*export DX_SSH_KEY=\(.*\)$/\1/p' "$DEFAULT_ENV" | head -n 1)"
EXPECT_KEY_REL="${EXPECT_KEY_RAW#\$\{HOME\}/}"
# ssh expands ~ from the passwd entry (when it expands at all), which can
# differ from $HOME.
PASSWD_HOME="$(cd ~ 2>/dev/null && pwd)"
# The literal tilde ssh -G prints when it does not expand ~ (built without a
# quoted tilde, which ShellCheck SC2088 rejects).
TILDE="$(printf '%s' '~')"

if [ -n "$EXPECT_PORT" ] && [ -n "$EXPECT_KEY_REL" ] && [ "$EXPECT_KEY_REL" != "$EXPECT_KEY_RAW" ]; then
    test_pass "default profile values read from tests/profiles/default.env (port $EXPECT_PORT, key ~/$EXPECT_KEY_REL)"
else
    test_fail "default profile values read from tests/profiles/default.env (port '$EXPECT_PORT', key '$EXPECT_KEY_RAW')"
fi
if [ -n "$REAL_SSH" ]; then
    test_pass "a real ssh client is available for config-dump checks"
else
    test_fail "a real ssh client is available for config-dump checks"
fi

# section_text -- the docs section, heading included, to stdout.
section_text() {
    awk -v h="$HEADING" '
        $0 == h { on = 1; print; next }
        on && /^## / { exit }
        on { print }
    ' "$GUEST_DOC"
}

SECTION="$(section_text)"
if [ -n "$SECTION" ]; then
    test_pass "docs/guest.md has the section '$HEADING'"
else
    test_fail "docs/guest.md has the section '$HEADING'"
fi
printf '%s\n' "$SECTION" > "$WORK/section.md"

# Split the section's ```sshconfig fences into $WORK/block-N.conf.
BLOCK_COUNT="$(awk -v dir="$WORK" '
    /^```sshconfig[[:space:]]*$/ { n++; on = 1; file = dir "/block-" n ".conf"; printf "" > file; next }
    on && /^```[[:space:]]*$/ { on = 0; close(file); next }
    on { print > file }
    END { print n + 0 }
' "$WORK/section.md")"
if [ "$BLOCK_COUNT" = 2 ]; then
    test_pass "the section holds exactly two sshconfig blocks"
else
    test_fail "the section holds exactly two sshconfig blocks (found $BLOCK_COUNT)"
fi

# ssh_dump FILE ALIAS -- the real client's resolved config, never connecting.
ssh_dump() {
    "$REAL_SSH" -G -F "$1" "$2" 2>/dev/null
}

# dump_value DUMP KEY -- first value line for KEY ("" when absent).
dump_value() {
    printf '%s\n' "$1" | awk -v k="$2" '$1 == k { sub(/^[^ ]+ /, ""); print; exit }'
}

# check_alias FILE ALIAS WANT_REMOTE -- print one line per violated expectation.
check_alias() {
    local file="$1" alias="$2" want_remote="$3" dump key_value want_a want_b
    dump="$(ssh_dump "$file" "$alias")" || { echo "ssh -G failed on $file"; return 0; }
    [ "$(dump_value "$dump" hostname)" = 127.0.0.1 ] || echo "hostname is '$(dump_value "$dump" hostname)', want 127.0.0.1"
    [ "$(dump_value "$dump" user)" = dx ] || echo "user is '$(dump_value "$dump" user)', want dx"
    [ "$(dump_value "$dump" port)" = "$EXPECT_PORT" ] || echo "port is '$(dump_value "$dump" port)', want $EXPECT_PORT"
    key_value="$(dump_value "$dump" identityfile)"
    want_a="$HOME/$EXPECT_KEY_REL"
    want_b="$PASSWD_HOME/$EXPECT_KEY_REL"
    # Some clients print ~ unexpanded, others expand it.
    if [ "$key_value" != "$want_a" ] && [ "$key_value" != "$want_b" ] && [ "$key_value" != "$TILDE/$EXPECT_KEY_REL" ]; then
        echo "identityfile is '$key_value', want $want_a"
    fi
    [ "$(dump_value "$dump" identitiesonly)" = yes ] || echo "identitiesonly is '$(dump_value "$dump" identitiesonly)', want yes"
    [ "$(dump_value "$dump" hostkeyalias)" = dx-host ] || echo "hostkeyalias is '$(dump_value "$dump" hostkeyalias)', want dx-host"
    [ "$(dump_value "$dump" stricthostkeychecking)" = accept-new ] || echo "stricthostkeychecking is '$(dump_value "$dump" stricthostkeychecking)', want accept-new"
    if [ "$want_remote" = yes ]; then
        [ "$(dump_value "$dump" remotecommand)" = "bash -l" ] || echo "remotecommand is '$(dump_value "$dump" remotecommand)', want 'bash -l'"
    else
        [ -z "$(dump_value "$dump" remotecommand)" ] || echo "remotecommand is '$(dump_value "$dump" remotecommand)', want none"
    fi
}

assert_alias() {
    local label="$1" file="$2" alias="$3" want_remote="$4" problems
    if [ ! -f "$file" ]; then
        test_fail "$label: block file missing"
        return 0
    fi
    problems="$(check_alias "$file" "$alias" "$want_remote")"
    if [ -z "$problems" ]; then
        test_pass "$label"
    else
        test_fail "$label: $(printf '%s' "$problems" | tr '\n' ';')"
    fi
}

assert_alias "block 1 resolves dx-host (plain SSH/SFTP alias, no RemoteCommand)" "$WORK/block-1.conf" dx-host no
assert_alias "block 2 resolves dx-host-vscode (HostKeyAlias dx-host, RemoteCommand bash -l)" "$WORK/block-2.conf" dx-host-vscode yes

# Hard to game: the checker must reject a wrong snippet (spec mutation: port).
if [ -f "$WORK/block-1.conf" ] && [ -n "$EXPECT_PORT" ]; then
    sed "s/^\([[:space:]]*Port[[:space:]]\{1,\}\)[0-9]\{1,\}/\19$EXPECT_PORT/" "$WORK/block-1.conf" > "$WORK/mutant.conf"
    if [ -n "$(check_alias "$WORK/mutant.conf" dx-host no)" ]; then
        test_pass "the config-dump check rejects a snippet with the wrong port"
    else
        test_fail "the config-dump check rejects a snippet with the wrong port"
    fi
else
    test_fail "the config-dump check rejects a snippet with the wrong port (no block to mutate)"
fi

# The aliases must not share one snippet: dx-host must not pick up
# RemoteCommand from block 2 and block 2 must not be a plain alias.
if [ -f "$WORK/block-1.conf" ] && [ -f "$WORK/block-2.conf" ] && ! cmp -s "$WORK/block-1.conf" "$WORK/block-2.conf"; then
    test_pass "the two blocks differ"
else
    test_fail "the two blocks differ"
fi

# has_text NEEDLE -- case-insensitive fixed-string match in the section.
has_text() {
    grep -Fiq -- "$1" <<<"$SECTION"
}
assert_text() {
    if has_text "$1"; then
        test_pass "section mentions: $2"
    else
        test_fail "section mentions: $2 (missing '$1')"
    fi
}

assert_text "only while the guest is running" "browsing works only while the guest runs"
assert_text "remote.SSH.enableRemoteCommand" "the VS Code setting name"
assert_text "code --remote ssh-remote+dx-host-vscode /persist" "the code --remote command"
assert_text "SFTP" "an SFTP file browser"
assert_text "root-only" "root-only entries are unreadable"
assert_text "etc/ssh" "etc/ssh as the example"
assert_text "factory reset" "the factory-reset case"
assert_text "dx-ssh" "confirming from inside the guest via dx-ssh"
assert_text "ssh-keygen -R dx-host" "the ssh-keygen -R dx-host remedy"
# WP1.4: the guest supports VS Code's server through nix-ld, and the first
# connection downloads the server (slow once).
assert_text "nix-ld" "the guest runs VS Code's server through nix-ld (WP1.4)"
assert_text "first connection" "what the first connection does (WP1.4)"
assert_text "download" "the first connection downloads the VS Code server (WP1.4)"

if grep -Fiq 'enableRemoteCommand": true' <<<"$SECTION"; then
    test_pass "section shows the setting as \"remote.SSH.enableRemoteCommand\": true"
else
    test_fail "section shows the setting as \"remote.SSH.enableRemoteCommand\": true"
fi

# Remedy order: the fingerprint is confirmed BEFORE the pin is removed.
FP_LINE="$(grep -Fin -- "fingerprint" <<<"$SECTION" | head -n 1 | cut -d: -f1)"
KEYGEN_LINE="$(grep -Fn -- "ssh-keygen -R dx-host" <<<"$SECTION" | head -n 1 | cut -d: -f1)"
if [ -n "$FP_LINE" ] && [ -n "$KEYGEN_LINE" ] && [ "$FP_LINE" -lt "$KEYGEN_LINE" ]; then
    test_pass "fingerprint check comes before ssh-keygen -R dx-host"
else
    test_fail "fingerprint check comes before ssh-keygen -R dx-host (fingerprint line '${FP_LINE}', ssh-keygen line '${KEYGEN_LINE}')"
fi

print_summary
exit_with_code
