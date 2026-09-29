#!/bin/bash
# WP5.1 (Fable A2): the bootstrap publish-or-skip sync body, previously
# embedded directly in the bin/dx-sync-bootstrap entrypoint. bin/dx*
# entrypoints are exempt from the kcov 100% line-coverage gate
# (tests/coverage/exclusions.txt: "covered by host behavior contracts; pure
# logic lives in bin/lib") -- moving the whole sync body here puts every one
# of its branches inside that gate, which is why this refactor also adds
# unit coverage for the branches that used to ride along on that exemption:
# missing source, publication-lock held/timeout, container absent, unsafe
# DX_BOOTSTRAP_PATH, entrypoint never ready.
#
# dx-start-container used to decide "did this sync really publish?" by
# pattern-matching dx-sync-bootstrap's own prose on captured stdout
# (dx_bootstrap_sync_published_generation, now deleted -- see
# docs/refactor/decisions/D7-start-generation.md). That coupling breaks the
# moment the prose is reworded, even though nothing about the actual
# publish/skip outcome changed. dx_bootstrap_sync_result_write/_read replace
# it with a small structured result file dx-sync-bootstrap writes and
# dx-start-container reads, so the wording of the human-facing messages is
# free to change without silently breaking that decision.

# dx_bootstrap_sync <container> <source> <path>
#
# The whole publish-or-skip body. Returns 0 when a real publish happened, 3
# when the payload was unchanged (no publish, not an error), 1 on any error.
# Sets the CALLER's `generation` local (Bash dynamic scoping, same pattern as
# dx_bootstrap_confirm_publication_check's `running`) to the generation id on
# both non-error outcomes, rather than printing it -- this function is called
# directly, not inside a `$(...)` capture, so its own progress/result prose
# (the "Syncing bootstrap generation ..." line in particular) still prints in
# real time as it runs, exactly as it did as the top-level script body.
dx_bootstrap_sync() {
    local container="$1" source="$2" path="$3"
    local tar_create_args=() content_digest published published_generation published_digest generation_id
    container_exists "$container" || { echo "Error: Container $container does not exist. Run ./bin/dx-create-container first." >&2; return 1; }
    # WP4.2 / Fable A6: honours DX_BOOTSTRAP_WAIT_TIMEOUT (default 30, matching
    # the magic 30 this used to hard-code) with an injectable clock instead of a
    # bare `sleep 1`, so a test can drive this bound without a real 30s wait.
    dx_wait_until "$DX_BOOTSTRAP_WAIT_TIMEOUT" 1 container_is_running "$container" || true
    container_is_running "$container" || { echo "Error: Container $container is not running. Run ./bin/dx-start-container first." >&2; return 1; }
    case "$path" in ''|/) echo "Error: Unsafe DX_BOOTSTRAP_PATH: $path" >&2; return 1 ;; esac

    # WP4.2 / Fable A6: same injectable-clock migration as the container-running
    # wait above; DX_BOOTSTRAP_WAIT_TIMEOUT's bound is unchanged, only the
    # hand-rolled `for`/`sleep 1` counting is replaced.
    dx_wait_until "$DX_BOOTSTRAP_WAIT_TIMEOUT" 1 dx_runtime_exec "$container" sh -c 'test -f "$1/.dx-bootstrap-waiting" || test -f "$1/.dx-bootstrap-ready" || test -L "$1/current"' -- "$path" >/dev/null 2>&1 || true
    dx_runtime_exec "$container" sh -c 'test -f "$1/.dx-bootstrap-waiting" || test -f "$1/.dx-bootstrap-ready" || test -L "$1/current"' -- "$path" >/dev/null 2>&1 || {
        echo "Error: Container $container entrypoint never became ready after ${DX_BOOTSTRAP_WAIT_TIMEOUT}s." >&2; return 1;
    }
    [ -f "$source/bootstrap.sh" ] || { echo "Error: Bootstrap source $source/bootstrap.sh does not exist." >&2; return 1; }

    tar_create_args=()
    tar --no-xattrs -C "$source" -cf /dev/null . >/dev/null 2>&1 && tar_create_args+=(--no-xattrs)
    tar --no-mac-metadata -C "$source" -cf /dev/null . >/dev/null 2>&1 && tar_create_args+=(--no-mac-metadata)
    # Publish only when the payload actually differs from what is already current.
    # A generation id is minted from the clock, so republishing identical content
    # moves `current` for no reason and leaves the running guest looking stale
    # forever -- see dx_bootstrap_content_digest.
    #
    # A guest published before this existed has no digest to compare, so it reports
    # nothing and we publish, which re-establishes the digest for next time.
    #
    # The completeness test is `current/bootstrap.sh`, deliberately not
    # `.dx-bootstrap-ready`: the guest launcher clears that marker on every boot, so
    # on a restart it is always absent at the moment this runs. Gating the skip on
    # it would mean never skipping on the one path that matters.
    #
    # The marker is the launcher's go-ahead, not a completeness record: the launcher
    # waits for it before resolving `current`, so both outcomes here must set it --
    # the publication below, and the skip above. The flat compatibility symlinks
    # point at `current/...` rather than a generation, so they need no republication
    # either.
    content_digest="$(dx_bootstrap_content_digest "$source" || true)"
    if [ -n "$content_digest" ]; then
    published="$(dx_runtime_exec "$container" sh -c '
        root=$1
        [ -L "$root/current" ] || exit 0
        [ -f "$root/current/bootstrap.sh" ] || exit 0
        readlink "$root/current"
        cat "$root/current/.dx-content-digest" 2>/dev/null || true
    ' -- "$path" 2>/dev/null || true)"
        published_generation="$(printf '%s\n' "$published" | sed -n '1s#^generations/##p')"
        published_digest="$(printf '%s\n' "$published" | sed -n '2p')"
        if [ -n "$published_digest" ] && [ "$published_digest" = "$content_digest" ]; then
            # Publishing is also what prunes execution leases from earlier boots.
            # Skipping it leaves the previous boot's PID 1 lease beside the live
            # one, and dx_bootstrap_lease_generation returns whichever it sees
            # first -- so the drift check would report the guest as running a
            # generation it booted two restarts ago. Prune by boot id, which is the
            # part that makes a lease stale across a restart; publication still owns
            # the fuller process-identity retention pass.
        dx_runtime_exec "$container" sh -c '
            root=$1
            boot=$(cat /proc/sys/kernel/random/boot_id) || exit 0
            for lease in "$root/.locks/leases"/*; do
                [ -f "$lease" ] || continue
                tab=$(printf "\t")
                IFS="$tab" read -r lease_generation lease_boot lease_rest < "$lease" || continue
                [ "$lease_boot" = "$boot" ] || rm -f "$lease"
            done
        ' -- "$path" >/dev/null 2>&1 || true
            # Signal boot readiness here too. The guest launcher waits for this
            # marker before resolving `current`, so a skip that stayed silent would
            # stall every restart with unchanged content for the launcher's full
            # grace period.
        dx_runtime_exec "$container" sh -c '
            root=$1
            touch "$root/.dx-bootstrap-ready"
            rm -f "$root/.dx-bootstrap-waiting"
        ' -- "$path" >/dev/null 2>&1 || true
            echo "Bootstrap content is unchanged; generation $published_generation stays current."
            generation="$published_generation"
            return 3
        fi
    fi

    generation_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    echo "Syncing bootstrap generation $generation_id from $source to $container:$path..."

    if ! COPYFILE_DISABLE=1 tar "${tar_create_args[@]}" -C "$source" -cf - . | dx_runtime_exec -i "$container" sh -c '
set -eu
root=$1
generation=$2
content_digest=${3:-}
generations=$root/generations
locks=$root/.locks
lock=$locks/publication
stage=$generations/.staging-$generation
process_start() {
    stat_line=$(cat "/proc/${1:-0}/stat" 2>/dev/null) || return 1
    stat_fields=${stat_line##*) }
    set -- $stat_fields
    [ "$#" -ge 20 ] || return 1
    shift 19
    printf "%s\n" "$1"
}
[ -d "$root" ] && [ ! -L "$root" ] || { echo "Error: unsafe bootstrap root $root." >&2; exit 1; }
for path in "$generations" "$locks" "$locks/leases"; do [ ! -L "$path" ] || { echo "Error: refusing symlinked bootstrap state path $path." >&2; exit 1; }; done
mkdir -p "$generations" "$locks/leases"
chown root:root "$root" "$generations" "$locks" "$locks/leases"
chmod 0755 "$root" "$generations"
chmod 0700 "$locks" "$locks/leases"
elapsed=0
while ! mkdir "$lock" 2>/dev/null; do
    if [ -f "$lock/owner" ]; then
        tab=$(printf "\t")
        IFS="$tab" read -r owner_boot owner_pid owner_start < "$lock/owner" || true
        boot=$(cat /proc/sys/kernel/random/boot_id)
        live_start=$(process_start "${owner_pid:-0}" || true)
        if [ -z "${owner_boot:-}" ] || [ -z "${owner_pid:-}" ] || [ -z "${owner_start:-}" ] \
            || [ "$owner_boot" != "$boot" ] || [ "$owner_start" != "$live_start" ]; then
            rm -f "$lock/owner"; rmdir "$lock" 2>/dev/null || true; continue
        fi
    elif [ "$elapsed" -ge 2 ] && rmdir "$lock" 2>/dev/null; then
        elapsed=0
        continue
    fi
    [ "$elapsed" -lt 30 ] || { echo "Error: timed out waiting for bootstrap publication lock." >&2; exit 1; }
    sleep 1; elapsed=$((elapsed + 1))
done
boot=$(cat /proc/sys/kernel/random/boot_id)
start=$(process_start $$) || { rmdir "$lock" 2>/dev/null || true; exit 1; }
owner_tmp="$locks/.owner.$$.tmp"
if ! printf "%s\t%s\t%s\n" "$boot" "$$" "$start" > "$owner_tmp" || ! mv "$owner_tmp" "$lock/owner"; then
    rm -f "$owner_tmp"; rmdir "$lock" 2>/dev/null || true; exit 1
fi
cleanup() { rm -rf "$stage"; rm -f "$lock/owner"; rmdir "$lock" 2>/dev/null || true; }
trap cleanup EXIT
trap "exit 129" HUP
trap "exit 130" INT
trap "exit 143" TERM
mkdir "$stage"
tar -xf - -C "$stage"
# Consume anything the extractor left unread. tar stops at the end-of-archive
# marker and does not necessarily drain the trailing padding the creator writes
# to fill its final block, so the host-side `tar -cf -` can take EPIPE on that
# last write. The host runs the pipeline under `set -o pipefail`, which would
# then report a complete, correct publication as a failed sync. Whether it
# fires depends on the tar implementations at both ends, so it presents as an
# intermittent sync failure rather than a reproducible one.
cat >/dev/null
for required in bootstrap.sh flake.nix flake.lock; do [ -f "$stage/$required" ] && [ ! -L "$stage/$required" ] || { echo "Error: staged bootstrap is missing a regular $required." >&2; exit 1; }; done
predecessor=""
if [ -L "$root/current" ]; then
    predecessor=$(readlink "$root/current")
    case "$predecessor" in generations/*) predecessor=${predecessor#generations/} ;; *) echo "Error: invalid bootstrap current pointer." >&2; exit 1 ;; esac
    case "$predecessor" in ""|*/*|[.-]*|*[!A-Za-z0-9_.-]*) echo "Error: invalid bootstrap predecessor generation." >&2; exit 1 ;; esac
fi
printf "%s\n" "$predecessor" > "$stage/.predecessor"
printf "%s\n" "$content_digest" > "$stage/.dx-content-digest"
chown -R root:root "$stage"
find "$stage" -type d -exec chmod 0555 {} +
find "$stage" -type f -exec chmod 0444 {} +
find "$stage" -type f \( -name "*.sh" -o -name bootstrap.sh \) -exec chmod 0555 {} +
[ ! -e "$generations/$generation" ] && [ ! -L "$generations/$generation" ] || { echo "Error: bootstrap generation already exists: $generation." >&2; exit 1; }
mv "$stage" "$generations/$generation"
current_tmp="$root/.current.$$.tmp"
[ ! -e "$current_tmp" ] && [ ! -L "$current_tmp" ] || { echo "Error: bootstrap pointer staging path already exists." >&2; exit 1; }
ln -s "generations/$generation" "$current_tmp"
mv -Tf "$current_tmp" "$root/current"
for item in bootstrap.sh flake.nix flake.lock home.nix nixvim.nix home nvim scripts pins bootstrap; do
    [ -e "$root/current/$item" ] || continue
    rm -rf "$root/$item"
    ln -s "current/$item" "$root/$item"
done
touch "$root/.dx-bootstrap-ready"
rm -f "$root/.dx-bootstrap-waiting"

# Retain current, its immutable predecessor, and generations with a fully
# matching boot/PID/start-time lease. Stale leases are removed.
current=$generation
for lease in "$locks/leases"/*; do
    [ -f "$lease" ] || continue
    tab=$(printf "\t"); IFS="$tab" read -r lease_gen lease_boot lease_pid lease_start < "$lease" || true
    lease_name=${lease##*/}
    case "$lease_gen" in ""|[.-]*|*[!A-Za-z0-9_.-]*) rm -f "$lease"; continue ;; esac
    case "$lease_boot" in ""|*[!A-Za-z0-9-]*) rm -f "$lease"; continue ;; esac
    case "$lease_pid" in ""|*[!0-9]*) rm -f "$lease"; continue ;; esac
    case "$lease_start" in ""|*[!0-9]*) rm -f "$lease"; continue ;; esac
    [ "$lease_name" = "$lease_gen.$lease_pid" ] || { rm -f "$lease"; continue; }
    live_start=$(process_start "${lease_pid:-0}" || true)
    if [ "$lease_boot" != "$boot" ] || [ -z "$live_start" ] || [ "$lease_start" != "$live_start" ]; then rm -f "$lease"; fi
done
for candidate in "$generations"/*; do
    [ -d "$candidate" ] || continue; id=${candidate##*/}
    [ "$id" = "$current" ] && continue
    [ -n "$predecessor" ] && [ "$id" = "$predecessor" ] && continue
    leased=false
    for lease in "$locks/leases/$id".*; do [ -f "$lease" ] && leased=true; done
    if [ "$leased" = false ]; then
        chmod -R u+w "$candidate"
        rm -rf "$candidate"
    fi
done
trap - EXIT HUP INT TERM
rm -f "$lock/owner"; rmdir "$lock"
' -- "$path" "$generation_id" "$content_digest"; then
        return 1
    fi
    echo "Bootstrap generation $generation_id is ready."
    generation="$generation_id"
    return 0
}

# dx_bootstrap_sync_result_write <file> <outcome> <generation>
#
# Publishes the sync's outcome for dx-start-container to read, replacing the
# prose-parsing this used to require. Written to a sibling temp file and
# renamed into place (mv -f), so a reader never observes a partial file.
dx_bootstrap_sync_result_write() {
    local file="$1" outcome="$2" generation="$3" tmp
    case "$outcome" in
        published|unchanged) ;;
        *) return 1 ;;
    esac
    case "$generation" in ''|*/*|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    tmp="$(mktemp "${file}.XXXXXX")" || return 1
    { printf 'outcome=%s\n' "$outcome" && printf 'generation=%s\n' "$generation"; } > "$tmp" \
        && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# dx_bootstrap_sync_result_read <file>
#
# Its own bounded reader: reads exactly two lines (never sources the file --
# the result file is data a prior process wrote, not code to execute) and
# rejects anything that is not exactly `outcome=published` or
# `outcome=unchanged` on the first line and a safe `generation=<id>` on the
# second, including a missing file, a symlink, a short read (0 or 1 lines),
# or a third line trailing the first two. Sets the CALLER's `outcome` and
# `generation` locals (Bash dynamic scoping, same pattern as
# dx_bootstrap_sync) rather than printing them.
dx_bootstrap_sync_result_read() {
    local file="$1" line1 line2 _
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    exec 3< "$file" || return 1
    if ! IFS= read -r line1 <&3; then exec 3<&-; return 1; fi
    if ! IFS= read -r line2 <&3; then exec 3<&-; return 1; fi
    if IFS= read -r _ <&3; then exec 3<&-; return 1; fi
    exec 3<&-
    case "$line1" in
        outcome=published|outcome=unchanged) outcome="${line1#outcome=}" ;;
        *) return 1 ;;
    esac
    case "$line2" in
        generation=*) generation="${line2#generation=}" ;;
        *) return 1 ;;
    esac
    case "$generation" in ''|*/*|[.-]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
}
