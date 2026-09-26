#!/bin/bash
# tests/qnap/phase0-spike.sh
#
# qnap-dxe-plan.md Phase 0 -- "Disposable spike". Versioned, non-interactive
# replacement for running the plan's nine spike steps by hand. Every
# resource this script creates is named "dxe-spike-<role>" AND carries the
# label dxe.role=spike; every query/delete filters by that label, so nothing
# unlabelled is ever touched. Never privileged, never CAP_SYS_ADMIN, never
# published to the LAN or the internet, never a TCP-exposed daemon. Guest SSH
# (step 5/7) is published on the NAS's own Tailscale address only (DQ5,
# amended 2026-09-26) -- discovered at run time, never hard-coded -- or, if
# that address cannot be discovered, on 127.0.0.1 as a fallback (in which
# case step 7 reports FAIL: there is nothing tailnet-reachable to verify).
#
# Usage:
#   tests/qnap/phase0-spike.sh [--dry-run] [--with-container-restart] [--with-service-restart] [--with-nas-reboot]
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
# Step 8's three restarts are independently guarded: --with-container-restart
# gates 8a (restart the dxe-spike-container only), --with-service-restart
# gates 8b (the Container Station qpkg restart), and --with-nas-reboot gates
# 8c (a full NAS reboot). Without a flag, its step is reported skipped
# ("needs maintenance window") and no restart/reboot command is ever issued.
# --cleanup alone removes only dxe.role=spike-labelled leftovers from an
# earlier run (containers, then volumes, then the built image), proven by a
# before/after diff of the full (unfiltered) container/volume/image listing.
#
# The NAS is a production system: --report writes the FULL step-by-step log
# (may include the discovered Docker CLI absolute path -- fine, since this
# file is private), and --summary writes only step verdicts plus a reminder
# that resources use the dxe-spike- prefix, nothing else. BOTH default to a
# location OUTSIDE this repository (see dxe_qnap_private_dir in
# lib/phase0-common.sh) -- this repository never gets more than the one-line
# outcome the operator adds to qnap-dxe-plan.md by hand. See
# tests/qnap/README.md.
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
DXE_WITH_CONTAINER_RESTART=0
DXE_WITH_SERVICE_RESTART=0
DXE_WITH_NAS_REBOOT=0
REPORT_PATH=""
SUMMARY_PATH=""

usage() {
    echo "Usage: $(basename "$0") [--dry-run] [--with-container-restart] [--with-service-restart] [--with-nas-reboot] [--report FILE] [--summary FILE]" >&2
    echo "       $(basename "$0") --cleanup [--dry-run] [--report FILE] [--summary FILE]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DXE_DRY_RUN=1; shift ;;
        --cleanup) DXE_CLEANUP=1; shift ;;
        --with-container-restart) DXE_WITH_CONTAINER_RESTART=1; shift ;;
        --with-service-restart) DXE_WITH_SERVICE_RESTART=1; shift ;;
        --with-nas-reboot) DXE_WITH_NAS_REBOOT=1; shift ;;
        --report) [ "$#" -ge 2 ] || { echo "Error: --report requires FILE." >&2; exit 2; }; REPORT_PATH="$2"; shift 2 ;;
        --report=*) REPORT_PATH="${1#*=}"; shift ;;
        --summary) [ "$#" -ge 2 ] || { echo "Error: --summary requires FILE." >&2; exit 2; }; SUMMARY_PATH="$2"; shift 2 ;;
        --summary=*) SUMMARY_PATH="${1#*=}"; shift ;;
        --help) usage; exit 0 ;;
        *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$REPORT_PATH" ] || REPORT_PATH="$(dxe_qnap_private_dir)/phase0-spike-$(dxe_qnap_utc_date).log"
[ -n "$SUMMARY_PATH" ] || SUMMARY_PATH="$(dxe_qnap_private_dir)/phase0-spike-summary-$(dxe_qnap_utc_date).md"

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

# --- Discover the Docker CLI's absolute path (once, before any step) ------
#
# Confirmed on the real NAS: the non-interactive PATH lacks the Docker CLI,
# so every step below must use the discovered absolute path rather than a
# bare "docker" -- see lib/phase0-common.sh's dxe_qnap_docker_run comment.
# An explicit DXE_QNAP_DOCKER always wins (skips the round trip). Never
# prints the discovered path outside the full --report (private).
dxe_qnap_ensure_docker_bin() {
    if [ -n "${DXE_QNAP_DOCKER:-}" ]; then
        echo "Using DXE_QNAP_DOCKER override (absolute path not repeated here)."
        return 0
    fi
    if [ "$DXE_DRY_RUN" = 1 ]; then
        dxe_qnap_ssh_capture "$(dxe_qnap_docker_discovery_remote_script)" >/dev/null
        DXE_QNAP_DOCKER='<discovered-docker-path>'
        return 0
    fi
    local discovered
    discovered="$(dxe_qnap_ssh_capture "$(dxe_qnap_docker_discovery_remote_script)")"
    discovered="$(printf '%s\n' "$discovered" | tail -n1 | tr -d '\r')"
    if [ -z "$discovered" ] || [ "$discovered" = NOTFOUND ]; then
        echo "Error: could not discover the Docker CLI's absolute path on $(dxe_qnap_host) (checked the non-interactive PATH and the Container Station qpkg's own bin directory). Set DXE_QNAP_DOCKER=<path> to override. See tests/qnap/README.md." >&2
        exit 1
    fi
    DXE_QNAP_DOCKER="$discovered"
    echo "Discovered the Docker CLI (absolute path recorded only in the private --report, never in --summary)."
}

# --- Discover the NAS's Tailscale IPv4 address (once, before any step) ----
#
# DQ5 (amended 2026-09-26): the guest's SSH port publishes on the NAS's own
# Tailscale address only -- not loopback, not the LAN, not 0.0.0.0 -- so the
# controller reaches it directly over the tailnet (exposure governed by
# Tailscale ACLs), instead of jumping through the NAS (that jump failed on
# the real NAS: sshd's QTS-default "AllowTcpForwarding no" makes ssh -W/
# ProxyJump "administratively prohibited"). Never hard-coded, never printed
# outside the private --report (same rule as the discovered Docker CLI path
# above). Unlike dxe_qnap_ensure_docker_bin, failure here is never fatal:
# step 5 falls back to binding 127.0.0.1 only so the rest of the spike still
# runs, and step 7 reports FAIL with a clear reason instead of silently
# checking nothing.
DXE_QNAP_TAILNET_ADDR=""

dxe_qnap_ensure_tailnet_addr() {
    if [ "$DXE_DRY_RUN" = 1 ]; then
        dxe_qnap_ssh_capture "$(dxe_qnap_tailnet_addr_discovery_remote_script)" >/dev/null
        DXE_QNAP_TAILNET_ADDR='<tailnet-ip>'
        return 0
    fi
    local discovered
    discovered="$(dxe_qnap_ssh_capture "$(dxe_qnap_tailnet_addr_discovery_remote_script)")"
    discovered="$(printf '%s\n' "$discovered" | tail -n1 | tr -d '\r')"
    if [ -z "$discovered" ] || [ "$discovered" = NOTFOUND ]; then
        DXE_QNAP_TAILNET_ADDR=""
        echo "Warning: could not discover the NAS's Tailscale address (checked the Tailscale qpkg CLI's \"ip -4\" and the tailscale0 interface directly). Step 5 will fall back to publishing 127.0.0.1 only; step 7 will report FAIL. See tests/qnap/README.md."
        return 0
    fi
    DXE_QNAP_TAILNET_ADDR="$discovered"
    echo "Discovered the NAS's Tailscale address (recorded only in the private --report, never in --summary)."
}

# --- Base image reference (DQ7: native architecture; step 2) --------------

dxe_spike_base_image_ref() {
    sed -n 's/^FROM //p' "$CONTAINERFILE" | head -n1
}

dxe_spike_base_image_tag_only() {
    dxe_spike_base_image_ref | sed 's/@sha256:[0-9a-f]*$//'
}

# --- Step 5's in-container listener (no sshd in the minimal base image) ---
#
# Confirmed locally (Apple `container`, the same pinned base image this
# Containerfile's FROM line names, run with no volume/cache so the fetch is
# fully cold): the base image has bash, curl, and nix on PATH, but NO
# busybox, nc, socat, python3, or perl -- so a chain that merely tries each
# of those in turn always falls through to the final "else" branch and
# never actually listens on 2222 (exactly what the second real NAS run hit:
# the port was bound but nothing answered, so the direct connect was
# refused instantly). The tool this image DOES reliably have is Nix itself,
# so the listener is fetched through it instead: `nix shell nixpkgs#busybox
# --command busybox httpd` pulls a busybox closure from the default flake
# registry (nixpkgs -> github:NixOS/nixpkgs, resolved via cache.nixos.org)
# and runs its httpd in the foreground. `--extra-experimental-features
# "nix-command flakes"` is required on the invocation itself -- confirmed
# locally that this image's /etc/nix/nix.conf does not enable either
# feature by default (`nix show-config` reports "experimental Nix feature
# 'nix-command' is disabled" with neither flag passed). The fetch needs
# outbound network access and, confirmed locally on a cold store, took
# ~67s; expect a minute or more on the real NAS too -- see step 7's bounded
# retry below, which exists because of exactly this delay. `exec sleep
# infinity` remains only as the last-resort fallback if the whole nix
# invocation itself fails (e.g. no outbound network) -- step 7's bounded
# poll then times out and reports FAIL with a clear reason instead of
# hanging or reporting a misleading "connect refused" as the whole story.
dxe_spike_listener_command() {
    printf '%s' 'mkdir -p /tmp/dxe-spike-www && echo PONG > /tmp/dxe-spike-www/index.html && { nix --extra-experimental-features "nix-command flakes" shell nixpkgs#busybox --command busybox httpd -f -p 2222 -h /tmp/dxe-spike-www; } || exec sleep infinity'
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
    local spike_image_tag tag_present=""
    spike_image_tag="$(dxe_spike_name image):phase0"

    if [ "$DXE_DRY_RUN" != 1 ]; then
        before="$(dxe_spike_snapshot)"
    fi

    containers="$(dxe_qnap_docker_capture ps -a --filter "label=$DXE_SPIKE_LABEL" --format '{{.Names}}' || true)"
    volumes="$(dxe_qnap_docker_capture volume ls --filter "label=$DXE_SPIKE_LABEL" --format '{{.Name}}' || true)"
    images="$(dxe_qnap_docker_capture image ls --filter "label=$DXE_SPIKE_LABEL" --format '{{.Repository}}:{{.Tag}}' || true)"

    if [ "$DXE_DRY_RUN" = 1 ]; then
        echo "(dry-run: removal targets are unknown without connecting; the queries above are what would run)"
        dxe_qnap_docker_run rmi "$spike_image_tag"
        return 0
    fi

    # Every removal below redirects its own stdin from /dev/null: each
    # dxe_qnap_docker_run call forks a real ssh process, and ssh (like the
    # real one this stubs) keeps stdin connected to the remote command
    # unless told otherwise. Left alone inside a "while read <<<\"$list\""
    # loop, that ssh process inherits the SAME file descriptor the loop's
    # own "read" is consuming from, and draining it (as a real ssh
    # commonly does for even a short remote command) leaves nothing for
    # the next "read" -- so the loop silently stops after its first
    # iteration. This is exactly what the first real --cleanup run hit:
    # "dxe-spike-nix" was removed and the run stopped, leaving the other
    # labelled volumes behind. Redirecting each removal's stdin away from
    # the loop's here-string keeps the two completely separate.
    if [ -n "$containers" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            status=0; dxe_qnap_docker_run rm -f "$name" </dev/null || status=$?
            step_verdict "cleanup-container" "$status" "$name"
        done <<<"$containers"
    else
        echo "No labelled containers to remove."
    fi

    if [ -n "$volumes" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            status=0; dxe_qnap_docker_run volume rm "$name" </dev/null || status=$?
            step_verdict "cleanup-volume" "$status" "$name"
        done <<<"$volumes"
    else
        echo "No labelled volumes to remove."
    fi

    if [ -n "$images" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            status=0; dxe_qnap_docker_run rmi "$name" </dev/null || status=$?
            step_verdict "cleanup-image" "$status" "$name"
        done <<<"$images"
    else
        echo "No labelled images to remove."
    fi

    # docker tag (step 3) never attaches a label, so the spike's image
    # reference never appears in the label-filtered listing above --
    # remove it by its fixed, well-known name instead. Only the tag
    # reference is removed; the base image step 2 pulled keeps its own
    # reference and stays cached (intentional: re-running the spike should
    # not have to re-pull the base image every time). Checked for presence
    # first (by reference, not by label) so a --cleanup run with nothing
    # to untag stays idempotent rather than reporting a spurious FAIL for
    # "no such image".
    tag_present="$(dxe_qnap_docker_capture image ls --filter "reference=$spike_image_tag" --format '{{.Repository}}:{{.Tag}}' || true)"
    if [ -n "$tag_present" ]; then
        status=0; dxe_qnap_docker_run rmi "$spike_image_tag" </dev/null || status=$?
        step_verdict "cleanup-image-tag" "$status" "$spike_image_tag"
    else
        echo "No spike image tag ($spike_image_tag) to remove."
    fi

    after="$(dxe_spike_snapshot)"
    dxe_spike_diff_snapshot "$before" "$after" || true
    return "$STEP_FAILED"
}

# --- The nine spike steps --------------------------------------------------

dxe_spike_run_steps() {
    local before=""
    local status=0

    step_header 1 "Connect with a command-scoped Docker SSH endpoint"
    status=0; dxe_qnap_ssh_exec true || status=$?
    step_verdict 1a "$status" "ssh reachability (already verified before mutation)"
    status=0; dxe_qnap_docker_run version || status=$?
    step_verdict 1b "$status" "$(dxe_qnap_docker_bin) version via ssh"

    step_header 2 "Pull pinned base image for native architecture"
    local base_ref tag_ref resolved tag_resolved base_id tag_id
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

    # The step-9 safety snapshot is taken here, AFTER step 2's pull(s), not
    # at the very start of the run: step 2 deliberately pulls the pinned
    # base image (and its floating tag, when it differs) as part of the
    # spike itself, so a snapshot taken before that pull would see the
    # newly cached image as an "unexpected" non-spike change in step 9's
    # diff guard purely because of what step 2 itself just did -- the
    # first real run hit exactly this ("Error: unexpected change to a
    # non-spike resource: > <base image ref>"), reporting a false FAIL
    # unrelated to cleanup. Steps 1 and 2 never create or delete a
    # container/volume/image other than this expected pull, so nothing is
    # lost by starting the safety snapshot here instead of at step 1.
    [ "$DXE_DRY_RUN" = 1 ] || before="$(dxe_spike_snapshot)"

    step_header 3 "Tag the pulled base image as the spike image (no remote build needed)"
    # QNAP's Docker wrapper creates a per-user build directory under
    # Container Station's own data area and refuses it there for a
    # non-default administrator -- confirmed against the real NAS:
    # "mkdir .../container-station/homes/<user>: permission denied". The
    # Containerfile is a single "FROM <pinned ref>" line (see
    # dxe_spike_base_image_ref above -- the single source of truth for the
    # pin; it is never re-parsed or hardcoded a second time here), so a
    # remote `docker build` added nothing but a name. Step 2 already
    # pulled base_ref; tag that same already-pulled image instead -- no
    # additional pull, no build context to stream, no per-user build
    # directory touched. `docker tag` is a plain-token docker invocation
    # (unlike step 5's), so the usual dxe_qnap_docker_run/_capture path
    # needs no special quoting.
    status=0; dxe_qnap_docker_run tag "$base_ref" "$(dxe_spike_name image):phase0" || status=$?
    base_id="$(dxe_qnap_docker_capture image inspect --format '{{.Id}}' "$base_ref" 2>/dev/null || echo UNKNOWN)"
    tag_id="$(dxe_qnap_docker_capture image inspect --format '{{.Id}}' "$(dxe_spike_name image):phase0" 2>/dev/null || echo UNKNOWN)"
    if [ "$DXE_DRY_RUN" != 1 ]; then
        if [ "$status" -eq 0 ] && [ "$base_id" != UNKNOWN ] && [ "$tag_id" = "$base_id" ]; then
            step_verdict 3 0 "tagged $(dxe_spike_name image):phase0 (image ID $tag_id matches the pulled reference)"
        else
            step_verdict 3 1 "tag failed or image ID mismatch (status=$status base=$base_id tag=$tag_id)"
        fi
    fi

    step_header 4 "Create three disposable labelled volumes"
    local role
    for role in nix persist bootstrap; do
        status=0; dxe_qnap_docker_run volume create --label "$DXE_SPIKE_LABEL" "$(dxe_spike_name "$role")" || status=$?
        step_verdict "4-$role" "$status" "volume $(dxe_spike_name "$role")"
    done

    step_header 5 "Run a disposable container (Nix volume at /nix; no --privileged, no CAP_SYS_ADMIN)"
    # DQ5 (amended 2026-09-26): publish to the NAS's own discovered Tailscale
    # address only, never loopback and never 0.0.0.0 -- unless that address
    # could not be discovered (dxe_qnap_ensure_tailnet_addr above), in which
    # case fall back to 127.0.0.1 so the rest of the spike still runs; step 7
    # then reports FAIL (there is nothing tailnet-reachable to verify).
    local publish_addr publish_detail
    if [ -n "$DXE_QNAP_TAILNET_ADDR" ]; then
        publish_addr="$DXE_QNAP_TAILNET_ADDR"
        publish_detail="published to the NAS's Tailscale address only; exposure governed by Tailscale ACLs"
    else
        publish_addr="127.0.0.1"
        publish_detail="Tailscale address not discovered -- fell back to loopback-only publication; step 7 will report FAIL"
    fi
    if [ "$DXE_DRY_RUN" = 1 ]; then
        dxe_qnap_docker_run run -d \
            --name "$(dxe_spike_name container)" \
            --label "$DXE_SPIKE_LABEL" \
            -v "$(dxe_spike_name nix):/nix" \
            -p "$publish_addr:2222:2222" \
            "$(dxe_spike_name image):phase0" \
            /bin/sh -c "$(dxe_spike_listener_command)"
    else
        # ssh concatenates every trailing argument after the destination
        # host with a single space and hands the joined string to the
        # remote login shell to parse (see dxe_qnap_ssh_raw and friends
        # above) -- fine when every docker argument is a plain token, but
        # this step's final argument is itself a POSIX-sh if/then/fi
        # script full of spaces and shell metacharacters. Passed as one of
        # several trailing ssh arguments (dxe_qnap_docker_run's usual
        # shape, still used for the dry-run preview above), that quoting
        # is destroyed the instant ssh rejoins the argv, and the remote
        # shell re-parses "then"/"elif"/"fi" as bare words with no
        # enclosing "if" -- exactly the "sh: -c: line 0: syntax error near
        # unexpected token 'then'" the first real run hit. Fix: build the
        # whole remote docker invocation as ONE already-quoted string with
        # dxe_argv_desc (the same printf %q helper every dry-run preview
        # in this file already trusts to round-trip an argv -- see its own
        # comment) and hand ssh that single string as its only trailing
        # argument, so there is nothing left for ssh's own rejoin step to
        # break.
        local ssh_opts=() ssh_opt remote_cmd
        while IFS= read -r ssh_opt; do ssh_opts+=("$ssh_opt"); done <<<"$(dxe_qnap_ssh_opts)"
        remote_cmd="$(dxe_argv_desc "$(dxe_qnap_docker_bin)" run -d \
            --name "$(dxe_spike_name container)" \
            --label "$DXE_SPIKE_LABEL" \
            -v "$(dxe_spike_name nix):/nix" \
            -p "$publish_addr:2222:2222" \
            "$(dxe_spike_name image):phase0" \
            /bin/sh -c "$(dxe_spike_listener_command)")"
        printf '+ ssh %s %s\n' "$(dxe_qnap_host)" "$remote_cmd" >&2
        status=0
        ssh "${ssh_opts[@]}" "$(dxe_qnap_host)" "$remote_cmd" || status=$?
        step_verdict 5 "$status" "container $(dxe_spike_name container) ($publish_detail)"
    fi

    step_header 6 "Stream a small tar payload through docker exec -i and verify sha256"
    if [ "$DXE_DRY_RUN" = 1 ]; then
        dxe_maybe_run tar -cf - -C /tmp payload.txt
        dxe_qnap_docker_run exec -i "$(dxe_spike_name container)" tar -xf - -C /tmp
        dxe_qnap_docker_run exec "$(dxe_spike_name container)" sh -c 'sha256sum /tmp/payload.txt'
    else
        local payload_dir local_sha remote_sha stream_status=0 remote_cmd
        local ssh_opts=() ssh_opt
        while IFS= read -r ssh_opt; do ssh_opts+=("$ssh_opt"); done <<<"$(dxe_qnap_ssh_opts)"
        payload_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-spike-payload.XXXXXX")"
        printf 'dxe phase0 spike payload %s\n' "$(date -u +%s)" >"$payload_dir/payload.txt"
        local_sha="$(shasum -a 256 "$payload_dir/payload.txt" 2>/dev/null | awk '{print $1}')"
        [ -n "$local_sha" ] || local_sha="$(sha256sum "$payload_dir/payload.txt" | awk '{print $1}')"
        printf '+ tar -C %s -cf - payload.txt | ssh %s %s exec -i %s tar -xf - -C /tmp\n' \
            "$payload_dir" "$(dxe_qnap_host)" "$(dxe_qnap_docker_bin)" "$(dxe_spike_name container)" >&2
        tar -C "$payload_dir" -cf - payload.txt \
            | ssh "${ssh_opts[@]}" "$(dxe_qnap_host)" "$(dxe_qnap_docker_bin)" exec -i "$(dxe_spike_name container)" tar -xf - -C /tmp \
            || stream_status=$?
        # Same class of bug as step 5, just silent instead of a hard
        # syntax error: this "-c" argument is one of several trailing ssh
        # arguments (docker_bin, exec, container name, sh, -c, script), so
        # ssh's own concatenate-then-reparse loses its quoting -- the
        # remote sh -c ends up running bare "sha256sum" (no file operand,
        # reading stdin instead of /tmp/payload.txt) with "/tmp/payload.txt"
        # and the rest silently dropped or reordered, corrupting this
        # step's own verdict instead of announcing itself. Same fix as
        # step 5: build the whole remote invocation as ONE already-quoted
        # string with dxe_argv_desc and hand ssh that single string as its
        # only trailing argument.
        remote_cmd="$(dxe_argv_desc "$(dxe_qnap_docker_bin)" exec "$(dxe_spike_name container)" sh -c 'sha256sum /tmp/payload.txt 2>/dev/null || shasum -a 256 /tmp/payload.txt')"
        printf '+ ssh %s %s\n' "$(dxe_qnap_host)" "$remote_cmd" >&2
        remote_sha="$(ssh "${ssh_opts[@]}" "$(dxe_qnap_host)" "$remote_cmd" 2>/dev/null | awk '{print $1}')"
        rm -rf "$payload_dir"
        if [ "$stream_status" -eq 0 ] && [ -n "$remote_sha" ] && [ "$remote_sha" = "$local_sha" ]; then
            step_verdict 6 0 "sha256 matched ($local_sha)"
        else
            step_verdict 6 1 "sha256 mismatch or stream failure (local=$local_sha remote=$remote_sha)"
        fi
    fi

    step_header 7 "Bind guest port 2222 to the NAS's Tailscale address only and verify"
    # DQ5 (amended 2026-09-26): the real first spike run confirmed loopback
    # binding but then found "ssh -W"/ProxyJump through the NAS
    # "administratively prohibited" -- the NAS's sshd carries QTS's default
    # "AllowTcpForwarding no", and QTS regenerates its sshd config, so a
    # persistent local override would be fragile. A BusyBox `nc`
    # exec-channel relay was proven possible and considered, but rejected in
    # favour of publishing directly to the NAS's Tailscale address (step 5)
    # and having the controller connect there directly -- no jump host, no
    # forwarding, exposure governed entirely by Tailscale ACLs. There is
    # still no sshd in the spike container to reach via a normal ssh
    # connection (see the comment on dxe_spike_listener_command above), so
    # this step proves reachability with a plain TCP connect from the
    # controller instead. The host-side published port exists (and so
    # ss -ltn above already sees it LISTEN-ing) the instant the container
    # starts, regardless of whether the nix-fetched listener inside has
    # bound it yet -- confirmed on the real NAS: a refused connect there
    # looked identical to "will never listen", and only a bounded retry can
    # tell "still starting" apart from "never will" (see
    # dxe_spike_listener_command's comment: the nix shell fetch alone can
    # take a minute or more). So the direct connect is polled, not tried
    # once, up to DXE_QNAP_LISTENER_WAIT_SECONDS (default 180) every 5s.
    if [ "$DXE_DRY_RUN" = 1 ]; then
        # dxe_maybe_run is a pure preview here (DXE_DRY_RUN=1 always returns
        # without executing) against the placeholder address
        # dxe_qnap_ensure_tailnet_addr set above.
        printf 'Step 7 will poll the direct connect up to DXE_QNAP_LISTENER_WAIT_SECONDS=%ss (default 180; 5s cadence) before declaring FAIL, since the listener now starts asynchronously; the commands below are one such attempt:\n' "${DXE_QNAP_LISTENER_WAIT_SECONDS:-180}"
        dxe_maybe_run nc -z -w 5 "$DXE_QNAP_TAILNET_ADDR" 2222
        dxe_maybe_run curl -s --http0.9 --max-time 5 "http://$DXE_QNAP_TAILNET_ADDR:2222/"
    elif [ -z "$DXE_QNAP_TAILNET_ADDR" ]; then
        step_verdict 7 1 "the NAS's Tailscale address could not be discovered (see step 5); nothing to verify"
    else
        local ss_output tailnet_only=1 ss_line
        ss_output="$(dxe_qnap_ssh_capture 'ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null')"
        case "$ss_output" in *"$DXE_QNAP_TAILNET_ADDR:2222"*) ;; *) tailnet_only=0 ;; esac
        # Every LISTEN line naming :2222 must be the discovered tailnet
        # address -- not 0.0.0.0:2222, not [::]:2222, not any other address.
        while IFS= read -r ss_line; do
            case "$ss_line" in
                *:2222*)
                    case "$ss_line" in
                        *"$DXE_QNAP_TAILNET_ADDR:2222"*) ;;
                        *) tailnet_only=0 ;;
                    esac
                    ;;
            esac
        done <<<"$ss_output"
        if [ "$tailnet_only" -eq 1 ]; then
            echo "Step 7: ss -ltn confirms 2222 is bound to the NAS's Tailscale address only (address recorded in the private report only)."
            # Poll the direct connect instead of trying it once: the
            # listener inside the container starts asynchronously (it is
            # fetched through nix on first use -- see
            # dxe_spike_listener_command), so an immediate "connection
            # refused" here does not yet mean the listener will never come
            # up. Bounded so a genuinely absent listener (the last-resort
            # "exec sleep infinity" fallback) still reports FAIL rather than
            # hanging forever.
            local wait_total="${DXE_QNAP_LISTENER_WAIT_SECONDS:-180}" wait_interval=5 waited=0
            local connect_rc=1 pong_ok=0 fetch_out=""
            while :; do
                if command -v nc >/dev/null 2>&1; then
                    connect_rc=0; nc -z -w 5 "$DXE_QNAP_TAILNET_ADDR" 2222 || connect_rc=$?
                elif ( exec 3<>"/dev/tcp/$DXE_QNAP_TAILNET_ADDR/2222" ) 2>/dev/null; then
                    connect_rc=0
                else
                    connect_rc=1
                fi
                [ "$connect_rc" -eq 0 ] && break
                [ "$waited" -ge "$wait_total" ] && break
                sleep "$wait_interval"
                waited=$((waited + wait_interval))
            done
            if [ "$connect_rc" -eq 0 ]; then
                if command -v curl >/dev/null 2>&1; then
                    fetch_out="$(curl -s --http0.9 --max-time 5 "http://$DXE_QNAP_TAILNET_ADDR:2222/" 2>/dev/null || true)"
                else
                    fetch_out="$( { exec 3<>"/dev/tcp/$DXE_QNAP_TAILNET_ADDR/2222"; cat <&3; } 2>/dev/null || true )"
                fi
                case "$fetch_out" in *PONG*) pong_ok=1 ;; esac
            fi
            if [ "$connect_rc" -eq 0 ] && [ "$pong_ok" -eq 1 ]; then
                step_verdict 7 0 "bound to the tailnet address only, reachable directly from the controller after ${waited}s, PONG confirmed"
            elif [ "$connect_rc" -eq 0 ]; then
                step_verdict 7 1 "bound to the tailnet address only, direct TCP connect succeeded after ${waited}s but PONG not confirmed"
            else
                step_verdict 7 1 "no listener available in the image (direct connect never succeeded after polling for ${waited}s, up to DXE_QNAP_LISTENER_WAIT_SECONDS=${wait_total}s; last rc=$connect_rc)"
            fi
        else
            step_verdict 7 1 "bound-to-tailnet-address-only NOT confirmed by ss -ltn"
        fi
    fi

    step_header 8 "Guarded restarts (container, Container Station, NAS)"
    # 8a is gated independently of 8b/8c: the container it restarts is
    # "$(dxe_spike_name container)" -- the same name AND dxe.role=spike
    # label step 5 gave it at creation, so restarting it by that exact
    # name inherently restarts only the one resource that carries both.
    if [ "$DXE_WITH_CONTAINER_RESTART" = 1 ]; then
        status=0; dxe_qnap_docker_run restart "$(dxe_spike_name container)" || status=$?
        step_verdict 8a "$status" "container restart"
    else
        step_skip 8a "container restart skipped (needs maintenance window; rerun with --with-container-restart)"
    fi
    if [ "$DXE_WITH_SERVICE_RESTART" = 1 ]; then
        status=0; dxe_qnap_ssh_exec "$(dxe_spike_container_station_restart_cmd)" || status=$?
        step_verdict 8b "$status" "Container Station restart: $(dxe_spike_container_station_restart_cmd)"
    else
        step_skip 8b "Container Station restart skipped (needs maintenance window; rerun with --with-service-restart)"
    fi
    if [ "$DXE_WITH_NAS_REBOOT" = 1 ]; then
        status=0; dxe_qnap_ssh_exec reboot || status=$?
        step_verdict 8c "$status" "NAS reboot (ssh reboot)"
    else
        step_skip 8c "NAS reboot skipped (needs an agreed maintenance window; rerun with --with-nas-reboot)"
    fi

    step_header 9 "Delete only labelled spike resources; prove nothing else changed"
    dxe_spike_cleanup || true
    if [ "$DXE_DRY_RUN" != 1 ]; then
        local after
        after="$(dxe_spike_snapshot)"
        dxe_spike_diff_snapshot "$before" "$after" || true
    fi
    return "$STEP_FAILED"
}

# --- Entry point ------------------------------------------------------------

if [ "$DXE_DRY_RUN" != 1 ]; then
    dxe_qnap_require_reachable || exit 1
fi

echo "QNAP Phase 0 spike -- host alias: $(dxe_qnap_host)$( [ "$DXE_DRY_RUN" = 1 ] && printf ' (DRY RUN: nothing will connect)' || true)"

dxe_qnap_ensure_docker_bin || exit 1
dxe_qnap_ensure_tailnet_addr

if [ "$DXE_DRY_RUN" = 1 ]; then
    # Streams directly to the terminal as it runs; nothing is written to
    # disk under --dry-run (nothing was connected, so there is nothing to
    # report -- matches phase0-inventory.sh's own --dry-run behavior).
    if [ "$DXE_CLEANUP" = 1 ]; then
        step_header cleanup "Remove only dxe.role=spike-labelled leftovers"
        dxe_spike_cleanup || true
    else
        dxe_spike_run_steps || true
    fi
else
    mkdir -p "$(dirname "$REPORT_PATH")" "$(dirname "$SUMMARY_PATH")"
    # Captured (not streamed) so STEP_FAILED can be recovered from the
    # subshell command substitution creates via its own exit status --
    # a piped "| tee" would run the same subshell without exposing that
    # status cleanly, and everything below still needs it. set +e/-e
    # brackets the assignment itself: under this script's own set -e, a
    # failing "var=$(cmd)" assignment is fatal on the spot (same class of
    # bug the "status=0; cmd || status=$?" idiom elsewhere in this file
    # exists to avoid) -- "|| true" on the assignment would dodge that abort
    # but also discard the real status before "$?" could ever read it.
    set +e
    if [ "$DXE_CLEANUP" = 1 ]; then
        full_output="$( { step_header cleanup "Remove only dxe.role=spike-labelled leftovers"; dxe_spike_cleanup; } 2>&1 )"
    else
        full_output="$(dxe_spike_run_steps 2>&1)"
    fi
    STEP_FAILED=$?
    set -e
    printf '%s\n' "$full_output"

    full_output="$(printf '%s\n' "$full_output" | dxe_redact_secrets)"

    {
        dxe_qnap_report_header "$BASE_DIR" "QNAP Phase 0 spike (FULL -- private, never commit)"
        printf '%s\n' "$full_output"
    } >"$REPORT_PATH.tmp.$$" || { rm -f "$REPORT_PATH.tmp.$$"; exit 1; }
    mv "$REPORT_PATH.tmp.$$" "$REPORT_PATH"

    {
        dxe_qnap_report_header "$BASE_DIR" "QNAP Phase 0 spike (summary)"
        echo "Whitelisted fields only: step verdicts and the fact that every"
        echo "resource uses the \"$DXE_SPIKE_PREFIX<role>\" name prefix -- no"
        echo "hostnames, paths, digests, or account names. Private by default"
        echo "(see tests/qnap/README.md)."
        echo
        printf '%s\n' "$full_output" \
            | grep -E '^Step [A-Za-z0-9-]+: (PASS|FAIL|SKIP)' \
            | sed -E 's/^(Step [A-Za-z0-9-]+: (PASS|FAIL|SKIP)).*/\1/' \
            || echo "(no step verdicts recorded)"
    } >"$SUMMARY_PATH.tmp.$$" || { rm -f "$SUMMARY_PATH.tmp.$$"; exit 1; }
    mv "$SUMMARY_PATH.tmp.$$" "$SUMMARY_PATH"

    echo "Full report (private, do not commit): $REPORT_PATH" >&2
    echo "Summary (private, do not commit): $SUMMARY_PATH" >&2
fi

echo
if [ "$STEP_FAILED" -eq 0 ]; then
    echo "QNAP Phase 0 spike: all reported steps PASSED (or were dry-run previewed / intentionally skipped)."
else
    echo "QNAP Phase 0 spike: one or more steps FAILED. See above." >&2
fi
exit "$STEP_FAILED"
