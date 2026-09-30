#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=../bin/lib/dx-host-util.sh
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# WP5.2: dx_bootstrap_launch_command and dx_sync_guest_program both now
# concatenate dx_guest_publication_protocol_snippet's rendered text in
# front of their own logic (bin/lib/dx-bootstrap-protocol.sh), so this file
# must exist before either one is sourced -- exactly the order
# bin/dx-lib.sh itself uses.
# shellcheck source=../bin/lib/dx-bootstrap-protocol.sh
source "$BASE_DIR/bin/lib/dx-bootstrap-protocol.sh"
# shellcheck source=../bin/lib/dx-ssh-common.sh
source "$BASE_DIR/bin/lib/dx-ssh-common.sh"
# shellcheck source=../bin/lib/dx-bootstrap-sync.sh
source "$BASE_DIR/bin/lib/dx-bootstrap-sync.sh"
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

# WP4.2 / Fable A6: the "wait for the container to be running" preflight
# (bin/dx-sync-bootstrap, immediately after the container_exists check) must
# honour DX_BOOTSTRAP_WAIT_TIMEOUT -- not a hard-coded 30 -- and its sleeps
# must be injectable, not a bare `sleep 1`, or this case waits out a real 30s
# against unmigrated code. A runtime whose container exists but never reports
# running must fail fast, with the preflight's existing message, after at
# most DX_BOOTSTRAP_WAIT_TIMEOUT sleeps.
wait_fixture="$fixture/wait-preflight"; mkdir -p "$wait_fixture"
fake_dir_wait="$(fake_tool_dir_create "$wait_fixture")"
fake_tool_write "$fake_dir_wait" container '
case "${1:-}" in
  list)
    shift
    case " $* " in
      *" -a "*) printf "%s\n" "$DX_CONTAINER_NAME" ;;
    esac
    exit 0
    ;;
esac
exit 1
'
fake_tool_write "$fake_dir_wait" fake-sleep '
[ -z "${DXE_FAKE_SLEEP_LOG:-}" ] || printf "%s\n" "$1" >> "$DXE_FAKE_SLEEP_LOG"
exit 0
'
wait_sleep_log="$wait_fixture/sleep.log"
wait_status=0
wait_out="$(env PATH="$fake_dir_wait:$PATH" \
    DX_CONTAINER_NAME=dx-bootstrap-wait-contract \
    DX_BOOTSTRAP_SOURCE="$good" \
    DX_BOOTSTRAP_PATH="$wait_fixture/root" \
    DX_BOOTSTRAP_WAIT_TIMEOUT=2 \
    DX_SLEEP=fake-sleep \
    DXE_FAKE_SLEEP_LOG="$wait_sleep_log" \
    "$BASE_DIR/bin/dx-sync-bootstrap" 2>&1)" || wait_status=$?
if [ "$wait_status" -ne 0 ] && printf '%s\n' "$wait_out" | stdin_matches -F 'Error: Container dx-bootstrap-wait-contract is not running. Run ./bin/dx-start-container first.'; then
    test_pass "a container that never starts fails the sync fast with the existing message"
else
    test_fail "a container that never starts fails the sync fast with the existing message (status=$wait_status, out: $wait_out)"
fi
wait_sleep_count=0
[ -f "$wait_sleep_log" ] && wait_sleep_count="$(wc -l < "$wait_sleep_log" | tr -d ' ')"
if [ "$wait_sleep_count" -ge 1 ] && [ "$wait_sleep_count" -le 2 ]; then
    test_pass "the container-running preflight honours DX_BOOTSTRAP_WAIT_TIMEOUT via the injectable DX_SLEEP seam, not a hard-coded 30 real sleeps"
else
    test_fail "the container-running preflight honours DX_BOOTSTRAP_WAIT_TIMEOUT via the injectable DX_SLEEP seam, not a hard-coded 30 real sleeps (fake sleep recorded $wait_sleep_count calls)"
fi

# WP5.2: acquire_publication_lock was inlined in the launcher; the lock
# acquisition itself now comes from the shared
# dx_guest_publication_protocol_snippet (bin/lib/dx-bootstrap-protocol.sh),
# concatenated in front of the launcher's own remaining logic below.
assert_file_contains_literal "$BASE_DIR/bin/lib/dx-ssh-common.sh" 'dx_guest_publication_protocol_snippet' "launcher renders the shared publication-lock protocol in front of its own logic"
assert_file_contains_literal "$BASE_DIR/bin/lib/dx-ssh-common.sh" 'publication_lock_acquire "$lock" 30 || exit 1' "launcher creates its execution lease under the publication lock"
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
# ordering a real start has -- proven by polling for the SAME readiness
# marker the launcher itself writes (dx_bootstrap_launch_command,
# bin/lib/dx-ssh-common.sh: `touch "$root/.dx-bootstrap-waiting"` runs
# immediately before it enters its `while [ ! -f .../.dx-bootstrap-ready" ]`
# loop) instead of guessing how long a backgrounded launcher takes to get
# scheduled with a fixed `sleep 2` (Fable D10), which either wastes time on
# a fast host or races a loaded one.
if wait_until "[ -f '$restart_root/.dx-bootstrap-waiting' ]" 100; then
    test_pass "the launcher reaches its wait loop (readiness marker present) before the host publishes"
else
    test_fail "the launcher reaches its wait loop (readiness marker present) before the host publishes"
fi
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

# A recording PASSTHROUGH for DX_SLEEP (Fable D10): logs the call, then
# actually sleeps for real (via the genuine `sleep` binary elsewhere on
# PATH -- this fixture never names anything else "sleep"), so a fixture that
# needs a REAL background writer's delay to actually elapse (case (e) below)
# keeps working exactly as before, but the count of confirm-loop polls is
# now a transcript on disk instead of an elapsed-seconds guess: zero
# recorded sleeps proves the skip path never entered the confirm loop at
# all; one or more proves the confirm loop actually polled rather than
# checking once. Never a no-op stub (that would only prove the confirm loop
# stopped calling sleep, not that it kept working) -- see this repo's own
# "no-op stub hides root-vs-dx bugs" lesson applied to timing instead of
# privilege.
fake_tool_write "$fake_dir" fake-sleep '
[ -z "${DXE_FAKE_SLEEP_LOG:-}" ] || printf "%s\n" "$1" >> "$DXE_FAKE_SLEEP_LOG"
exec sleep "$@"
'

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
    # Exclude the transient .staging-<gen> directory a publish stages under
    # before its atomic rename to the real generation id -- catching it here
    # would lease a name the launcher (or, in this fixture, the confirm loop)
    # can never actually see published. wait_until (tests/lib/harness.sh,
    # Fable D10) polls this bounded by attempt count, not a bare `sleep 0.05`
    # loop asserting nothing about how long it took.
    _dxe_bootstrap_publication_gen_found() {
        gen="$(find "$root/generations" -mindepth 1 -maxdepth 1 -type d ! -name '.staging-*' 2>/dev/null | head -1)" || true
        [ -n "$gen" ]
    }
    wait_until _dxe_bootstrap_publication_gen_found 100
    unset -f _dxe_bootstrap_publication_gen_found
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
# never runs on this path. Proven through the DX_SLEEP transcript (zero
# recorded calls) rather than an elapsed-seconds bound (Fable D10), which
# would falsely fail on a host too loaded to finish the skip path in 5s and
# falsely pass a confirm loop that polled a handful of times very quickly.
start_root_c="$fixture/start-c"; mkdir -p "$start_root_c"; : > "$start_root_c/.dx-bootstrap-waiting"
run_start_container "$good" "$start_root_c" 1 >/dev/null 2>&1 || true
start_c_sleep_log="$fixture/start-c-sleep.log"
start_c_status=0
start_c_out="$(DX_SLEEP=fake-sleep DXE_FAKE_SLEEP_LOG="$start_c_sleep_log" \
    run_start_container "$good" "$start_root_c" 30 2>&1)" || start_c_status=$?
start_c_sleep_count=0
[ -f "$start_c_sleep_log" ] && start_c_sleep_count="$(wc -l < "$start_c_sleep_log" | tr -d ' ')"
if [ "$start_c_status" -eq 0 ] && printf '%s\n' "$start_c_out" | stdin_matches -F 'stays current' \
    && ! printf '%s\n' "$start_c_out" | stdin_matches -F 'Error:' && [ "$start_c_sleep_count" -eq 0 ]; then
    test_pass "dx-start-container's unchanged-content skip is unaffected: no wait despite a 30s bound"
else
    test_fail "dx-start-container's unchanged-content skip is unaffected: no wait despite a 30s bound (status $start_c_status, sleeps $start_c_sleep_count, out '$start_c_out')"
fi

# (e) Published, lease appears late but within the bound: still succeeds --
# guards against the deadline being too tight, and against a poll loop that
# only checks once instead of actually polling (a 2s writer delay forces at
# least one full 1s sleep-and-recheck cycle before the match). The writer's
# 2s delay is real (a genuine background process, not something DX_SLEEP
# could stand in for), so DX_SLEEP here is the RECORDING passthrough
# (actually sleeps, just also logs), and "the poll loop actually polls" is
# proven by at least one recorded sleep rather than an elapsed-seconds
# window (Fable D10).
start_root_e="$fixture/start-e"; mkdir -p "$start_root_e"; : > "$start_root_e/.dx-bootstrap-waiting"
lease_the_published_generation "$start_root_e" 2 &
lease_e_pid=$!
start_e_sleep_log="$fixture/start-e-sleep.log"
start_e_status=0
start_e_out="$(DX_SLEEP=fake-sleep DXE_FAKE_SLEEP_LOG="$start_e_sleep_log" \
    run_start_container "$good" "$start_root_e" 5 2>&1)" || start_e_status=$?
wait "$lease_e_pid" 2>/dev/null || true
start_e_sleep_count=0
[ -f "$start_e_sleep_log" ] && start_e_sleep_count="$(wc -l < "$start_e_sleep_log" | tr -d ' ')"
if [ "$start_e_status" -eq 0 ] && [ "$start_e_sleep_count" -ge 1 ] \
    && ! printf '%s\n' "$start_e_out" | stdin_matches -F 'Error:'; then
    test_pass "dx-start-container succeeds on a lease that appears late but within the bound (the poll loop actually polls)"
else
    test_fail "dx-start-container succeeds on a lease that appears late but within the bound (status $start_e_status, sleeps $start_e_sleep_count, out '$start_e_out')"
fi

assert_file_not_contains "$BASE_DIR/bin/dx-start-container" 'OLD_BASE' "dx-start-container no longer probes the guest for the old-base signature (docs/refactor/migration-gates.md#old-base-guards)"

# --- WP5.1 (Fable A2): dx_bootstrap_sync branch coverage --------------------
#
# The whole publish-or-skip body moved from bin/dx-sync-bootstrap (a bin/dx*
# entrypoint, exempt from the kcov 100% gate -- tests/coverage/exclusions.txt)
# into bin/lib/dx-bootstrap-sync.sh, which is inside that gate. These cases
# cover the branches that used to ride along on the entrypoint exemption.

# Container absent.
absent_root="$fixture/absent-root"; mkdir -p "$absent_root"
mkdir -p "$fixture/absent-fake"
fake_dir_absent="$(fake_tool_dir_create "$fixture/absent-fake")"
fake_tool_write "$fake_dir_absent" container '
case "${1:-}" in
  system) exit 0 ;;
  list) exit 0 ;;
esac
exit 1
'
absent_status=0
absent_out="$(env PATH="$fake_dir_absent:$PATH" \
    DX_CONTAINER_NAME=dx-bootstrap-absent \
    DX_BOOTSTRAP_SOURCE="$good" \
    DX_BOOTSTRAP_PATH="$absent_root" \
    DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
    "$BASE_DIR/bin/dx-sync-bootstrap" 2>&1)" || absent_status=$?
if [ "$absent_status" -ne 0 ] && printf '%s\n' "$absent_out" | stdin_matches -F 'Error: Container dx-bootstrap-absent does not exist. Run ./bin/dx-create-container first.'; then
    test_pass "a nonexistent container fails the sync with the existing message"
else
    test_fail "a nonexistent container fails the sync with the existing message (status $absent_status, out '$absent_out')"
fi

# Unsafe DX_BOOTSTRAP_PATH: "/" reaches dx_bootstrap_sync's own guard through
# the real entrypoint. (An empty DX_BOOTSTRAP_PATH is already rejected one
# layer up, by config resolution itself -- dx_init_config's "invalid resolved
# value" -- before dx-sync-bootstrap ever runs; that half of the case pattern
# is exercised directly against dx_bootstrap_sync in section 9 instead.)
unsafe_status=0
unsafe_out="$(env PATH="$fake_dir:$PATH" \
    DX_CONTAINER_NAME=dx-bootstrap-contract \
    DX_BOOTSTRAP_SOURCE="$good" \
    DX_BOOTSTRAP_PATH=/ \
    DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
    "$BASE_DIR/bin/dx-sync-bootstrap" 2>&1)" || unsafe_status=$?
if [ "$unsafe_status" -ne 0 ] && printf '%s\n' "$unsafe_out" | stdin_matches -F 'Error: Unsafe DX_BOOTSTRAP_PATH: /'; then
    test_pass "an unsafe DX_BOOTSTRAP_PATH of '/' is refused"
else
    test_fail "an unsafe DX_BOOTSTRAP_PATH of '/' is refused (status $unsafe_status, out '$unsafe_out')"
fi

# Entrypoint never ready: the container exists and is running, but the guest
# never signals readiness. Bounded by DX_BOOTSTRAP_WAIT_TIMEOUT via the same
# injectable DX_SLEEP seam as the container-running preflight above.
never_ready_root="$fixture/never-ready-root"; mkdir -p "$never_ready_root"
mkdir -p "$fixture/never-ready-fake"
fake_dir_never_ready="$(fake_tool_dir_create "$fixture/never-ready-fake")"
fake_tool_write "$fake_dir_never_ready" container '
case "${1:-}" in
  system) exit 0 ;;
  list) printf "%s\n" "$DX_CONTAINER_NAME"; exit 0 ;;
  exec) exit 1 ;;
esac
exit 1
'
fake_tool_write "$fake_dir_never_ready" fake-sleep 'exit 0'
never_ready_status=0
never_ready_out="$(env PATH="$fake_dir_never_ready:$PATH" \
    DX_CONTAINER_NAME=dx-bootstrap-never-ready \
    DX_BOOTSTRAP_SOURCE="$good" \
    DX_BOOTSTRAP_PATH="$never_ready_root" \
    DX_BOOTSTRAP_WAIT_TIMEOUT=2 \
    DX_SLEEP=fake-sleep \
    "$BASE_DIR/bin/dx-sync-bootstrap" 2>&1)" || never_ready_status=$?
if [ "$never_ready_status" -ne 0 ] && printf '%s\n' "$never_ready_out" | stdin_matches -F 'Error: Container dx-bootstrap-never-ready entrypoint never became ready after 2s.'; then
    test_pass "a guest that never signals readiness fails the sync with the existing message"
else
    test_fail "a guest that never signals readiness fails the sync with the existing message (status $never_ready_status, out '$never_ready_out')"
fi

# Missing source.
missing_source_root="$fixture/missing-source-root"; mkdir -p "$missing_source_root"
: > "$missing_source_root/.dx-bootstrap-waiting"
no_source_dir="$fixture/no-source"; mkdir -p "$no_source_dir"
no_source_status=0
no_source_out="$(env PATH="$fake_dir:$PATH" \
    DX_CONTAINER_NAME=dx-bootstrap-contract \
    DX_BOOTSTRAP_SOURCE="$no_source_dir" \
    DX_BOOTSTRAP_PATH="$missing_source_root" \
    DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
    "$BASE_DIR/bin/dx-sync-bootstrap" 2>&1)" || no_source_status=$?
if [ "$no_source_status" -ne 0 ] && printf '%s\n' "$no_source_out" | stdin_matches -F "Error: Bootstrap source $no_source_dir/bootstrap.sh does not exist."; then
    test_pass "a bootstrap source missing bootstrap.sh fails the sync with the existing message"
else
    test_fail "a bootstrap source missing bootstrap.sh fails the sync with the existing message (status $no_source_status, out '$no_source_out')"
fi

# Publication lock held forever (a permanently "alive"-looking owner, per the
# shared boot-id/stat fakes below) times out rather than waiting for real --
# faking `sleep` itself keeps the guest's own hard-coded 30-iteration loop
# fast and deterministic, since that loop calls `sleep` directly rather than
# through the host's DX_SLEEP seam.
lock_timeout_fixture="$fixture/lock-timeout"; mkdir -p "$lock_timeout_fixture"
lock_timeout_fake="$(fake_tool_dir_create "$lock_timeout_fixture")"
fake_tool_write "$lock_timeout_fake" container '
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
fake_tool_write "$lock_timeout_fake" chown 'exit 0'
fake_tool_write "$lock_timeout_fake" cat '
if [ "${1:-}" = /proc/sys/kernel/random/boot_id ]; then
  printf "%s\n" test-boot-id
elif [ "${1:-}" != "${1#/proc/}" ] && [ "${1##*/}" = stat ]; then
  printf "1 (sh) S"; field=4; while [ "$field" -le 21 ]; do printf " 0"; field=$((field + 1)); done; printf " 99\n"
else
  exec /bin/cat "$@"
fi
'
fake_tool_write "$lock_timeout_fake" awk '
case "$*" in */proc/*/stat*) printf "%s\n" 99 ;; *) exec /usr/bin/awk "$@" ;; esac
'
fake_tool_write "$lock_timeout_fake" mv '
if [ "${1:-}" = -Tf ]; then rm -f "$3"; exec /bin/mv -f "$2" "$3"; else exec /bin/mv "$@"; fi
'
fake_tool_write "$lock_timeout_fake" sleep 'exit 0'
lock_timeout_root="$fixture/lock-timeout-root"
mkdir -p "$lock_timeout_root/.locks/publication"
: > "$lock_timeout_root/.dx-bootstrap-waiting"
printf 'test-boot-id\t424242\t99\n' > "$lock_timeout_root/.locks/publication/owner"
lock_timeout_status=0
lock_timeout_out="$(env PATH="$lock_timeout_fake:$PATH" \
    DX_CONTAINER_NAME=dx-bootstrap-lock-timeout \
    DX_BOOTSTRAP_SOURCE="$good" \
    DX_BOOTSTRAP_PATH="$lock_timeout_root" \
    DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
    "$BASE_DIR/bin/dx-sync-bootstrap" 2>&1)" || lock_timeout_status=$?
if [ "$lock_timeout_status" -ne 0 ] && printf '%s\n' "$lock_timeout_out" | stdin_matches -F 'timed out waiting for the guest publication lock'; then
    test_pass "a permanently held publication lock times out rather than waiting forever"
else
    test_fail "a permanently held publication lock times out rather than waiting forever (status $lock_timeout_status, out '$lock_timeout_out')"
fi

# --- WP5.1 Red/Green: dx-start-container must decide "did a real publish
# happen" from dx-sync-bootstrap's structured result file, never from its
# prose ------------------------------------------------------------------
#
# Before this refactor, dx-start-container's only signal was
# dx_bootstrap_sync_published_generation pattern-matching the exact literal
# "Bootstrap generation <id> is ready." on dx-sync-bootstrap's captured
# stdout. Reworded prose went unrecognised, fell through to the never-fails
# unchanged-content diagnostic (dx_bootstrap_report_drift), and the start
# exited 0 with at most a warning -- even though a real publish had just
# happened and the guest's lease would never match it. Confirmed by hand
# against the pre-WP5.1 tree (bin/dx-start-container, bin/lib/dx-container.sh
# at commit b6ff834): this exact fixture exits 0 with
# "Warning: dx-reword-contract is running bootstrap generation gen-old, but
# gen-published-old is now published." Driving the REAL dx-start-container
# (from a fixture copy of bin/, so its "$SCRIPT_DIR/dx-sync-bootstrap" sibling
# reference resolves inside the fixture) against a fake sync that reports
# success with entirely reworded prose while a lease for the published
# generation never appears proves the decoupling: the result file's outcome
# is what dx-start-container now acts on, so it fails instead (D7 option 3).
reword_home="$fixture/reword-home"; mkdir -p "$reword_home"
reword_bin="$fixture/reword-bin"
cp -R "$BASE_DIR/bin" "$reword_bin"
cat > "$reword_bin/dx-sync-bootstrap" <<'FAKESYNC'
#!/bin/bash
set -euo pipefail
result_file=""
while [ $# -gt 0 ]; do
    case "$1" in
        --result-file) result_file="$2"; shift 2 ;;
        *) shift ;;
    esac
done
echo "Published bootstrap generation reworded-gen-x."
[ -z "$result_file" ] || printf 'outcome=published\ngeneration=reworded-gen-x\n' > "$result_file"
FAKESYNC
chmod 0755 "$reword_bin/dx-sync-bootstrap"

mkdir -p "$fixture/reword-fake"
reword_fake="$(fake_tool_dir_create "$fixture/reword-fake")"
fake_tool_write "$reword_fake" container '
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
fake_tool_write "$reword_fake" fake-sleep 'exit 0'

reword_root="$fixture/reword-root"
mkdir -p "$reword_root/.locks/leases"
: > "$reword_root/.locks/leases/gen-old.1"
ln -sfn generations/gen-published-old "$reword_root/current"

reword_status=0
reword_out="$(env PATH="$reword_fake:$PATH" \
    HOME="$reword_home" \
    DX_CONTAINER_NAME=dx-reword-contract \
    DX_NIX_VOLUME=dx-reword-contract-nix \
    DX_BOOTSTRAP_SOURCE="$good" \
    DX_BOOTSTRAP_PATH="$reword_root" \
    DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
    DX_BOOTSTRAP_CONFIRM_TIMEOUT=2 \
    DX_SLEEP=fake-sleep \
    "$reword_bin/dx-start-container" 2>&1)" || reword_status=$?
if [ "$reword_status" -ne 0 ] \
    && printf '%s\n' "$reword_out" | stdin_matches -F 'Published bootstrap generation reworded-gen-x.' \
    && printf '%s\n' "$reword_out" | stdin_matches -F 'Error: dx-reword-contract published bootstrap generation reworded-gen-x'; then
    test_pass "WP5.1: a real publish is recognised from the structured result file even when dx-sync-bootstrap's own prose is reworded, and the start fails when the lease never matches (D7 option 3)"
else
    test_fail "WP5.1: a real publish is recognised from the structured result file even when dx-sync-bootstrap's own prose is reworded, and the start fails when the lease never matches (D7 option 3) (status $reword_status, out '$reword_out')"
fi

# --- WP5.1: dx-start-container fails loudly on a missing or malformed result
# file, rather than silently treating it as either outcome. Same fixture-copy
# technique, a fresh fake sync per case.
result_file_home="$fixture/result-file-home"; mkdir -p "$result_file_home"
mkdir -p "$fixture/result-file-fake"
result_file_fake="$(fake_tool_dir_create "$fixture/result-file-fake")"
fake_tool_write "$result_file_fake" container '
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

cat > "$reword_bin/dx-sync-bootstrap" <<'FAKESYNC'
#!/bin/bash
set -euo pipefail
echo "Bootstrap generation missing-result-gen is ready."
FAKESYNC
chmod 0755 "$reword_bin/dx-sync-bootstrap"
missing_result_root="$fixture/missing-result-root"; mkdir -p "$missing_result_root"
missing_result_status=0
missing_result_out="$(env PATH="$result_file_fake:$PATH" \
    HOME="$result_file_home" \
    DX_CONTAINER_NAME=dx-missing-result-contract \
    DX_NIX_VOLUME=dx-missing-result-contract-nix \
    DX_BOOTSTRAP_SOURCE="$good" \
    DX_BOOTSTRAP_PATH="$missing_result_root" \
    DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
    "$reword_bin/dx-start-container" 2>&1)" || missing_result_status=$?
if [ "$missing_result_status" -ne 0 ] && printf '%s\n' "$missing_result_out" | stdin_matches -F 'is missing or malformed'; then
    test_pass "dx-start-container fails loudly when the sync never populates the result file"
else
    test_fail "dx-start-container fails loudly when the sync never populates the result file (status $missing_result_status, out '$missing_result_out')"
fi

cat > "$reword_bin/dx-sync-bootstrap" <<'FAKESYNC'
#!/bin/bash
set -euo pipefail
result_file=""
while [ $# -gt 0 ]; do
    case "$1" in
        --result-file) result_file="$2"; shift 2 ;;
        *) shift ;;
    esac
done
echo "Bootstrap generation malformed-result-gen is ready."
[ -z "$result_file" ] || printf 'this is not the right shape\n' > "$result_file"
FAKESYNC
chmod 0755 "$reword_bin/dx-sync-bootstrap"
malformed_result_root="$fixture/malformed-result-root"; mkdir -p "$malformed_result_root"
malformed_result_status=0
malformed_result_out="$(env PATH="$result_file_fake:$PATH" \
    HOME="$result_file_home" \
    DX_CONTAINER_NAME=dx-malformed-result-contract \
    DX_NIX_VOLUME=dx-malformed-result-contract-nix \
    DX_BOOTSTRAP_SOURCE="$good" \
    DX_BOOTSTRAP_PATH="$malformed_result_root" \
    DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
    "$reword_bin/dx-start-container" 2>&1)" || malformed_result_status=$?
if [ "$malformed_result_status" -ne 0 ] && printf '%s\n' "$malformed_result_out" | stdin_matches -F 'is missing or malformed'; then
    test_pass "dx-start-container fails loudly when the sync writes a malformed result file"
else
    test_fail "dx-start-container fails loudly when the sync writes a malformed result file (status $malformed_result_status, out '$malformed_result_out')"
fi

# --- WP6.7/WP6.8 (Astra F7/F8): the healthcheck probe -----------------------
#
# dx_bootstrap_health_command renders ONE fixed program (no configuration
# ever interpolated into it, D6) that validates the full lease identity --
# generation, boot id, pid, live process start time -- plus a completion
# marker tied to that identity, published only after bootstrap_phases
# succeeds (readiness, not mere generation ownership).
health_fixture="$fixture/health"
mkdir -p "$health_fixture"
health_fake="$(fake_tool_dir_create "$health_fixture")"
fake_tool_write "$health_fake" cat '
case "$1" in
  /proc/sys/kernel/random/boot_id) printf "%s\n" test-boot-id ;;
  /proc/1/stat) printf "1 (sh) S"; f=4; while [ "$f" -le 21 ]; do printf " 0"; f=$((f + 1)); done; printf " 99\n" ;;
  /proc/*/stat) exit 1 ;;
  *) exec /bin/cat "$@" ;;
esac
'
health_probe="$(dx_bootstrap_health_command)"

health_probe_2="$(DX_BOOTSTRAP_PATH='/some/other/$(printf injected >&2)/path' dx_bootstrap_health_command)"
if [ "$health_probe" = "$health_probe_2" ]; then
    test_pass "dx_bootstrap_health_command's program text never changes with DX_BOOTSTRAP_PATH (D6: data, not code)"
else
    test_fail "dx_bootstrap_health_command's program text never changes with DX_BOOTSTRAP_PATH (D6: data, not code)"
fi

health_run() {
    # $1: bootstrap root. Fresh .locks/leases + .locks/ready + generations/review
    # laid out by the caller before invoking this.
    env DX_BOOTSTRAP_PATH="$1" PATH="$health_fake:$PATH" sh -c "$health_probe"
}

health_fresh() {
    rm -rf "$health_fixture/root"
    mkdir -p "$health_fixture/root/.locks/leases" "$health_fixture/root/.locks/ready" "$health_fixture/root/generations/review"
    ln -sfn generations/review "$health_fixture/root/current"
}

# F8: a hostile DX_BOOTSTRAP_PATH is transported as data and never executed.
health_fresh
hostile_out=""
for hostile in \
    '/guest-bootstrap/$(printf injected >&2)' \
    '/guest-bootstrap/with space' \
    "/guest-bootstrap/with'quote" \
    '/guest-bootstrap/with$dollar' \
    '/guest-bootstrap/with\backslash'; do
    one_out="$(health_run "$hostile" 2>&1)" || true
    hostile_out="$hostile_out$one_out"
done
if printf '%s' "$hostile_out" | grep -q injected; then
    test_fail "F8: a path containing \$(printf injected >&2) produces no side effect (got: $hostile_out)"
else
    test_pass "F8: a path containing \$(printf injected >&2), spaces, quotes, \$, and backslashes produces no side effect"
fi

# F7: stale lease (dead pid) -> unhealthy.
health_fresh
printf 'review\ttest-boot-id\t999999\t50\n' > "$health_fixture/root/.locks/leases/review.999999"
if health_run "$health_fixture/root" >/dev/null 2>&1; then
    test_fail "F7: a lease naming a pid that no longer exists is unhealthy"
else
    test_pass "F7: a lease naming a pid that no longer exists is unhealthy"
fi

# F7: live pid, recorded start does not match live start (PID reuse) -> unhealthy.
health_fresh
printf 'review\ttest-boot-id\t1\t50\n' > "$health_fixture/root/.locks/leases/review.1"
if health_run "$health_fixture/root" >/dev/null 2>&1; then
    test_fail "F7: a live pid whose recorded start time does not match /proc (pid reuse) is unhealthy"
else
    test_pass "F7: a live pid whose recorded start time does not match /proc (pid reuse) is unhealthy"
fi

# F7: fully live, matching lease but no completion marker -> unhealthy (readiness).
health_fresh
printf 'review\ttest-boot-id\t1\t99\n' > "$health_fixture/root/.locks/leases/review.1"
if health_run "$health_fixture/root" >/dev/null 2>&1; then
    test_fail "F7: a live matching lease with no completion marker is unhealthy (readiness, not ownership)"
else
    test_pass "F7: a live matching lease with no completion marker is unhealthy (readiness, not ownership)"
fi

# F7: fully live, matching lease plus a completion marker written after
# activation -> healthy.
: > "$health_fixture/root/.locks/ready/1.99"
if health_run "$health_fixture/root" >/dev/null 2>&1; then
    test_pass "F7: a live matching lease plus its completion marker is healthy"
else
    test_fail "F7: a live matching lease plus its completion marker is healthy"
fi

# The marker itself is published by the guest side, tied to the exact
# identity the launcher recorded, only after bootstrap_phases succeeds.
source "$CONTAINER_DIR/bootstrap/common.sh"
marker_root="$health_fixture/marker-root"; mkdir -p "$marker_root"
if (
    DX_BOOTSTRAP_PATH="$marker_root" dx_bootstrap_publish_ready_marker review test-boot-id 99 4242
    [ -f "$marker_root/.locks/ready/4242.99" ] && [ ! -L "$marker_root/.locks/ready/4242.99" ]
); then
    test_pass "dx_bootstrap_publish_ready_marker writes a regular-file marker keyed by pid.start"
else
    test_fail "dx_bootstrap_publish_ready_marker writes a regular-file marker keyed by pid.start"
fi
marker_root_noop="$health_fixture/marker-root-noop"; mkdir -p "$marker_root_noop"
if (
    DX_BOOTSTRAP_PATH="$marker_root_noop" dx_bootstrap_publish_ready_marker "" "" "" ""
    [ ! -e "$marker_root_noop/.locks/ready" ]
); then
    test_pass "dx_bootstrap_publish_ready_marker is a no-op with no lease identity (the unsignalled-fallback boot)"
else
    test_fail "dx_bootstrap_publish_ready_marker is a no-op with no lease identity (the unsignalled-fallback boot)"
fi

assert_file_contains_literal "$BASE_DIR/bin/dx-create-container" 'DX_HEALTHCHECK_CMD="$(dx_bootstrap_health_command)"' "the healthcheck program is rendered by the single shared function, not built inline"
assert_file_contains_literal "$BASE_DIR/bin/dx-create-container" '--env "DX_BOOTSTRAP_PATH=$DX_BOOTSTRAP_PATH"' "DX_BOOTSTRAP_PATH crosses to the probe as container-environment data, not interpolated text"
assert_file_not_contains "$BASE_DIR/bin/dx-create-container" 'DX_BOOTSTRAP_PATH/current' "no healthcheck program text is built by interpolating the configured path"

# --- Direct-call battery: dx_bootstrap_sync and the sync-result codec -----
#
# Every branch above already runs through the real bin/dx-sync-bootstrap /
# bin/dx-start-container entrypoints -- how a human actually restarts a
# guest -- and every one of them passes. But each of those forks a brand-new
# bash process to run the entrypoint, and this sandbox's kcov does not
# attribute a forked script's own lines back to it (checked directly outside
# this suite: a trivial two-line script that always runs, executed as a
# forked child of a traced parent, reports 0/2 lines covered; the identical
# two lines sourced and run in this same process report 2/2), so the
# coverage gate never sees dx-bootstrap-sync.sh's body execute no matter how
# many entrypoint-level cases exist above. These cases call the same
# functions directly, in this already-traced process, reusing the exact
# fakes the entrypoint cases above already proved correct, so the gate can
# see what those cases already proved behaviourally. (The one part this
# cannot reach is the generation-publish body itself: it is a string
# dx_bootstrap_sync hands to `dx_runtime_exec -i ... sh -c`, which really
# does fork a new interpreter for the guest side, exactly as production
# does -- the "publishes"/"unchanged" entrypoint cases far above already
# exercise that half behaviourally, through the same fake `container exec`
# passthrough.)
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"
source "$BASE_DIR/bin/lib/dx-bootstrap-sync.sh"

direct_root="$fixture/direct-call"; mkdir -p "$direct_root"

(
    generation=""
    direct_status=0
    direct_out="$(PATH="$fake_dir_absent:$PATH" DX_CONTAINER_NAME=dx-bootstrap-absent DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
        dx_bootstrap_sync dx-bootstrap-absent "$good" "$direct_root/absent-root" 2>&1)" || direct_status=$?
    [ "$direct_status" -eq 1 ] && printf '%s\n' "$direct_out" | stdin_matches -F 'Error: Container dx-bootstrap-absent does not exist. Run ./bin/dx-create-container first.'
) && test_pass "dx_bootstrap_sync fails on a nonexistent container (direct call)" \
  || test_fail "dx_bootstrap_sync fails on a nonexistent container (direct call)"

(
    generation=""
    direct_status=0
    direct_out="$(PATH="$fake_dir_wait:$PATH" DX_CONTAINER_NAME=dx-bootstrap-wait-contract DX_BOOTSTRAP_WAIT_TIMEOUT=1 DX_SLEEP=fake-sleep \
        dx_bootstrap_sync dx-bootstrap-wait-contract "$good" "$direct_root/not-running-root" 2>&1)" || direct_status=$?
    [ "$direct_status" -eq 1 ] && printf '%s\n' "$direct_out" | stdin_matches -F 'Error: Container dx-bootstrap-wait-contract is not running. Run ./bin/dx-start-container first.'
) && test_pass "dx_bootstrap_sync fails when the container never reports running (direct call)" \
  || test_fail "dx_bootstrap_sync fails when the container never reports running (direct call)"

(
    generation=""
    direct_status=0
    direct_out="$(PATH="$fake_dir:$PATH" DX_CONTAINER_NAME=dx-bootstrap-contract DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
        dx_bootstrap_sync dx-bootstrap-contract "$good" / 2>&1)" || direct_status=$?
    [ "$direct_status" -eq 1 ] && printf '%s\n' "$direct_out" | stdin_matches -F 'Error: Unsafe DX_BOOTSTRAP_PATH: /'
) && test_pass "dx_bootstrap_sync refuses an unsafe path of '/' (direct call)" \
  || test_fail "dx_bootstrap_sync refuses an unsafe path of '/' (direct call)"

(
    generation=""
    direct_status=0
    direct_out="$(PATH="$fake_dir_never_ready:$PATH" DX_CONTAINER_NAME=dx-bootstrap-never-ready DX_BOOTSTRAP_WAIT_TIMEOUT=2 DX_SLEEP=fake-sleep \
        dx_bootstrap_sync dx-bootstrap-never-ready "$good" "$direct_root/never-ready-root" 2>&1)" || direct_status=$?
    [ "$direct_status" -eq 1 ] && printf '%s\n' "$direct_out" | stdin_matches -F 'Error: Container dx-bootstrap-never-ready entrypoint never became ready after 2s.'
) && test_pass "dx_bootstrap_sync fails when the guest never signals readiness (direct call)" \
  || test_fail "dx_bootstrap_sync fails when the guest never signals readiness (direct call)"

(
    generation=""
    direct_missing_source_root="$direct_root/missing-source-root"; mkdir -p "$direct_missing_source_root"
    : > "$direct_missing_source_root/.dx-bootstrap-waiting"
    direct_no_source_dir="$direct_root/no-source"; mkdir -p "$direct_no_source_dir"
    direct_status=0
    direct_out="$(PATH="$fake_dir:$PATH" DX_CONTAINER_NAME=dx-bootstrap-contract DX_BOOTSTRAP_WAIT_TIMEOUT=1 \
        dx_bootstrap_sync dx-bootstrap-contract "$direct_no_source_dir" "$direct_missing_source_root" 2>&1)" || direct_status=$?
    [ "$direct_status" -eq 1 ] && printf '%s\n' "$direct_out" | stdin_matches -F "Error: Bootstrap source $direct_no_source_dir/bootstrap.sh does not exist."
) && test_pass "dx_bootstrap_sync fails when the source is missing bootstrap.sh (direct call)" \
  || test_fail "dx_bootstrap_sync fails when the source is missing bootstrap.sh (direct call)"

# dx_bootstrap_sync_result_write/_read: the codec dx-start-container uses to
# learn "did this sync really publish" without parsing dx-sync-bootstrap's
# prose (docs/refactor/decisions/D7-start-generation.md). Its defensive
# branches are otherwise only reachable by driving a full dx-start-container
# round trip per case -- which is what made the "malformed result file" case
# above need a whole reworded-prose fixture just to reach ONE of them; call
# the codec directly, in this process, for the rest.
result_dir="$direct_root/result-codec"; mkdir -p "$result_dir"

(
    ! dx_bootstrap_sync_result_write "$result_dir/bad-outcome" bogus gen-1
) && test_pass "dx_bootstrap_sync_result_write refuses an outcome other than published/unchanged" \
  || test_fail "dx_bootstrap_sync_result_write refuses an outcome other than published/unchanged"

(
    ! dx_bootstrap_sync_result_write "$result_dir/bad-generation" published ../escape
) && test_pass "dx_bootstrap_sync_result_write refuses an unsafe generation id" \
  || test_fail "dx_bootstrap_sync_result_write refuses an unsafe generation id"

(
    outcome=""; generation=""
    dx_bootstrap_sync_result_write "$result_dir/roundtrip" published gen-42 \
        && dx_bootstrap_sync_result_read "$result_dir/roundtrip" \
        && [ "$outcome" = published ] && [ "$generation" = gen-42 ]
) && test_pass "dx_bootstrap_sync_result_write/_read round-trip a published outcome" \
  || test_fail "dx_bootstrap_sync_result_write/_read round-trip a published outcome"

(
    ! dx_bootstrap_sync_result_read "$result_dir/does-not-exist"
) && test_pass "dx_bootstrap_sync_result_read refuses a missing file" \
  || test_fail "dx_bootstrap_sync_result_read refuses a missing file"

(
    ln -sfn roundtrip "$result_dir/symlinked"
    ! dx_bootstrap_sync_result_read "$result_dir/symlinked"
) && test_pass "dx_bootstrap_sync_result_read refuses a symlinked result file" \
  || test_fail "dx_bootstrap_sync_result_read refuses a symlinked result file"

(
    : > "$result_dir/empty"
    ! dx_bootstrap_sync_result_read "$result_dir/empty"
) && test_pass "dx_bootstrap_sync_result_read refuses an empty result file" \
  || test_fail "dx_bootstrap_sync_result_read refuses an empty result file"

(
    printf 'outcome=published\n' > "$result_dir/one-line"
    ! dx_bootstrap_sync_result_read "$result_dir/one-line"
) && test_pass "dx_bootstrap_sync_result_read refuses a result file with only one line" \
  || test_fail "dx_bootstrap_sync_result_read refuses a result file with only one line"

(
    printf 'outcome=published\ngeneration=gen-1\ntrailing\n' > "$result_dir/three-lines"
    ! dx_bootstrap_sync_result_read "$result_dir/three-lines"
) && test_pass "dx_bootstrap_sync_result_read refuses a result file with a trailing third line" \
  || test_fail "dx_bootstrap_sync_result_read refuses a result file with a trailing third line"

(
    printf 'outcome=bogus\ngeneration=gen-1\n' > "$result_dir/bad-outcome-line"
    ! dx_bootstrap_sync_result_read "$result_dir/bad-outcome-line"
) && test_pass "dx_bootstrap_sync_result_read refuses an unrecognised outcome line" \
  || test_fail "dx_bootstrap_sync_result_read refuses an unrecognised outcome line"

(
    printf 'outcome=published\nbogus=gen-1\n' > "$result_dir/bad-generation-line"
    ! dx_bootstrap_sync_result_read "$result_dir/bad-generation-line"
) && test_pass "dx_bootstrap_sync_result_read refuses a second line that is not generation=" \
  || test_fail "dx_bootstrap_sync_result_read refuses a second line that is not generation="

(
    printf 'outcome=published\ngeneration=../escape\n' > "$result_dir/bad-generation-value"
    ! dx_bootstrap_sync_result_read "$result_dir/bad-generation-value"
) && test_pass "dx_bootstrap_sync_result_read refuses an unsafe generation value" \
  || test_fail "dx_bootstrap_sync_result_read refuses an unsafe generation value"

# --- WP5.2 (Fable A3/B3, extends Astra R3): one fixture, run against ALL
# THREE implementations of the guest publication-lock protocol -- the
# launcher's rendering (dx_bootstrap_launch_command) and the sync's
# rendering (dx_sync_guest_program, with
# dx_guest_publication_protocol_snippet prepended exactly as
# dx_bootstrap_sync itself does at call time) -- asserting identical
# outcomes AND identical stderr for: a live, same-boot owner (waits, times
# out); an owner recorded under a previous boot (reclaimed); a reused pid
# whose recorded start time no longer matches a live process (reclaimed);
# an ownerless lock directory (reclaimed after a short grace); and a
# reclaim whose own rename target is already occupied (falls through to
# the same timeout, never takes over). `sleep` is stubbed to a no-op in
# every context so the two 30s-bounded waits (the live-owner and the
# reclaim-loses cases) finish immediately. The guest's own dx-ai-lock.sh
# joins this same fixture as a third implementation once it shares this
# protocol too (WP5.2 Refactor).
# A subdirectory of $fixture, not a fresh mktemp -d: $fixture's own cleanup
# trap (set at the top of this file) already removes everything under it
# on exit, so this needs no EXIT trap of its own -- setting one here would
# only replace that earlier one, not run alongside it.
wp52_dir="$fixture/wp52-cross-impl"
mkdir -p "$wp52_dir"

wp52_extract_protocol_block() {
    awk '
        /^# --- BEGIN dx_guest_publication_protocol/ { flag=1 }
        flag { print }
        /^# --- END dx_guest_publication_protocol/ { flag=0 }
    '
}

wp52_driver='
    sleep() { :; }
lock=$1
proc_root=$2
collide=${3:-0}
DX_LOCK_PROC_ROOT=$proc_root
mkdir -p "$proc_root/$$"
printf "%s\n" "$$ (probe) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 555" > "$proc_root/$$/stat"
[ "$collide" = 1 ] && : > "$lock.reclaim.$$"
publication_lock_acquire "$lock" 30
'

launcher_rendering="$(dx_bootstrap_launch_command)"
sync_rendering="$(printf '%s\n%s' "$(dx_guest_publication_protocol_snippet)" "$dx_sync_guest_program")"

{ printf '%s\n' "$launcher_rendering" | wp52_extract_protocol_block; printf '%s\n' "$wp52_driver"; } > "$wp52_dir/launcher_probe.sh"
{ printf '%s\n' "$sync_rendering" | wp52_extract_protocol_block; printf '%s\n' "$wp52_driver"; } > "$wp52_dir/sync_probe.sh"

wp52_run_launcher() {
    local lock="$1" proc_root="$2" collide="${3:-0}" rc=0
    sh "$wp52_dir/launcher_probe.sh" "$lock" "$proc_root" "$collide" 2>"$wp52_dir/err"; rc=$?
    printf '%s' "$rc"
}
wp52_run_sync() {
    local lock="$1" proc_root="$2" collide="${3:-0}" rc=0
    sh "$wp52_dir/sync_probe.sh" "$lock" "$proc_root" "$collide" 2>"$wp52_dir/err"; rc=$?
    printf '%s' "$rc"
}

wp52_self_boot="feedfeed-0000-0000-0000-000000000000"

# wp52_case <scenario-name> <fixture-setup-fn>
# <fixture-setup-fn> is called once per implementation as
# `fn <proc_root> <lock>`, before that implementation's runner executes.
wp52_case() {
    local scenario="$1" setup="$2" collide="${3:-0}"
    local impl rc err owner
    local rc_launcher="" rc_sync=""
    local err_launcher="" err_sync=""
    local owner_boot_launcher="" owner_boot_sync=""
    for impl in launcher sync; do
        local base="$wp52_dir/case-$scenario-$impl"
        rm -rf "$base"
        local proc_root="$base/proc" lock="$base/lock"
        mkdir -p "$proc_root/sys/kernel/random"
        "$setup" "$proc_root" "$lock"
        case "$impl" in
            launcher) rc="$(wp52_run_launcher "$lock" "$proc_root" "$collide")" ;;
            sync) rc="$(wp52_run_sync "$lock" "$proc_root" "$collide")" ;;
        esac
        err="$(cat "$wp52_dir/err" 2>/dev/null || true)"
        owner=""
        [ -f "$lock/owner" ] && owner="$(cut -f1 "$lock/owner" 2>/dev/null || true)"
        case "$impl" in
            launcher) rc_launcher="$rc"; err_launcher="$err"; owner_boot_launcher="$owner" ;;
            sync) rc_sync="$rc"; err_sync="$err"; owner_boot_sync="$owner" ;;
        esac
    done
    if [ "$rc_launcher" = "$rc_sync" ] && [ "$err_launcher" = "$err_sync" ]; then
        test_pass "WP5.2: $scenario -- launcher/sync agree (rc=$rc_launcher)"
    else
        test_fail "WP5.2: $scenario -- launcher/sync diverge (rc: launcher=$rc_launcher sync=$rc_sync; stderr: launcher='$err_launcher' sync='$err_sync')"
    fi
    if [ "$rc_launcher" = 0 ]; then
        if [ "$owner_boot_launcher" = "$wp52_self_boot" ] && [ "$owner_boot_sync" = "$wp52_self_boot" ]; then
            test_pass "WP5.2: $scenario -- both record the acquirer's own boot id"
        else
            test_fail "WP5.2: $scenario -- both record the acquirer's own boot id (got launcher='$owner_boot_launcher' sync='$owner_boot_sync')"
        fi
    fi
}

# (1) A live, same-boot owner: every implementation waits it out and times
# out, leaving the owner record untouched.
wp52_setup_live_owner() {
    local proc_root="$1" lock="$2"
    printf '%s\n' "$wp52_self_boot" > "$proc_root/sys/kernel/random/boot_id"
    mkdir -p "$lock" "$proc_root/777777"
    printf '%s\n' '777777 (owner) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 42' > "$proc_root/777777/stat"
    printf '%s\t%s\t%s\n' "$wp52_self_boot" 777777 42 > "$lock/owner"
}
wp52_case "a live same-boot owner" wp52_setup_live_owner

# (2) An owner recorded under a previous boot: reclaimed and acquired.
wp52_setup_previous_boot_owner() {
    local proc_root="$1" lock="$2"
    printf '%s\n' "$wp52_self_boot" > "$proc_root/sys/kernel/random/boot_id"
    mkdir -p "$lock" "$proc_root/777777"
    printf '%s\n' '777777 (owner) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 42' > "$proc_root/777777/stat"
    printf '%s\t%s\t%s\n' "previous-boot-id" 777777 42 > "$lock/owner"
}
wp52_case "an owner from a previous boot" wp52_setup_previous_boot_owner

# (3) A reused pid: the recorded start time no longer matches the live
# process at that pid (a dead owner's pid reassigned to something else).
wp52_setup_reused_pid() {
    local proc_root="$1" lock="$2"
    printf '%s\n' "$wp52_self_boot" > "$proc_root/sys/kernel/random/boot_id"
    mkdir -p "$lock" "$proc_root/777777"
    printf '%s\n' '777777 (new-owner) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 42' > "$proc_root/777777/stat"
    printf '%s\t%s\t%s\n' "$wp52_self_boot" 777777 999 > "$lock/owner"
}
wp52_case "a reused pid with a different start time" wp52_setup_reused_pid

# (4) An ownerless lock directory: reclaimed after the same short grace
# every implementation now shares (WP3.5's dx-ai copy used to reclaim this
# immediately, with no such grace).
wp52_setup_ownerless() {
    local proc_root="$1" lock="$2"
    printf '%s\n' "$wp52_self_boot" > "$proc_root/sys/kernel/random/boot_id"
    mkdir -p "$lock"
}
wp52_case "an ownerless lock directory" wp52_setup_ownerless

# (5) A reclaim whose own rename target is already occupied: this attempt
# does not take over -- it falls through to the same wait/timeout every
# other contender uses, leaving the stale owner record untouched.
wp52_setup_reclaim_loses() {
    local proc_root="$1" lock="$2"
    printf '%s\n' "$wp52_self_boot" > "$proc_root/sys/kernel/random/boot_id"
    mkdir -p "$lock"
    printf '%s\t%s\t%s\n' "$wp52_self_boot" 777777 999 > "$lock/owner"
}
wp52_case "a reclaim rename that loses" wp52_setup_reclaim_loses 1

print_summary
exit_with_code
