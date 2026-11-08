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
# Self-test caller for the actionlint action: a workflow under .github/workflows/. The bad change
# reads a property the github context does not have, which actionlint reports and cannot fix.
#
# Usage: tests/self-test/actionlint.sh bad|clean|none|nested [DIR] (see lib.sh)

set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
st_init "$@"

rev="$(st_rev https://github.com/rhysd/actionlint)"
st_write .pre-commit-config.yaml <<EOF
repos:
  - repo: https://github.com/rhysd/actionlint
    rev: ${rev}
    hooks:
      - id: actionlint
        name: actionlint
        files: ^\.github/workflows/.*\.(yml|yaml)$
        args: ["-shellcheck", "shellcheck -S error"]
      - id: actionlint
        alias: actionlint-oneline
        name: actionlint (one line per one error)
        files: ^\.github/workflows/.*\.(yml|yaml)$
        args: ["-oneline", "-shellcheck", "shellcheck -S error"]
        stages: [manual]
EOF
st_write .github/workflows/build.yaml <<'EOF'
name: Build

on:
  push:

permissions:
  contents: read

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Say hello
        run: echo "hello"
EOF
st_write notes.txt <<<"Notes."
st_commit_base "chore(caller): add the clean base"

case "${ST_MODE}" in
bad)
	cat >>"${ST_DIR}/.github/workflows/build.yaml" <<'EOF'
      - name: Read a property github does not have
        env:
          VALUE: ${{ github.not_a_property }}
        run: echo "${VALUE}"
EOF
	st_commit "ci(build): read an unknown property"
	;;
clean | nested)
	cat >>"${ST_DIR}/.github/workflows/build.yaml" <<'EOF'
      - name: Say which ref
        env:
          REF: ${{ github.ref }}
        run: echo "${REF}"
EOF
	st_commit "ci(build): print the ref"
	;;
none)
	st_write notes.txt <<<"Notes, updated."
	st_commit "docs(notes): update the notes"
	;;
esac

st_finish 'property "not_a_property" is not defined' actionlint-oneline manual
