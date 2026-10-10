#!/bin/bash
# Host-side module for the per-guest /persist directory on a NAS (plan D-8).
# Safe to source; performs no I/O merely by being sourced.
#
# The marker FORMAT (what .dxe-persist-dir contains, how it is parsed and
# written) is POSIX sh shared with the guest, so it lives in
# container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh. Like
# bin/lib/dx-backup.sh and its selector, this module sources it directly by
# path -- both live in the same repository checkout on the host.

DX_PERSIST_DIR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DX_PERSIST_DIR_PROJECT_ROOT="$(cd "$DX_PERSIST_DIR_LIB_DIR/../.." && pwd)"
DX_PERSIST_DIR_MARKER_SOURCE="$DX_PERSIST_DIR_PROJECT_ROOT/container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh"
# shellcheck source=../../container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh
source "$DX_PERSIST_DIR_MARKER_SOURCE"
