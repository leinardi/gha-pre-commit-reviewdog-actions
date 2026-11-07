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
# Self-test caller for the conventional-commits action: the range's commit messages are what is
# checked. The bad head commit has a message that is not a Conventional Commit; the clean one is a
# scoped Conventional Commit; the none range holds only a merge commit, which the action skips,
# so no commit is checked (its message is not conventional either, to prove the skip).
#
# The action has no result or ran output, so the expected finding is the bad subject line and
# check-hook is empty: there is no file hook to run afterwards.
#
# Usage: tests/self-test/conventional-commits.sh bad|clean|none|nested [DIR] (see lib.sh)

set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
st_init "$@"

rev="$(st_rev https://github.com/compilerla/conventional-pre-commit)"
st_write .pre-commit-config.yaml <<EOF
repos:
  - repo: https://github.com/compilerla/conventional-pre-commit
    rev: ${rev}
    hooks:
      - id: conventional-pre-commit
        stages: [commit-msg]
        args: ["--force-scope"]
EOF
st_write notes.txt <<<"Notes."
st_commit "chore(caller): add the configuration"
st_write notes.txt <<<"Notes, second version."
st_commit_base "docs(notes): extend the notes"

case "${ST_MODE}" in
bad)
	st_write notes.txt <<<"Notes, third version."
	st_commit "updated some notes"
	;;
clean | nested)
	st_write notes.txt <<<"Notes, third version."
	st_commit "docs(notes): extend the notes again"
	;;
none)
	# A merge of HEAD with its own parent: the range from-ref..to-ref is this one merge commit.
	tree="$(git -C "${ST_DIR}" rev-parse 'HEAD^{tree}')"
	merge="$(git -C "${ST_DIR}" commit-tree "${tree}" -p HEAD -p HEAD~1 -m "Merge without a conventional message")"
	git -C "${ST_DIR}" merge -q --ff-only "${merge}"
	;;
esac

st_finish 'updated some notes' "" ""
