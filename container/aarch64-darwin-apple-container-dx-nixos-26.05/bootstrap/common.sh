#!/usr/bin/env bash
# Source-only bootstrap common phase. Safe to source.

# Keep installation and repair of the early bootstrap toolchain in lockstep.
# A command merely being on PATH is not proof that its store closure survived a
# previous interrupted image import.
DX_NIX_FEAT_OPTS=(--extra-experimental-features "nix-command flakes")
DX_NIX_NET_OPTS=(--option connect-timeout 15 --option stalled-download-timeout 60 --option download-attempts 2)

# Marker paths are durable state and must be either absent or a regular file.
# In particular, GNU mv treats a directory destination as a request to move
# the temporary file inside it, which can make a publication appear to
# succeed while leaving the marker absent. Reject symlinks and other file
# types before any migration or marker read can trust them.
dx_validate_atomic_marker_path() {
    local marker="$1"
    local description="${2:-marker}"
    if [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
        echo "Error: refusing to use $description; expected an absent or regular-file path: $marker" >&2
        return 1
    fi
}

# Replace a marker atomically. Production bootstrap runs on GNU/Linux, where
# -T prevents a destination directory from ever being treated as a container
# for the temporary file. Sourceable Darwin tests use the portable fallback;
# callers have already rejected directory/symlink destinations above.
dx_publish_atomic_marker() {
    local temporary="$1"
    local marker="$2"
    local description="${3:-marker}"
    dx_validate_atomic_marker_path "$marker" "$description" || return 1
    case "$(uname -s 2>/dev/null || true)" in
        Linux) mv -Tf "$temporary" "$marker" ;;
        *) mv -f "$temporary" "$marker" ;;
    esac
}

# Publishes the completion marker the host healthcheck probe requires
# alongside a live, identity-matched lease before it reports the guest
# healthy (Astra F7; bin/lib/dx-ssh-common.sh's dx_bootstrap_health_command).
# Keyed by pid.start -- exactly the pair the probe independently revalidates
# against live /proc state before it will even look for this file -- so a
# reused pid from an earlier, unrelated boot can never satisfy today's check
# by coincidence. $1 generation, $2 boot id, $3 start time, $4 pid: the SAME
# four positional values the launcher passed to bootstrap_main (it computed
# them once, before exec; this never re-derives them). A no-op, not a
# failure, when there is no lease identity to publish against (the
# unsignalled-fallback boot in the launcher's own else branch never writes a
# lease either, so the probe can never match it regardless). Best-effort on
# a real failure: losing this marker only keeps the healthcheck unhealthy,
# never sshd itself, so bootstrap_main does not abort the boot over it.
dx_bootstrap_publish_ready_marker() {
    local generation="$1" boot_id="$2" start="$3" pid="$4"
    local root="${DX_BOOTSTRAP_PATH:-}"
    [ -n "$root" ] && [ -n "$pid" ] && [ -n "$start" ] || return 0
    local dir="$root/.locks/ready"
    mkdir -p "$dir" 2>/dev/null || return 1
    local marker="$dir/$pid.$start"
    local tmp="$dir/.ready.$pid.$start.tmp"
    printf '%s\t%s\t%s\t%s\n' "$generation" "$boot_id" "$pid" "$start" > "$tmp" || { rm -f "$tmp"; return 1; }
    dx_publish_atomic_marker "$tmp" "$marker" "bootstrap readiness marker"
}

dx_pipeline_succeeded() {
    local status
    for status in "$@"; do
        [ "$status" -eq 0 ] || return 1
    done
}

essentials_profile_path() {
    local root="${DX_ESSENTIALS_ROOT:-}"
    local joined="" candidate resolved
    for candidate in \
        "$root/nix/var/nix/profiles/per-user/root/profile/bin" \
        "$root/root/.local/state/nix/profiles/profile/bin" \
        "$root/root/.nix-profile/bin"; do
        resolved="$(readlink -f "$candidate" 2>/dev/null)" || continue
        [ -d "$resolved" ] || continue
        joined="${joined:+$joined:}$resolved"
    done
    printf '%s\n' "$joined"
}

essentials_profile_store_path() {
    local root="${DX_ESSENTIALS_ROOT:-}"
    local candidate resolved
    for candidate in \
        "$root/nix/var/nix/profiles/per-user/root/profile" \
        "$root/root/.local/state/nix/profiles/profile" \
        "$root/root/.nix-profile"; do
        resolved="$(readlink -f "$candidate" 2>/dev/null)" || continue
        [ -d "$resolved" ] || continue
        printf '%s\n' "$resolved"
        return 0
    done
    return 1
}

install_essential_packages() {
    local bootstrap_root="${DX_BOOTSTRAP_ROOT:-/guest-bootstrap}"
    # Name the target profile explicitly. An unqualified `nix profile install`
    # resolves the *default* profile via $HOME/.nix-profile, and whether that
    # lands on /nix/var/nix/profiles/per-user/root/profile (a fresh
    # manifest.json) or /nix/var/nix/profiles/default (the upstream
    # nixos/nix image's legacy manifest.nix environment, already populated
    # with gzip/gnutar/coreutils-full and the like) depends on whether HOME
    # is set for the calling process -- which differs by runtime (Docker
    # injects HOME=/root at the container-process level; Apple leaves HOME
    # unset for PID 1) and is not a property of this install itself. Pointing
    # at the per-user root profile -- exactly what essentials_profile_store_path
    # already checks first -- makes the target the same on every runtime.
    nix profile install --profile /nix/var/nix/profiles/per-user/root/profile "$bootstrap_root#bootstrap-essentials" --no-update-lock-file "${DX_NIX_FEAT_OPTS[@]}" "${DX_NIX_NET_OPTS[@]}"
}

# The bootstrap essentials closure is bounded, so verify its content as well
# as registration on every boot.  `--no-contents` trusts a registered but
# truncated executable, which is precisely the SIGBUS failure this guards.
essentials_store_valid() {
    local profile
    profile="$(essentials_profile_store_path)" || return 1
    run_as_dx "nix --extra-experimental-features 'nix-command flakes' store verify --recursive --no-trust '$profile'" >/dev/null 2>&1
}

repair_store_closure() {
    local path="$1"
    [ -n "$path" ] || return 1
    run_as_dx "nix --extra-experimental-features 'nix-command flakes' --option connect-timeout 15 --option stalled-download-timeout 60 --option download-attempts 2 store verify --recursive --repair --no-trust '$path'"
}

# store-trust-plan.md Problem 2 ("after the remount, no binary from the
# persistent store may be trusted to prove that same trust root sound"),
# Design 2-3 (docs/refactor/store-trust-design.md section 2). Runs
# immediately after the volume is in its final place (the remount, in
# apple-image mode; container start, in direct-volume mode -- bootstrap_main
# calls this at the same shared call site either way, so it means the same
# thing in both), before nix_restore_image_default_profile touches any of
# its own named tools (readlink, mkdir, mktemp, rm, ln, chown, mv) and
# before ensure_essentials_valid -- the only content-level verifier in this
# boot -- gets a chance to run at all.
#
# A bare `command -v` proves a name resolves, not that the binary is
# intact: a truncated/corrupted executable can still resolve via PATH and
# then fail on exec (the same SIGBUS-class failure essentials_store_valid's
# own comment above describes for a *later* closure member). Actually
# invoking each one with a harmless, read-only, universally-supported
# `--version` catches that class deterministically, right here, instead of
# it surfacing later as either a misdiagnosed error message or total
# silence (both observed in docs/refactor/store-trust-design.md section
# 2.1's characterisation, against this exact unmodified function set).
#
# Deliberate fail-fast, per Q6: no independent repair is attempted for this
# class (unlike ensure_essentials_valid's own bounded content repair for its
# closure) -- every failure here names the broken tool and points at the
# volume-scoped recovery path.
verify_remount_prerequisites() {
    local tool resolved
    for tool in readlink mkdir mktemp rm ln chown mv setpriv bash nix; do
        resolved="$(command -v "$tool" 2>/dev/null)" || {
            echo "Error: '$tool' is missing from PATH after the Nix volume reached its final place; the persistent store cannot be trusted before its own verifier runs. Recovery: ./bin/dx-destroy-container (or ./bin/dx-destroy) if a container still exists, then ./bin/dx-reset-nix-volume, then ./bin/dx to rebuild /nix from the image." >&2
            return 1
        }
        if ! "$resolved" --version >/dev/null 2>&1; then
            echo "Error: '$tool' ($resolved) is present but fails to execute after the Nix volume reached its final place; the persistent store cannot be trusted before its own verifier runs. Recovery: ./bin/dx-destroy-container (or ./bin/dx-destroy) if a container still exists, then ./bin/dx-reset-nix-volume, then ./bin/dx to rebuild /nix from the image." >&2
            return 1
        fi
    done
    if ! run_as_dx true; then
        echo "Error: run_as_dx cannot execute a trivial command after the Nix volume reached its final place (the setpriv/env/bash -l boundary ensure_essentials_valid itself depends on); the persistent store cannot be trusted before its own verifier runs. Recovery: ./bin/dx-destroy-container (or ./bin/dx-destroy) if a container still exists, then ./bin/dx-reset-nix-volume, then ./bin/dx to rebuild /nix from the image." >&2
        return 1
    fi
}

ensure_essentials_valid() {
    local profile
    local phase_started=$SECONDS
    profile="$(essentials_profile_store_path)" || {
        echo "Error: bootstrap essentials profile is unavailable after the /nix volume remount." >&2
        echo "Bootstrap phase: essentials verification/repair failed after $((SECONDS - phase_started))s." >&2
        return 1
    }
    if essentials_store_valid; then
        echo "Bootstrap essentials closure is registered and present."
        echo "Bootstrap phase: essentials verification/repair completed in $((SECONDS - phase_started))s."
        return 0
    fi

    echo "Bootstrap essentials closure is incomplete after the /nix volume remount; repairing it..." >&2
    repair_store_closure "$profile" || true
    if ! essentials_store_valid; then
        echo "Error: could not repair the bootstrap essentials closure." >&2
        echo "Bootstrap phase: essentials verification/repair failed after $((SECONDS - phase_started))s." >&2
        return 1
    fi
    hash -r 2>/dev/null || true
    local essentials_path
    essentials_path="$(essentials_profile_path)"
    [ -n "$essentials_path" ] && export PATH="$essentials_path:$PATH"
    echo "Bootstrap phase: essentials verification/repair completed in $((SECONDS - phase_started))s."
}

# Do not let a corrupt mmap-exec of ssh-keygen terminate bootstrap before sshd
# starts.  The bounded closure repair is repeated only when key generation
# actually fails, so healthy boots pay one fast registration check above.
generate_host_keys() {
    local attempt rc ssh_keygen_path openssh_path
    for attempt in 1 2 3; do
        if ssh-keygen -A; then
            return 0
        fi
        rc=$?
        echo "Warning: ssh-keygen -A failed (attempt $attempt/3, exit $rc); repairing OpenSSH and retrying." >&2
        ssh_keygen_path="$(readlink -f "$(command -v ssh-keygen)" 2>/dev/null || true)"
        openssh_path="${ssh_keygen_path%/bin/ssh-keygen}"
        [ -n "$openssh_path" ] && repair_store_closure "$openssh_path" || true
        [ -n "$ssh_keygen_path" ] && cat "$ssh_keygen_path" >/dev/null 2>&1 || true
        sleep 1
    done
    echo "Error: ssh-keygen -A failed after bounded repair attempts." >&2
    return 1
}

# 1. Bootstrapping dependencies (Section 2/3)
run_as_dx() {
    local cmd="$1"
    # setpriv --reuid=dx --regid=dx --init-groups bash -l -c "$cmd"
    # Note: bash -l is needed to pick up the profile
    setpriv --reuid=dx --regid=dx --init-groups env HOME=/home/dx USER=dx PATH="/home/dx/.nix-profile/bin:$PATH" bash -l -c "$cmd"
}

run_as_dx_with_timeout() {
    local timeout_seconds="$1"
    shift

    setpriv --reuid=dx --regid=dx --init-groups env HOME=/home/dx USER=dx PATH="/home/dx/.nix-profile/bin:$PATH" \
        timeout --kill-after=30s "${timeout_seconds}s" "$@"
}

validate_positive_integer() {
    local name="$1"
    local value="$2"

    case "$value" in
        ''|*[!0-9]*|0)
            echo "Error: $name must be a positive integer, got '$value'." >&2
            return 1
            ;;
    esac
}
