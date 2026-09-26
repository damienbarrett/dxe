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

# --- The restart path must run the generation published for *this* boot.
#
# `current` already points at the previous boot's generation when a container
# restarts, so a launcher that waits only for `current` to exist resolves it
# immediately -- before dx-start-container has had any chance to sync. The guest
# then runs the previous boot's payload. That is why a bootstrap change has
# needed two starts to take effect, and why a guest whose bootstrap died could
# not be recovered by syncing: dx-sync-bootstrap refuses when the container is
# not running, and the container will not stay running on the broken payload.
restart_root="$fixture/launch-restart"
mkdir -p "$restart_root/generations/gen-previous" "$restart_root/generations/gen-current" "$restart_root/.locks/leases"
for restart_gen in gen-previous gen-current; do
    cat > "$restart_root/generations/$restart_gen/bootstrap.sh" <<GUEST
#!/bin/sh
printf '%s\n' "$restart_gen" > "$restart_root/ran"
GUEST
    chmod 0755 "$restart_root/generations/$restart_gen/bootstrap.sh"
done
ln -sfn generations/gen-previous "$restart_root/current"
dx_bootstrap_launch_command > "$restart_root/launcher.sh"

env PATH="$fake_dir:$PATH" sh "$restart_root/launcher.sh" "$restart_root" >"$restart_root/out" 2>&1 &
restart_launcher_pid=$!
# Let the launcher reach its wait before the host publishes, which is the
# ordering a real start has.
sleep 2
ln -sfn generations/gen-current "$restart_root/current"
: > "$restart_root/.dx-bootstrap-ready"
wait "$restart_launcher_pid" 2>/dev/null || true

restart_ran="$(cat "$restart_root/ran" 2>/dev/null || true)"
if [ "$restart_ran" = gen-current ]; then
    test_pass "the launcher runs the generation published for this boot, not the previous boot's"
else
    test_fail "the launcher runs the generation published for this boot, not the previous boot's (ran '${restart_ran:-none}')"
fi

# Availability guard: a container started outside dx-start-container gets no
# publication signal at all. Waiting forever would be worse than running the
# payload already present, so fall back after a bounded grace and say so.
grace_root="$fixture/launch-grace"
mkdir -p "$grace_root/generations/gen-only" "$grace_root/.locks/leases"
cat > "$grace_root/generations/gen-only/bootstrap.sh" <<GUEST
#!/bin/sh
printf '%s\n' gen-only > "$grace_root/ran"
GUEST
chmod 0755 "$grace_root/generations/gen-only/bootstrap.sh"
ln -sfn generations/gen-only "$grace_root/current"
dx_bootstrap_launch_command > "$grace_root/launcher.sh"
env DX_BOOTSTRAP_PUBLISH_GRACE=2 PATH="$fake_dir:$PATH" sh "$grace_root/launcher.sh" "$grace_root" >"$grace_root/out" 2>&1 || true
grace_ran="$(cat "$grace_root/ran" 2>/dev/null || true)"
if [ "$grace_ran" = gen-only ] && grep -q 'no publication signal' "$grace_root/out"; then
    test_pass "an unsignalled start falls back to the current generation after a bounded wait"
else
    test_fail "an unsignalled start falls back to the current generation after a bounded wait (ran '${grace_ran:-none}', out '$(cat "$grace_root/out" 2>/dev/null || true)')"
fi

# The launcher can only wait for a signal the host always sends. An unchanged
# sync skips publication, so if only the publishing path signalled readiness,
# every restart with unchanged content would stall for the full grace.
run_sync "$good" >/dev/null
rm -f "$root/.dx-bootstrap-ready"
run_sync "$good" >/dev/null
if [ -f "$root/.dx-bootstrap-ready" ]; then
    test_pass "an unchanged sync still signals boot readiness"
else
    test_fail "an unchanged sync still signals boot readiness"
fi

# --- D7 option 3: dx-start-container confirms, bounded, that a real publish
# was actually picked up before declaring the start a success -- Q4 "fail the
# start" (docs/refactor/decisions/D7-start-generation.md). Drive the real
# bin/dx-start-container end to end against the same fake `container` (exec
# maps to local execution) that already exercises the real dx-sync-bootstrap
# above, so this exercises the actual wiring, not just the two helper
# functions in isolation. Each scenario gets its own fresh bootstrap-path
# root so none of this file's earlier fixture history (leases, generations)
# can leak into what these assertions check.
start_home="$fixture/start-container-home"

run_start_container() {
    env PATH="$fake_dir:$PATH" \
        HOME="$start_home" \
        DX_CONTAINER_NAME=dx-start-contract \
        DX_NIX_VOLUME=dx-start-contract-nix \
        DX_BOOTSTRAP_SOURCE="$1" \
        DX_BOOTSTRAP_PATH="$2" \
        DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
        DX_BOOTSTRAP_CONFIRM_TIMEOUT="${3:-2}" \
        "$BASE_DIR/bin/dx-start-container"
}

# Write a PID-1 execution lease naming whatever generation a start under $1
# just published, as soon as (optionally, after an extra delay) that
# generation directory appears -- standing in for the guest launcher noticing
# the publish and leasing it, without a real guest.
lease_the_published_generation() {
    local root="$1" delay="${2:-0}" gen=""
    for _ in $(seq 1 100); do
        # Exclude the transient .staging-<gen> directory a publish stages
        # under before its atomic rename to the real generation id -- catching
        # it here would lease a name the launcher (or, in this fixture, the
        # confirm loop) can never actually see published.
        gen="$(find "$root/generations" -mindepth 1 -maxdepth 1 -type d ! -name '.staging-*' 2>/dev/null | head -1)" || true
        [ -n "$gen" ] && break
        sleep 0.05
    done
    [ -n "$gen" ] || return 1
    gen=${gen##*/}
    [ "$delay" = 0 ] || sleep "$delay"
    mkdir -p "$root/.locks/leases"
    printf '%s\t%s\t%s\t%s\n' "$gen" test-boot-id 1 99 > "$root/.locks/leases/$gen.1"
}

# (a) Published, lease names the new generation within the bound: success.
start_root_a="$fixture/start-a"; mkdir -p "$start_root_a"; : > "$start_root_a/.dx-bootstrap-waiting"
lease_the_published_generation "$start_root_a" 0 &
lease_a_pid=$!
start_a_status=0
start_a_out="$(run_start_container "$good" "$start_root_a" 3 2>&1)" || start_a_status=$?
wait "$lease_a_pid" 2>/dev/null || true
if [ "$start_a_status" -eq 0 ] && printf '%s\n' "$start_a_out" | stdin_matches -F 'is ready.' \
    && ! printf '%s\n' "$start_a_out" | stdin_matches -F 'Error:'; then
    test_pass "dx-start-container succeeds when the lease names the just-published generation within the bound"
else
    test_fail "dx-start-container succeeds when the lease names the just-published generation within the bound (status $start_a_status, out '$start_a_out')"
fi

# (b) Published, lease never names it: the start fails, naming both
# generations and the remedy, with nothing left half-done (no lease writer at
# all here -- the guest simply never picks the publish up).
start_root_b="$fixture/start-b"; mkdir -p "$start_root_b"; : > "$start_root_b/.dx-bootstrap-waiting"
start_b_status=0
start_b_out="$(run_start_container "$good" "$start_root_b" 2 2>&1)" || start_b_status=$?
start_b_published="$(printf '%s\n' "$start_b_out" | sed -n 's/^Bootstrap generation \(.*\) is ready\.$/\1/p' | tail -1)"
if [ "$start_b_status" -ne 0 ] && [ -n "$start_b_published" ] \
    && printf '%s\n' "$start_b_out" | stdin_matches -F "Error: dx-start-contract published bootstrap generation $start_b_published" \
    && printf '%s\n' "$start_b_out" | stdin_matches -F 'dx-stop-container'; then
    test_pass "dx-start-container fails the start when the lease never names the published generation, naming both and the remedy"
else
    test_fail "dx-start-container fails the start when the lease never names the published generation, naming both and the remedy (status $start_b_status, out '$start_b_out')"
fi
if [ -d "$start_root_b/.locks/publication" ]; then
    test_fail "a failed confirmation leaves the publication lock held (no partial side effects)"
else
    test_pass "a failed confirmation leaves the publication lock held (no partial side effects)"
fi

# (c) Unchanged content (skip path): today's behaviour exactly -- no wait,
# even with a generously large bound configured, proving the confirm loop
# never runs on this path.
start_root_c="$fixture/start-c"; mkdir -p "$start_root_c"; : > "$start_root_c/.dx-bootstrap-waiting"
run_start_container "$good" "$start_root_c" 1 >/dev/null 2>&1 || true
SECONDS=0
start_c_status=0
start_c_out="$(run_start_container "$good" "$start_root_c" 30 2>&1)" || start_c_status=$?
start_c_elapsed=$SECONDS
if [ "$start_c_status" -eq 0 ] && printf '%s\n' "$start_c_out" | stdin_matches -F 'stays current' \
    && ! printf '%s\n' "$start_c_out" | stdin_matches -F 'Error:' && [ "$start_c_elapsed" -lt 5 ]; then
    test_pass "dx-start-container's unchanged-content skip is unaffected: no wait despite a 30s bound"
else
    test_fail "dx-start-container's unchanged-content skip is unaffected: no wait despite a 30s bound (status $start_c_status, elapsed ${start_c_elapsed}s, out '$start_c_out')"
fi

# (e) Published, lease appears late but within the bound: still succeeds --
# guards against the deadline being too tight, and against a poll loop that
# only checks once instead of actually polling (a 2s writer delay forces at
# least one full 1s sleep-and-recheck cycle before the match).
start_root_e="$fixture/start-e"; mkdir -p "$start_root_e"; : > "$start_root_e/.dx-bootstrap-waiting"
lease_the_published_generation "$start_root_e" 2 &
lease_e_pid=$!
SECONDS=0
start_e_status=0
start_e_out="$(run_start_container "$good" "$start_root_e" 5 2>&1)" || start_e_status=$?
start_e_elapsed=$SECONDS
wait "$lease_e_pid" 2>/dev/null || true
if [ "$start_e_status" -eq 0 ] && [ "$start_e_elapsed" -ge 1 ] && [ "$start_e_elapsed" -lt 5 ] \
    && ! printf '%s\n' "$start_e_out" | stdin_matches -F 'Error:'; then
    test_pass "dx-start-container succeeds on a lease that appears late but within the bound (the poll loop actually polls)"
else
    test_fail "dx-start-container succeeds on a lease that appears late but within the bound (status $start_e_status, elapsed ${start_e_elapsed}s, out '$start_e_out')"
fi

assert_file_not_contains "$BASE_DIR/bin/dx-start-container" 'OLD_BASE' "dx-start-container no longer probes the guest for the old-base signature (docs/refactor/migration-gates.md#old-base-guards)"

print_summary
exit_with_code
