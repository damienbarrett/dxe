#!/bin/bash
# Shared SSH endpoint and option assembly. Safe to source.

dx_ssh_endpoint() { printf '%s\n' dx@127.0.0.1; }

dx_ssh_append_common_options() {
    # The caller names an indexed array. Bash 3.2-compatible printf -v appends
    # are deliberately avoided; callers use this newline form with read loops.
    printf '%s\n' -p "$DX_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
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
    boot_id=$(cat /proc/sys/kernel/random/boot_id)
    start=$(process_start $$)
    umask 077
    lease_tmp="$root/.locks/leases/.lease.$$.tmp"
    printf '%s\t%s\t%s\t%s\n' "$generation" "$boot_id" "$$" "$start" > "$lease_tmp"
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
