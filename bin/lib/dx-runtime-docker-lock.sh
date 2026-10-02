#!/bin/bash
# Docker-over-SSH remote per-profile lock (item 6): acquire/audit/release,
# called directly by bin/dx-lock and (read-only) bin/dx-status -- not part
# of the dx_runtime_<op> contract, since Apple's runtime is always local and
# has no concurrent-invocation problem to solve. One of the four files
# bin/lib/dx-runtime-docker.sh sources (see docs/refactor/decisions/
# D8-docker-adapter-history.md for the split's history); that file remains
# the facade every caller sources and dispatches through, and sources
# bin/lib/dx-runtime-docker-identity.sh and
# bin/lib/dx-runtime-docker-lifecycle.sh before this file, so
# dx_runtime_docker_profile_id and dx_runtime_docker_label_flags are already
# defined by the time any function below actually runs.
#
# Safe to source: defines functions and constants only, no I/O, no command
# dispatch, no shell options, at import time (same contract as every other
# bin/lib/*.sh file).

# --- Remote per-profile lock (item 6) --------------------------------------
#
# Not part of the dx_runtime_<op> contract (Apple's runtime is
# always local -- one controller, one daemon, no concurrent-invocation
# problem to solve -- so it has no lock concept to dispatch to); called
# directly by bin/dx-lock. Docker's one atomic "create, fail if already
# present" primitive is container-NAME uniqueness (`docker volume create`
# is idempotent and does NOT fail if the volume already exists, so it
# cannot serve as an exclusion primitive; `docker create --name X` fails
# atomically with a "Conflict... name is already in use" error if X
# exists) -- so the lock itself is a labelled, never-started container
# named "dxe-lock-<profile-id>", using the Containerfile's pinned base image
# reference (dx_runtime_docker_base_image_ref, the same reference
# dx_runtime_docker_image_build pulls) as its (never run) base image. Never
# $DX_IMAGE: that is a local-only tag the profile's own dx-create-image
# makes, so it does not exist -- and cannot be pulled -- on the remote
# daemon for a never-created profile, and dx acquires this lock BEFORE
# dx-create-image (WP6.5). The owner label identifies more than a
# PID alone (docs/refactor/constraints.md: "Locks and execution leases
# identify an owner by more than PID alone"): controller hostname, this
# process's PID, a random component, and a UTC timestamp.

dx_runtime_docker_lock_name() {
    printf 'dxe-lock-%s' "$(dx_runtime_docker_profile_id)"
}

dx_runtime_docker_lock_owner_token() {
    local host
    host="$(hostname 2>/dev/null)"
    [ -n "$host" ] || host=unknown-host
    printf '%s:%s:%s:%s' "$host" "$$" "$RANDOM" "$(date -u +%Y%m%dT%H%M%SZ)"
}

# Acquires the lock (create-if-absent, fail-if-held) and prints the owner
# token it just claimed, so a caller that wants to release only its own
# acquisition can pass that exact token back to dx_runtime_docker_lock_release.

dx_runtime_docker_lock_acquire() {
    local lock_name owner base_ref
    [ -n "${DX_CONTEXT_DIR:-}" ] || {
        echo "Error: DX_CONTEXT_DIR is not set; the remote lock needs the Containerfile's pinned base image reference." >&2
        return 1
    }
    base_ref="$(dx_runtime_docker_base_image_ref "$DX_CONTEXT_DIR")" || return 1
    lock_name="$(dx_runtime_docker_lock_name)"
    owner="$(dx_runtime_docker_lock_owner_token)"
    # Reuses the same shared label helper containers and volumes already
    # call, so the lock picks up io.dxe.system (and any future addition)
    # without duplicating the other four labels by hand.
    dx_runtime_docker_label_flags lock
    dx_runtime_docker_cli create --name "$lock_name" \
        "${DXE_RUNTIME_DOCKER_LABEL_ARGV[@]}" \
        --label "io.dxe.owner=$owner" \
        "$base_ref" >/dev/null 2>&1 || {
        echo "Error: could not acquire the remote lock '$lock_name' (it may already be held -- run 'dx-lock status' to see by whom)." >&2
        # Astra F4 / WP6.5: this atomic create-fails-if-present primitive
        # can never distinguish a live owner from an interrupted one (the
        # process that minted the owner token below may be long gone), so
        # a caller (bin/lib/dx-container.sh's dx_lifecycle_lock_acquire,
        # via the neutral dx_runtime_lock_acquire dispatch in
        # bin/lib/dx-runtime.sh) never guesses either way -- it always
        # prints the current owner/creation-time metadata plus the remedy
        # here, in this file (the one place already exempted from
        # tests/test_runtime_boundary_audit.sh's boundary scan), so an
        # operator can confirm staleness by other means before forcing it.
        dx_runtime_docker_lock_audit >&2 || true
        echo "Review the owner above; confirm by other means whether it is genuinely stale, then either wait for it to finish or clear it with 'dx-lock unlock --force' (see 'dx-lock status')." >&2
        return 1
    }
    printf '%s' "$owner"
}

# Prints "held by <owner> since <created>" or "not held" -- always
# succeeds (a missing lock is a normal, reportable state, not an error).
# This is the read-only half bin/dx-status exposes.

dx_runtime_docker_lock_audit() {
    local lock_name fields owner created
    lock_name="$(dx_runtime_docker_lock_name)"
    fields="$(dx_runtime_docker_cli container inspect --format '{{index .Config.Labels "io.dxe.owner"}}|{{.Created}}' "$lock_name" 2>/dev/null)" || {
        printf 'not held\n'
        return 0
    }
    fields="$(printf '%s\n' "$fields" | tail -n1 | tr -d '\r')"
    IFS='|' read -r owner created <<<"$fields"
    printf 'held by %s since %s\n' "${owner:-<unknown>}" "${created:-<unknown>}"
}

# Explicit unlock (bin/dx-lock's "unlock --force"). Verifies profile/role
# labels first (DQ6: a collision refuses, never an adoption); when
# expected_owner is non-empty, ALSO refuses unless the current owner label
# matches exactly (a caller that acquired the lock itself, releasing only
# its own acquisition). Elapsed time alone is never checked here or
# anywhere in this file -- the audit above is the only way to decide
# staleness, and that decision is the operator's, made outside this
# function, before calling it with --force.

dx_runtime_docker_lock_release() {
    local expected_owner="$1" lock_name fields managed profile role owner
    lock_name="$(dx_runtime_docker_lock_name)"
    fields="$(dx_runtime_docker_cli container inspect --format '{{index .Config.Labels "io.dxe.managed"}}|{{index .Config.Labels "io.dxe.profile"}}|{{index .Config.Labels "io.dxe.role"}}|{{index .Config.Labels "io.dxe.owner"}}' "$lock_name" 2>/dev/null)" || {
        echo "Error: no lock '$lock_name' to release." >&2
        return 1
    }
    fields="$(printf '%s\n' "$fields" | tail -n1 | tr -d '\r')"
    IFS='|' read -r managed profile role owner <<<"$fields"
    if [ "$managed" != true ] || [ "$profile" != "$(dx_runtime_docker_profile_id)" ] || [ "$role" != lock ]; then
        echo "Error: refusing to release '$lock_name': it exists but is not labelled as this profile's lock (qnap-dxe-plan.md DQ6 -- a collision, not an adoption candidate)." >&2
        return 1
    fi
    if [ -n "$expected_owner" ] && [ "$owner" != "$expected_owner" ]; then
        echo "Error: refusing to release '$lock_name': it is held by a different owner ($owner), not the one requesting release ($expected_owner)." >&2
        return 1
    fi
    dx_runtime_docker_cli rm "$lock_name" >/dev/null
}

# dx_runtime_lock_path's docker-ssh implementation (bin/lib/dx-runtime.sh's
# dispatch). The remote lock container has no local path to expose -- its
# "owner token" is the minted host:pid:random:timestamp string
# dx_runtime_docker_lock_acquire already prints, which a caller reads
# directly rather than ever dispatching here. Exists only so the dispatch
# has a docker-ssh target to resolve to at all; always fails closed.
dx_runtime_docker_lock_path() {
    echo "Error: dx_runtime_docker_lock_path: docker-ssh's lock lives in the remote lock container, not a local directory." >&2
    return 1
}

