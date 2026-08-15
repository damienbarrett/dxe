#!/bin/bash
# Shared SSH endpoint, option assembly, and guest execution boundary. Safe to source.

dx_ssh_endpoint() { printf '%s\n' dx@127.0.0.1; }

# Single source of truth for the SSH connection options shared by every DX SSH
# entry point: dx-ssh's interactive branch, its argument branch, and dx-herdr
# (F10). Bash 3.2 cannot return an array from a function, so callers build
# their own indexed array from this newline-per-token stream -- one token per
# line so a value containing whitespace (in principle, $DX_SSH_KEY) still
# round-trips intact:
#   local ssh_opts=() opt
#   while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dx_ssh_common_options)"
dx_ssh_common_options() {
    printf '%s\n' \
        -i "$DX_SSH_KEY" \
        -p "$DX_SSH_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        -o LogLevel=ERROR \
        -o ConnectTimeout="$DX_SSH_CONNECT_TIMEOUT"
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

    local host_tz
    host_tz="$(dx_get_host_timezone)"

    local ssh_opts=() opt
    while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dx_ssh_common_options)"

    ssh "${ssh_opts[@]}" "$(dx_ssh_endpoint)" "$(dx_guest_bash_command "$host_tz" "$remote_cmd_body")"
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

    local ssh_opts=() opt
    while IFS= read -r opt; do ssh_opts+=("$opt"); done <<<"$(dx_ssh_common_options)"

    local status=0
    ssh -t "${ssh_opts[@]}" "$(dx_ssh_endpoint)" "$(dx_guest_bash_command "$host_tz" "$remote_cmd_body")" || status=$?
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
while [ ! -L "$root/current" ] && [ ! -f "$root/.dx-bootstrap-ready" ]; do sleep 1; done
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
