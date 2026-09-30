#!/bin/bash
# WP1.4 (Fable D2): the file list below used to be a fifth hand-maintained
# copy of which suites run under Bash 3.2; it is now derived by
# tests/run.sh --bash32 from every tests/test_*.sh's own `# bash32: yes`
# header (tier: unit and bash32: yes together), so a suite that is safe
# under 3.2 opts in at the file, not here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="$(/bin/bash --version | head -1)"
case "$version" in *'version 3.2.'*) ;; *) echo "Error: /bin/bash is not Bash 3.2: $version" >&2; exit 1 ;; esac

/bin/bash -n "$SCRIPT_DIR"/../bin/dx* "$SCRIPT_DIR"/../bin/lib/*.sh "$SCRIPT_DIR"/qnap/phase0-*.sh "$SCRIPT_DIR"/qnap/lib/*.sh
# tests/qnap/phase0-*.sh run on this Mac's default Bash 3.2, exactly like
# bin/dx*, so the `bash -n` line above is their Bash 3.2 regression net;
# tests/test_section27_qnap_scripts.sh (its own `# bash32: yes` suite) is
# swept below along with everything else.
"$SCRIPT_DIR/run.sh" --tier unit --bash32
