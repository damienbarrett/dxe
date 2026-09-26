#!/bin/bash
# tests/qnap/phase0-spike.sh
#
# qnap-dxe-plan.md Phase 0 -- "Disposable spike". Versioned, non-interactive
# replacement for running the plan's nine spike steps by hand. Every
# resource this script creates is named "dxe-spike-<role>" AND carries the
# label dxe.role=spike; every query/delete filters by that label, so nothing
# unlabelled is ever touched. Never privileged, never CAP_SYS_ADMIN, never
# published beyond 127.0.0.1, never a TCP-exposed daemon.
#
# Usage:
#   tests/qnap/phase0-spike.sh [--dry-run] [--with-service-restart] [--with-nas-reboot]
#   tests/qnap/phase0-spike.sh --cleanup [--dry-run]
#
# Environment:
#   DXE_QNAP_HOST                 ssh_config alias for the QNAP (default: qnap-dxe)
#   DXE_QNAP_SSH_CONNECT_TIMEOUT  seconds (default: 10)
#
# --dry-run prints the exact command list this run would issue and connects
# nowhere. Without --dry-run, the script refuses to run at all (exit
# non-zero, before any mutation) unless DXE_QNAP_HOST is reachable over a
# non-interactive SSH connection.
#
# --with-service-restart / --with-nas-reboot gate step 8's restarts; without
# them, that step is reported skipped ("needs maintenance window") and no
# restart/reboot command is ever issued. --cleanup alone removes only
# dxe.role=spike-labelled leftovers from an earlier run (containers, then
# volumes, then the built image), proven by a before/after diff of the full
# (unfiltered) container/volume/image listing.
#
# See tests/qnap/README.md for how to prepare access and read step output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTAINER_DIR="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-26.05"
CONTAINERFILE="$CONTAINER_DIR/Containerfile"
# shellcheck source=lib/phase0-common.sh
source "$SCRIPT_DIR/lib/phase0-common.sh"

DXE_DRY_RUN=0
DXE_CLEANUP=0
DXE_WITH_SERVICE_RESTART=0
DXE_WITH_NAS_REBOOT=0

usage() {
    echo "Usage: $(basename "$0") [--dry-run] [--with-service-restart] [--with-nas-reboot]" >&2
    echo "       $(basename "$0") --cleanup [--dry-run]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DXE_DRY_RUN=1; shift ;;
        --cleanup) DXE_CLEANUP=1; shift ;;
        --with-service-restart) DXE_WITH_SERVICE_RESTART=1; shift ;;
        --with-nas-reboot) DXE_WITH_NAS_REBOOT=1; shift ;;
        --help) usage; exit 0 ;;
        *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

STEP_FAILED=0
step_header() { printf '\n--- Step %s: %s ---\n' "$1" "$2"; }

# Print a PASS/FAIL verdict for a step whose command ran through
# dxe_maybe_run/dxe_maybe_capture (so its exit status is meaningful).
# Silent under --dry-run: nothing ran, so there is nothing to verify -- the
# DRY-RUN command line already printed by dxe_maybe_run is the whole point.
step_verdict() {
    local num="$1" status="$2" detail="${3:-}"
    [ "$DXE_DRY_RUN" != 1 ] || return 0
    if [ "$status" -eq 0 ]; then
        printf 'Step %s: PASS%s\n' "$num" "${detail:+ ($detail)}"
    else
        printf 'Step %s: FAIL%s\n' "$num" "${detail:+ ($detail)}"
        STEP_FAILED=1
    fi
}

step_skip() { printf 'Step %s: SKIP (%s)\n' "$1" "$2"; }

# --- Base image reference (DQ7: native architecture; step 2) --------------

dxe_spike_base_image_ref() {
    sed -n 's/^FROM //p' "$CONTAINERFILE" | head -n1
}

dxe_spike_base_image_tag_only() {
    dxe_spike_base_image_ref | sed 's/@sha256:[0-9a-f]*$//'
}

# --- Step 5's in-container listener (no sshd in the minimal base image) ---
#
# Tries, in order, a tool the base image is likely to have: busybox httpd,
# then nc, then socat. Whichever answers is recorded by step 7's real run
# (this script cannot itself observe which branch a real NAS takes without
# running against one -- see tests/qnap/README.md and the task report).
dxe_spike_listener_command() {
    printf '%s' 'if command -v busybox >/dev/null 2>&1 && busybox httpd 2>&1 | grep -qi usage; then mkdir -p /tmp/dxe-spike-www && echo PONG > /tmp/dxe-spike-www/index.html && exec busybox httpd -f -p 2222 -h /tmp/dxe-spike-www; elif command -v nc >/dev/null 2>&1; then while true; do printf PONG | nc -l -p 2222 || nc -l 2222; done; elif command -v socat >/dev/null 2>&1; then exec socat TCP-LISTEN:2222,fork,reuseaddr SYSTEM:"printf PONG"; else exec sleep infinity; fi'
}

# Best-guess QNAP service-restart command for Container Station, following
# the common QNAP qpkg init-script convention. NOT verified against a real
# NAS (Phase 0 has none yet) -- confirm the qpkg's actual "Shell" field in
# /etc/config/qpkg.conf at the first real run and adjust here if it differs;
# see tests/qnap/README.md and the task report for this caveat.
dxe_spike_container_station_restart_cmd() {
    printf '%s' '/etc/init.d/container-station.sh restart'
}

# --- Resource snapshot (safety proof: "nothing else changed") -------------

dxe_spike_snapshot() {
    {
        dxe_qnap_docker_capture ps -a --format '{{.Names}}' || true
        dxe_qnap_docker_capture volume ls --format '{{.Name}}' || true
        dxe_qnap_docker_capture image ls --format '{{.Repository}}:{{.Tag}}' || true
    } 2>/dev/null | sort
}

dxe_spike_diff_snapshot() {
    local before="$1" after="$2" line unexpected=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            "> $DXE_SPIKE_PREFIX"*|"< $DXE_SPIKE_PREFIX"*) ;;
            '> '*|'< '*)
                echo "Error: unexpected change to a non-spike resource: $line" >&2
                unexpected=1
                ;;
        esac
    done < <(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)
    if [ "$unexpected" -eq 1 ]; then
        STEP_FAILED=1
        return 1
    fi
    echo "Diff proof: only dxe-spike-* resources changed between snapshots."
    return 0
}

# --- Cleanup: remove only dxe.role=spike-labelled resources ---------------

dxe_spike_cleanup() {
    local before="" after="" containers="" volumes="" images="" name status=0

    if [ "$DXE_DRY_RUN" != 1 ]; then
        before="$(dxe_spike_snapshot)"
    fi

    containers="$(dxe_qnap_docker_capture ps -a --filter "label=$DXE_SPIKE_LABEL" --format '{{.Names}}' || true)"
    volumes="$(dxe_qnap_docker_capture volume ls --filter "label=$DXE_SPIKE_LABEL" --format '{{.Name}}' || true)"
    images="$(dxe_qnap_docker_capture image ls --filter "label=$DXE_SPIKE_LABEL" --format '{{.Repository}}:{{.Tag}}' || true)"

    if [ "$DXE_DRY_RUN" = 1 ]; then
        echo "(dry-run: removal targets are unknown without connecting; the queries above are what would run)"
        return 0
    fi

    if [ -n "$containers" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            status=0; dxe_qnap_docker_run rm -f "$name" || status=$?
            step_verdict "cleanup-container" "$status" "$name"
        done <<<"$containers"
    else
        echo "No labelled containers to remove."
    fi

    if [ -n "$volumes" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            status=0; dxe_qnap_docker_run volume rm "$name" || status=$?
            step_verdict "cleanup-volume" "$status" "$name"
        done <<<"$volumes"
    else
        echo "No labelled volumes to remove."
    fi

    if [ -n "$images" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            status=0; dxe_qnap_docker_run rmi "$name" || status=$?
            step_verdict "cleanup-image" "$status" "$name"
        done <<<"$images"
    else
        echo "No labelled images to remove."
    fi

    after="$(dxe_spike_snapshot)"
    dxe_spike_diff_snapshot "$before" "$after" || true
}

# --- The nine spike steps --------------------------------------------------

dxe_spike_run_steps() {
    local before=""
    [ "$DXE_DRY_RUN" = 1 ] || before="$(dxe_spike_snapshot)"

    local status=0

    step_header 1 "Connect with a command-scoped Docker SSH endpoint"
    status=0; dxe_qnap_ssh_exec true || status=$?
    step_verdict 1a "$status" "ssh reachability (already verified before mutation)"
    status=0; dxe_qnap_docker_run version || status=$?
    step_verdict 1b "$status" "docker -H $(dxe_qnap_docker_host_arg) version"

    step_header 2 "Pull pinned base image for native architecture"
    local base_ref tag_ref resolved tag_resolved
    base_ref="$(dxe_spike_base_image_ref)"
    tag_ref="$(dxe_spike_base_image_tag_only)"
    status=0; dxe_qnap_docker_run pull "$base_ref" || status=$?
    step_verdict 2 "$status" "pulled $base_ref"
    if [ "$DXE_DRY_RUN" != 1 ]; then
        resolved="$(dxe_qnap_docker_capture inspect --format '{{index .RepoDigests 0}}' "$base_ref" 2>/dev/null || echo UNKNOWN)"
        printf 'Step 2: uname -m / resolved digest recorded separately by phase0-inventory.sh; this image digest=%s\n' "$resolved"
        if [ "$tag_ref" != "$base_ref" ]; then
            status=0; dxe_qnap_docker_run pull "$tag_ref" || status=$?
            step_verdict 2b "$status" "fallback tag pull $tag_ref"
            tag_resolved="$(dxe_qnap_docker_capture inspect --format '{{index .RepoDigests 0}}' "$tag_ref" 2>/dev/null || echo UNKNOWN)"
            if [ "$tag_resolved" = "$resolved" ]; then
                echo "Step 2b: tag reference resolves to the same digest as the pin (no drift)."
            else
                echo "Step 2b: WARNING tag reference resolved to a DIFFERENT digest ($tag_resolved) than the pin ($resolved)."
            fi
        fi
    fi

    step_header 3 "Build the current minimal Containerfile remotely"
    status=0; dxe_qnap_docker_run build --label "$DXE_SPIKE_LABEL" -t "$(dxe_spike_name image):phase0" "$CONTAINER_DIR" || status=$?
    step_verdict 3 "$status" "built $(dxe_spike_name image):phase0 from $CONTAINER_DIR"

    step_header 4 "Create three disposable labelled volumes"
    local role
    for role in nix persist bootstrap; do
        status=0; dxe_qnap_docker_run volume create --label "$DXE_SPIKE_LABEL" "$(dxe_spike_name "$role")" || status=$?
        step_verdict "4-$role" "$status" "volume $(dxe_spike_name "$role")"
    done

    step_header 5 "Run a disposable container (Nix volume at /nix; no --privileged, no CAP_SYS_ADMIN)"
    status=0
    dxe_qnap_docker_run run -d \
        --name "$(dxe_spike_name container)" \
        --label "$DXE_SPIKE_LABEL" \
        -v "$(dxe_spike_name nix):/nix" \
        -p 127.0.0.1:2222:2222 \
        "$(dxe_spike_name image):phase0" \
        /bin/sh -c "$(dxe_spike_listener_command)" || status=$?
    step_verdict 5 "$status" "container $(dxe_spike_name container)"

    step_header 6 "Stream a small tar payload through docker exec -i and verify sha256"
    if [ "$DXE_DRY_RUN" = 1 ]; then
        dxe_maybe_run tar -cf - -C /tmp payload.txt
        dxe_qnap_docker_run exec -i "$(dxe_spike_name container)" tar -xf - -C /tmp
        dxe_qnap_docker_run exec "$(dxe_spike_name container)" sh -c 'sha256sum /tmp/payload.txt'
    else
        local payload_dir local_sha remote_sha stream_status=0
        payload_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-spike-payload.XXXXXX")"
        printf 'dxe phase0 spike payload %s\n' "$(date -u +%s)" >"$payload_dir/payload.txt"
        local_sha="$(shasum -a 256 "$payload_dir/payload.txt" 2>/dev/null | awk '{print $1}')"
        [ -n "$local_sha" ] || local_sha="$(sha256sum "$payload_dir/payload.txt" | awk '{print $1}')"
        printf '+ tar -C %s -cf - payload.txt | docker -H %s exec -i %s tar -xf - -C /tmp\n' \
            "$payload_dir" "$(dxe_qnap_docker_host_arg)" "$(dxe_spike_name container)" >&2
        tar -C "$payload_dir" -cf - payload.txt | docker -H "$(dxe_qnap_docker_host_arg)" exec -i "$(dxe_spike_name container)" tar -xf - -C /tmp || stream_status=$?
        remote_sha="$(docker -H "$(dxe_qnap_docker_host_arg)" exec "$(dxe_spike_name container)" sh -c 'sha256sum /tmp/payload.txt 2>/dev/null || shasum -a 256 /tmp/payload.txt' 2>/dev/null | awk '{print $1}')"
        rm -rf "$payload_dir"
        if [ "$stream_status" -eq 0 ] && [ -n "$remote_sha" ] && [ "$remote_sha" = "$local_sha" ]; then
            step_verdict 6 0 "sha256 matched ($local_sha)"
        else
            step_verdict 6 1 "sha256 mismatch or stream failure (local=$local_sha remote=$remote_sha)"
        fi
    fi

    step_header 7 "Bind guest port 2222 to QNAP loopback only and verify"
    # -W hands ssh's own stdio to a raw TCP connection the NAS makes to its
    # own loopback:2222 -- an ssh CLI option, so it must sit before the
    # destination, unlike every other call in this script (which passes a
    # remote command string after the destination). There is no sshd in the
    # spike container to "-J" through past this single hop (see the comment
    # on dxe_spike_listener_command above), so this -W probe alone is the
    # reachability proof; both the dry-run preview and the real probe below
    # build the same ssh_opts array so they can never drift apart.
    local ssh_opts=() ssh_opt
    while IFS= read -r ssh_opt; do ssh_opts+=("$ssh_opt"); done <<<"$(dxe_qnap_ssh_opts)"
    if [ "$DXE_DRY_RUN" = 1 ]; then
        # dxe_maybe_run is a pure preview here (DXE_DRY_RUN=1 always returns
        # without executing); the real probe below is a distinct,
        # timeout-wrapped invocation because -W blocks until the tunnel
        # closes, which a bare dxe_maybe_run call must never attempt.
        dxe_maybe_run ssh "${ssh_opts[@]}" -W 127.0.0.1:2222 "$(dxe_qnap_host)"
    else
        local ss_output loopback_ok=1
        ss_output="$(dxe_qnap_ssh_capture 'ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null')"
        case "$ss_output" in *"127.0.0.1:2222"*) ;; *) loopback_ok=0 ;; esac
        case "$ss_output" in *"0.0.0.0:2222"*|*":::2222"*|*"*:2222"*) loopback_ok=0 ;; esac
        if [ "$loopback_ok" -eq 1 ]; then
            echo "Step 7: ss -ltn confirms 2222 is bound to 127.0.0.1 only."
            # A forced timeout closing an otherwise-live connection (124)
            # counts as reached; an immediate SSH-level connect failure
            # (255) does not.
            local reach_rc=0
            if command -v timeout >/dev/null 2>&1; then
                timeout 5 ssh "${ssh_opts[@]}" -W 127.0.0.1:2222 "$(dxe_qnap_host)" </dev/null >/dev/null 2>&1 || reach_rc=$?
            else
                ssh "${ssh_opts[@]}" -W 127.0.0.1:2222 "$(dxe_qnap_host)" </dev/null >/dev/null 2>&1 || reach_rc=$?
            fi
            if [ "$reach_rc" -eq 0 ] || [ "$reach_rc" -eq 124 ]; then
                step_verdict 7 0 "loopback-only, reachable via the NAS as jump"
            else
                step_verdict 7 1 "loopback-only confirmed, but the raw TCP forward failed (rc=$reach_rc)"
            fi
        else
            step_verdict 7 1 "loopback-only publication NOT confirmed by ss -ltn"
        fi
    fi

    step_header 8 "Guarded restarts (container, Container Station, NAS)"
    if [ "$DXE_WITH_SERVICE_RESTART" = 1 ]; then
        status=0; dxe_qnap_docker_run restart "$(dxe_spike_name container)" || status=$?
        step_verdict 8a "$status" "container restart"
        status=0; dxe_qnap_ssh_exec "$(dxe_spike_container_station_restart_cmd)" || status=$?
        step_verdict 8b "$status" "Container Station restart: $(dxe_spike_container_station_restart_cmd)"
    else
        step_skip 8a "container restart skipped (needs maintenance window; rerun with --with-service-restart)"
        step_skip 8b "Container Station restart skipped (needs maintenance window; rerun with --with-service-restart)"
    fi
    if [ "$DXE_WITH_NAS_REBOOT" = 1 ]; then
        status=0; dxe_qnap_ssh_exec reboot || status=$?
        step_verdict 8c "$status" "NAS reboot (ssh reboot)"
    else
        step_skip 8c "NAS reboot skipped (needs an agreed maintenance window; rerun with --with-nas-reboot)"
    fi

    step_header 9 "Delete only labelled spike resources; prove nothing else changed"
    dxe_spike_cleanup
    if [ "$DXE_DRY_RUN" != 1 ]; then
        local after
        after="$(dxe_spike_snapshot)"
        dxe_spike_diff_snapshot "$before" "$after" || true
    fi
}

# --- Entry point ------------------------------------------------------------

if [ "$DXE_DRY_RUN" != 1 ] && ! command -v docker >/dev/null 2>&1; then
    echo "Error: local 'docker' CLI not found. The Docker-over-SSH control plane (DQ1) requires Docker installed on the controller (this Mac)." >&2
    exit 1
fi

if [ "$DXE_DRY_RUN" != 1 ]; then
    dxe_qnap_require_reachable || exit 1
fi

echo "QNAP Phase 0 spike -- host alias: $(dxe_qnap_host)$( [ "$DXE_DRY_RUN" = 1 ] && printf ' (DRY RUN: nothing will connect)' || true)"

if [ "$DXE_CLEANUP" = 1 ]; then
    step_header cleanup "Remove only dxe.role=spike-labelled leftovers"
    dxe_spike_cleanup
else
    dxe_spike_run_steps
fi

echo
if [ "$STEP_FAILED" -eq 0 ]; then
    echo "QNAP Phase 0 spike: all reported steps PASSED (or were dry-run previewed / intentionally skipped)."
else
    echo "QNAP Phase 0 spike: one or more steps FAILED. See above." >&2
fi
exit "$STEP_FAILED"
