#!/usr/bin/env bash
# Source-only bootstrap usage-service phase. Safe to source.
#
# Usage-service mode (docs/refactor/usage-service-host.md, design item 3):
# when the container was created with DX_USAGE_SERVICE=on, bootstrap_main
# does not exec sshd directly. It builds an s6 service directory and execs
# s6-svscan as PID 1 (the same PID the lease and readiness marker name)
# supervising three services, each logging through a bounded s6-log:
#
#   sshd                   the same argv as the off path (-D -e -p 2222)
#   agent-stats            the launcher, as dx (scripts/dx-usage-service.sh serve)
#   agent-stats-watchdog   the health poller, as root so it can drive s6-svc
#                          (scripts/dx-usage-service.sh watchdog)
#
# The launcher scripts live in the bootstrap volume (root-owned), which is
# why the root-run watchdog may execute one of them.

# Writes an executable run script: `dx_usage_service_write_run FILE INTERPRETER
# COMMAND [ARG...]`. Every word is %q-quoted so no value is re-parsed by the
# shell that runs the script; stderr joins stdout so the service's own log pipe
# (s6-svscan connects <service>/log) carries both.
dx_usage_service_write_run() {
    local file="$1" interpreter="$2" word body
    shift 2
    body="$(printf '#!%s\nexec 2>&1\nexec' "$interpreter"; for word in "$@"; do printf ' %q' "$word"; done)"
    printf '%s\n' "$body" > "$file" || return 1
    chmod 0755 "$file"
}

# Builds the service directory `dx_usage_service_build_tree [SCAN_DIR
# [SERVICES_ROOT]]` (defaults: /run/dx-services, a tmpfs rebuilt on every boot,
# and /persist/services/agent-stats). Returns 1 with a clear message, before
# creating anything, when an s6 tool is missing from PATH.
dx_usage_service_build_tree() {
    local scan_dir="${1:-/run/dx-services}" services_root="${2:-/persist/services/agent-stats}"
    local tool sshd_bin s6_log bash_bin setpriv_bin env_bin name scripts
    case "$scan_dir" in ""|/) echo "Error: refusing to build the usage-service directory at '$scan_dir'." >&2; return 1 ;; esac
    for tool in s6-svscan s6-log sshd setpriv env bash; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "Error: DX_USAGE_SERVICE=on needs '$tool' on PATH but it is missing (s6 comes from the guest flake's bootstrapEssentials, and bootstrap upgrades an existing guest's essentials profile before this point, so reaching here means that upgrade failed or did not provide it); refusing to start the service tree." >&2
            return 1
        }
    done
    sshd_bin="$(command -v sshd)"; s6_log="$(command -v s6-log)"; bash_bin="$(command -v bash)"
    setpriv_bin="$(command -v setpriv)"; env_bin="$(command -v env)"
    scripts="${DX_BOOTSTRAP_ROOT:-/guest-bootstrap}/scripts"

    install -d -o dx -g dx -m 0755 "$services_root" "$services_root/logs" || return 1
    # Earlier boots ran s6-log as root, leaving root:root 0700 log directories
    # inside the dx-owned tree (dx-backup, running as dx, then fails closed on
    # them); re-own exactly the logs subtree. Idempotent.
    chown -R dx:dx "$services_root/logs" || return 1
    rm -rf "$scan_dir" || return 1
    mkdir -p "$scan_dir" || return 1
    # Where the s6 tools live, for root callers whose PATH lacks the essentials
    # profile (bin/dx-usage-service via exec, the dx-ai hook via sudo). A dot
    # entry, so s6-svscan ignores it.
    ln -s "$(dirname "$(command -v s6-svscan)")" "$scan_dir/.s6-bin" || return 1
    for name in sshd agent-stats agent-stats-watchdog; do
        mkdir -p "$scan_dir/$name/log" || return 1
        # 10 archived files of at most 1 MB each per service, ISO 8601 stamps. As
        # dx, so the directories s6-log creates are dx-owned like the rest of
        # the services tree.
        dx_usage_service_write_run "$scan_dir/$name/log/run" "$bash_bin" \
            "$setpriv_bin" --reuid=dx --regid=dx --init-groups \
            "$s6_log" n10 s1000000 T "$services_root/logs/$name" || return 1
    done
    dx_usage_service_write_run "$scan_dir/sshd/run" "$bash_bin" "$sshd_bin" -D -e -p 2222 || return 1
    dx_usage_service_write_run "$scan_dir/agent-stats/run" "$bash_bin" \
        "$setpriv_bin" --reuid=dx --regid=dx --init-groups \
        "$env_bin" HOME=/home/dx USER=dx "PATH=/home/dx/.nix-profile/bin:$PATH" \
        "$bash_bin" "$scripts/dx-usage-service.sh" serve || return 1
    dx_usage_service_write_run "$scan_dir/agent-stats-watchdog/run" "$bash_bin" \
        "$env_bin" "PATH=/home/dx/.nix-profile/bin:$PATH" \
        "$bash_bin" "$scripts/dx-usage-service.sh" watchdog || return 1
}

# Builds the tree and replaces this process with s6-svscan over it. Only
# returns (non-zero) when the tree could not be built, i.e. before any exec.
# Production passes no arguments (the defaults apply); the tests pass fixture
# paths, which is why ShellCheck sees parameters nobody passes.
# shellcheck disable=SC2120
dx_bootstrap_exec_usage_service() {
    local scan_dir="${1:-/run/dx-services}"
    dx_usage_service_build_tree "$scan_dir" "${2:-/persist/services/agent-stats}" || return 1
    echo "Guest bootstrap complete. Starting s6-svscan supervising sshd, agent-stats and agent-stats-watchdog..."
    exec "$(command -v s6-svscan)" "$scan_dir"
}

# bootstrap_main's one call: returns 0 (nothing done) unless DX_USAGE_SERVICE is
# exactly "on" -- anything else is off, so a typo can never keep SSH from coming
# up. When on, builds the tree and execs s6-svscan; a failure to build it (a
# missing s6) aborts the boot here, before any exec.
dx_bootstrap_usage_service_dispatch() {
    [ "${DX_USAGE_SERVICE:-off}" = on ] || return 0
    dx_bootstrap_exec_usage_service || exit 1
}
