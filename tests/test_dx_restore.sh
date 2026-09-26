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

# --- A target path that is a SUFFIX of another target's path, queried in the
# same --hash-paths batch, must not be misclassified by a substring match on
# the guest-hash lookup (dx_backup_restore_status). The longer path is
# listed FIRST so its hashes-file line is what a naive substring search for
# the shorter path's own line would find first: "repo/.gitignore\t" is a
# literal substring of "other/repo/.gitignore\tpresent\t...". The longer
# path is present-and-different in the guest (a real conflict); the shorter
# is entirely absent (a plain create). A field-exact match must tell them
# apart. ---
mirror_root="$DX_BACKUP_DIR/$DX_CONTAINER_NAME"
mkdir -p "$mirror_root/current/other/repo" "$mirror_root/current/repo"
printf 'mirror-content-for-longer\n' > "$mirror_root/current/other/repo/.gitignore"
printf 'mirror-content-for-shorter\n' > "$mirror_root/current/repo/.gitignore"
mkdir -p "$FIXTURE/persist/other/repo"
printf 'guest-diverged-content\n' > "$FIXTURE/persist/other/repo/.gitignore"
rm -f "$FIXTURE/persist/repo/.gitignore" 2>/dev/null
suffix_dry_out="$("$BASE_DIR/bin/dx-restore" --dry-run other/repo/.gitignore repo/.gitignore 2>&1)"
if printf '%s\n' "$suffix_dry_out" | stdin_matches -F 'would create: repo/.gitignore'; then
    test_pass "a target path that is a suffix of another target's path is not misread as a conflict (correctly: create)"
else
    test_fail "a target path that is a suffix of another target's path is not misread as a conflict (correctly: create) (got: $suffix_dry_out)"
fi
if printf '%s\n' "$suffix_dry_out" | stdin_matches -F 'would OVERWRITE (conflicts with the guest): other/repo/.gitignore'; then
    test_pass "the longer path (a genuine conflict) is still correctly classified alongside a suffix-colliding sibling"
else
    test_fail "the longer path (a genuine conflict) is still correctly classified alongside a suffix-colliding sibling (got: $suffix_dry_out)"
fi
rm -rf "$FIXTURE/persist/other" "$mirror_root/current/other" "$mirror_root/current/repo"

# --- Branch 17: a restore batch over DX_BACKUP_HASH_PATHS_ARG_THRESHOLD
# (bin/lib/dx-backup.sh; chosen: 1000) ships the path list into the guest as
# a file (--hash-paths-file) instead of one `container exec` positional
# argument per path -- the same ARG_MAX concern, and the same fix shape, as
# dx-backup's own fetch transfer (test_dx_backup.sh). 1001 paths here
# exercises that path; the 2-path suffix-collision case above already
# exercises the small-batch positional-args fast path. ---
bulk_dir="$FIXTURE/persist/home/dx/bulk"
mkdir -p "$bulk_dir"
i=1
while [ "$i" -le 1001 ]; do
    printf 'bulk-%d\n' "$i" > "$bulk_dir/f$i.txt"
    i=$((i + 1))
done
"$BASE_DIR/bin/dx-backup" >/dev/null
rm -rf "$bulk_dir"

BULK_EXEC_LOG="$FIXTURE/bulk-exec.log"
: > "$BULK_EXEC_LOG"
fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$FIXTURE"'/persist"
LOG="'"$BULK_EXEC_LOG"'"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container; exit 0 ;;
esac
if [ "${1:-}" = exec ]; then
    shift
    has_i=0
    if [ "${1:-}" = -i ]; then has_i=1; shift; fi
    if [ "${1:-}" = -u ]; then shift; shift; fi
    shift
    {
        echo "---EXEC---"
        echo "has_i=$has_i"
        for a in "$@"; do printf "ARG:%s\n" "$a"; done
    } >> "$LOG"
    args=()
    for a in "$@"; do
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST"); else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'

bulk_dry_out="$("$BASE_DIR/bin/dx-restore" --dry-run home/dx/bulk 2>&1)"
bulk_create_count="$(printf '%s\n' "$bulk_dry_out" | { grep -c '^would create: home/dx/bulk/' || true; })"
if [ "$bulk_create_count" -eq 1001 ]; then
    test_pass "a restore batch over the ARG_MAX threshold (1001) is still classified correctly"
else
    test_fail "a restore batch over the ARG_MAX threshold (1001) is still classified correctly (got $bulk_create_count)"
fi

if grep -Fxq 'ARG:--hash-paths-file' "$BULK_EXEC_LOG"; then
    test_pass "a restore batch over the threshold uses --hash-paths-file, not one positional argument per path"
else
    test_fail "a restore batch over the threshold uses --hash-paths-file, not one positional argument per path (log: $(cat "$BULK_EXEC_LOG"))"
fi
if grep -Fxq 'ARG:--hash-paths' "$BULK_EXEC_LOG"; then
    test_fail "a restore batch over the threshold does not also use the plain positional --hash-paths mode"
else
    test_pass "a restore batch over the threshold does not also use the plain positional --hash-paths mode"
fi

"$BASE_DIR/bin/dx-restore" --force home/dx/bulk >/dev/null
bulk_restored_count="$(find "$bulk_dir" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ "$bulk_restored_count" -eq 1001 ]; then
    test_pass "a restore batch over the threshold pushes every file back correctly"
else
    test_fail "a restore batch over the threshold pushes every file back correctly (got $bulk_restored_count)"
fi

# --- The SHIP exec itself fails for a large batch: dx-restore reports
# failure cleanly rather than falling through to the plain --hash-paths
# call (which would risk the very ARG_MAX this threshold exists to avoid). ---
: > "$BULK_EXEC_LOG"
fake_tool_write "$FAKE_DIR" container '
FIX_PERSIST="'"$FIXTURE"'/persist"
LOG="'"$BULK_EXEC_LOG"'"
case "${1:-}" in
    system) exit 0 ;;
    list) printf "%s\n" test-container; exit 0 ;;
esac
if [ "${1:-}" = exec ]; then
    shift
    has_i=0
    if [ "${1:-}" = -i ]; then has_i=1; shift; fi
    if [ "${1:-}" = -u ]; then shift; shift; fi
    shift
    {
        echo "---EXEC---"
        echo "has_i=$has_i"
        for a in "$@"; do printf "ARG:%s\n" "$a"; done
    } >> "$LOG"
    if [ "${1:-}" = sh ]; then exit 42; fi
    args=()
    for a in "$@"; do
        if [ "$a" = /persist ]; then args+=("$FIX_PERSIST"); else args+=("$a"); fi
    done
    exec "${args[@]}"
fi
exit 1
'
set +e
bulk_ship_fail_out="$("$BASE_DIR/bin/dx-restore" --dry-run home/dx/bulk 2>&1)"
bulk_ship_fail_rc=$?
set -e
[ "$bulk_ship_fail_rc" -ne 0 ] && test_pass "a restore batch over the threshold reports failure when the ship exec fails" || test_fail "a restore batch over the threshold reports failure when the ship exec fails (got: $bulk_ship_fail_out)"
if grep -Fxq 'ARG:--hash-paths' "$BULK_EXEC_LOG"; then
    test_fail "a failed ship exec does not fall back to the plain positional --hash-paths mode"
else
    test_pass "a failed ship exec does not fall back to the plain positional --hash-paths mode"
fi

rm -rf "$bulk_dir" "$mirror_root/current/home/dx/bulk"

print_summary
exit_with_code
