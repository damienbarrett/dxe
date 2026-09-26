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
#     shape as bin/dx-put/bin/dx-get, just against "docker -H ssh://..."
#     instead of the local "container" CLI.

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
# a persistent global `docker context`.
dxe_qnap_docker_host_arg() { printf 'ssh://%s' "$(dxe_qnap_host)"; }

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

# Dry-run-aware docker-over-SSH call (DQ1: command-scoped endpoint, never a
# persistent global context) whose exit status is what matters.
dxe_qnap_docker_run() { dxe_maybe_run docker -H "$(dxe_qnap_docker_host_arg)" "$@"; }

# Same, but for a call whose stdout a caller needs to parse.
dxe_qnap_docker_capture() { dxe_maybe_capture docker -H "$(dxe_qnap_docker_host_arg)" "$@"; }

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
