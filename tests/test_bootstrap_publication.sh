#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=../bin/lib/dx-ssh-common.sh
source "$BASE_DIR/bin/lib/dx-ssh-common.sh"
test_section "Transactional Bootstrap Publication"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-bootstrap-publication.XXXXXX")"
trap 'chmod -R u+w "$fixture" 2>/dev/null || true; rm -rf "$fixture"' EXIT
fake_dir="$(fake_tool_dir_create "$fixture")"
root="$fixture/guest-bootstrap"; good="$fixture/good"; good_two="$fixture/good-two"; broken="$fixture/broken"
mkdir -p "$root" "$good" "$good_two" "$broken"
: > "$root/.dx-bootstrap-waiting"
for file in bootstrap.sh flake.nix flake.lock; do printf '%s\n' "good-$file" > "$good/$file"; done
for file in bootstrap.sh flake.nix flake.lock; do printf '%s\n' "good-two-$file" > "$good_two/$file"; done
chmod 0755 "$good/bootstrap.sh"
chmod 0755 "$good_two/bootstrap.sh"
printf '%s\n' broken-bootstrap > "$broken/bootstrap.sh"
printf '%s\n' broken-flake > "$broken/flake.nix"

fake_tool_write "$fake_dir" container '
case "${1:-}" in
  system) exit 0 ;;
  list) printf "%s\n" "$DX_CONTAINER_NAME"; exit 0 ;;
  exec)
    shift
    [ "${1:-}" != -i ] || shift
    shift
    exec "$@"
    ;;
esac
exit 1
'
fake_tool_write "$fake_dir" chown 'exit 0'
fake_tool_write "$fake_dir" cat '
if [ "${1:-}" = /proc/sys/kernel/random/boot_id ]; then
  printf "%s\n" test-boot-id
elif [ "${1:-}" != "${1#/proc/}" ] && [ "${1##*/}" = stat ]; then
  printf "1 (sh) S"; field=4; while [ "$field" -le 21 ]; do printf " 0"; field=$((field + 1)); done; printf " 99\n"
else
  exec /bin/cat "$@"
fi
'
fake_tool_write "$fake_dir" awk '
case "$*" in */proc/*/stat*) printf "%s\n" 99 ;; *) exec /usr/bin/awk "$@" ;; esac
'
fake_tool_write "$fake_dir" mv '
if [ "${1:-}" = -Tf ]; then rm -f "$3"; exec /bin/mv -f "$2" "$3"; else exec /bin/mv "$@"; fi
'

run_sync() {
    env PATH="$fake_dir:$PATH" \
        DX_CONTAINER_NAME=dx-bootstrap-contract \
        DX_BOOTSTRAP_SOURCE="$1" \
        DX_BOOTSTRAP_PATH="$root" \
        DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
        "$BASE_DIR/bin/dx-sync-bootstrap"
}

mkdir -p "$root/.locks/publication"
if run_sync "$good" >/dev/null; then test_pass "valid staged bootstrap publishes"; else test_fail "valid staged bootstrap publishes"; fi
first_target="$(readlink "$root/current")"
if [ -n "$first_target" ] && [ "$(cat "$root/current/bootstrap.sh")" = good-bootstrap.sh ]; then
    test_pass "current points at the complete staged generation"
else
    test_fail "current points at the complete staged generation"
fi
if [ -L "$root/bootstrap.sh" ] && [ "$(readlink "$root/bootstrap.sh")" = current/bootstrap.sh ]; then
    test_pass "flat-layout compatibility path follows current"
else
    test_fail "flat-layout compatibility path follows current"
fi
mode="$(dx_path_mode "$root/current/flake.nix")"
[ "$mode" = 444 ] && test_pass "published bootstrap files are read-only" || test_fail "published bootstrap files are read-only"

if run_sync "$broken" >/dev/null 2>&1; then test_fail "incomplete staged bootstrap is rejected"; else test_pass "incomplete staged bootstrap is rejected"; fi
if [ "$(readlink "$root/current")" = "$first_target" ] && [ "$(cat "$root/current/bootstrap.sh")" = good-bootstrap.sh ]; then
    test_pass "failed extraction/validation preserves last-known-good current"
else
    test_fail "failed extraction/validation preserves last-known-good current"
fi
if find "$root/generations" -maxdepth 1 -name '.staging-*' -print | stdin_matches .; then
    test_fail "failed bootstrap staging is collected"
else
    test_pass "failed bootstrap staging is collected"
fi

# A fully matching lease protects an otherwise obsolete generation during GC.
leased_id=leased-generation
mkdir "$root/generations/$leased_id"
for file in bootstrap.sh flake.nix flake.lock; do printf '%s\n' "leased-$file" > "$root/generations/$leased_id/$file"; done
mkdir -p "$root/.locks/leases"
printf '%s\t%s\t%s\t%s\n' "$leased_id" test-boot-id 4242 99 > "$root/.locks/leases/$leased_id.4242"
if run_sync "$good_two" >/dev/null && [ -d "$root/generations/$leased_id" ] && [ -f "$root/.locks/leases/$leased_id.4242" ]; then
    test_pass "collection retains a generation with a fully matching live lease"
else
    test_fail "collection retains a generation with a fully matching live lease"
fi

# PID reuse (same PID, different start identity) invalidates the lease and lets
# the next publication collect the stale generation.
stale_id=stale-generation
mkdir "$root/generations/$stale_id"
for file in bootstrap.sh flake.nix flake.lock; do printf '%s\n' "stale-$file" > "$root/generations/$stale_id/$file"; done
printf '%s\t%s\t%s\t%s\n' "$stale_id" test-boot-id 4343 98 > "$root/.locks/leases/$stale_id.4343"
if run_sync "$good" >/dev/null && [ ! -e "$root/generations/$stale_id" ] && [ ! -e "$root/.locks/leases/$stale_id.4343" ]; then
    test_pass "collection rejects a stale lease after PID identity reuse"
else
    test_fail "collection rejects a stale lease after PID identity reuse"
fi

# Two writers serialize through the publication lock. The final current and
# its recorded predecessor must both be complete generations.
run_sync "$good" >/dev/null & sync_one=$!
run_sync "$good_two" >/dev/null & sync_two=$!
sync_status=0
wait "$sync_one" || sync_status=1
wait "$sync_two" || sync_status=1
current_id="$(readlink "$root/current")"; current_id=${current_id#generations/}
predecessor_id="$(cat "$root/generations/$current_id/.predecessor")"
if [ "$sync_status" -eq 0 ] \
    && [ -f "$root/generations/$current_id/bootstrap.sh" ] \
    && [ -n "$predecessor_id" ] \
    && [ -f "$root/generations/$predecessor_id/bootstrap.sh" ]; then
    test_pass "concurrent syncs retain complete current and predecessor generations"
else
    test_fail "concurrent syncs retain complete current and predecessor generations"
fi

assert_file_contains_literal "$BASE_DIR/bin/lib/dx-ssh-common.sh" 'acquire_publication_lock' "launcher creates its execution lease under the publication lock"
assert_file_contains_literal "$BASE_DIR/bin/lib/dx-ssh-common.sh" 'payload="$root/generations/$generation"' "launcher executes the exact leased generation"

# The execution lease is written under a restrictive umask, but that umask must
# not survive the exec into the guest bootstrap. A leaked 077 silently strips
# group and other bits from every file the bootstrap creates without an explicit
# mode -- /etc/os-release among them, which then fails to be readable by dx.
# This only affects the generation layout, so a flat-layout guest looks correct
# while a generation guest does not. Executing the launcher is the point: the
# two assertions above inspect its text and cannot observe an inherited umask.
launch_root="$fixture/launch"
mkdir -p "$launch_root/generations/gen-umask" "$launch_root/.locks/leases"
cat > "$launch_root/generations/gen-umask/bootstrap.sh" <<'GUEST'
#!/bin/sh
umask > "$(dirname "$0")/../../recorded-umask"
GUEST
chmod 0755 "$launch_root/generations/gen-umask/bootstrap.sh"
ln -sfn generations/gen-umask "$launch_root/current"

# The launcher ensures /persist exists, which a test host will not permit.
fake_tool_write "$fake_dir" mkdir '
count=$#; index=0
while [ "$index" -lt "$count" ]; do
    argument=$1; shift
    [ "$argument" = /persist ] || set -- "$@" "$argument"
    index=$((index + 1))
done
exec /bin/mkdir "$@"
'
dx_bootstrap_launch_command > "$launch_root/launcher.sh"
env PATH="$fake_dir:$PATH" sh "$launch_root/launcher.sh" "$launch_root" >"$launch_root/launcher.out" 2>&1 || true

# The generation a guest boots is otherwise unobservable. `container exec` is
# unavailable on a guest whose bootstrap died -- which is exactly when the
# question "is this even the code I published?" matters -- but `container logs`
# still works, so the launcher must name its resolved generation on the way
# past. See dx-start-plan.md.
if grep -q 'gen-umask' "$launch_root/launcher.out" 2>/dev/null; then
    test_pass "launcher logs the bootstrap generation it resolved"
else
    test_fail "launcher logs the bootstrap generation it resolved (got '$(cat "$launch_root/launcher.out" 2>/dev/null || true)')"
fi

recorded="$(cat "$launch_root/recorded-umask" 2>/dev/null || true)"
if [ -n "$recorded" ] && [ "$recorded" != 0077 ]; then
    test_pass "launcher does not leak its lease umask into the guest bootstrap"
else
    test_fail "launcher does not leak its lease umask into the guest bootstrap (got ${recorded:-none})"
fi

# The other half of that contract: scoping the umask must not stop protecting
# the lease it was introduced for.
lease_file="$(find "$launch_root/.locks/leases" -type f -name 'gen-umask.*' -print 2>/dev/null | head -1)"
lease_mode="$([ -n "$lease_file" ] && dx_path_mode "$lease_file" || true)"
if [ "$lease_mode" = 600 ]; then
    test_pass "execution lease is still written privately"
else
    test_fail "execution lease is still written privately (mode ${lease_mode:-none})"
fi

# --- Unchanged content must not mint a new generation.
#
# Generation ids come from the clock (`date -u ...-$$`), so before this every
# sync published a distinct id and repointed `current` even when nothing had
# changed. Because dx-start-container syncs *after* starting, the guest was
# then permanently "running an older generation" than the one just published,
# and the drift warning fired on every single start -- which meant it could not
# distinguish "you have unsynced changes" from "you just synced".
# Establish a known current generation first: earlier cases in this file leave
# `current` pointing at whichever payload they published last, so re-syncing
# $good without this would be a genuine content change.
run_sync "$good" >/dev/null
unchanged_before="$(readlink "$root/current")"
unchanged_count_before="$(find "$root/generations" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
unchanged_output="$(run_sync "$good" 2>&1)"
unchanged_after="$(readlink "$root/current")"
unchanged_count_after="$(find "$root/generations" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [ "$unchanged_after" = "$unchanged_before" ] && [ "$unchanged_count_after" = "$unchanged_count_before" ]; then
    test_pass "re-syncing identical content publishes no new generation"
else
    test_fail "re-syncing identical content publishes no new generation (was $unchanged_before/$unchanged_count_before, now $unchanged_after/$unchanged_count_after)"
fi
case "$unchanged_output" in
    *"unchanged"*) test_pass "an unchanged sync says so rather than claiming a publication" ;;
    *) test_fail "an unchanged sync says so rather than claiming a publication (got '$unchanged_output')" ;;
esac

# The restart path: the guest launcher clears .dx-bootstrap-ready on every boot
# and waits for `current` or that marker, so the marker is always absent when
# dx-start-container syncs. An unchanged sync must still skip here -- gating the
# skip on that marker made it never fire on the one path the drift warning
# actually fires on.
rm -f "$root/.dx-bootstrap-ready"
restart_before="$(readlink "$root/current")"
restart_output="$(run_sync "$good" 2>&1)"
if [ "$(readlink "$root/current")" = "$restart_before" ]; then
    test_pass "unchanged content skips even when the boot readiness marker is absent"
else
    test_fail "unchanged content skips even when the boot readiness marker is absent (got '$restart_output')"
fi

# Publishing prunes leases from earlier boots; a skip must do the same, or the
# drift check reads a stale PID 1 lease and names the wrong running generation.
mkdir -p "$root/.locks/leases"
printf 'stale-gen\tother-boot-id\t1\t29\n' > "$root/.locks/leases/stale-gen.1"
printf 'live-gen\ttest-boot-id\t1\t29\n' > "$root/.locks/leases/live-gen.1"
run_sync "$good" >/dev/null
if [ ! -e "$root/.locks/leases/stale-gen.1" ] && [ -f "$root/.locks/leases/live-gen.1" ]; then
    test_pass "an unchanged sync prunes leases from earlier boots and keeps the live one"
else
    test_fail "an unchanged sync prunes leases from earlier boots and keeps the live one"
fi

# A generation published before digests existed has none recorded, so the sync
# must fall back to publishing rather than skipping on an empty comparison.
chmod -R u+w "$root/current/" 2>/dev/null || true
rm -f "$root/current/.dx-content-digest"
legacy_before="$(readlink "$root/current")"
run_sync "$good" >/dev/null
if [ "$(readlink "$root/current")" != "$legacy_before" ] && [ -f "$root/current/.dx-content-digest" ]; then
    test_pass "a generation with no recorded digest republishes and records one"
else
    test_fail "a generation with no recorded digest republishes and records one"
fi

# The other half: a real content change must still publish.
changed_before="$(readlink "$root/current")"
run_sync "$good_two" >/dev/null
changed_after="$(readlink "$root/current")"
if [ "$changed_after" != "$changed_before" ] && [ "$(cat "$root/current/bootstrap.sh")" = good-two-bootstrap.sh ]; then
    test_pass "changed content still publishes a new generation"
else
    test_fail "changed content still publishes a new generation"
fi

print_summary
exit_with_code
