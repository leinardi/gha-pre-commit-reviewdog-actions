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
# Self-test caller for the yamllint action: a YAML file with yamllint's default rules. The bad
# change repeats a mapping key (key-duplicates), which yamllint reports and cannot fix.
#
# Usage: tests/self-test/yamllint.sh bad|clean|none|nested [DIR] (see lib.sh)

set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
st_init "$@"

rev="$(st_rev https://github.com/adrienverge/yamllint)"
st_write .pre-commit-config.yaml <<EOF
repos:
  - repo: https://github.com/adrienverge/yamllint
    rev: ${rev}
    hooks:
      - id: yamllint
      - id: yamllint
        alias: yamllint-parsable
        name: "yamllint (parsable output)"
        args: ["--format", "parsable"]
        stages: [manual]
EOF
st_write data.yaml <<'EOF'
---
name: caller
EOF
st_write notes.txt <<<"Notes."
st_commit_base "chore(caller): add the clean base"

case "${ST_MODE}" in
bad)
	st_write data.yaml <<'EOF'
---
name: caller
name: again
EOF
	st_commit "feat(data): rename"
	;;
clean | nested)
	st_write data.yaml <<'EOF'
---
name: caller
version: 2
EOF
	st_commit "feat(data): add the version"
	;;
none)
	st_write notes.txt <<<"Notes, updated."
	st_commit "docs(notes): update the notes"
	;;
esac

st_finish 'key-duplicates' yamllint-parsable manual
