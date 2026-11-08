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
# Self-test caller for the mypy action: a typed Python module. The bad change assigns an int to a
# str variable.
#
# Usage: tests/self-test/mypy.sh bad|clean|none|nested [DIR] (see lib.sh)

set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
st_init "$@"

rev="$(st_rev https://github.com/pre-commit/mirrors-mypy)"
st_write .pre-commit-config.yaml <<EOF
repos:
  - repo: https://github.com/pre-commit/mirrors-mypy
    rev: ${rev}
    hooks:
      - id: mypy
      - id: mypy
        alias: mypy-json-output
        name: mypy (json output)
        args:
          [
            "--output",
            "json",
            "--hide-error-context",
            "--show-column-numbers",
            "--show-absolute-path",
            "--no-pretty",
            "--ignore-missing-imports",
            "--scripts-are-modules",
          ]
        stages: [manual]
EOF
st_write src/calc.py <<'EOF'
def add(a: int, b: int) -> int:
    return a + b
EOF
st_write notes.txt <<<"Notes."
st_commit_base "chore(caller): add the clean base"

case "${ST_MODE}" in
bad)
	cat >>"${ST_DIR}/src/calc.py" <<'EOF'


total: str = add(1, 2)
EOF
	st_commit "feat(calc): add a total"
	;;
clean | nested)
	cat >>"${ST_DIR}/src/calc.py" <<'EOF'


total: int = add(1, 2)
EOF
	st_commit "feat(calc): add a total"
	;;
none)
	st_write notes.txt <<<"Notes, updated."
	st_commit "docs(notes): update the notes"
	;;
esac

st_finish 'Incompatible types in assignment' mypy-json-output manual
