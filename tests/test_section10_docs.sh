#!/bin/bash
# Section 10: Update Documentation
# Tests for: README.md explains principles, workflow, configuration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
README="$BASE_DIR/README.md"

test_section "Section 10: Update Documentation"

# Test: README.md exists
assert_file_exists "$README" "README.md exists"

# Test: README explains lightweight Containerfile rule
assert_file_contains "$README" "[Ll]ightweight\|[Cc]ontainerfile" "README explains lightweight Containerfile rule"

# Test: README documents guest bootstrap owns installation
assert_file_contains "$README" "[Bb]ootstrap\|[Gg]uest.*install\|[Gg]uest.*config" "README documents guest bootstrap responsibility"

# Test: README documents SSH key creation/providing
assert_file_contains "$README" "[Ss][Ss][Hh].*[Kk]ey\|[Cc]reate.*key\|[Pp]rovide.*key" "README documents SSH key creation"

# Test: README documents passwordless sudo for dx user
assert_file_contains "$README" "[Pp]asswordless.*sudo\|sudo.*NOPASSWD\|dx.*sudo" "README documents passwordless sudo for dx"

# Test: README documents SSH password and root login disabled
assert_file_contains "$README" "[Pp]assword.*[Ll]ogin.*disable\|[Rr]oot.*[Ll]ogin.*disable\|PasswordAuthentication no" "README documents SSH password login disabled"

# Test: README documents NixVim as only editor config path
assert_file_contains "$README" "[Nn]ix[Vv]im\|[Ee]ditor.*[Cc]onfig.*[Nn]ix[Vv]im" "README documents NixVim as editor config"

# Test: README documents build/create/start/ssh/status/put/stop workflow
assert_file_contains "$README" "[Bb]uild\|dx-build" "README documents build workflow"
assert_file_contains "$README" "[Cc]reate\|dx-create" "README documents create workflow"
assert_file_contains "$README" "[Ss]tart\|dx-start" "README documents start workflow"
assert_file_contains "$README" "[Ss][Ss][Hh]\|dx-ssh" "README documents ssh workflow"
assert_file_contains "$README" "[Ss]tatus\|dx-status" "README documents status workflow"
assert_file_contains "$README" "[Pp]ut\|dx-put" "README documents put workflow"
assert_file_contains "$README" "[Ss]top\|dx-stop" "README documents stop workflow"
assert_file_contains "$README" "dx-ai" "README documents optional AI tool workflow"

# Test: README documents rerunning guest bootstrap
assert_file_contains "$README" "[Rr]erun\|[Rr]e-run\|[Rr]ebootstrap\|[Rr]e-bootstrap" "README documents rerunning guest bootstrap"

print_summary
exit_with_code
