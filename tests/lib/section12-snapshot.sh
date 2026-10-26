#!/bin/bash
# Safe to source: functions only. Builds the clean repository snapshot that
# tests/test_section12_validate_linux.sh ships into the guest.
#
# The archive goes through a FILE inside the caller's own temp directory, never
# a `writer | tar -x` pipe: macOS bsdtar can close its stdin early, the writer
# then dies of EPIPE and pipefail turns that into rc 141 (2026-10-16 live run).

# section12_snapshot_build BASE_DIR SNAPSHOT_DIR WORK_DIR
#   BASE_DIR     the checkout to snapshot (git archive HEAD, else a plain copy
#                without VCS metadata and macOS AppleDouble sidecar files)
#   SNAPSHOT_DIR existing directory that receives the files
#   WORK_DIR     existing temp directory, outside SNAPSHOT_DIR, for the archive
section12_snapshot_build() {
    local base="$1" snapshot="$2" work="$3" archive
    archive="$work/section12-snapshot.tar"
    if git -C "$base" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$base" archive -o "$archive" HEAD || return 1
    else
        (cd "$base" && COPYFILE_DISABLE=1 tar --exclude '._*' --exclude '.git' -cf "$archive" .) || return 1
    fi
    tar -xf "$archive" -C "$snapshot" || return 1
    rm -f "$archive"
}
