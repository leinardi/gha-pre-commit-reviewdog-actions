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
# Self-test caller for the pre-commit-hooks action, with its default hook list. The bad change
# adds a text file with trailing whitespace and no final newline (fixed in place) and a YAML file
# that does not parse (a validator-only failure, which changes nothing).
#
# Every one of these hooks runs on any file type, so the none row is a commit that only deletes a
# file, which leaves no changed file to run on. The nested row is the one with an untracked nested
# checkout (see lib.sh): its files would be fixed by trailing-whitespace and end-of-file-fixer if
# the action ever passed them to a hook.
#
# The bad content is written with printf, not a heredoc, so this file has no trailing whitespace
# for this repository's own hooks to fix.
#
# Usage: tests/self-test/pre-commit-hooks.sh bad|clean|none|nested [DIR] (see lib.sh)

set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
st_init "$@"

rev="$(st_rev https://github.com/pre-commit/pre-commit-hooks)"
st_write .pre-commit-config.yaml <<EOF
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: ${rev}
    hooks:
      - id: check-merge-conflict
      - id: end-of-file-fixer
      - id: trailing-whitespace
      - id: check-yaml
      - id: check-json
      - id: check-toml
      - id: check-added-large-files
EOF
st_write notes.txt <<<"Notes."
st_write docs/guide.txt <<<"A guide."
st_write obsolete.txt <<<"To be deleted."
st_commit_base "chore(caller): add the clean base"

case "${ST_MODE}" in
bad)
	printf 'Trailing whitespace   \nand no final newline' >"${ST_DIR}/docs/guide.txt"
	printf 'key: [unclosed\n' >"${ST_DIR}/config.yaml"
	st_commit "docs(guide): extend the guide"
	;;
clean | nested)
	st_write docs/guide.txt <<<"A guide, extended."
	st_write config.yaml <<<"key: [closed]"
	st_commit "docs(guide): extend the guide"
	;;
none)
	rm -- "${ST_DIR}/obsolete.txt"
	st_commit "chore(caller): delete an obsolete file"
	;;
esac

st_finish '+Trailing whitespace' trailing-whitespace pre-commit
