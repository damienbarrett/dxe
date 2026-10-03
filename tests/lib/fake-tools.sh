#!/bin/bash
# Reusable fake executable helpers. Safe to source.

# Every network-reaching tool a fixture directory refuses by default. A
# fixture that puts this directory first on PATH but forgets to write one of
# its fakes would otherwise fall through to the REAL tool and, with a fixture
# alias that is also a real ssh_config alias, reach a real host (incident
# 2026-10-03). A fake written afterwards with fake_tool_write replaces the
# default at the same path.
FAKE_TOOLS_FAIL_CLOSED_LIST="ssh scp sftp docker tailscale container nix curl"

fake_tool_dir_create() {
    local parent="${1:-${TMPDIR:-/tmp}}" directory fake_tool_name
    directory="$(mktemp -d "$parent/dxe-fake-tools.XXXXXX")" || return 1
    for fake_tool_name in $FAKE_TOOLS_FAIL_CLOSED_LIST; do
        fake_tool_write "$directory" "$fake_tool_name" \
            "echo 'fake-tools: no fake for $fake_tool_name; refusing to reach a real host' >&2
exit 99"
    done
    printf '%s\n' "$directory"
}

fake_tool_write() {
    local directory="$1" name="$2" body="$3"
    mkdir -p "$directory"
    # #!/usr/bin/env bash, not #!/bin/bash (Fable E3): a hardcoded /bin/bash
    # shebang only resolves where that literal path exists -- true on macOS
    # and Ubuntu, false on a NixOS or nix-profile host, where the
    # container-free tier could otherwise never run at all. env searches
    # PATH instead, so this fake still resolves bash as long as PATH names
    # wherever bash actually lives (see tests/lib/harness.sh's
    # with_fake_runtime, which pins exactly that).
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$directory/$name"
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
# if it set DXE_FAKE_SSH_ARGV_LOG to a writable file path first. The write
# APPENDS (Fable D5 -- was `>`, which only ever left the LAST call visible
# and made "assert there was no second call" impossible); a fixture that
# wants only the latest call's argv truncates the log itself right before
# making that one call.
#
# The eval below runs the "remote" command on the controller itself, so the
# controller's PATH stands in for the NAS's non-interactive PATH. A fixture
# whose remote must NOT have a bare `docker` (the discovery refusal, the
# qpkg-glob fallback) sets DXE_FAKE_SSH_REMOTE_PATH to a directory it
# controls; otherwise a host that really has one -- GitHub's ubuntu runners
# ship /usr/bin/docker -- leaks into the fake remote and the test proves
# nothing (CI run 36296075448, 2026-09-27). Unset, the PATH is left alone.
#
# Whatever DXE_FAKE_SSH_REMOTE_PATH names, a directory holding ONLY a
# `bash` symlink (resolved from THIS process's still-unrestricted PATH,
# before the override below) is always appended (Fable E3): every fake
# this eval might reach -- whether at that restricted path or further
# down it via a glob, like the qpkg-fallback fixture's docker -- now has a
# `#!/usr/bin/env bash` shebang, not a hardcoded `#!/bin/bash`, so env
# needs bash to still be findable even on a deliberately bare remote PATH.
# This does not weaken what a fixture is proving: the tool under test
# (docker, tailscale, ...) is still absent from DXE_FAKE_SSH_REMOTE_PATH
# exactly as that fixture set it, only bash itself is additionally
# reachable.
#
# This directory must never be the real bash binary's own directory
# (bash's `dirname "$(command -v bash)"`, what this used to append
# directly): on GitHub's ubuntu runners that directory is /usr/bin, which
# also holds a real `docker` -- appending it leaked a real `docker` onto
# the "bare PATH" a discovery-refusal/qpkg-fallback fixture had gone to
# the trouble of keeping empty, so those two cases passed on this Mac (no
# /usr/bin/docker here) and failed on CI (CI run 36640705743, following
# the SAME leak this comment already named once, from CI run 36296075448,
# 2026-09-27 -- that fix narrowed WHERE the leak came from without
# actually closing it). Fixed by creating a private directory under the
# fixture's own tool directory, seeded with nothing but a `bash` symlink,
# the first time it is needed, and appending THAT instead.
fake_qnap_ssh_write() {
    local directory="$1" bash_only_dir="$1/.dxe-fake-bash-only"
    fake_tool_write "$directory" ssh "$(printf '%s\n%s' \
        "dxe_fake_bash_only_dir=\"$bash_only_dir\"" \
        'if [ -n "${DXE_FAKE_SSH_ARGV_LOG:-}" ]; then printf "%s\n" "$@" >> "$DXE_FAKE_SSH_ARGV_LOG"; fi
if [ -n "${DXE_FAKE_SSH_REMOTE_PATH:-}" ]; then
    if [ ! -e "$dxe_fake_bash_only_dir/bash" ]; then
        mkdir -p "$dxe_fake_bash_only_dir"
        ln -sf "$(command -v bash)" "$dxe_fake_bash_only_dir/bash"
    fi
    PATH="$DXE_FAKE_SSH_REMOTE_PATH:$dxe_fake_bash_only_dir"
    export PATH
fi
dx_fake_last=""
for dx_fake_arg in "$@"; do dx_fake_last="$dx_fake_arg"; done
eval "$dx_fake_last"')"
}
