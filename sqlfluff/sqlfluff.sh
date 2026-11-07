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
# The sqlfluff run step: picks the passes from the run-fix input, then runs lib/run-passes.sh.
#
# Environment: RUN_FIX (the action's run-fix input: true or false) and PASSES (the action's lint
# and fix passes, from action.yaml); every other variable is run-passes.sh's, passed through
# unchanged. With RUN_FIX=false the pass with id "fix" is dropped, so sqlfluff-fix never runs and
# fix-exitcode stays empty. Any other RUN_FIX is an operational error before anything runs: an
# ::error::, the outputs exitcode=0, lint-exitcode= (empty), ran=false, result=error, findings=0,
# and exit 2.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_PASSES="${HERE}/../lib/run-passes.sh"

# Workflow-command data must have %, CR and LF escaped, or a value could end the message early
# and start a command of its own.
esc() {
	local s="$*"
	s="${s//'%'/%25}"
	s="${s//$'\r'/%0D}"
	s="${s//$'\n'/%0A}"
	printf '%s' "${s}"
}

refuse() {
	echo "::error::sqlfluff: $(esc "$*"); nothing was run"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf '%s\n' "exitcode=0" "lint-exitcode=" "ran=false" "result=error" "findings=0" >>"${GITHUB_OUTPUT}"
	fi
	exit 2
}

case "${RUN_FIX-}" in
true) ;;
false)
	PASSES="$(jq -c 'map(select(.id != "fix"))' <<<"${PASSES:-}")" ||
		refuse "PASSES is not a JSON array of passes"
	export PASSES
	;;
*) refuse "run-fix must be true or false, got '${RUN_FIX-}'" ;;
esac
exec "${RUN_PASSES}"
