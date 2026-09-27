#!/bin/bash
# Reusable fake executable helpers. Safe to source.

fake_tool_dir_create() {
    local parent="${1:-${TMPDIR:-/tmp}}"
    mktemp -d "$parent/dxe-fake-tools.XXXXXX"
}

fake_tool_write() {
    local directory="$1" name="$2" body="$3"
    mkdir -p "$directory"
    printf '#!/bin/bash\n%s\n' "$body" > "$directory/$name"
    chmod 0755 "$directory/$name"
}

# Fake `ssh` for the DX guest boundary. dx_guest_bash_command transports the
# guest command body base64-encoded (R4), so a fixture matching plaintext
# substrings of "$@" sees only the wrapper -- it would report "unexpected
# response" for every probe, or worse, keep passing for the wrong reason if
# the assertion happened to be satisfied by the wrapper text.
#
# Two distinct things cross this boundary and fixtures must be able to say
# which one they mean, so both are exposed by name rather than by mutating
# "$@":
#
#   DX_FAKE_GUEST_RAW  the remote command string as ssh received it -- the env
#                      prefix and the `bash -l -c '...'` wrapper. Match this to
#                      assert the boundary itself (the F1 regression guard).
#   DX_FAKE_GUEST_CMD  the decoded command body, obtained exactly as the
#                      guest's inner bash obtains it. Match this to assert what
#                      the guest was actually asked to do.
#
# The decode lives here so every ssh fixture agrees on how the boundary works.
fake_ssh_write() {
    local directory="$1" body="$2"
    fake_tool_write "$directory" ssh "$(printf '%s\n%s' \
'DX_FAKE_GUEST_RAW=""
DX_FAKE_GUEST_CMD=""
for dx_fake_arg in "$@"; do DX_FAKE_GUEST_RAW="$dx_fake_arg"; done
case "$DX_FAKE_GUEST_RAW" in
    *DX_GUEST_CMD_B64=*)
        dx_fake_b64=${DX_FAKE_GUEST_RAW#*DX_GUEST_CMD_B64=}
        dx_fake_b64=${dx_fake_b64%% *}
        DX_FAKE_GUEST_CMD="$(printf %s "$dx_fake_b64" | base64 -d)"
        ;;
esac' "$body")"
}

# Fake `ssh` for the docker-ssh runtime adapter's MANAGEMENT-plane transport
# (bin/lib/dx-runtime-docker.sh), distinct from fake_ssh_write above (that
# one is the DX guest boundary's own base64-wrapped transport; this one is
# not that). The real adapter always sends ONE already-quoted remote
# command string (dx_runtime_docker_quote_argv), matching exactly how a
# real sshd hands the joined trailing argument to the remote login shell to
# parse -- this fake reproduces that hand-off with a plain `eval` in its own
# process, so a fixture's own fake `docker` (or `uname`, etc.) executable,
# placed on PATH in the same directory via fake_tool_write, runs exactly as
# it would on the real remote host. A test asserting the exact argv ssh
# itself was invoked with (the management connection options, or the raw
# quoted command string before it is parsed) should read $DXE_FAKE_SSH_ARGV_LOG
# if it set DXE_FAKE_SSH_ARGV_LOG to a writable file path first.
fake_qnap_ssh_write() {
    local directory="$1"
    fake_tool_write "$directory" ssh '
if [ -n "${DXE_FAKE_SSH_ARGV_LOG:-}" ]; then printf "%s\n" "$@" > "$DXE_FAKE_SSH_ARGV_LOG"; fi
dx_fake_last=""
for dx_fake_arg in "$@"; do dx_fake_last="$dx_fake_arg"; done
eval "$dx_fake_last"
'
}
