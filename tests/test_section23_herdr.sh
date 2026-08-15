#!/bin/bash
# Section 23: Herdr Integration
# Tests for: dx-herdr host wrapper, Herdr persistence, config seeding, and capability probe
#
# Note: --help/argument-rejection host-contract assertions for dx-herdr live in
# Section 9 (test_section9_host_scripts.sh), which runs in the Bash 3.2 tier.
# This section owns Herdr-specific behaviour only: fake-boundary probes, TOML
# seeding, and live checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"

test_section "Section 23: Herdr Integration"

DX_HERDR="$BASE_DIR/bin/dx-herdr"
PERSISTENCE="$CONTAINER_DIR/bootstrap/persistence.sh"
ACTIVATION="$CONTAINER_DIR/bootstrap/activation.sh"

# --- Host wrapper structure & syntax ---
assert_file_exists "$DX_HERDR" "dx-herdr host script exists"
assert_file_contains "$DX_HERDR" 'set -euo pipefail' "dx-herdr owns strict mode"
if bash -n "$DX_HERDR"; then test_pass "dx-herdr passes bash syntax"; else test_fail "dx-herdr passes bash syntax"; fi

# --- Boundary probes with fake tools ---
#
# Each block below isolates its `export PATH` change (and any fake-tool
# fixtures) inside a subshell, but the pass/fail assertion runs in the parent
# shell: test_pass/test_fail increment counters that are local to the shell
# that calls them, so an assertion made inside a `( … )` subshell can never
# affect this script's result (it dies with the subshell). The subshell's
# final statement is instead the actual boolean condition being tested, and
# its exit status (via the `if`/command-substitution-assignment) is what the
# parent branches on to call the real test_pass/test_fail.
if (
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    fake_tool_write "$fake_dir" container 'echo "other-container"'
    export PATH="$fake_dir:$PATH"

    set +e
    out="$("$DX_HERDR" 2>&1)"
    rc=$?
    set -e
    rm -rf "$fake_dir"
    [ "$rc" -ne 0 ] && echo "$out" | grep -q "not running"
); then
    test_pass "dx-herdr fails when container is not running"
else
    test_fail "dx-herdr fails when container is not running"
fi

# A non-fatal bootstrap activation failure must not become an ephemeral Herdr
# session: readiness is checked before any package probe or interactive attach.
if diag="$(
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    attach_marker="$fake_dir/attached"
    fake_tool_write "$fake_dir" container "echo \"$DX_CONTAINER_NAME\""
    fake_ssh_write "$fake_dir" '
        if [[ "$DX_FAKE_GUEST_CMD" == *".dxe-persistence-ready"* ]]; then exit 1; fi
        if [[ "$DX_FAKE_GUEST_CMD" == *"herdr"* ]]; then touch "'"$attach_marker"'"; fi
        exit 0
    '
    export PATH="$fake_dir:$PATH"

    set +e
    out="$("$DX_HERDR" 2>&1)"
    rc=$?
    set -e
    attached=no; [ -e "$attach_marker" ] && attached=yes
    rm -rf "$fake_dir"
    printf 'rc=%s attached=%s out=%s' "$rc" "$attached" "$out"
    [ "$rc" -eq 1 ] && [ "$attached" = no ] && echo "$out" | grep -q "persistence is not ready" && echo "$out" | grep -q "dx-recreate"
)"; then
    test_pass "dx-herdr refuses an unready persistence layout before attaching (R3)"
else
    test_fail "dx-herdr refuses an unready persistence layout before attaching (R3) ($diag)"
fi

# A present marker cannot bless an unsafe persistent target. This fake guest
# returns a negative readiness answer only when the probe includes the real-
# directory and non-symlink checks; otherwise it simulates a falsely ready
# guest and exposes the erroneous attach.
if diag="$(
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    attach_marker="$fake_dir/attached"
    fake_tool_write "$fake_dir" container "echo \"$DX_CONTAINER_NAME\""
    fake_ssh_write "$fake_dir" '
        case "$DX_FAKE_GUEST_CMD" in
            *".dxe-persistence-ready"*)
                case "$DX_FAKE_GUEST_CMD" in
                    *"[ -d /persist/home/dx/.config/herdr ]"*"[ ! -L /persist/home/dx/.config/herdr ]"*"[ -d /persist/home/dx/.local/state/herdr ]"*"[ ! -L /persist/home/dx/.local/state/herdr ]"*"[ ! -L /persist/home/dx/.config/herdr/.dxe-persistence-ready ]"*) exit 1 ;;
                    *) printf "%s" DX_HERDR_PRESENT; exit 0 ;;
                esac
                ;;
            *"command -v herdr"*) printf "%s" DX_HERDR_PRESENT; exit 0 ;;
            *"herdr"*) touch "'"$attach_marker"'"; exit 0 ;;
        esac
        exit 0
    '
    export PATH="$fake_dir:$PATH"

    set +e
    out="$("$DX_HERDR" 2>&1)"
    rc=$?
    set -e
    attached=no; [ -e "$attach_marker" ] && attached=yes
    rm -rf "$fake_dir"
    printf 'rc=%s attached=%s out=%s' "$rc" "$attached" "$out"
    [ "$rc" -eq 1 ] && [ "$attached" = no ] && echo "$out" | grep -q "persistence is not ready"
)"; then
    test_pass "dx-herdr rejects unsafe persistent targets or readiness markers (R3)"
else
    test_fail "dx-herdr rejects unsafe persistent targets or readiness markers (R3) ($diag)"
fi

if diag="$(
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    fake_tool_write "$fake_dir" container "echo \"$DX_CONTAINER_NAME\""  # not hard-coded: the live tier runs under the dx-test profile
    fake_ssh_write "$fake_dir" '
        if [[ "$DX_FAKE_GUEST_CMD" == *".dxe-persistence-ready"* ]]; then printf "%s" DX_HERDR_PRESENT; exit 0; fi
        if [[ "$DX_FAKE_GUEST_CMD" == *"command -v herdr"* ]]; then exit 1; fi
        if [[ "$DX_FAKE_GUEST_CMD" == *"dx-ai --supports herdr"* ]]; then exit 1; fi
        exit 0
    '
    export PATH="$fake_dir:$PATH"

    set +e
    out="$("$DX_HERDR" 2>&1)"
    rc=$?
    set -e
    rm -rf "$fake_dir"
    printf 'rc=%s out=%s' "$rc" "$out"
    [ "$rc" -eq 1 ] && echo "$out" | grep -q "lacks Herdr capability" && echo "$out" | grep -q "dx-recreate"
)"; then
    test_pass "dx-herdr gives dx-recreate diagnostic when helper lacks Herdr capability"
else
    test_fail "dx-herdr gives dx-recreate diagnostic when helper lacks Herdr capability (got $diag)"
fi

if diag="$(
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    fake_tool_write "$fake_dir" container "echo \"$DX_CONTAINER_NAME\""  # not hard-coded: the live tier runs under the dx-test profile
    probe_marker="$fake_dir/herdr-installed"
    fake_ssh_write "$fake_dir" '
        if [[ "$DX_FAKE_GUEST_CMD" == *".dxe-persistence-ready"* ]]; then printf "%s" DX_HERDR_PRESENT; exit 0; fi
        if [[ "$DX_FAKE_GUEST_CMD" == *"command -v herdr"* ]]; then
            if [ -f "'"$probe_marker"'" ]; then printf "%s" DX_HERDR_PRESENT; exit 0; else exit 1; fi
        fi
        if [[ "$DX_FAKE_GUEST_CMD" == *"dx-ai --supports herdr"* ]]; then printf "%s" DX_HERDR_PRESENT; exit 0; fi
        if [[ "$DX_FAKE_GUEST_CMD" == *"dx-ai"* ]]; then
            echo "BUNDLE_INSTALLED"
            touch "'"$probe_marker"'"
            exit 0
        fi
        if [[ "$DX_FAKE_GUEST_CMD" == *"herdr"* ]]; then
            echo "ATTACHED_HERDR"
            exit 0
        fi
        exit 0
    '
    export PATH="$fake_dir:$PATH"

    set +e
    out="$("$DX_HERDR" 2>&1)"
    rc=$?
    set -e
    rm -rf "$fake_dir"
    printf 'out=%s' "$out"
    [ "$rc" -eq 0 ] && echo "$out" | grep -q "Installing optional AI tools bundle" && echo "$out" | grep -q "BUNDLE_INSTALLED" && echo "$out" | grep -q "ATTACHED_HERDR"
)"; then
    test_pass "dx-herdr auto-installs Herdr via dx-ai when supported and attaches"
else
    test_fail "dx-herdr auto-installs Herdr via dx-ai when supported and attaches ($diag)"
fi

# --- F1 regression guard ---
#
# The guest's `dx` login shell is Nushell, and `ssh host "<string>"` hands
# <string> to that login shell for parsing. Nushell accepts a plain external
# command (`echo hello`) but rejects POSIX-only syntax such as `2>&1` or the
# `command` builtin at *parse* time -- so a raw, unwrapped probe string always
# fails on a real guest regardless of the real answer. The fix is for every
# guest command to cross an explicit `env ... bash -lc '...'` boundary, the
# same one the interactive attach path already uses: Nushell parses `env
# NAME=value... bash -c '<opaque>'` as a plain external-command invocation
# (each NAME=value token and the single-quoted string are just arguments), and
# never has to parse what's inside the quotes.
#
# This fake `ssh` simulates that failure mode directly (rather than emulating
# Nushell's parser): it rejects any invocation whose remote command string
# does not itself contain a `bash -l -c`/`bash -lc` boundary, with a
# distinctive exit code and stderr marker so a regression is unambiguous. Only
# once a command has crossed that boundary does it answer the probe.
if diag="$(
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    fake_tool_write "$fake_dir" container "echo \"$DX_CONTAINER_NAME\""  # not hard-coded: the live tier runs under the dx-test profile
    probe_marker="$fake_dir/herdr-installed"
    fake_ssh_write "$fake_dir" '
        case "$DX_FAKE_GUEST_RAW" in
            *"bash -l -c"*|*"bash -lc"*) ;;
            *)
                echo "FAKE_SSH_REJECTED_RAW_COMMAND: $DX_FAKE_GUEST_RAW" >&2
                exit 97
                ;;
        esac
        case "$DX_FAKE_GUEST_CMD" in
            *".dxe-persistence-ready"*)
                printf "%s" DX_HERDR_PRESENT
                ;;
            *"command -v herdr"*)
                if [ -f "'"$probe_marker"'" ]; then printf "%s" DX_HERDR_PRESENT; else exit 1; fi
                ;;
            *"dx-ai --supports herdr"*)
                printf "%s" DX_HERDR_PRESENT
                ;;
            *"dx-ai"*)
                echo "BUNDLE_INSTALLED"
                touch "'"$probe_marker"'"
                ;;
            *"herdr"*)
                echo "ATTACHED_HERDR"
                ;;
        esac
    '
    export PATH="$fake_dir:$PATH"

    set +e
    out="$("$DX_HERDR" 2>&1)"
    rc=$?
    set -e
    rm -rf "$fake_dir"
    printf 'rc=%s out=%s' "$rc" "$out"
    [ "$rc" -eq 0 ] && echo "$out" | grep -q "BUNDLE_INSTALLED" && echo "$out" | grep -q "ATTACHED_HERDR" \
        && ! echo "$out" | grep -q "FAKE_SSH_REJECTED_RAW_COMMAND"
)"; then
    test_pass "dx-herdr crosses the bash -lc boundary for every guest command (F1 regression guard)"
else
    test_fail "dx-herdr crosses the bash -lc boundary for every guest command (F1 regression guard) ($diag)"
fi

# --- F2: SSH transport failure must not be misreported as a missing capability ---
if diag="$(
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    fake_tool_write "$fake_dir" container "echo \"$DX_CONTAINER_NAME\""  # not hard-coded: the live tier runs under the dx-test profile
    fake_ssh_write "$fake_dir" 'exit 255'
    export PATH="$fake_dir:$PATH"

    set +e
    out="$("$DX_HERDR" 2>&1)"
    rc=$?
    set -e
    rm -rf "$fake_dir"
    printf 'rc=%s out=%s' "$rc" "$out"
    [ "$rc" -eq 1 ] && ! echo "$out" | grep -q "lacks Herdr capability" && ! echo "$out" | grep -q "dx-recreate"
)"; then
    test_pass "dx-herdr reports an SSH transport failure distinctly from a missing-capability diagnostic (F2)"
else
    test_fail "dx-herdr reports an SSH transport failure distinctly from a missing-capability diagnostic (F2) ($diag)"
fi

# --- F2: $DX_SSH_KEY must be checked before probing, not after ---
if diag="$(
    fake_dir="$(fake_tool_dir_create "${TMPDIR:-/tmp}")"
    fake_tool_write "$fake_dir" container "echo \"$DX_CONTAINER_NAME\""  # not hard-coded: the live tier runs under the dx-test profile
    ssh_marker="$fake_dir/ssh-invoked"
    fake_ssh_write "$fake_dir" 'touch "'"$ssh_marker"'"; exit 0'
    export PATH="$fake_dir:$PATH"

    set +e
    out="$(DX_SSH_KEY="$fake_dir/no-such-key" "$DX_HERDR" 2>&1)"
    rc=$?
    set -e
    invoked=absent
    [ -f "$ssh_marker" ] && invoked=present
    rm -rf "$fake_dir"
    printf 'rc=%s invoked=%s out=%s' "$rc" "$invoked" "$out"
    [ "$rc" -eq 1 ] && [ "$invoked" = absent ] && echo "$out" | grep -q "SSH key file not found"
)"; then
    test_pass "dx-herdr checks \$DX_SSH_KEY before probing, not after (F2)"
else
    test_fail "dx-herdr checks \$DX_SSH_KEY before probing, not after (F2) ($diag)"
fi

# --- F10: dx-herdr must not build/invoke its own ssh boundary ---
if grep -qE '(^|[^A-Za-z0-9_-])ssh([^A-Za-z0-9_-]|$)' "$DX_HERDR"; then
    test_fail "dx-herdr contains no ssh invocation of its own (F10)"
else
    test_pass "dx-herdr contains no ssh invocation of its own (F10)"
fi
assert_file_not_contains "$DX_HERDR" 'ssh_opts' "dx-herdr builds no SSH option array of its own (F10)"

# --- F11: HERDR_* must not be set (empty or otherwise) on the shared boundary ---
if grep -q 'HERDR_SOCKET_PATH=' "$BASE_DIR/bin/lib/dx-ssh-common.sh" || grep -q 'HERDR_CLIENT_SOCKET_PATH=' "$BASE_DIR/bin/lib/dx-ssh-common.sh"; then
    test_fail "the shared SSH boundary does not set HERDR_* (F11)"
else
    test_pass "the shared SSH boundary does not set HERDR_* (F11)"
fi

# --- Unit tests: TOML configuration seeding ---
#
# Each case sources activation.sh (which defines dx_seed_herdr_config) inside
# its own subshell to keep that function out of this script's namespace, for
# the same reason as above: the assertion is evaluated in the parent via the
# subshell's exit status, so a broken seeding rule can still fail this suite.
fixture_cfg="$(mktemp "${TMPDIR:-/tmp}/dxe-herdr-toml.XXXXXX")"
trap 'rm -f "$fixture_cfg" "$fixture_cfg.tmp"*' EXIT

# Test fresh file creation
rm -f "$fixture_cfg"
if (
    source "$ACTIVATION"
    dx_seed_herdr_config "$fixture_cfg"
    grep -q 'pane_history = true' "$fixture_cfg" && grep -q 'scrollback_limit_bytes = 10000000' "$fixture_cfg"
); then
    test_pass "dx_seed_herdr_config seeds default options in fresh file"
else
    test_fail "dx_seed_herdr_config seeds default options in fresh file"
fi

# Test preserving existing table headers
cat > "$fixture_cfg" <<'EOF'
[experimental]
custom_opt = 123

[advanced]
other_opt = "hello"
EOF
if (
    source "$ACTIVATION"
    dx_seed_herdr_config "$fixture_cfg"
    grep -q 'custom_opt = 123' "$fixture_cfg" && grep -q 'pane_history = true' "$fixture_cfg" && grep -q 'other_opt = "hello"' "$fixture_cfg" && grep -q 'scrollback_limit_bytes = 10000000' "$fixture_cfg"
); then
    test_pass "dx_seed_herdr_config inserts missing options into existing tables preserving comments/keys"
else
    test_fail "dx_seed_herdr_config inserts missing options into existing tables preserving comments/keys"
fi

# Test preserving explicit user values
cat > "$fixture_cfg" <<'EOF'
[experimental]
pane_history = false

[advanced]
scrollback_limit_bytes = 5000000
EOF
if (
    source "$ACTIVATION"
    dx_seed_herdr_config "$fixture_cfg"
    grep -q 'pane_history = false' "$fixture_cfg" && grep -q 'scrollback_limit_bytes = 5000000' "$fixture_cfg"
); then
    test_pass "dx_seed_herdr_config preserves explicit user settings"
else
    test_fail "dx_seed_herdr_config preserves explicit user settings"
fi

# --- F7: table-scope-aware seeding regression guards ---
#
# The pre-fix seeder grepped for key names anywhere in the file and matched
# table headers with an exact-line regex. That produced three reproduced
# failure modes (herdr-refactor.md F7): a key name under an unrelated table
# suppressed seeding entirely; a header with a trailing comment caused a
# *second*, duplicate `[experimental]` table to be appended (a TOML parse
# error); and a key under a same-named sub-table (`[experimental.nested]`)
# also suppressed seeding. Each case below was observed failing against the
# pre-fix function before the table-scope-aware awk pass replaced it.

# Case: key names present only under an unrelated table must not suppress
# seeding into the correct tables.
cat > "$fixture_cfg" <<'EOF'
[other]
pane_history = false
scrollback_limit_bytes = 1
EOF
if (
    source "$ACTIVATION"
    dx_seed_herdr_config "$fixture_cfg"
    grep -q '^pane_history = false' "$fixture_cfg" \
        && grep -q '^\[experimental\]$' "$fixture_cfg" \
        && grep -q '^pane_history = true' "$fixture_cfg" \
        && grep -q '^\[advanced\]$' "$fixture_cfg" \
        && grep -q '^scrollback_limit_bytes = 10000000' "$fixture_cfg"
); then
    test_pass "dx_seed_herdr_config seeds into [experimental]/[advanced] even when an unrelated table holds the same key names (F7)"
else
    test_fail "dx_seed_herdr_config seeds into [experimental]/[advanced] even when an unrelated table holds the same key names (F7)"
fi

# Case: a table header with a trailing comment must be recognized as that
# table (not appended as a brand-new, duplicate table).
cat > "$fixture_cfg" <<'EOF'
[experimental] # mine
foo = 1
EOF
if (
    source "$ACTIVATION"
    dx_seed_herdr_config "$fixture_cfg"
    [ "$(grep -c '\[experimental\]' "$fixture_cfg")" -eq 1 ] \
        && grep -q 'pane_history = true' "$fixture_cfg" \
        && grep -q 'foo = 1' "$fixture_cfg"
); then
    test_pass "dx_seed_herdr_config never emits a duplicate table for a commented header (F7)"
else
    test_fail "dx_seed_herdr_config never emits a duplicate table for a commented header (F7)"
fi

# Case: a key under a differently-named sub-table (`[experimental.nested]`)
# must not suppress seeding the top-level `[experimental]` table.
cat > "$fixture_cfg" <<'EOF'
[experimental.nested]
pane_history = false
EOF
if (
    source "$ACTIVATION"
    dx_seed_herdr_config "$fixture_cfg"
    grep -q '^\[experimental\.nested\]$' "$fixture_cfg" \
        && grep -q '^pane_history = false$' "$fixture_cfg" \
        && grep -q '^\[experimental\]$' "$fixture_cfg" \
        && grep -q '^pane_history = true$' "$fixture_cfg"
); then
    test_pass "dx_seed_herdr_config treats [experimental.nested] as a distinct table from [experimental] (F7)"
else
    test_fail "dx_seed_herdr_config treats [experimental.nested] as a distinct table from [experimental] (F7)"
fi

# Case: running the seeder twice must be byte-for-byte idempotent.
cat > "$fixture_cfg" <<'EOF'
# a user comment
[experimental]
custom_opt = 123

[advanced]
other_opt = "hello"
EOF
if (
    source "$ACTIVATION"
    dx_seed_herdr_config "$fixture_cfg"
    cp "$fixture_cfg" "$fixture_cfg.first-run"
    dx_seed_herdr_config "$fixture_cfg"
    cmp -s "$fixture_cfg.first-run" "$fixture_cfg"
    rc=$?
    rm -f "$fixture_cfg.first-run"
    exit "$rc"
); then
    test_pass "dx_seed_herdr_config is idempotent: a second run is byte-identical (F7)"
else
    test_fail "dx_seed_herdr_config is idempotent: a second run is byte-identical (F7)"
fi

# Case: atomic publication -- no leftover temp file, no `>>` in-place append,
# and the original file is preserved byte-for-byte on the seeder's own
# publication path (a plain successful run's tmp file must not survive it).
cat > "$fixture_cfg" <<'EOF'
[experimental]
custom_opt = 123
EOF
if (
    source "$ACTIVATION"
    dx_seed_herdr_config "$fixture_cfg"
    ! ls "$(dirname "$fixture_cfg")"/.dxe-herdr-config.* >/dev/null 2>&1
); then
    test_pass "dx_seed_herdr_config leaves no leftover temp file after a successful publish (F7)"
else
    test_fail "dx_seed_herdr_config leaves no leftover temp file after a successful publish (F7)"
fi
assert_file_not_contains "$ACTIVATION" '>> "\$config_file"' "dx_seed_herdr_config never appends in-place with >> (F7)"

# Case: TOML this seeder cannot understand conservatively (a top-level dotted
# key) must fail closed -- non-zero exit, a diagnostic, the file left
# completely untouched, and no temp file left behind.
cat > "$fixture_cfg" <<'EOF'
experimental.pane_history = true
EOF
cp "$fixture_cfg" "$fixture_cfg.before-fail-closed"
if (
    source "$ACTIVATION"
    set +e
    out="$(dx_seed_herdr_config "$fixture_cfg" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] \
        && [ -n "$out" ] \
        && cmp -s "$fixture_cfg.before-fail-closed" "$fixture_cfg" \
        && ! ls "$(dirname "$fixture_cfg")"/.dxe-herdr-config.* >/dev/null 2>&1
); then
    test_pass "dx_seed_herdr_config fails closed on TOML it cannot update safely, leaving the file untouched (F7)"
else
    test_fail "dx_seed_herdr_config fails closed on TOML it cannot update safely, leaving the file untouched (F7)"
fi
rm -f "$fixture_cfg.before-fail-closed"

# Case: a missing/empty file is created with mode 0600.
rm -f "$fixture_cfg"
if (
    source "$ACTIVATION"
    dx_seed_herdr_config "$fixture_cfg"
    mode="$(dx_path_mode "$fixture_cfg")"
    [ "$mode" = "600" ]
); then
    test_pass "dx_seed_herdr_config creates a fresh config.toml with mode 0600 (F7)"
else
    test_fail "dx_seed_herdr_config creates a fresh config.toml with mode 0600 (F7)"
fi

# --- F5: setup_herdr_persistence rejects symlinked targets/parents ---
#
# The pre-fix function guarded its persistent targets with
# `[ -e "$p" ] && [ ! -d "$p" ]`. `-d` dereferences, so a symlink to a
# directory passed as a legitimate target, and root would then mkdir/chown/
# chmod straight through it. setup_herdr_persistence now takes the persistent
# and home base directories as optional parameters (production callers still
# invoke it with zero args and get the real /persist/home/dx and /home/dx
# paths) purely so this can be exercised, with the real function, against a
# disposable fixture tree instead of mutating this machine's real
# filesystem.
#
# run_as_dx here executes the command for real (as this shell's own user)
# rather than dropping privileges to a "dx" system user that does not exist
# on this host; `-sfnT` is translated to the portable `-sfn` because this
# suite runs on both GNU and BSD `ln` hosts and only the guest's `ln` is GNU.
# The chown stub remaps the literal "dx:dx" spec to this process's own
# uid:gid (preserving any -h/-R flags) so the real chown(1) syscall succeeds
# on a fixture the test itself owns, while still proving setup_herdr_persistence
# asked for the right ownership operation.
herdr_persist_chown() {
    local args=() a
    for a in "$@"; do
        case "$a" in
            dx:dx) args+=("$(id -u):$(id -g)") ;;
            *) args+=("$a") ;;
        esac
    done
    command chown "${args[@]}"
}
herdr_persist_run_as_dx() {
    local cmd="${1/ln -sfnT/ln -sfn}"
    bash -c "$cmd"
}

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/dxe-herdr-persist.XXXXXX")"
trap 'rm -f "$fixture_cfg" "$fixture_cfg.tmp"*; rm -rf "$fixture_root"' EXIT

# Symlinked persistent target rejected before any mutation.
if (
    persist_home="$fixture_root/a/persist/home/dx"
    home="$fixture_root/a/home/dx"
    outside="$fixture_root/a/outside"
    mkdir -p "$outside" "$persist_home/.config" "$persist_home/.local/state" "$home/.config" "$home/.local/state"
    ln -s "$outside" "$persist_home/.config/herdr"
    before_mode="$(dx_path_mode "$outside")"

    chown() { herdr_persist_chown "$@"; }
    run_as_dx() { herdr_persist_run_as_dx "$@"; }
    source "$PERSISTENCE"
    set +e
    out="$(setup_herdr_persistence "$persist_home" "$home" 2>&1)"
    rc=$?
    set -e
    after_mode="$(dx_path_mode "$outside")"
    [ "$rc" -ne 0 ] && [ -n "$out" ] && [ "$before_mode" = "$after_mode" ]
); then
    test_pass "setup_herdr_persistence rejects a symlinked persistent target before any mutation (F5)"
else
    test_fail "setup_herdr_persistence rejects a symlinked persistent target before any mutation (F5)"
fi

# Symlinked parent (of a persistent target) rejected before any mutation.
if (
    persist_home="$fixture_root/b/persist/home/dx"
    home="$fixture_root/b/home/dx"
    outside="$fixture_root/b/outside"
    mkdir -p "$outside" "$persist_home" "$home/.config" "$home/.local/state"
    ln -s "$outside" "$persist_home/.config"

    chown() { herdr_persist_chown "$@"; }
    run_as_dx() { herdr_persist_run_as_dx "$@"; }
    source "$PERSISTENCE"
    set +e
    out="$(setup_herdr_persistence "$persist_home" "$home" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] && [ -n "$out" ] && [ -z "$(ls -A "$outside" 2>/dev/null)" ]
); then
    test_pass "setup_herdr_persistence rejects a symlinked parent directory before any mutation (F5)"
else
    test_fail "setup_herdr_persistence rejects a symlinked parent directory before any mutation (F5)"
fi

# The parent of persist_home is still inside the persistent-volume boundary
# and is user-controlled enough to require the same defense. Do not walk
# farther up this fixture path: its /tmp ancestor is a host implementation
# detail, not part of the guest/persistent-volume trust boundary.
if (
    persist_home="$fixture_root/parent/persist/home/dx"
    home="$fixture_root/parent/home/dx"
    outside="$fixture_root/parent/outside"
    mkdir -p "$fixture_root/parent/persist" "$home/.config" "$home/.local/state" "$outside"
    ln -s "$outside" "$fixture_root/parent/persist/home"

    chown() { herdr_persist_chown "$@"; }
    run_as_dx() { herdr_persist_run_as_dx "$@"; }
    source "$PERSISTENCE"
    set +e
    out="$(setup_herdr_persistence "$persist_home" "$home" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] && [ -n "$out" ] && [ ! -e "$outside/dx/.config/herdr" ]
); then
    test_pass "setup_herdr_persistence rejects a symlinked persist-home ancestor before mutation (R1)"
else
    test_fail "setup_herdr_persistence rejects a symlinked persist-home ancestor before mutation (R1)"
fi

# R1: every user-controlled ancestor must be rejected before root creates the
# state directory through it. Checking only .local/state is too late when
# .local itself is a symlink.
if (
    persist_home="$fixture_root/r1/persist/home/dx"
    home="$fixture_root/r1/home/dx"
    outside="$fixture_root/r1/outside"
    mkdir -p "$persist_home" "$home/.config" "$home/.local/state" "$outside"
    ln -s "$outside" "$persist_home/.local"

    chown() { herdr_persist_chown "$@"; }
    run_as_dx() { herdr_persist_run_as_dx "$@"; }
    source "$PERSISTENCE"
    set +e
    out="$(setup_herdr_persistence "$persist_home" "$home" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] && [ -n "$out" ] && [ ! -e "$outside/state/herdr" ]
); then
    test_pass "setup_herdr_persistence rejects a symlinked .local ancestor before mutation (R1)"
else
    test_fail "setup_herdr_persistence rejects a symlinked .local ancestor before mutation (R1)"
fi

# R2: configure_guest calls activation in an || list, which disables Bash's
# ambient errexit for this function. The first failed home link must return
# explicitly and prevent the state-side link from being attempted.
if (
    persist_home="$fixture_root/r2/persist/home/dx"
    home="$fixture_root/r2/home/dx"
    mkdir -p "$persist_home/.config" "$persist_home/.local/state" "$home/.config" "$home/.local/state"
    calls=0
    chown() { herdr_persist_chown "$@"; }
    run_as_dx() { calls=$((calls + 1)); [ "$calls" -ne 1 ]; }
    source "$PERSISTENCE"
    set +e
    setup_herdr_persistence "$persist_home" "$home" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] && [ "$calls" -eq 1 ] && [ ! -e "$home/.config/herdr" ] && [ ! -e "$home/.local/state/herdr" ]
); then
    test_pass "setup_herdr_persistence returns after the first failed mutation (R2)"
else
    test_fail "setup_herdr_persistence returns after the first failed mutation (R2)"
fi

# A home config migrated into a previously absent persistent target can carry
# an old marker. It must be invalidated before a later state-side failure.
if (
    persist_home="$fixture_root/r3-migrated-marker/persist/home/dx"
    home="$fixture_root/r3-migrated-marker/home/dx"
    mkdir -p "$persist_home/.config" "$persist_home/.local/state" "$home/.config/herdr" "$home/.local/state"
    printf '%s\n' stale > "$home/.config/herdr/.dxe-persistence-ready"
    calls=0
    chown() { herdr_persist_chown "$@"; }
    # Config-link succeeds; state-link fails. The marker must be gone even
    # though setup returns non-zero before a complete activation.
    run_as_dx() { calls=$((calls + 1)); [ "$calls" -ne 2 ]; }
    source "$PERSISTENCE"
    set +e
    setup_herdr_persistence "$persist_home" "$home" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] && [ "$calls" -eq 2 ] && [ ! -e "$persist_home/.config/herdr/.dxe-persistence-ready" ]
); then
    test_pass "setup_herdr_persistence invalidates a migrated config marker before state setup (R3)"
else
    test_fail "setup_herdr_persistence invalidates a migrated config marker before state setup (R3)"
fi

# dx_activate_herdr must not delete a readiness marker through a malicious
# persistent-config symlink before setup_herdr_persistence rejects it.
if (
    persist_home="$fixture_root/r1-marker/persist/home/dx"
    home="$fixture_root/r1-marker/home/dx"
    outside="$fixture_root/r1-marker/outside"
    mkdir -p "$persist_home/.config" "$persist_home/.local/state" "$home/.config" "$home/.local/state" "$outside"
    printf '%s\n' keep > "$outside/.dxe-persistence-ready"
    ln -s "$outside" "$persist_home/.config/herdr"

    chown() { herdr_persist_chown "$@"; }
    run_as_dx() { herdr_persist_run_as_dx "$@"; }
    source "$PERSISTENCE"
    source "$ACTIVATION"
    set +e
    dx_activate_herdr "$persist_home" "$home" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] && [ "$(cat "$outside/.dxe-persistence-ready")" = keep ]
); then
    test_pass "dx_activate_herdr never deletes a readiness marker through a symlinked config target (R1/R3)"
else
    test_fail "dx_activate_herdr never deletes a readiness marker through a symlinked config target (R1/R3)"
fi

# The ready marker is published only after its ownership and mode are set.
# A failure there must not leave a visible marker that dx-herdr could trust.
if (
    persist_home="$fixture_root/r3-marker/persist/home/dx"
    home="$fixture_root/r3-marker/home/dx"
    mkdir -p "$persist_home/.config" "$persist_home/.local/state" "$home/.config" "$home/.local/state"

    chown() {
        case "${!#}" in
            */.dxe-persistence-ready.*) return 1 ;;
            *) herdr_persist_chown "$@" ;;
        esac
    }
    run_as_dx() { herdr_persist_run_as_dx "$@"; }
    source "$PERSISTENCE"
    source "$ACTIVATION"
    set +e
    dx_activate_herdr "$persist_home" "$home" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] && [ ! -e "$persist_home/.config/herdr/.dxe-persistence-ready" ] && [ -z "$(find "$persist_home/.config/herdr" -name '.dxe-persistence-ready.*' -print -quit)" ]
); then
    test_pass "dx_activate_herdr publishes no readiness marker when preparation fails (R3)"
else
    test_fail "dx_activate_herdr publishes no readiness marker when preparation fails (R3)"
fi

# Timestamped backups get explicit dx:dx ownership and mode 0700.
if (
    persist_home="$fixture_root/c/persist/home/dx"
    home="$fixture_root/c/home/dx"
    mkdir -p "$persist_home/.config" "$persist_home/.local/state" "$home/.config" "$home/.local/state"
    : > "$persist_home/.config/herdr"

    chown() { herdr_persist_chown "$@"; }
    run_as_dx() { herdr_persist_run_as_dx "$@"; }
    source "$PERSISTENCE"
    setup_herdr_persistence "$persist_home" "$home" >/dev/null 2>&1
    backup="$(ls "$persist_home"/.config/herdr.non-directory-backup.* 2>/dev/null | head -n1)"
    [ -n "$backup" ] || exit 1
    mode="$(dx_path_mode "$backup")"
    [ "$mode" = "700" ]
); then
    test_pass "setup_herdr_persistence gives timestamped backups explicit ownership and mode 0700 (F5)"
else
    test_fail "setup_herdr_persistence gives timestamped backups explicit ownership and mode 0700 (F5)"
fi

# Repeat activation is a no-op apart from repairing declared ownership/modes.
if (
    persist_home="$fixture_root/d/persist/home/dx"
    home="$fixture_root/d/home/dx"
    mkdir -p "$persist_home/.config" "$persist_home/.local/state" "$home/.config" "$home/.local/state"

    chown() { herdr_persist_chown "$@"; }
    run_as_dx() { herdr_persist_run_as_dx "$@"; }
    source "$PERSISTENCE"
    setup_herdr_persistence "$persist_home" "$home" >/dev/null 2>&1
    : > "$persist_home/.config/herdr/config.toml"
    chmod 0755 "$persist_home/.config/herdr"

    setup_herdr_persistence "$persist_home" "$home" >/dev/null 2>&1
    mode="$(dx_path_mode "$persist_home/.config/herdr")"
    [ "$mode" = "700" ] \
        && [ -f "$persist_home/.config/herdr/config.toml" ] \
        && [ -L "$home/.config/herdr" ] \
        && [ "$(readlink "$home/.config/herdr")" = "$persist_home/.config/herdr" ]
); then
    test_pass "setup_herdr_persistence's repeat activation is a no-op apart from repairing declared ownership/modes (F5)"
else
    test_fail "setup_herdr_persistence's repeat activation is a no-op apart from repairing declared ownership/modes (F5)"
fi

# --- Live defect: home-side parents must be dx:dx-owned, or a fresh guest's
# first Herdr activation cannot write the symlink ---
#
# Live `dx-recreate` of a fresh dx-test guest failed with:
#   ln: failed to create symbolic link '/home/dx/.local/state/herdr': Permission denied
# setup_herdr_persistence's `mkdir -p` creates persistent_config_parent,
# persistent_state_parent, home_config_parent, and home_state_parent all as
# root, but only the *persistent* targets are later chowned to dx:dx --
# herdr-plan.md's "Create both persistent targets and their home-side
# parents as dx:dx, mode 0700" was only half-implemented. On a fresh guest
# ~/.local/state does not yet exist (~/.config typically already does, from
# setup_gh_persistence, which runs first in configure_guest), so root
# creates it root-owned and the unprivileged `run_as_dx "ln -sfnT ..."`
# below cannot write into it.
#
# Every other fixture in this file stubs the privilege boundary away
# entirely (`chown() { :; }; run_as_dx() { :; }`, or a `run_as_dx` that
# executes for real as this shell's own already-owns-everything user), so a
# permission failure can never surface there -- the suite stayed green
# while the guest died. This fixture instead tracks *simulated* dx
# ownership: the chown stub records, in a manifest file, only the paths
# this suite actually asked to chown dx:dx (and, when `-R` is given, their
# existing descendants); the run_as_dx stub looks up the destination
# symlink's parent directory in that manifest and refuses -- exactly as a
# real unprivileged `ln` would -- to write into a directory that was never
# chowned. An unchowned parent therefore fails here exactly as it failed on
# the live guest, and the assertions below check the observable outcome
# (the symlinks exist, and the parents carry simulated dx ownership/mode),
# not any error string.
herdr_boundary_chown() {
    local recursive=0 args=() a
    for a in "$@"; do
        case "$a" in
            -R) recursive=1 ;;
            -h) ;;
            dx:dx) ;;
            *) args+=("$a") ;;
        esac
    done
    for a in "${args[@]}"; do
        printf '%s\n' "$a" >> "$herdr_owned_manifest"
        if [ "$recursive" -eq 1 ]; then
            find "$a" -mindepth 1 >> "$herdr_owned_manifest" 2>/dev/null || true
        fi
    done
    return 0
}
herdr_boundary_run_as_dx() {
    local cmd="$1" dest dest_dir
    dest="$(printf '%s' "$cmd" | sed -E "s/^ln -sfnT '[^']*' '([^']*)'\$/\1/")"
    if [ -z "$dest" ] || [ "$dest" = "$cmd" ]; then
        echo "herdr_boundary_run_as_dx: fixture only understands a single ln -sfnT call, got: $cmd" >&2
        return 1
    fi
    dest_dir="$(dirname "$dest")"
    if [ -f "$herdr_owned_manifest" ] && grep -qxF "$dest_dir" "$herdr_owned_manifest"; then
        bash -c "${cmd/ln -sfnT/ln -sfn}"
    else
        echo "ln: failed to create symbolic link '$dest': Permission denied" >&2
        return 1
    fi
}

if diag="$(
    persist_home="$fixture_root/f/persist/home/dx"
    home="$fixture_root/f/home/dx"
    herdr_owned_manifest="$fixture_root/f/.owned-by-dx"
    mkdir -p "$persist_home" "$home/.config"
    : > "$herdr_owned_manifest"
    # Simulate the real guest boot ordering: setup_gh_persistence already
    # created and chowned ~/.config (mode 0755, shared with other tools)
    # before Herdr activation runs; ~/.local/state does not exist yet.
    chmod 0755 "$home/.config"
    printf '%s\n' "$home/.config" >> "$herdr_owned_manifest"

    chown() { herdr_boundary_chown "$@"; }
    run_as_dx() { herdr_boundary_run_as_dx "$@"; }
    source "$PERSISTENCE"

    set +e
    out="$(setup_herdr_persistence "$persist_home" "$home" 2>&1)"
    rc=$?
    set -e
    printf 'rc=%s out=%s' "$rc" "$out"

    [ "$rc" -eq 0 ] \
        && [ -L "$home/.config/herdr" ] \
        && [ -L "$home/.local/state/herdr" ] \
        && [ "$(readlink "$home/.config/herdr")" = "$persist_home/.config/herdr" ] \
        && [ "$(readlink "$home/.local/state/herdr")" = "$persist_home/.local/state/herdr" ] \
        && grep -qxF "$home/.local/state" "$herdr_owned_manifest" \
        && [ "$(dx_path_mode "$home/.local/state")" = "700" ] \
        && [ "$(dx_path_mode "$home/.config")" = "755" ]
)"; then
    test_pass "setup_herdr_persistence chowns a freshly created ~/.local/state to dx:dx so the symlink can be written, without clobbering a pre-existing shared ~/.config mode (live dx-recreate Permission denied defect)"
else
    test_fail "setup_herdr_persistence chowns a freshly created ~/.local/state to dx:dx so the symlink can be written, without clobbering a pre-existing shared ~/.config mode (live dx-recreate Permission denied defect) ($diag)"
fi

# --- F4: Herdr persistence/config must activate even on a fresh guest ---
#
# dx_activate_herdr used to be called only inside configure_guest's AI-tools
# opt-in branch, so a fresh guest's first Herdr session wrote into ordinary
# /home/dx directories; the *next* bootstrap would then migrate or relocate
# them into a timestamped backup, silently changing where the user's first
# session lived. Every mutating primitive configure_guest reaches is
# overridden below (including ones activation.sh itself defines, which must
# be overridden *after* sourcing since sourcing would otherwise clobber the
# override) so this never touches the real host filesystem; the AI-tools
# guard is forced false via the stubbed `grep`.
if (
    source "$ACTIVATION"

    ensure_nix_ownership() { :; }
    chown() { :; }
    mkdir() { :; }
    run_as_dx() { :; }
    setup_gh_persistence() { :; }
    setup_tmux_persistence() { :; }
    setup_keyring_service() { :; }
    run_home_manager_activation() { :; }
    usermod() { :; }
    grep() { return 1; }
    herdr_activated=0
    dx_activate_herdr() { herdr_activated=1; }

    configure_guest >/dev/null 2>&1
    [ "$herdr_activated" -eq 1 ]
); then
    test_pass "configure_guest activates Herdr persistence even when the AI-tools guard is false (F4)"
else
    test_fail "configure_guest activates Herdr persistence even when the AI-tools guard is false (F4)"
fi

# --- L5 regression guards: the early bootstrap environment lacks awk ---
#
# Live defect: awk is not in the early essentials profile, so the seeder failed,
# the failure propagated, and the guest never booted. Two separate faults are
# guarded here: the diagnostic must name the real cause (it used to blame the
# user's TOML for a missing binary), and an optional seeding step must never be
# able to abort bootstrap. The suite's own host always has awk, which is exactly
# why this needs a fixture that removes it while keeping coreutils.
if diag="$(
    shim="$(mktemp -d)"
    for t in dirname mktemp chmod mv cat rm grep sed; do
        p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$shim/$t"
    done
    # shellcheck source=/dev/null
    . "$ACTIVATION"
    cfg="$(mktemp)"; printf '[experimental]\nfoo = 1\n' > "$cfg"
    PATH="$shim" dx_seed_herdr_config "$cfg" >/dev/null 2>&1
    out="$(cat "$cfg")"
    rm -rf "$shim" "$cfg"
    printf '%s' "$out"
    # NB: a bare `case ... esac` here would be mis-parsed by Bash 3.2 inside a
    # double-quoted "$(...)" -- the statement text leaks into the output. The
    # [[ ]] form has no bare parens and is safe in the 3.2 tier.
    [[ "$out" == *"pane_history = true"* && "$out" == *"scrollback_limit_bytes = 10000000"* ]]
)"; then
    test_pass "dx_seed_herdr_config seeds correctly with no awk on PATH (L5 regression guard)"
else
    test_fail "dx_seed_herdr_config seeds correctly with no awk on PATH (L5 regression guard) (got: $diag)"
fi

if (
    # A failing Herdr activation must not abort configure_guest: sshd runs as
    # the foreground process, so an aborted bootstrap means no guest at all.
    # shellcheck source=/dev/null
    . "$ACTIVATION"
    set -euo pipefail
    dx_activate_herdr() { return 1; }
    run_as_dx() { :; }; chown() { :; }; mkdir() { :; }
    setup_keyring_service() { :; }; run_home_manager_activation() { :; }
    setup_tmux_persistence() { :; }; setup_gh_persistence() { :; }
    usermod() { :; }; touch() { :; }; grep() { return 1; }
    configure_guest >/dev/null 2>&1
) then
    test_pass "configure_guest survives a failing Herdr activation"
else
    test_fail "configure_guest survives a failing Herdr activation"
fi


# --- Live integration tests ---
if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "Herdr live tests skipped by --skip-integration"
    print_summary
    exit_with_code
fi

if ! requires_container; then
    test_skip "Container not available for Herdr live tests"
    print_summary
    exit_with_code
fi

if ! wait_for_ssh 60; then
    test_fail "SSH not reachable on localhost:$DX_SSH_PORT"
    print_summary
    exit_with_code
fi

run_guest() {
    "$BASE_DIR/bin/dx-ssh" "$1"
}

# Check Herdr presence after dx-ai
if run_guest "command -v herdr" >/dev/null 2>&1; then
    test_pass "Live: herdr is on PATH in guest"

    # Check Herdr version and AGPL license notice if herdr --version works
    if run_guest "herdr --version" >/dev/null 2>&1; then
        test_pass "Live: herdr --version runs successfully"
    fi

    # Check persistence symlinks
    if run_guest "test -L ~/.config/herdr && readlink ~/.config/herdr | grep -q /persist/" >/dev/null 2>&1; then
        test_pass "Live: ~/.config/herdr is symlinked to /persist"
    else
        test_fail "Live: ~/.config/herdr is symlinked to /persist"
    fi

    if run_guest "test -L ~/.local/state/herdr && readlink ~/.local/state/herdr | grep -q /persist/" >/dev/null 2>&1; then
        test_pass "Live: ~/.local/state/herdr is symlinked to /persist"
    else
        test_fail "Live: ~/.local/state/herdr is symlinked to /persist"
    fi

    # Check config.toml seeded content
    if run_guest "grep -q 'pane_history = true' ~/.config/herdr/config.toml" >/dev/null 2>&1; then
        test_pass "Live: config.toml has pane_history = true"
    else
        test_fail "Live: config.toml has pane_history = true"
    fi
else
    test_skip "Live: Herdr is not installed in guest yet (run dx-ai or dx-herdr)"
fi

print_summary
exit_with_code
