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
