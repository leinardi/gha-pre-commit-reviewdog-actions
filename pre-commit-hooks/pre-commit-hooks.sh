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
# Runs the caller's list of pre-commit hooks as one pass of lib/run-passes.sh: every hook on one
# snapshot, so fixes that overlap (end-of-file-fixer and trailing-whitespace on one file) become
# one diff, reported as "pre-commit-hooks (hooks fixes)".
#
# Environment: HOOKS, the action's `hooks` input: one hook id or alias per line; blank lines and
# lines starting with # are skipped, the rest is trimmed. Each id must match
# ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ (never an option, no spaces, no inline comment), appear once, and
# there must be at least one. Every other variable is run-passes.sh's (ACTION_NAME, FROM_REF,
# TO_REF, WORKING_DIRECTORY, REPORTER, REVIEWDOG_GITHUB_API_TOKEN, VALIDATE_ONLY, ...), passed
# through unchanged; PASSES is built here and replaces any value from the environment.
#
# An invalid list is an operational error before anything runs: an ::error::, the outputs
# exitcode=0, hooks-exitcode= (empty), ran=false, result=error and findings=0, and exit 2, as
# run-passes.sh does for its own bad inputs. Otherwise run-passes.sh's outputs and exit status are
# this script's.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_PASSES="${HERE}/../lib/run-passes.sh"

esc() {
	local s="$*"
	s="${s//'%'/%25}"
	s="${s//$'\r'/%0D}"
	s="${s//$'\n'/%0A}"
	printf '%s' "${s}"
}

refuse() {
	echo "::error::pre-commit-hooks: $(esc "$*"); nothing was run"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf '%s\n' "exitcode=0" "hooks-exitcode=" "ran=false" "result=error" "findings=0" >>"${GITHUB_OUTPUT}"
	fi
	exit 2
}

[[ -n "${HOOKS+set}" ]] || refuse "HOOKS is not set"

hooks=()
declare -A seen=()
n=0
while IFS= read -r line || [[ -n "${line}" ]]; do
	n=$((n + 1))
	line="${line%$'\r'}"
	line="${line#"${line%%[![:space:]]*}"}"
	line="${line%"${line##*[![:space:]]}"}"
	[[ -n "${line}" && "${line}" != \#* ]] || continue
	if [[ ! "${line}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
		refuse "hooks line ${n} '${line}' is not a hook id (^[A-Za-z0-9_][A-Za-z0-9_.-]*\$: one id per line, comments on their own line)"
	fi
	[[ -z "${seen[${line}]:-}" ]] || refuse "hooks lists ${line} more than once"
	seen[${line}]=1
	hooks+=("${line}")
done <<<"${HOOKS}"
((${#hooks[@]} > 0)) || refuse "hooks lists no hook id"

PASSES="$(printf '%s\n' "${hooks[@]}" | jq -R -s -c '
	[{id: "hooks", hooks: (split("\n") | map(select(length > 0))), stage: "pre-commit",
	  reports: [{source: "tree", format: "diff", name: "pre-commit-hooks (hooks fixes)"}]}]')" ||
	refuse "jq could not build PASSES"
export PASSES
exec "${RUN_PASSES}"
