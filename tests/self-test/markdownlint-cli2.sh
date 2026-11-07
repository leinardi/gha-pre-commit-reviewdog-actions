#!/usr/bin/env bash
#
# MIT License
#
# Copyright (c) 2026 Roberto Leinardi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Self-test caller for the markdownlint-cli2 action: a README with markdownlint's default rules.
# The bad change skips heading levels (MD001), which markdownlint reports and cannot fix.
#
# Same rev as this repository's own hook; its additional_dependencies (a custom table rule) are
# left out, because the caller has no markdownlint config that loads the rule.
#
# Usage: tests/self-test/markdownlint-cli2.sh bad|clean|none|nested [DIR] (see lib.sh)

set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
st_init "$@"

rev="$(st_rev https://github.com/DavidAnson/markdownlint-cli2)"
st_write .pre-commit-config.yaml <<EOF
repos:
  - repo: https://github.com/DavidAnson/markdownlint-cli2
    rev: ${rev}
    hooks:
      - id: markdownlint-cli2
EOF
st_write README.md <<'EOF'
# Caller

A generated repository for the self-test.
EOF
st_write notes.txt <<<"Notes."
st_commit_base "chore(caller): add the clean base"

case "${ST_MODE}" in
bad)
	cat >>"${ST_DIR}/README.md" <<'EOF'

#### Skipped heading levels

This heading jumps from level one to level four.
EOF
	st_commit "docs(readme): add a section"
	;;
clean | nested)
	cat >>"${ST_DIR}/README.md" <<'EOF'

## Usage

Run the self-test.
EOF
	st_commit "docs(readme): add the usage"
	;;
none)
	st_write notes.txt <<<"Notes, updated."
	st_commit "docs(notes): update the notes"
	;;
esac

st_finish 'MD001' markdownlint-cli2 pre-commit
