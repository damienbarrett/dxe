#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -z "$(git -C "$ROOT" status --porcelain)" ] || {
    echo "Error: release worktree is not clean." >&2
    exit 1
}
echo "Release worktree check passed."
