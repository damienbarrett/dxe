#!/bin/bash
set -uo pipefail
# Increment 3 (Branch 10, feat/persist-backup): dx-restore, driven through the
# same fake-container boundary as tests/test_dx_backup.sh (see that file's
# header for why the fake `container exec` passes through for real against a
# fixture directory standing in for /persist).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
GUEST="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-26.05"
test_section "Persist backup: dx-restore (fake-container boundary)"

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-dx-restore-test.XXXXXX")"
trap 'chmod -R u+w "$FIXTURE" 2>/dev/null || true; rm -rf "$FIXTURE"' EXIT

FAKE_DIR="$(fake_tool_dir_create "$FIXTURE")"
mkdir -p "$FIXTURE/persist" "$FIXTURE/bootstrap"
ln -sfn "$GUEST" "$FIXTURE/bootstrap/current"

fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$FIXTURE"'/persist"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container; exit 0 ;;
esac
if [ "${1:-}" = exec ]; then
    shift
    [ "${1:-}" != -i ] || shift
    if [ "${1:-}" = -u ]; then shift; shift; fi
    shift
    args=()
    for a in "$@"; do
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST"); else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'
fake_tool_write "$FAKE_DIR" chown 'printf "%s\n" "$*" >> "$DX_FAKE_CHOWN_LOG"; exit 0'

export PATH="$FAKE_DIR:$PATH"
export DX_CONTAINER_NAME=test-container
export DX_BOOTSTRAP_PATH="$FIXTURE/bootstrap"
export DX_BACKUP_DIR="$FIXTURE/backups"
export DX_FAKE_CHOWN_LOG="$FIXTURE/chown.log"

# --- No backup taken yet: dx-restore refuses clearly. ---
if "$BASE_DIR/bin/dx-restore" >/dev/null 2>&1; then test_fail "dx-restore refuses when no backup mirror exists"; else test_pass "dx-restore refuses when no backup mirror exists"; fi

# Seed a mirror by running a real dx-backup first (increment 2's own code,
# already covered by test_dx_backup.sh -- used here only as fixture setup).
# Two files share the git/repo parent directory (two.txt, three.txt) so a
# full restore's directory-precreation pass exercises its own
# already-queued dedup branch, not just the single-file case.
mkdir -p "$FIXTURE/persist/home/dx" "$FIXTURE/persist/git/repo"
printf 'alpha\n' > "$FIXTURE/persist/home/dx/one.txt"
printf 'beta\n' > "$FIXTURE/persist/git/repo/two.txt"
printf 'gamma\n' > "$FIXTURE/persist/git/repo/three.txt"
"$BASE_DIR/bin/dx-backup" >/dev/null

# --- Unsafe restore paths are rejected. ---
for bad in /etc/passwd '../escape' 'a/../../b'; do
    if "$BASE_DIR/bin/dx-restore" "$bad" >/dev/null 2>&1; then test_fail "dx-restore rejects unsafe path '$bad'"; else test_pass "dx-restore rejects unsafe path '$bad'"; fi
done

# --- dry-run: guest files are untouched and unchanged, and nothing is
# reported for identical content. ---
before_one="$(cat "$FIXTURE/persist/home/dx/one.txt")"
dry_out="$("$BASE_DIR/bin/dx-restore" --dry-run 2>&1)"
if [ "$(cat "$FIXTURE/persist/home/dx/one.txt")" = "$before_one" ]; then test_pass "dry-run does not touch the guest"; else test_fail "dry-run does not touch the guest"; fi
if printf '%s\n' "$dry_out" | stdin_matches -F 'already identical: home/dx/one.txt'; then test_pass "dry-run reports identical content correctly"; else test_fail "dry-run reports identical content correctly (got: $dry_out)"; fi

# --- Full round trip: delete everything from the guest, restore it back. ---
rm -rf "$FIXTURE/persist/home" "$FIXTURE/persist/git"
"$BASE_DIR/bin/dx-restore" >/dev/null
if [ "$(cat "$FIXTURE/persist/home/dx/one.txt")" = alpha ] && [ "$(cat "$FIXTURE/persist/git/repo/two.txt")" = beta ] && [ "$(cat "$FIXTURE/persist/git/repo/three.txt")" = gamma ]; then
    test_pass "a full restore round-trips every mirrored file back into the guest"
else
    test_fail "a full restore round-trips every mirrored file back into the guest"
fi

# --- Restoring a single named FILE (not a directory) only creates/pushes
# that one file. ---
rm -f "$FIXTURE/persist/home/dx/one.txt"
"$BASE_DIR/bin/dx-restore" home/dx/one.txt >/dev/null
if [ "$(cat "$FIXTURE/persist/home/dx/one.txt")" = alpha ]; then test_pass "restoring a single named file restores it"; else test_fail "restoring a single named file restores it"; fi

# The chown log is expected to carry the literal guest-absolute path
# (/persist/...): that argument is intentionally NOT remapped by this fake
# (it is fed straight to `container exec`, exactly as a real guest would
# receive it -- only the fake's own tar/selector passthrough needs the
# fixture substitution).
if grep -qF 'dx:dx /persist/home/dx/one.txt' "$FIXTURE/chown.log" 2>/dev/null; then test_pass "restore restores dx ownership on the pushed file"; else test_fail "restore restores dx ownership on the pushed file (log: $(cat "$FIXTURE/chown.log" 2>/dev/null))"; fi

# --- Restoring a named subpath only touches that subpath. ---
rm -rf "$FIXTURE/persist/git"
printf 'unrelated-guest-edit\n' > "$FIXTURE/persist/home/dx/one.txt"
"$BASE_DIR/bin/dx-restore" --force git >/dev/null
if [ "$(cat "$FIXTURE/persist/git/repo/two.txt")" = beta ]; then test_pass "restoring a named subpath restores it"; else test_fail "restoring a named subpath restores it"; fi
if [ "$(cat "$FIXTURE/persist/home/dx/one.txt")" = unrelated-guest-edit ]; then test_pass "restoring a named subpath leaves other paths alone"; else test_fail "restoring a named subpath leaves other paths alone"; fi

# --- Conflict refusal without --force; --force overwrites. ---
set +e
conflict_out="$("$BASE_DIR/bin/dx-restore" 2>&1)"
conflict_rc=$?
set -e
[ "$conflict_rc" -ne 0 ] && test_pass "restore refuses without --force when the guest differs" || test_fail "restore refuses without --force when the guest differs"
if printf '%s\n' "$conflict_out" | stdin_matches -F 'home/dx/one.txt'; then test_pass "the refusal names the conflicting path"; else test_fail "the refusal names the conflicting path"; fi
if [ "$(cat "$FIXTURE/persist/home/dx/one.txt")" = unrelated-guest-edit ]; then test_pass "a refused restore leaves the guest's divergent content untouched"; else test_fail "a refused restore leaves the guest's divergent content untouched"; fi

"$BASE_DIR/bin/dx-restore" --force >/dev/null
if [ "$(cat "$FIXTURE/persist/home/dx/one.txt")" = alpha ]; then test_pass "--force overwrites the guest's divergent content"; else test_fail "--force overwrites the guest's divergent content"; fi

# --- A restore that changes nothing (target already absent from both sides)
# reports cleanly rather than erroring. ---
if "$BASE_DIR/bin/dx-restore" no/such/path >/dev/null 2>&1; then test_fail "restoring a path absent from the mirror is an error"; else test_pass "restoring a path absent from the mirror is an error"; fi

print_summary
exit_with_code
