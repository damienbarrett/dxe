#!/bin/bash
# Shared SSH endpoint, option assembly, and guest execution boundary. Safe to source.

# Remote-aware since Branch 11 / Phase 5 (qnap-dxe-plan.md DQ5;
# docs/refactor/remote-aware-ssh.md section 3): Apple keeps dx@127.0.0.1
# unchanged (dx_runtime_apple_guest_ssh_address is a fixed constant, no
# discovery); docker-ssh dials dx@<the NAS's discovered Tailscale address>.
# Every entry point that calls this or dx_ssh_common_options below (dx-ssh,
# dx-herdr, dx-wait-ssh, dx-tunnel.sh) inherits the correct destination
# automatically -- one seam, no per-caller branching on DX_RUNTIME.
dx_ssh_endpoint() { printf '%s\n' "dx@$(dx_runtime_guest_ssh_address)"; }

# Per-profile known-hosts pinning for docker-ssh (Branch 11 / Phase 5,
# qnap-dxe-plan.md DQ5 item 8; docs/refactor/remote-aware-ssh.md section
# 4): a real, persistent, per-profile file, never /dev/null -- so the
# guest's own SSH host identity is verified normally after first contact,
# unlike Apple's disposable, constantly-recreated local guest (pinning
# that would be pure churn, not a real guarantee). Scoped by
# $DX_CONTAINER_NAME plus dx_profile_state_segment's own value (colons
# replaced, since a raw identity string is not a safe path segment) --
# WP3.4 / Fable A1: the SAME shared helper (bin/lib/dx-host-util.sh) that
# bin/lib/dx-backup.sh's dx_backup_resolve_dir and bin/lib/dx-tunnel.sh's
# dx_tunnel_key now also use, so the three can no longer diverge on how
# they resolve or fail-close on it -- not the docker-adapter's own
# dx_runtime_docker_profile_id: this file is not one of the two adapters
# (Section 32's audit), so it must never name an adapter-specific function
# directly. The file itself is never created here: ssh's own accept-new
# behaviour creates (and appends to) it on first contact; only the parent
# directory is prepared, and only for docker-ssh (Apple never calls this).
dx_ssh_known_hosts_dir() {
    local identity
    identity="$(dx_profile_state_segment)" || return 1
    printf '%s/dxe/%s/%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "${DX_CONTAINER_NAME:?}" "${identity//:/_}"
}
dx_ssh_known_hosts_path() { printf '%s/known_hosts\n' "$(dx_ssh_known_hosts_dir)"; }

# Ensures the pin directory exists, is a real directory (never a symlink),
# and is owned by the current user, 0700 -- the same safety shape
# bin/lib/dx-tunnel.sh's own dx_tunnel_prepare_state already uses for "a
# per-profile local state directory," reused here rather than a second,
# parallel idiom.
dx_ssh_known_hosts_prepare() {
    local dir
    dir="$(dx_ssh_known_hosts_dir)"
    [ ! -L "$dir" ] || { echo "Error: refusing symlinked SSH known-hosts directory $dir." >&2; return 1; }
    if [ ! -e "$dir" ]; then mkdir -p "$dir" 2>/dev/null || [ -d "$dir" ] || return 1; fi
    [ ! -L "$dir" ] && [ -d "$dir" ] || { echo "Error: SSH known-hosts path is not a safe directory: $dir." >&2; return 1; }
    [ "$(dx_path_uid "$dir")" = "$(id -u)" ] || { echo "Error: SSH known-hosts directory is not owned by the current user: $dir." >&2; return 1; }
    chmod 0700 "$dir"
}

# Single source of truth for the SSH connection options shared by every DX SSH
# entry point: dx-ssh's interactive branch, its argument branch, dx-herdr
# (F10), dx-wait-ssh, and dx-tunnel.sh (Branch 11 / Phase 5). Bash 3.2
# cannot return an array from a function, so callers build their own
# indexed array from this newline-per-token stream -- one token per line so
# a value containing whitespace (in principle, $DX_SSH_KEY) still
# round-trips intact. THIS FUNCTION CAN NOW FAIL (docker-ssh's known-hosts
# directory safety check) -- every caller must capture its output into a
# variable and check the exit status BEFORE building an array from it:
#   local opts_stream ssh_opts=() opt
#   opts_stream="$(dx_ssh_common_options)" || return 1
#   while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$opts_stream"
# ("while ... <<<\"$(dx_ssh_common_options)\"" directly, with no capture in
# between, silently discards a failure: the here-string only ever sees
# dx_ssh_common_options's STDOUT, and the while loop's own exit status --
# not the failing command's -- is what a caller would see.)
dx_ssh_common_options() {
    if [ "${DX_RUNTIME:-apple}" = docker-ssh ]; then
        dx_ssh_known_hosts_prepare || return 1
        printf '%s\n' \
            -i "$DX_SSH_KEY" \
            -p "$DX_SSH_PORT" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$(dx_ssh_known_hosts_path)" \
            -o IdentitiesOnly=yes \
            -o LogLevel=ERROR \
            -o ConnectTimeout="$DX_SSH_CONNECT_TIMEOUT"
    else
        printf '%s\n' \
            -i "$DX_SSH_KEY" \
            -p "$DX_SSH_PORT" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes \
            -o LogLevel=ERROR \
            -o ConnectTimeout="$DX_SSH_CONNECT_TIMEOUT"
    fi
}

# Guest PATH baseline so Nix-installed tools resolve regardless of the dx
# user's login shell. Single source of truth for F10.
dx_guest_path() { printf '%s' "/home/dx/.nix-profile/bin:/home/dx/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; }

# CA trust roots so Nix-built network tools (curl, nix, dx-ai, ...) find a
# certificate bundle. Single source of truth for F10.
dx_guest_ssl_env() { printf '%s' "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"; }

# `cd` prefix into $DX_GUEST_WORKDIR, or empty when unset. This is used only
# by dx-ssh's already-base64-encoded argument transport; callers that use the
# shared bash -lc command builder below must use the base64 helper instead.
dx_guest_workdir_snippet() {
    if [ -n "${DX_GUEST_WORKDIR:-}" ]; then
        printf 'cd %s && ' "$(printf '%q' "$DX_GUEST_WORKDIR")"
    fi
}

# Opaque, login-shell-safe transport for arbitrary bytes crossing into the
# guest. The outer command is parsed by dx's configured login shell before
# bash ever receives it, so a `%q`-escaped shell token is not sufficient when
# it is then embedded in the single-quoted bash -c program: `%q` protects a
# token for direct Bash parsing, not for insertion into an already-open
# quoted string. Base64's alphabet survives any login shell's quoting rules
# intact, so the inner bash decodes it into a quoted variable instead.
dx_guest_base64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# Keep arbitrary workdir bytes out of the outer remote command string (R4).
dx_guest_workdir_base64() {
    if [ -n "${DX_GUEST_WORKDIR:-}" ]; then
        dx_guest_base64 "$DX_GUEST_WORKDIR"
    fi
}

# The env prefix that must precede every guest-side command body. Every guest
# command has to cross into a POSIX bash login shell explicitly, regardless of
# the dx user's actual login shell (nushell/fish): Nushell accepts
# `env NAME=value... prog -c '<opaque>'` as a plain external-command
# invocation (each NAME=value token and the single-quoted string are just
# arguments to `env`/`bash`), but it chokes the moment it has to parse
# POSIX-only syntax such as `2>&1` or the `command` builtin itself (F1).
# Callers must nest the actual command inside the single-quoted
# `bash -l -c '...'` boundary this feeds -- see dx_guest_bash_command below --
# never hand a raw command string to ssh.
dx_guest_env_prefix() {
    local host_tz="$1"
    printf 'env HOST_TZ="%s" PATH="%s" %s TERM=xterm-256color' "$host_tz" "$(dx_guest_path)" "$(dx_guest_ssl_env)"
}

# Build the full remote command: the env prefix above, feeding a POSIX bash
# login shell that decodes and enters the workdir, then decodes and runs the
# command body. Single source of truth for F10; used by dx-ssh's interactive
# branch and by dx-herdr's probes/install/attach.
#
# The body is transported base64-encoded for the same reason the workdir is
# (R4): interpolating it into the single-quoted `bash -l -c '...'` program
# breaks the moment it contains an apostrophe. `eval` rather than a pipe into
# another `bash -l` is deliberate -- the interactive callers (tmux, herdr)
# need the body to inherit the pty on stdin, which a pipe would consume.
dx_guest_bash_command() {
    local host_tz="$1" body="$2" workdir_b64="" body_b64=""
    workdir_b64="$(dx_guest_workdir_base64)" || return 1
    body_b64="$(dx_guest_base64 "$body")" || return 1
    printf "%s DX_GUEST_WORKDIR_B64=%s DX_GUEST_CMD_B64=%s bash -l -c 'if [ -n \"\${DX_GUEST_WORKDIR_B64:-}\" ]; then DX_GUEST_WORKDIR=\"\$(printf %%s \"\$DX_GUEST_WORKDIR_B64\" | base64 -d)\" || exit 1; cd \"\$DX_GUEST_WORKDIR\" || exit 1; fi; DX_GUEST_CMD=\"\$(printf %%s \"\$DX_GUEST_CMD_B64\" | base64 -d)\" || exit 1; eval \"\$DX_GUEST_CMD\"'" \
        "$(dx_guest_env_prefix "$host_tz")" "$workdir_b64" "$body_b64"
}

# Run a non-interactive guest command over the boundary above, with no pty.
# Prints whatever the remote command prints and returns ssh's own exit status
# unmodified: OpenSSH exits 255 when the *transport* fails (auth, connect, bad
# host key, ...) and otherwise forwards the remote command's own exit status,
# so a caller can distinguish "SSH could not run this" from "the guest said
# no" (F2). Checks $DX_SSH_KEY before dialing out, not after.
dx_ssh_run_guest_command() {
    local remote_cmd_body="$1"

    if [ ! -f "$DX_SSH_KEY" ]; then
        echo "Error: SSH key file not found at $DX_SSH_KEY." >&2
        return 255
    fi

    # Resolved into a local, checked explicitly, before dialing out: a
    # caller of this function is very often itself the subject of a "||"
    # (Herdr's own probes capture this with "|| rc=$?"), which suspends
    # `set -e` for anything this function does during that call -- an
    # inline "$(dx_ssh_endpoint)" at the ssh call site would then silently
    # become an empty destination argument instead of aborting, if guest
    # SSH address discovery ever failed (DQ5). Matches ssh's own transport-
    # failure convention (255).
    local endpoint
    endpoint="$(dx_ssh_endpoint)" || return 255

    local host_tz
    host_tz="$(dx_get_host_timezone)"

    # Captured, then checked, before building the array: dx_ssh_common_options
    # can now genuinely fail (known-hosts pin directory safety checks under
    # docker-ssh), and "while read <<<\"$(cmd)\"" discards a failing cmd's
    # exit status -- same reasoning as the endpoint above.
    local opts_stream
    opts_stream="$(dx_ssh_common_options)" || return 255
    local ssh_opts=() opt
    while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$opts_stream"

    ssh "${ssh_opts[@]}" "$endpoint" "$(dx_guest_bash_command "$host_tz" "$remote_cmd_body")"
}

# Single source of truth for the one-shot login-shell readiness probe
# bin/dx-wait-ssh's poll loop and bin/dx-status's SSH section both need
# (Branch 11 / Phase 6, qnap-dxe-plan.md Phase 6 item 5): the same option
# array dx_ssh_common_options always builds, plus this probe's own
# BatchMode=yes (a readiness probe must never hang on a password/
# passphrase prompt -- specifically this probe's concern, not every SSH
# caller's), dialling dx_ssh_endpoint and running "bash -lc 'true'" -- the
# exact command text both callers already sent inline before this
# extraction, kept unchanged so neither caller's observable behaviour
# moves. $1 is a caller-supplied file path for the probe's stderr
# (overwritten every call, never appended), matching bin/dx-wait-ssh's own
# pre-existing PROBE_STDERR convention, so both callers can print/tail it
# identically. Returns ssh's own exit status; 255 (ssh's own transport-
# failure convention, matching dx_ssh_run_guest_command above) if the
# endpoint or options cannot even be built.
dx_ssh_probe_login_shell() {
    local stderr_file="$1"

    local endpoint
    endpoint="$(dx_ssh_endpoint)" || return 255

    local opts_stream
    opts_stream="$(dx_ssh_common_options)" || return 255
    local opts=() opt
    while IFS= read -r opt; do opts+=("$opt"); done <<<"$opts_stream"
    opts+=("-o" "BatchMode=yes")

    ssh "${opts[@]}" "$endpoint" "bash -lc 'true'" >/dev/null 2>"$stderr_file"
}

# Restore the guest's persisted colour scheme before the session's real
# program starts. Ordering is the whole design: this runs while the outer
# terminal is still directly attached to the SSH pty, with no multiplexer in
# the path, so the OSC sequences reach the terminal unwrapped and neither tmux
# nor Herdr needs to support passthrough for attach-time theming to work.
#
# This is a shared prefix rather than an inline snippet because it was inline
# in dx-ssh only, which is exactly how dx-herdr shipped without it: unifying
# the SSH transport (F10) left the theme restore behind in one caller's command
# body, invisible from the other. Herdr sessions therefore inherited whatever
# palette the terminal happened to be carrying.
dx_guest_theme_restore_prefix() {
    printf '%s' 'if [ -x /home/dx/.local/bin/dx-theme-restore ]; then /home/dx/.local/bin/dx-theme-restore 2>/dev/null || true; fi; '
}

# Attach an interactive (pty) guest session running $1 inside the boundary
# above. Prints the "Connecting..." banner once, installs the Apple Terminal
# colour-restore cleanup, and always returns the real ssh exit status -- it
# must never `exec` (F3): a successful exec replaces this process image
# before the EXIT trap could ever run, silently discarding the cleanup.
dx_run_interactive_ssh() {
    local remote_cmd_body="$1"

    if [ ! -f "$DX_SSH_KEY" ]; then
        echo "Error: SSH key file not found at $DX_SSH_KEY." >&2
        return 1
    fi

    # See dx_ssh_run_guest_command's own comment on why this is resolved
    # and checked explicitly rather than inlined at the ssh call site.
    local endpoint
    endpoint="$(dx_ssh_endpoint)" || return 1

    echo "Connecting to DX guest via SSH..." >&2

    local host_tz
    host_tz="$(dx_get_host_timezone)"

    local osc_reset=""
    if [ "${TERM_PROGRAM:-}" = "Apple_Terminal" ]; then
        osc_reset=$'\033]110\033\\\033]111\033\\\033]104\033\\'
    fi
    dx_ssh_cleanup_osc() {
        if [ -n "$osc_reset" ]; then
            printf '%s' "$osc_reset" >&2
        fi
    }
    trap dx_ssh_cleanup_osc EXIT

    # Captured, then checked, before building the array -- see
    # dx_ssh_run_guest_command's own comment; the trap above is already
    # armed, so a failure here still runs the terminal-colour cleanup
    # before returning, exactly like the normal exit path below.
    local opts_stream
    opts_stream="$(dx_ssh_common_options)" || { dx_ssh_cleanup_osc; trap - EXIT; return 1; }
    local ssh_opts=() opt
    while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$opts_stream"

    local status=0
    ssh -t "${ssh_opts[@]}" "$endpoint" "$(dx_guest_bash_command "$host_tz" "$remote_cmd_body")" || status=$?
    dx_ssh_cleanup_osc
    trap - EXIT
    return "$status"
}

dx_bootstrap_launch_command() {
    cat <<'EOF'
set -eu
root=$1
lock="$root/.locks/publication"
process_start() {
    stat_line=$(cat "/proc/${1:-0}/stat" 2>/dev/null) || return 1
    stat_fields=${stat_line##*) }
    set -- $stat_fields
    [ "$#" -ge 20 ] || return 1
    shift 19
    printf "%s\n" "$1"
}
[ -d "$root" ] && [ ! -L "$root" ] || { echo "Error: unsafe bootstrap root $root" >&2; exit 1; }
for path in "$root/.locks" "$root/.locks/leases"; do [ ! -L "$path" ] || { echo "Error: unsafe bootstrap state path $path" >&2; exit 1; }; done
mkdir -p /persist "$root/.locks/leases"
acquire_publication_lock() {
    elapsed=0
    while ! mkdir "$lock" 2>/dev/null; do
        if [ -f "$lock/owner" ]; then
            tab=$(printf "\t")
            IFS="$tab" read -r owner_boot owner_pid owner_start < "$lock/owner" || true
            boot=$(cat /proc/sys/kernel/random/boot_id)
            live_start=$(process_start "${owner_pid:-0}" || true)
            if [ -z "${owner_boot:-}" ] || [ -z "${owner_pid:-}" ] || [ -z "${owner_start:-}" ] \
                || [ "$owner_boot" != "$boot" ] || [ -z "$live_start" ] || [ "$owner_start" != "$live_start" ]; then
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
    owner_tmp="$root/.locks/.owner.$$.tmp"
    if ! printf "%s\t%s\t%s\n" "$boot" "$$" "$start" > "$owner_tmp" || ! mv "$owner_tmp" "$lock/owner"; then
        rm -f "$owner_tmp"; rmdir "$lock" 2>/dev/null || true; exit 1
    fi
}
release_publication_lock() { rm -f "$lock/owner"; rmdir "$lock"; }
rm -f "$root/.dx-bootstrap-ready"
touch "$root/.dx-bootstrap-waiting"
echo "Waiting for bootstrap payload in $root..."
# Wait for the host to signal that publication for *this* boot has settled, not
# merely for a `current` to exist. On a restart `current` already points at the
# previous boot's generation, so resolving it on sight runs the payload from the
# last boot -- which is why a bootstrap change used to need two starts, and why
# a guest whose bootstrap died could not be recovered by syncing (the sync
# refuses unless the container is running, and it will not stay running on the
# broken payload). dx-sync-bootstrap signals readiness whether it publishes or
# skips.
#
# A container started outside dx-start-container is never signalled at all.
# Waiting forever would be worse than running what is already published, so
# fall back after a bounded grace and say so.
publish_grace=${DX_BOOTSTRAP_PUBLISH_GRACE:-30}
waited=0
while [ ! -f "$root/.dx-bootstrap-ready" ]; do
    if [ -L "$root/current" ] && [ "$waited" -ge "$publish_grace" ]; then
        echo "Warning: no publication signal after ${waited}s; using the generation already current." >&2
        break
    fi
    sleep 1
    waited=$((waited + 1))
done
if [ -L "$root/current" ]; then
    acquire_publication_lock
    trap 'rm -f "$lock/owner"; rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM
    generation=$(readlink "$root/current")
    case "$generation" in generations/*) generation=${generation#generations/} ;; *) echo "Error: invalid bootstrap current pointer" >&2; exit 1 ;; esac
    case "$generation" in ""|*/*|[.-]*|*[!A-Za-z0-9_.-]*) echo "Error: invalid bootstrap generation" >&2; exit 1 ;; esac
    [ -f "$root/generations/$generation/bootstrap.sh" ] && [ ! -L "$root/generations/$generation/bootstrap.sh" ] || { echo "Error: incomplete bootstrap generation $generation" >&2; exit 1; }
    # Name the resolved generation before executing it. This is the only record
    # of which payload a boot actually ran that survives the guest dying:
    # `container exec` needs a live container, but `container logs` does not.
    echo "Using bootstrap generation $generation"
    boot_id=$(cat /proc/sys/kernel/random/boot_id)
    start=$(process_start $$)
    lease_tmp="$root/.locks/leases/.lease.$$.tmp"
    # Scope the restrictive umask to the lease write. It must not survive into
    # the bootstrap exec'd below, which creates world-readable files.
    (umask 077; printf '%s\t%s\t%s\t%s\n' "$generation" "$boot_id" "$$" "$start" > "$lease_tmp")
    mv "$lease_tmp" "$root/.locks/leases/$generation.$$"
    payload="$root/generations/$generation"
    release_publication_lock
    trap - EXIT HUP INT TERM
else
    payload="$root"
fi
rm -f "$root/.dx-bootstrap-waiting"
exec "$payload/bootstrap.sh" serve
EOF
}
