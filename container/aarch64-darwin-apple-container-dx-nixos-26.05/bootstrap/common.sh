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
    nix profile install "$bootstrap_root#bootstrap-essentials" --no-update-lock-file "${DX_NIX_FEAT_OPTS[@]}" "${DX_NIX_NET_OPTS[@]}"
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
