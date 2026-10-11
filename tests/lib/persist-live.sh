#!/bin/bash
# shellcheck disable=SC2034 # every constant here is read by the sourcing suites
# tier: unit
# bash32: yes
# Import-only (functions and constants; no output, no shell-option or trap
# changes, no I/O at import time). Bash 3.2 compatible.
#
# The guard and NAS helpers of the /persist host-access LIVE suite
# (tests/test_persist_host_dir_live.sh, plans/do WP7.1). Kept out of the suite
# itself so tests/test_persist_host_dir_live_guard.sh can source and
# unit-test every refusal, the bind-source confinement, the exact one-off
# container argv and the in-container scripts without a NAS.
#
# Contract (pinned by tests/test_persist_host_dir_live_guard.sh):
#
# persist_live_guard
#   Reads the resolved profile from the environment. Prints one
#   `Refusing: ...` line on stderr for EVERY rule the environment breaks and
#   returns 1; prints nothing and returns 0 when all hold. It makes no remote,
#   runtime or file-system call. The rules (the live suite destroys and
#   resets the guest it runs on, so everything those commands act on must be
#   disposable):
#     - DXE_PERSIST_LIVE_CANARY equals DX_CONTAINER_NAME (the explicit opt-in,
#       pinned to one guest so a stale export cannot apply to another);
#     - DX_CONTAINER_NAME is not dx-host, dx-test or dx-qnap, and matches
#       ^dx-[a-z0-9-]*canary[a-z0-9-]*$;
#     - DX_RUNTIME=docker-ssh, DX_PERSIST_STORAGE=host-path;
#     - DX_PERSIST_HOST_ROOT is a normalised absolute path other than / (no
#       //, /./, /../, trailing / or trailing /. or /..), so the derived
#       directory <root>/dxe/<canary>/persist names exactly one place;
#     - DX_NIX_VOLUME, DX_PERSIST_VOLUME and DX_BOOTSTRAP_VOLUME each contain
#       "canary";
#     - DX_IMAGE contains "canary" (dx-destroy and dx-factory-reset delete
#       the image by name; images carry no ownership labels);
#     - the file names of DX_SSH_KEY and DX_SSH_KEY_PUB contain "canary"
#       (dx-factory-reset deletes the key pair);
#     - DX_SSH_PORT is not 2222, the registry default and the production
#       QNAP guest's port;
#     - DX_CONTAINER_RESTART_POLICY=no (the guest-side check case needs a
#       guest that stopped itself to stay stopped);
#     - DX_USAGE_SERVICE=off (its host port would collide with the
#       production guest's);
#     - DX_PERSIST_HOST_MOUNT_SENTINEL is not empty (creation needs it).
#
# persist_live_canary_dir / persist_live_leaf
#   <root>/dxe/<canary> and <root>/dxe/<canary>/persist.
#
# persist_live_share_path_ok PATH
#   0 only when the guard's root and name rules hold and PATH is exactly
#   persist_live_canary_dir: the ONLY share path the suite ever binds into a
#   container of its own. Everything the suite changes on the share happens
#   inside that directory, which the tooling created for this guest alone and
#   which holds nothing but the leaf and the suite's own aside copies.
#
# persist_live_root_sh rw|ro SCRIPT [ARG...]
#   Refuses (status 2, one `Refusing:` line, no call) unless the mode is rw
#   or ro and persist_live_share_path_ok accepts the canary directory.
#   Otherwise exactly one call, passing stdin through:
#     dxe_runtime_call dx_runtime_run_ephemeral --rm -i --network none
#       --user 0:0 --pull never --label dxe.role=persist-live
#       --mount type=bind,source=<canary dir>,target=/canary[,readonly]
#       --entrypoint sh <DX_IMAGE> -c SCRIPT sh /canary [ARG...]
#   i.e. the WP4.4 root one-off-container pattern (root through Docker, no
#   network, never pulls, --mount so a missing source is an error, never
#   created), with ,readonly for ro.
#
# The PERSIST_LIVE_SCRIPT_* constants are the only programs those containers
# run. Each is ONE line (the docker-ssh transport %q-quotes argv, and a
# newline would become bash-only $'...' quoting on the NAS shell) with no
# single quote, starts with `cd -P -- "$1"` and then touches only these
# fixed names inside it, never recursively:
#   persist                    the guest directory (the leaf)
#   persist.dxe-live-aside     the leaf while a case has moved it aside
#   marker.dxe-live-orig       the real marker while a case has replaced it
#   persist.dxe-live-removed-<UTC>  the leaf after the final cleanup
#   persist/.dxe-persist-dir, persist/dxe-live-unmarked, persist/.dxe-persist-dir.XXXXXX
#
# persist_live_kv KEY TEXT -- the value of TEXT's first KEY=value line.
# persist_live_marker_text GUEST STATE [SOURCE_VOLUME] [CREATED_AT]
#   [MIGRATED_AT] [RETIRED_AT] -- plan D-3's marker text (schema=1 first),
#   one key per line, optional keys only when given.
# persist_live_record_path -- plan D-7's record:
#   ${XDG_STATE_HOME:-$HOME/.local/state}/dxe/persist-dirs/<DX_REMOTE_HOST>__<DX_CONTAINER_NAME>

PERSIST_LIVE_PROTECTED_GUESTS="dx-host dx-test dx-qnap"
PERSIST_LIVE_ASIDE=persist.dxe-live-aside
PERSIST_LIVE_MARKER_ORIG=marker.dxe-live-orig
PERSIST_LIVE_REMOVED_PREFIX=persist.dxe-live-removed-

PERSIST_LIVE_SCRIPT_PRELUDE='unset CDPATH; cd -P -- "$1" || { echo "dxe-live: cannot enter $1" >&2; exit 1; }; '

# Move the real leaf aside (it must be a real directory, the aside slot free).
PERSIST_LIVE_SCRIPT_ASIDE="$PERSIST_LIVE_SCRIPT_PRELUDE"'if [ -L persist ] || [ ! -d persist ]; then echo "dxe-live: persist is not a real directory" >&2; exit 1; fi; if [ -e persist.dxe-live-aside ] || [ -L persist.dxe-live-aside ]; then echo "dxe-live: persist.dxe-live-aside already exists" >&2; exit 1; fi; mv -- persist persist.dxe-live-aside'

# $2 = symlink | empty | unmarked: put that in the leaf's place (aside first).
PERSIST_LIVE_SCRIPT_REPLACE="$PERSIST_LIVE_SCRIPT_PRELUDE"'if [ -L persist.dxe-live-aside ] || [ ! -d persist.dxe-live-aside ]; then echo "dxe-live: the leaf is not aside" >&2; exit 1; fi; if [ -e persist ] || [ -L persist ]; then echo "dxe-live: persist already exists" >&2; exit 1; fi; case "$2" in symlink) ln -s persist.dxe-live-aside persist ;; empty) mkdir -m 0755 persist ;; unmarked) mkdir -m 0755 persist && echo "dxe live probe: deliberately unmarked" > persist/dxe-live-unmarked ;; *) echo "dxe-live: unknown replacement $2" >&2; exit 2 ;; esac'

# Put the real leaf back. Nothing aside: nothing to do. Whatever stands in
# for it is removed only when it is one of the suite's own shapes: a symlink,
# or a directory holding nothing, only a marker, or only the unmarked probe.
PERSIST_LIVE_SCRIPT_RESTORE_LEAF="$PERSIST_LIVE_SCRIPT_PRELUDE"'if [ ! -e persist.dxe-live-aside ] && [ ! -L persist.dxe-live-aside ]; then exit 0; fi; if [ -L persist.dxe-live-aside ] || [ ! -d persist.dxe-live-aside ]; then echo "dxe-live: persist.dxe-live-aside is not a real directory" >&2; exit 1; fi; if [ -L persist ]; then rm -f -- persist || exit 1; elif [ -d persist ]; then e=$(LC_ALL=C ls -A persist) || exit 1; case "$e" in "" | .dxe-persist-dir | dxe-live-unmarked) : ;; *) echo "dxe-live: persist holds entries the suite did not make; leaving it" >&2; exit 1 ;; esac; rm -f -- persist/.dxe-persist-dir persist/dxe-live-unmarked || exit 1; rmdir -- persist || exit 1; elif [ -e persist ]; then echo "dxe-live: persist is not a directory or symlink" >&2; exit 1; fi; mv -- persist.dxe-live-aside persist'

# $2 = hide | swap. Move the real marker out to marker.dxe-live-orig; for swap,
# write the marker text read from stdin in its place (temp file in the leaf,
# mode 0644, one mv: the production marker step).
PERSIST_LIVE_SCRIPT_MARKER_OUT="$PERSIST_LIVE_SCRIPT_PRELUDE"'case "$2" in hide | swap) : ;; *) echo "dxe-live: unknown marker action $2" >&2; exit 2 ;; esac; m=persist/.dxe-persist-dir; if [ -L persist ] || [ ! -d persist ]; then echo "dxe-live: persist is not a real directory" >&2; exit 1; fi; if [ -L "$m" ] || [ ! -f "$m" ]; then echo "dxe-live: no regular marker to move" >&2; exit 1; fi; if [ -e marker.dxe-live-orig ] || [ -L marker.dxe-live-orig ]; then echo "dxe-live: marker.dxe-live-orig already exists" >&2; exit 1; fi; mv -- "$m" marker.dxe-live-orig || exit 1; [ "$2" = swap ] || exit 0; t=$(mktemp persist/.dxe-persist-dir.XXXXXX) || exit 1; if cat > "$t" && chmod 0644 "$t" && mv -- "$t" "$m"; then exit 0; fi; rm -f -- "$t"; exit 1'

# Put the real marker back over whatever replaced it (one mv). Nothing saved:
# nothing to do.
PERSIST_LIVE_SCRIPT_MARKER_RESTORE="$PERSIST_LIVE_SCRIPT_PRELUDE"'m=persist/.dxe-persist-dir; if [ ! -e marker.dxe-live-orig ] && [ ! -L marker.dxe-live-orig ]; then exit 0; fi; if [ -L marker.dxe-live-orig ] || [ ! -f marker.dxe-live-orig ]; then echo "dxe-live: marker.dxe-live-orig is not a regular file" >&2; exit 1; fi; if [ -L persist ] || [ ! -d persist ]; then echo "dxe-live: persist is not a real directory" >&2; exit 1; fi; if [ -L "$m" ] || { [ -e "$m" ] && [ ! -f "$m" ]; }; then echo "dxe-live: the marker slot is not a regular file" >&2; exit 1; fi; mv -f -- marker.dxe-live-orig "$m"'

# $2 = 0751 | 0755: the leaf's own mode (the guest re-asserts 0755 at boot,
# so 0751 surviving a boot attempt proves the boot stopped before /persist).
PERSIST_LIVE_SCRIPT_LEAF_MODE="$PERSIST_LIVE_SCRIPT_PRELUDE"'case "$2" in 0751 | 0755) : ;; *) echo "dxe-live: unexpected mode $2" >&2; exit 2 ;; esac; if [ -L persist ] || [ ! -d persist ]; then echo "dxe-live: persist is not a real directory" >&2; exit 1; fi; chmod "$2" persist'

# $2 = a UTC stamp (digits, T, Z): the final cleanup moves the leaf aside for
# good instead of deleting anything.
PERSIST_LIVE_SCRIPT_RETIRE="$PERSIST_LIVE_SCRIPT_PRELUDE"'case "$2" in "" | *[!0-9TZ]*) echo "dxe-live: bad stamp $2" >&2; exit 2 ;; esac; if [ ! -e persist ] && [ ! -L persist ]; then exit 0; fi; if [ -e "persist.dxe-live-removed-$2" ] || [ -L "persist.dxe-live-removed-$2" ]; then echo "dxe-live: persist.dxe-live-removed-$2 already exists" >&2; exit 1; fi; mv -- persist "persist.dxe-live-removed-$2"'

# Read-only facts about the canary directory, one key=value per line:
#   leaf, marker, aside, orig: dir | file | symlink | other | absent
#   leaf_owner, leaf_mode (when leaf=dir), marker_owner, marker_mode (when
#   marker=file), one entry=<name> line per leaf entry (LC_ALL=C order, when
#   leaf=dir), app_state=<first line of persist/dxe-live/app-state.txt>.
PERSIST_LIVE_SCRIPT_STAT="$PERSIST_LIVE_SCRIPT_PRELUDE"'st() { stat -c "%u:%g %a" -- "$1" 2>/dev/null || stat -f "%u:%g %Lp" -- "$1"; }; kind() { if [ -L "$1" ]; then echo symlink; elif [ -d "$1" ]; then echo dir; elif [ -f "$1" ]; then echo file; elif [ -e "$1" ]; then echo other; else echo absent; fi; }; k=$(kind persist); echo "leaf=$k"; if [ "$k" = dir ]; then set -- $(st persist); echo "leaf_owner=$1"; echo "leaf_mode=$2"; fi; mk=absent; if [ "$k" = dir ]; then mk=$(kind persist/.dxe-persist-dir); fi; echo "marker=$mk"; if [ "$mk" = file ]; then set -- $(st persist/.dxe-persist-dir); echo "marker_owner=$1"; echo "marker_mode=$2"; fi; if [ "$k" = dir ]; then LC_ALL=C ls -A persist | sed "s/^/entry=/"; fi; echo "aside=$(kind persist.dxe-live-aside)"; echo "orig=$(kind marker.dxe-live-orig)"; a=persist/dxe-live/app-state.txt; if [ "$k" = dir ] && [ -f "$a" ]; then echo "app_state=$(head -n 1 "$a")"; else echo "app_state="; fi'

# persist_live_name_is_canary NAME
persist_live_name_is_canary() {
    case "$1" in
        dx-*canary*) : ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
    esac
    return 0
}

# persist_live_root_ok ROOT: a normalised absolute path other than /.
persist_live_root_ok() {
    case "$1" in
        '' | / | [!/]* | *//* | */./* | */../* | */ | */. | */..) return 1 ;;
    esac
    case "$1" in
        *"
"*) return 1 ;;
    esac
    return 0
}

persist_live_canary_dir() {
    printf '%s/dxe/%s\n' "${DX_PERSIST_HOST_ROOT:-}" "${DX_CONTAINER_NAME:-}"
}

persist_live_leaf() {
    printf '%s/dxe/%s/persist\n' "${DX_PERSIST_HOST_ROOT:-}" "${DX_CONTAINER_NAME:-}"
}

persist_live_record_path() {
    printf '%s/dxe/persist-dirs/%s__%s\n' "${XDG_STATE_HOME:-${HOME:-}/.local/state}" "${DX_REMOTE_HOST:-}" "${DX_CONTAINER_NAME:-}"
}

_persist_live_refuse() {
    printf 'Refusing: %s\n' "$1" >&2
}

persist_live_guard() {
    local name="${DX_CONTAINER_NAME:-}" refused=0 field value protected
    if [ "${DXE_PERSIST_LIVE_CANARY:-}" != "$name" ] || [ -z "$name" ]; then
        _persist_live_refuse "DXE_PERSIST_LIVE_CANARY must equal DX_CONTAINER_NAME ($name) to opt in to this live suite."
        refused=1
    fi
    for protected in $PERSIST_LIVE_PROTECTED_GUESTS; do
        if [ "$name" = "$protected" ]; then
            _persist_live_refuse "DX_CONTAINER_NAME=$name is a protected guest ($PERSIST_LIVE_PROTECTED_GUESTS); the live suite runs only on a disposable canary."
            refused=1
        fi
    done
    if ! persist_live_name_is_canary "$name"; then
        _persist_live_refuse "DX_CONTAINER_NAME=$name is not a canary name (it must match ^dx-[a-z0-9-]*canary[a-z0-9-]*\$)."
        refused=1
    fi
    if [ "${DX_RUNTIME:-}" != docker-ssh ]; then
        _persist_live_refuse "DX_RUNTIME must be docker-ssh (got '${DX_RUNTIME:-}')."
        refused=1
    fi
    if [ "${DX_PERSIST_STORAGE:-}" != host-path ]; then
        _persist_live_refuse "DX_PERSIST_STORAGE must be host-path (got '${DX_PERSIST_STORAGE:-}')."
        refused=1
    fi
    if ! persist_live_root_ok "${DX_PERSIST_HOST_ROOT:-}"; then
        _persist_live_refuse "DX_PERSIST_HOST_ROOT must be a normalised absolute path other than / (got '${DX_PERSIST_HOST_ROOT:-}')."
        refused=1
    fi
    for field in DX_NIX_VOLUME DX_PERSIST_VOLUME DX_BOOTSTRAP_VOLUME; do
        value="${!field:-}"
        case "$value" in
            *canary*) : ;;
            *)
                _persist_live_refuse "$field=$value does not contain \"canary\"; every volume this suite may create or delete must be a canary volume."
                refused=1
                ;;
        esac
    done
    case "${DX_IMAGE:-}" in
        *canary*) : ;;
        *)
            _persist_live_refuse "DX_IMAGE=${DX_IMAGE:-} does not contain \"canary\"; dx-destroy and dx-factory-reset delete the image by name."
            refused=1
            ;;
    esac
    for field in DX_SSH_KEY DX_SSH_KEY_PUB; do
        value="${!field:-}"
        case "${value##*/}" in
            *canary*) : ;;
            *)
                _persist_live_refuse "$field=$value is not a canary key (its file name must contain \"canary\"); dx-factory-reset deletes the key pair."
                refused=1
                ;;
        esac
    done
    if [ "${DX_SSH_PORT:-}" = 2222 ]; then
        _persist_live_refuse "DX_SSH_PORT=2222 is the default guest port (the production QNAP guest's); give the canary its own port."
        refused=1
    fi
    if [ "${DX_CONTAINER_RESTART_POLICY:-}" != no ]; then
        _persist_live_refuse "DX_CONTAINER_RESTART_POLICY must be no (got '${DX_CONTAINER_RESTART_POLICY:-}'); the guest-side check case needs a guest that stopped itself to stay stopped."
        refused=1
    fi
    if [ "${DX_USAGE_SERVICE:-}" != off ]; then
        _persist_live_refuse "DX_USAGE_SERVICE must be off (got '${DX_USAGE_SERVICE:-}'); the canary publishes no usage service."
        refused=1
    fi
    if [ -z "${DX_PERSIST_HOST_MOUNT_SENTINEL:-}" ]; then
        _persist_live_refuse "DX_PERSIST_HOST_MOUNT_SENTINEL is empty; create the sentinel file at the share root and name it in the profile."
        refused=1
    fi
    return "$refused"
}

# persist_live_share_path_ok PATH
persist_live_share_path_ok() {
    persist_live_root_ok "${DX_PERSIST_HOST_ROOT:-}" || return 1
    persist_live_name_is_canary "${DX_CONTAINER_NAME:-}" || return 1
    [ -n "$1" ] && [ "$1" = "$(persist_live_canary_dir)" ]
}

# persist_live_root_sh rw|ro SCRIPT [ARG...]
persist_live_root_sh() {
    local mode="$1" script="$2" dir mount
    shift 2
    dir="$(persist_live_canary_dir)"
    case "$mode" in
        rw | ro) : ;;
        *)
            _persist_live_refuse "persist_live_root_sh: unknown mode '$mode' (rw or ro)."
            return 2
            ;;
    esac
    if ! persist_live_share_path_ok "$dir"; then
        _persist_live_refuse "persist_live_root_sh: '$dir' is not the canary's own directory; no container started."
        return 2
    fi
    mount="type=bind,source=$dir,target=/canary"
    [ "$mode" = rw ] || mount="$mount,readonly"
    dxe_runtime_call dx_runtime_run_ephemeral --rm -i --network none --user 0:0 --pull never \
        --label dxe.role=persist-live --mount "$mount" \
        --entrypoint sh "${DX_IMAGE:-}" -c "$script" sh /canary "$@"
}

# persist_live_kv KEY TEXT
persist_live_kv() {
    printf '%s\n' "$2" | sed -n "s/^$1=//p" | sed -n '1p'
}

# persist_live_marker_text GUEST STATE [SOURCE_VOLUME] [CREATED_AT] [MIGRATED_AT] [RETIRED_AT]
persist_live_marker_text() {
    printf 'schema=1\nguest=%s\nstate=%s\n' "$1" "$2"
    [ -z "${3:-}" ] || printf 'source-volume=%s\n' "$3"
    [ -z "${4:-}" ] || printf 'created-at=%s\n' "$4"
    [ -z "${5:-}" ] || printf 'migrated-at=%s\n' "$5"
    [ -z "${6:-}" ] || printf 'retired-at=%s\n' "$6"
}
