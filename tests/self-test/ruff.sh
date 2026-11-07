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
# Self-test caller for the ruff action: a Python module with ruff's default rules. The bad change
# adds an unused import (fixed in place by ruff-check --fix), a use of an undefined name (F821,
# which ruff reports and cannot fix) and code ruff-format rewrites.
#
# Usage: tests/self-test/ruff.sh bad|clean|none|nested [DIR] (see lib.sh)

set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
st_init "$@"

rev="$(st_rev https://github.com/astral-sh/ruff-pre-commit)"
st_write .pre-commit-config.yaml <<EOF
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: ${rev}
    hooks:
      - id: ruff-check
        args: ["--fix"]
      - id: ruff-format
      - id: ruff-check
        alias: ruff-check-rdjson
        args: ["--fix", "-q", "--output-format=rdjson"]
        stages: [manual]
EOF
st_write src/greet.py <<'EOF'
def greet(name: str) -> str:
    return f"Hello, {name}"
EOF
st_write notes.txt <<<"Notes."
st_commit_base "chore(caller): add the clean base"

case "${ST_MODE}" in
bad)
	st_write src/greet.py <<'EOF'
import os


def greet( name: str ) -> str:
    return f"Hello, {name}" + undefined_suffix
EOF
	st_commit "feat(greet): add a suffix"
	;;
clean | nested)
	cat >>"${ST_DIR}/src/greet.py" <<'EOF'


def farewell(name: str) -> str:
    return f"Goodbye, {name}"
EOF
	st_commit "feat(greet): add a farewell"
	;;
none)
	st_write notes.txt <<<"Notes, updated."
	st_commit "docs(notes): update the notes"
	;;
esac

st_finish 'F821' ruff-check-rdjson manual
