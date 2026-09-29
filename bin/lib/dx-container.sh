#!/bin/bash
# Apple Container adapter. No preflight is performed while this file is sourced.
#
# Branch 11 / Phase 1 (qnap-dxe-plan.md DQ2): every function below that used
# to invoke the raw `container` binary now calls the runtime-neutral
# contract (bin/lib/dx-runtime.sh) instead; behaviour, output, and error
# handling are unchanged, only the raw call site moved to
# bin/lib/dx-runtime-apple.sh. Every name here is preserved exactly for
# existing callers and tests.
#
# `dx_container_list_names` (Branch 11 / Phase 3, Increment 4: fixed a
# boundary leak found during Phase 3's audit-extension work) used to call
# dx_runtime_apple_container_list_names directly, unconditionally -- under
# DX_RUNTIME=docker-ssh this reached for the local Apple `container` binary
# instead of dispatching to whichever runtime is actually configured. It now
# derives names from dx_runtime_container_list's raw table listing (the
# `--quiet` fast path and its own version-fallback stay Apple-internal,
# inside dx_runtime_apple_container_list_names, which dx_runtime_apple_
# container_exists/_running still use directly -- this wrapper's own two
# callers never needed that optimisation to be correct, only to be a valid
# per-runtime dispatch).

DX_CONTAINER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dx-runtime.sh
source "$DX_CONTAINER_LIB_DIR/dx-runtime.sh"

dx_require_container_cli() { dx_runtime_available; }

container_system_is_running() { dx_runtime_system_running; }
# Branch 11 / Phase 2: "Apple container system is not running" was correct
# wording (and is kept byte-for-byte, matching
# tests/test_runtime_boundary_audit.sh's own named exception for this
# exact string) when DX_RUNTIME=apple, the only runtime this message
# described until now; it would be factually wrong read for
# DX_RUNTIME=docker-ssh, which gets its own wording instead.
# dx_runtime_system_start always refuses for docker-ssh (with its own
# clear message pointing at the NAS's App Center UI) rather than actually
# starting anything remotely.
container_system_ensure_started() {
    if ! container_system_is_running; then
        if [ "${DX_RUNTIME:-apple}" = docker-ssh ]; then
            echo "Docker Engine on $DX_REMOTE_HOST is not running; starting it..."
        else
            echo "Apple container system is not running; starting it..."
        fi
        dx_runtime_system_start
    fi
}

dx_container_list_names() {
    if [ "$1" = true ]; then
        dx_runtime_container_list -a | awk 'NR > 1 {print $1}'
    else
        dx_runtime_container_list | awk 'NR > 1 {print $1}'
    fi
}

# No `-q`: see tests/test_helpers.sh's stdin_matches comment for why
# `writer | grep -q` is unsafe under `set -o pipefail` (every caller of these
# two functions). Redirecting to /dev/null instead keeps grep reading to EOF
# so the writer's later `printf` calls never see a closed pipe.
container_exists() { dx_runtime_container_exists "$1"; }
container_is_running() { dx_runtime_container_running "$1"; }
container_image_exists() { dx_runtime_image_exists "$1"; }
container_ensure_volume() { dx_runtime_volume_exists "$1" || dx_runtime_volume_create "$1"; }

# Branch 11 / Phase 6 (qnap-dxe-plan.md Phase 6 item 7): the whole-operation
# ownership proof bin/dx-factory-reset and bin/dx-destroy-volumes both need
# before EITHER issues a single delete call -- an immutable plan printed
# for every targeted resource, and the WHOLE operation refused (zero
# delete calls reached) if any one EXISTING resource fails its DQ6 label
# check. docker-ssh only: Apple has no DQ6 labels at all, so this is
# unconditionally a no-op under DX_RUNTIME=apple (skipped entirely, not
# merely printing the same thing) -- Apple's own typed-confirmation
# behaviour in each caller is therefore untouched, byte for byte.
#
# Args: one "kind:name:role" triple per target resource, e.g.
# "volume:dx-qnap-nix:nix". Delegates to the Docker adapter's own
# dx_runtime_docker_destructive_plan_and_verify -- a narrow, reasoned
# exception in tests/test_runtime_boundary_audit.sh (the same shape
# already granted to bin/dx-lock/bin/dx-status's read-only lock view):
# there is no dx_runtime_<op> contract equivalent to route through without
# inventing a new contract operation, which only one (unrelated)
# create-time health flag was pre-authorised for this phase.
dx_destructive_plan_and_verify() {
    [ "${DX_RUNTIME:-apple}" = docker-ssh ] || return 0
    dx_runtime_docker_destructive_plan_and_verify "$@"
}

# dx_wait_until's predicate for container_wait_stopped (WP4.2 / Fable A6):
# succeeds once the container is no longer running; otherwise prints the
# same "Waiting for container ... to stop..." notice this loop has always
# printed before backing off, and fails so dx_wait_until waits out the
# interval and tries again.
container_wait_stopped_check() {
    container_is_running "$1" || return 0
    echo "Waiting for container $1 to stop..."
    return 1
}

container_wait_stopped() {
    local name="$1" timeout="$2"
    dx_wait_until "$timeout" 1 container_wait_stopped_check "$name"
}

# Parse an exact --uuid argument/value pair from ps output.
container_runtime_pids() {
    ps -axo pid=,command= | awk -v wanted="$1" '/container-runtime-linux/ { for (i = 2; i <= NF; i++) if ($i == "--uuid" && (i + 1) <= NF && $(i + 1) == wanted) { print $1; break } }'
}

container_runtime_identity_matches() {
    local name="$1" pid="$2" start="$3" found
    found="$(container_runtime_pids "$name" | awk -v pid="$pid" '$1 == pid {print; exit}')"
    [ -n "$found" ] && dx_process_identity_matches "$pid" "$start"
}

container_kill_runtime_process() {
    local name="$1" records="" pid start elapsed
    for pid in $(container_runtime_pids "$name"); do
        start="$(dx_process_start_identity "$pid" || true)"
        [ -n "$start" ] && records="${records}${pid}|${start}
"
    done
    [ -n "$records" ] || { echo "No host runtime process found for container $name." >&2; return 1; }
    while IFS='|' read -r pid start; do
        [ -n "$pid" ] || continue
        if container_runtime_identity_matches "$name" "$pid" "$start"; then
            echo "Terminating host runtime process for container $name: $pid" >&2
            kill "$pid" 2>/dev/null || true
        fi
    done <<EOF
$records
EOF
    elapsed=0
    while [ "$elapsed" -lt "$DX_STOP_WAIT_TIMEOUT" ]; do
        [ -z "$(container_runtime_pids "$name")" ] && return 0
        sleep 1; elapsed=$((elapsed + 1))
    done
    while IFS='|' read -r pid start; do
        [ -n "$pid" ] || continue
        if container_runtime_identity_matches "$name" "$pid" "$start"; then
            echo "Runtime process for $name ignored TERM; sending KILL: $pid" >&2
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done <<EOF
$records
EOF
    elapsed=0
    while [ "$elapsed" -lt "$DX_STOP_WAIT_TIMEOUT" ]; do
        [ -z "$(container_runtime_pids "$name")" ] && return 0
        sleep 1; elapsed=$((elapsed + 1))
    done
    echo "Host runtime process for $name is still present." >&2
    return 1
}

container_stop_bounded() {
    local name="$1"
    if ! container_exists "$name"; then echo "Container $name does not exist. Nothing to stop."; return 0; fi
    if ! container_is_running "$name"; then echo "Container $name is already stopped."; return 0; fi
    echo "Stopping DX container: $name..."
    run_with_timeout "$DX_STOP_COMMAND_TIMEOUT" dx_runtime_container_stop --time "$DX_STOP_GRACE_SECONDS" "$name" || echo "Graceful stop command did not complete cleanly for $name." >&2
    container_wait_stopped "$name" "$DX_STOP_WAIT_TIMEOUT" && return 0
    echo "Container $name did not stop; sending container kill..." >&2
    run_with_timeout "$DX_STOP_COMMAND_TIMEOUT" dx_runtime_container_kill "$name" || true
    container_wait_stopped "$name" "$DX_STOP_WAIT_TIMEOUT" && return 0
    echo "Container $name is still running after container kill; terminating runtime process..." >&2
    container_kill_runtime_process "$name" || true
    container_wait_stopped "$name" "$DX_STOP_WAIT_TIMEOUT" && return 0
    echo "Container $name is still running after runtime-process fallback." >&2
    return 1
}

# The bootstrap generation the running guest is actually executing, read from
# the launcher's execution lease.
#
# Leases are named "<generation>.<pid>". PID 1 is the launcher: it is the
# container entrypoint and execs that generation's bootstrap.sh, so its lease
# alone names the code that is running. Other PIDs' leases are from earlier
# boots on this volume and must never be mistaken for it. Takes the lease
# listing as data (generation ids are restricted to [A-Za-z0-9_.-], so word
# splitting is safe) and returns non-zero when no launcher lease is present,
# which is the normal state of a guest that has never been synced.
dx_bootstrap_lease_generation() {
    local lease
    for lease in $1; do
        case "$lease" in
            *.1) printf '%s\n' "${lease%.1}"; return 0 ;;
        esac
    done
    return 1
}

# A deterministic digest of the bootstrap payload, used to decide whether a sync
# has anything to publish.
#
# Generation ids are minted from the clock ("<date>-<pid>"), so every sync used
# to produce a new id and repoint `current` even when the payload was byte for
# byte identical. dx-start-container syncs *after* starting the container, so
# the guest was then permanently "running an older generation" than the one just
# published, and the drift warning fired on every start -- which meant it could
# not distinguish a real unsynced change from the sync that had just run.
#
# Hashes the per-file digest listing, which carries both path and content, so a
# rename counts as a change. Modes deliberately do not: the guest re-derives
# them by name when it publishes, so a mode difference is not a content
# difference. Files only -- the payload has no symlinks and no meaningful empty
# directories.
#
# The tool pick is duplicated across the two branches rather than factored into
# a helper because `find -exec` needs a real command, not a shell function, and
# a shell loop feeding a pipeline is not reliably instrumentable by the coverage
# gate. `-exec ... +` also runs nothing on an empty tree, where `xargs` would
# hang waiting on stdin.
dx_bootstrap_content_digest() {
    local source="$1" digest
    [ -d "$source" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        digest="$(cd "$source" && find . -type f -exec sha256sum {} + | LC_ALL=C sort | sha256sum)" || return 1
    else
        digest="$(cd "$source" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256)" || return 1
    fi
    digest="${digest%% *}"
    case "$digest" in ''|*[!0-9a-f]*) return 1 ;; esac
    printf '%s\n' "$digest"
}

# Announce that the guest is running an older generation than the published
# one. This is the diagnostic for the unchanged-content skip path only (see
# dx_bootstrap_sync_published_generation below): a start whose sync actually
# published a new generation is confirmed, bounded, by
# dx_bootstrap_confirm_publication instead, which can fail the start outright
# (D7 option 3, docs/refactor/decisions/D7-start-generation.md). This function
# only makes a real drift visible when there was nothing to confirm -- an
# unsynced guest has no lease, and an unchanged tree republishes the same id,
# so it stays silent unless both generations are known and differ.
dx_bootstrap_report_drift() {
    local running="$1" published="$2" name="$3"
    [ -n "$running" ] && [ -n "$published" ] && [ "$running" != "$published" ] || return 0
    echo "Warning: $name is running bootstrap generation $running, but $published is now published." >&2
    echo "The guest boots whichever generation was current when it started, so a bootstrap change needs one more start to take effect." >&2
    echo "Run dx-start-container again to pick it up." >&2
    return 0
}

# Whether the sync that just ran (bin/dx-sync-bootstrap, captured stdout)
# actually published a new generation, or skipped because the payload was
# unchanged. dx-sync-bootstrap's own two terminal messages are the only
# distinction available without re-deriving the content digest ourselves:
# "Bootstrap generation <id> is ready." on a real publish, "... generation
# <id> stays current." on a skip. Prints the published generation id and
# returns 0 only for a real publish; a skip, or output matching neither
# message (defensive -- dx-sync-bootstrap only ever reaches one of the two on
# a successful exit), returns 1 with no output.
dx_bootstrap_sync_published_generation() {
    local output="$1" line generation
    while IFS= read -r line; do
        case "$line" in
            "Bootstrap generation "*" is ready.")
                generation=${line#Bootstrap generation }
                generation=${generation% is ready.}
                case "$generation" in ""|*/*|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
                printf '%s\n' "$generation"
                return 0
                ;;
        esac
    done <<EOF
$output
EOF
    return 1
}

# Bound how long a start waits for the guest's execution lease to confirm a
# publish that just happened -- only called for a real publish (never the
# unchanged-content skip, which dx_bootstrap_report_drift covers with no
# wait). The guest launcher only needs to notice an already-set
# .dx-bootstrap-ready on its next 1-second poll tick and lease immediately (it
# does not wait out its own DX_BOOTSTRAP_PUBLISH_GRACE in this branch, since
# ready is already present), so this polls at the same 1-second cadence as
# every other bounded wait in this codebase. Live-measured publish-to-lease
# latency on dx-test was 0.2-0.4s (docs/refactor/decisions/D7-start-generation.md);
# DX_BOOTSTRAP_CONFIRM_TIMEOUT's default gives that over 10x headroom.
#
# A match within the bound returns 0 silently -- success, exactly as before
# this existed. No match once the bound elapses is precisely Q4: the host
# published, but the guest is provably not running it. Prints an error naming
# both generations and the remedy to stderr and returns 1; the start that
# calls this must fail (D7 option 3). Read-only: every read here already
# tolerates failure (an absent lease, a guest that never leased at all), so
# there are no partial side effects to clean up on either outcome.
# dx_wait_until's predicate for dx_bootstrap_confirm_publication (WP4.2 /
# Fable A6). Sets the CALLER's `running` local (Bash dynamic scoping, same
# as dx_lock_acquire's own reclaim logic) rather than returning it, since
# dx_wait_until only reports success/failure -- the timeout error message
# below needs the last-observed value even when it never matched.
dx_bootstrap_confirm_publication_check() {
    local name="$1" bootstrap_path="$2" published="$3" lease_listing
    lease_listing="$(dx_runtime_exec "$name" sh -c 'ls -1 "$1/.locks/leases" 2>/dev/null || true' -- "$bootstrap_path" 2>/dev/null || true)"
    running=""
    [ -z "$lease_listing" ] || running="$(dx_bootstrap_lease_generation "$lease_listing" || true)"
    [ "$running" = "$published" ]
}

dx_bootstrap_confirm_publication() {
    local name="$1" bootstrap_path="$2" published="$3" timeout="$4"
    local running=""
    dx_wait_until "$timeout" 1 dx_bootstrap_confirm_publication_check "$name" "$bootstrap_path" "$published" && return 0
    echo "Error: $name published bootstrap generation $published, but after waiting ${timeout}s the guest is running ${running:-no leased generation (never synced, or still resolving)}." >&2
    echo "The running guest will not pick this publish up on its own. Restart it so its launcher waits for publication fresh: ./bin/dx-stop-container && ./bin/dx-start-container." >&2
    return 1
}
dx_nix_volume_claim_dir() { printf '%s/.dx-cache/nix-volume-claims\n' "${HOME:?}"; }

dx_nix_volume_claim_name_valid() {
    case "$1" in ''|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
}

dx_nix_volume_claim_read() {
    local claim="$1" record container_name pid start extra
    record="$(cat "$claim" 2>/dev/null)" || return 1
    case "$record" in *$'\n'*) return 1 ;; esac
    IFS="$(printf '\t')" read -r container_name pid start extra <<EOF
$record
EOF
    dx_nix_volume_claim_name_valid "$container_name" \
        && case "$pid" in *[!0-9]*|'') return 1 ;; esac \
        && [ -n "$start" ] && [ -z "$extra" ] || return 1
    printf '%s\t%s\t%s\n' "$container_name" "$pid" "$start"
}

dx_nix_volume_claim_acquire() {
    local volume="$1" container_name="$2" directory claim lock temporary record claim_container claim_pid claim_start
    dx_nix_volume_claim_name_valid "$volume" && dx_nix_volume_claim_name_valid "$container_name" || {
        echo "Error: refusing unsafe Nix-volume claim name." >&2
        return 1
    }
    directory="$(dx_nix_volume_claim_dir)"
    mkdir -p "$directory" || return 1
    [ ! -L "$directory" ] && [ -d "$directory" ] || { echo "Error: refusing unsafe Nix-volume claim directory $directory." >&2; return 1; }
    chmod 0700 "$directory"
    claim="$directory/$volume"; lock="$directory/.${volume}.lock"
    dx_lock_acquire "$lock" "${DX_TUNNEL_LOCK_TIMEOUT:-5}" || return 1
    [ ! -L "$claim" ] && { [ ! -e "$claim" ] || [ -f "$claim" ]; } || { echo "Error: refusing unsafe Nix-volume claim path $claim." >&2; dx_lock_release "$lock" || true; return 1; }
    if [ -e "$claim" ]; then
        if ! record="$(dx_nix_volume_claim_read "$claim")"; then
            echo "Error: refusing malformed Nix-volume claim $claim." >&2
            dx_lock_release "$lock" || true
            return 1
        fi
        IFS="$(printf '\t')" read -r claim_container claim_pid claim_start <<EOF
$record
EOF
        if container_exists "$claim_container"; then
            if [ "$claim_container" = "$container_name" ]; then
                dx_lock_release "$lock"
                return 0
            fi
            echo "Error: Nix volume $volume is already claimed by container $claim_container; destroy it or choose a distinct DX_NIX_VOLUME." >&2
            dx_lock_release "$lock" || true
            return 1
        fi
        if dx_process_identity_matches "$claim_pid" "$claim_start"; then
            echo "Error: Nix volume $volume is reserved while container $claim_container is being created." >&2
            dx_lock_release "$lock" || true
            return 1
        fi
    fi
    temporary="$(mktemp "$directory/.${volume}.claim.XXXXXX")" || { dx_lock_release "$lock" || true; return 1; }
    printf '%s\t%s\t%s\n' "$container_name" "$$" "$DXE_SELF_PROCESS_IDENTITY" > "$temporary" \
        && mv -f "$temporary" "$claim" || { rm -f "$temporary"; dx_lock_release "$lock" || true; return 1; }
    dx_lock_release "$lock"
}

dx_nix_volume_claim_release() {
    local volume="$1" container_name="$2" directory claim lock record claim_container claim_pid claim_start
    dx_nix_volume_claim_name_valid "$volume" && dx_nix_volume_claim_name_valid "$container_name" || return 1
    directory="$(dx_nix_volume_claim_dir)"; claim="$directory/$volume"; lock="$directory/.${volume}.lock"
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 0
    dx_lock_acquire "$lock" "${DX_TUNNEL_LOCK_TIMEOUT:-5}" || return 1
    [ ! -L "$claim" ] && { [ ! -e "$claim" ] || [ -f "$claim" ]; } || { dx_lock_release "$lock" || true; return 1; }
    if [ -e "$claim" ]; then
        record="$(dx_nix_volume_claim_read "$claim")" || { dx_lock_release "$lock" || true; return 1; }
        IFS="$(printf '\t')" read -r claim_container claim_pid claim_start <<EOF
$record
EOF
        [ "$claim_container" != "$container_name" ] || rm -f "$claim"
    fi
    dx_lock_release "$lock"
}
