#!/bin/bash
# Shared helpers for the QNAP Phase 0 scripts (tests/qnap/phase0-inventory.sh,
# tests/qnap/phase0-spike.sh). Safe to source: no shell options, no output,
# no network/process side effects merely from being sourced.
#
# Design note (per qnap-dxe-plan.md DQ1/DQ5 and the repository's own
# conventions): this is deliberately small and mirrors existing idioms rather
# than inventing a new framework --
#   - the newline-per-token option stream + "while IFS= read -r" array-build
#     idiom is exactly bin/lib/dx-ssh-common.sh's dx_ssh_common_options()
#     (Bash 3.2 cannot return an array from a function);
#   - dxe_qnap_ssh_* never sets -o StrictHostKeyChecking=no or a synthetic
#     UserKnownHostsFile the way the local guest transport does: the QNAP
#     management host is a stable Tailscale-adjacent target whose host key
#     DQ5/the plan invariants require verifying normally, and DQ1 says the
#     ssh_config alias -- not this script -- owns identity file and host-key
#     policy;
#   - the tar-over-exec streaming in phase0-spike.sh's step 6 is the same
#     shape as bin/dx-put/bin/dx-get, just piped into a plain ssh remote
#     command instead of the local "container" CLI (see dxe_qnap_docker_run
#     below for why this talks to Docker over ssh directly rather than
#     through the local Docker CLI's own "-H ssh://" transport).
#
# Confidentiality note: the real NAS is a production system. Nothing in this
# file, or in anything it prints, may ever hold its Tailscale MagicDNS name,
# tailnet address, storage-pool/dataset names, account name, or any key
# material -- only the ssh_config alias (DXE_QNAP_HOST). Absolute paths
# under the Container Station/Tailscale qpkgs are discovered at runtime over
# ssh and used only as ssh/docker command arguments; they are never the
# only source of a value written into a file this repository tracks (see
# phase0-inventory.sh/phase0-spike.sh's --summary output, and
# tests/test_section1_secrets.sh's leak scan, which is the enforcement).

# The ssh_config alias identifying the QNAP. DQ1: the alias owns username,
# identity file, MagicDNS name, and host-key policy; this script only ever
# stores/consumes the alias name, never raw option text.
dxe_qnap_host() { printf '%s' "${DXE_QNAP_HOST:-qnap-dxe}"; }

# Non-interactive SSH options shared by every QNAP management connection:
# never prompt, never read a tty, fail fast and quietly on a dead endpoint.
# Deliberately does NOT disable host-key checking (contrast
# bin/lib/dx-ssh-common.sh's dx_ssh_common_options(), which talks to the
# disposable local guest instead of the one stable management host).
dxe_qnap_ssh_opts() {
    printf '%s\n' \
        -o BatchMode=yes \
        -o ConnectTimeout="${DXE_QNAP_SSH_CONNECT_TIMEOUT:-10}" \
        -o LogLevel=ERROR
}

# The Docker CLI's command-scoped SSH endpoint (DQ1): "ssh://<alias>", never
# a persistent global `docker context`. Used only by phase0-inventory.sh's
# explicit "Mac-side control plane" check, which deliberately tests this
# naive mechanism to document whether it works on the real NAS -- it is
# NOT how phase0-spike.sh talks to Docker; see dxe_qnap_docker_run below.
dxe_qnap_docker_host_arg() { printf 'ssh://%s' "$(dxe_qnap_host)"; }

# The naive mechanism itself: the LOCAL Docker CLI's own ssh transport.
# Deliberately distinct from dxe_qnap_docker_run/_capture below (the
# mechanism phase0-spike.sh actually uses) -- conflating the two would
# silently stop testing what this check exists to test.
dxe_qnap_docker_naive_ssh_capture() { dxe_maybe_capture docker -H "$(dxe_qnap_docker_host_arg)" "$@"; }

# Build a human-readable, exactly-reversible description of an argv for
# dry-run preview and command tracing. printf %q is the single source of
# truth for both, so the preview a caller sees in --dry-run is never allowed
# to drift from what a real run would actually execute.
dxe_argv_desc() {
    local desc="" arg first=1
    for arg in "$@"; do
        if [ "$first" -eq 1 ]; then
            first=0
        else
            desc="$desc "
        fi
        desc="$desc$(printf '%q' "$arg")"
    done
    printf '%s' "$desc"
}

# Run (or, under DXE_DRY_RUN=1, only describe) a command whose own stdout
# matters only as a side effect (its exit status is what callers use).
# Never touches the network in dry-run mode: this is the sole gate that
# keeps every docker/ssh invocation in phase0-spike.sh out of dry-run runs.
dxe_maybe_run() {
    local desc
    desc="$(dxe_argv_desc "$@")"
    if [ "${DXE_DRY_RUN:-0}" = 1 ]; then
        printf 'DRY-RUN: %s\n' "$desc" >&2
        return 0
    fi
    printf '+ %s\n' "$desc" >&2
    "$@"
}

# Same gate, spelled differently at call sites that capture stdout via
# "$(...)" and need to parse it. Under DXE_DRY_RUN=1 this only prints the
# description (to stderr, so it can never contaminate the captured value)
# and yields empty output -- callers must treat an empty dry-run capture as
# "unknown, not connected" rather than as a real empty result. Deliberately
# just an alias for dxe_maybe_run (identical dry-run/live behavior; the two
# names exist so a call site can say which it means) rather than a second
# copy of the same gate that could drift out of sync with it.
dxe_maybe_capture() { dxe_maybe_run "$@"; }

# Build the ssh option argv into the caller's own array variable name via
# the newline-per-token idiom (Bash 3.2 has no array-returning functions).
# Usage: local ssh_opts=() opt; while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dxe_qnap_ssh_opts)"
# Encapsulated here once so every ssh call site is identical.
dxe_qnap_ssh_raw() {
    local ssh_opts=() opt
    while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dxe_qnap_ssh_opts)"
    ssh "${ssh_opts[@]}" "$(dxe_qnap_host)" "$@"
}

# Dry-run-aware ssh call whose exit status is what matters (e.g. a guarded
# restart). Never used for the reachability preflight itself, which must
# always be real -- see dxe_qnap_require_reachable below.
dxe_qnap_ssh_exec() {
    local ssh_opts=() opt
    while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dxe_qnap_ssh_opts)"
    dxe_maybe_run ssh "${ssh_opts[@]}" "$(dxe_qnap_host)" "$@"
}

# Dry-run-aware ssh call whose stdout a caller needs.
dxe_qnap_ssh_capture() {
    local ssh_opts=() opt
    while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dxe_qnap_ssh_opts)"
    dxe_maybe_capture ssh "${ssh_opts[@]}" "$(dxe_qnap_host)" "$@"
}

# Fail-closed reachability preflight. Always issues a REAL, non-dry-run ssh
# call (BatchMode, so a dead host/bad key/no tty fails in ConnectTimeout
# seconds rather than hanging or prompting) -- callers must never invoke this
# while DXE_DRY_RUN=1 or it defeats "nothing connects during --dry-run".
dxe_qnap_require_reachable() {
    if ! dxe_qnap_ssh_raw true >/dev/null 2>&1; then
        echo "Error: cannot reach QNAP host alias '$(dxe_qnap_host)' over a non-interactive SSH connection (BatchMode=yes, ConnectTimeout=${DXE_QNAP_SSH_CONNECT_TIMEOUT:-10}s)." >&2
        echo "Check the 'Host $(dxe_qnap_host)' stanza in ~/.ssh/config, that the NAS is powered on, and that it is reachable over Tailscale. See tests/qnap/README.md." >&2
        return 1
    fi
    return 0
}

# --- Discovering the Docker CLI on the NAS's non-interactive PATH --------
#
# Confirmed against the real NAS (a QuTS hero unit): the non-interactive SSH
# PATH does not include the Container Station qpkg's own bin directory, so
# a bare `command -v docker` over ssh finds nothing, and -- because Docker's
# own "-H ssh://" client transport also just runs "docker ..." on whatever
# PATH the remote non-interactive shell resolves -- so does
# `docker -H ssh://<alias> ...` run from the controller. This is exactly
# the case DQ1 anticipates: "If QNAP's non-interactive PATH does not expose
# the Container Station Docker CLI, Phase 0 must identify its stable
# absolute path... invoke a small fixed remote command over SSH in that
# case." phase0-spike.sh therefore never uses the local Docker CLI's
# "-H ssh://" transport at all -- every docker command is run as a plain
# ssh remote command against the discovered absolute path (dxe_qnap_ssh_exec/
# _capture's own transport, just with the docker binary as the remote
# command instead of an inline shell snippet).
#
# The absolute path itself is discovered at runtime (falling back to a glob
# under the Container Station qpkg's own bin directory) and only ever
# crosses as an ssh/docker command-line argument -- it is never the sole
# source of anything written into a file this repository tracks.
DXE_QNAP_DOCKER_BIN_GLOB='/share/*/.qpkg/container-station/bin/docker'

# Same idea for Tailscale: its qpkg is not on the non-interactive PATH
# either. Two candidate layouts, since qpkg install conventions vary.
DXE_QNAP_TAILSCALE_BIN_GLOB='/share/*/.qpkg/Tailscale/tailscale /share/*/.qpkg/Tailscale/bin/tailscale'

# The Docker CLI to invoke on the NAS: an explicit DXE_QNAP_DOCKER override,
# or "docker" as a last-resort default (works only if some future NAS
# actually has it on the non-interactive PATH). Callers that need the
# confirmed-working absolute path must have already run discovery (see
# phase0-spike.sh's dxe_qnap_ensure_docker_bin) and set DXE_QNAP_DOCKER.
dxe_qnap_docker_bin() { printf '%s' "${DXE_QNAP_DOCKER:-docker}"; }

# Prints a POSIX-sh snippet (safe to embed in a larger heredoc: BusyBox/ash
# compatible, no bashisms) that assigns shell variable $1 to the first of
# $2 found on PATH via `command -v`, or the first executable match of the
# space-separated glob pattern(s) in $3. Leaves $1 empty if neither is
# found. Used identically by phase0-inventory.sh (to discover both the
# Docker CLI and Tailscale) and phase0-spike.sh (Docker only), so the
# discovery logic itself cannot drift between the two scripts.
dxe_qpkg_binary_discovery_snippet() {
    local var="$1" cmd="$2" glob="$3"
    printf '%s=""\n' "$var"
    printf 'if command -v %s >/dev/null 2>&1; then %s="$(command -v %s)"; else for dxe_cand in %s; do if [ -x "$dxe_cand" ]; then %s="$dxe_cand"; break; fi; done; fi\n' \
        "$cmd" "$var" "$cmd" "$glob" "$var"
}

# A standalone remote script (one ssh round trip) that discovers the Docker
# CLI's absolute path and prints it alone (or NOTFOUND). Used by
# phase0-spike.sh's dxe_qnap_ensure_docker_bin; phase0-inventory.sh embeds
# dxe_qpkg_binary_discovery_snippet directly instead, since its discovery is
# one field among many in a single larger combined session.
dxe_qnap_docker_discovery_remote_script() {
    printf '%s\necho "${DXE_DOCKER_BIN:-NOTFOUND}"\n' "$(dxe_qpkg_binary_discovery_snippet DXE_DOCKER_BIN docker "$DXE_QNAP_DOCKER_BIN_GLOB")"
}

# Dry-run-aware call whose exit status is what matters: runs the discovered
# (or overridden) Docker CLI as a plain ssh remote command -- never through
# the local Docker CLI's own "-H ssh://" transport (see above).
dxe_qnap_docker_run() {
    local ssh_opts=() opt
    while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dxe_qnap_ssh_opts)"
    dxe_maybe_run ssh "${ssh_opts[@]}" "$(dxe_qnap_host)" "$(dxe_qnap_docker_bin)" "$@"
}

# Same, but for a call whose stdout a caller needs to parse.
dxe_qnap_docker_capture() {
    local ssh_opts=() opt
    while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dxe_qnap_ssh_opts)"
    dxe_maybe_capture ssh "${ssh_opts[@]}" "$(dxe_qnap_host)" "$(dxe_qnap_docker_bin)" "$@"
}

# --- Private, never-committed output location -----------------------------
#
# Both scripts' --report/--summary default here, never under the
# repository: the NAS is a production system and nothing it reveals belongs
# in a public git history. $HOME is used directly (not DX_PROJECT_ROOT),
# so the default survives regardless of which checkout/worktree ran the
# script.
dxe_qnap_private_dir() { printf '%s/dxe-recovery/qnap' "${HOME:?}"; }

# --- Spike resource naming/labelling (qnap-dxe-plan.md Phase 0 safety rule) ---
#
# Every resource the spike creates is named "dxe-spike-<role>" AND carries
# this label. Destructive/query commands filter by the label, never merely
# by guessing at names, so an unrelated resource that happens to start with
# "dxe-spike-" (there should never be one) still cannot be swept up by name
# alone without also carrying the label. DXE_SPIKE_LABEL is consumed by
# tests/qnap/phase0-spike.sh and tests/test_section27_qnap_scripts.sh, not
# within this file, so ShellCheck (run per-file) cannot see that use.
DXE_SPIKE_PREFIX="dxe-spike-"
# shellcheck disable=SC2034
DXE_SPIKE_LABEL="dxe.role=spike"

dxe_spike_name() { printf '%s%s' "$DXE_SPIKE_PREFIX" "$1"; }

# --- Secret redaction ------------------------------------------------------
#
# Best-effort, not a security boundary by itself: the real control is that
# the scripts never read /etc/tailscale, never print full `docker info`, and
# never print auth/registry sections in the first place (see each script).
# This is the second layer -- anything token/secret-shaped that slips into
# captured remote output (e.g. inside `docker version`'s free-text build
# metadata) is still masked before it reaches a report or stdout.
dxe_redact_secrets() {
    sed -E \
        -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED-TOKEN]/g' \
        -e 's/sk-[A-Za-z0-9]{20,}/[REDACTED-TOKEN]/g' \
        -e 's/xox[a-zA-Z]-[A-Za-z0-9-]{10,}/[REDACTED-TOKEN]/g' \
        -e 's/AKIA[0-9A-Z]{16}/[REDACTED-TOKEN]/g' \
        -e 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/[REDACTED-JWT]/g' \
        -e 's/([Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+)[A-Za-z0-9._-]{8,}/\1[REDACTED-TOKEN]/g' \
        -e 's/((^|[^A-Za-z0-9_])([Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Aa][Uu][Tt][Hh][_-]?[Kk][Ee][Yy])[[:space:]]*[:=][[:space:]]*)[^[:space:]]{4,}/\1[REDACTED]/g'
}

# --- Report header (both scripts open every report/log the same way) ------
#
# "the script's git commit ... the date, and the host alias (not the
# address)" -- qnap-dxe-plan.md Phase 0 scripts section.
dxe_qnap_utc_date() { date -u +%Y-%m-%d; }

dxe_qnap_report_header() {
    local repo_root="$1" title="$2" commit
    commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf '# %s\n\n' "$title"
    printf -- '- Commit: `%s`\n' "$commit"
    printf -- '- Date (UTC): `%s`\n' "$(dxe_qnap_utc_date)"
    printf -- '- Host alias: `%s`\n' "$(dxe_qnap_host)"
    printf '\n'
}
