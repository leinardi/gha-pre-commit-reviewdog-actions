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
# Checks the verdict of one CI self-test row: which action step ran, its outcome and its outputs,
# against what the row's mode requires.
#
# The self-test job has one `uses: ./self/<action>` step per action (a `uses:` cannot be built
# from the matrix), each with id run-<action>, `continue-on-error: true` and an `if:` on the
# matrix action. This reads the job's steps context (toJSON(steps)) and requires that exactly the
# row's step ran, and that:
#
#   mode    outcome  result   ran    exitcode
#   bad     failure  failed   true   not 0
#   clean   success  passed   true   0        (the hook ran on the change and passed)
#   nested  success  passed   true   0        (as clean; the nested checkout was left out)
#   none    success  skipped  false  0        (nothing the hooks look at changed)
#
# conventional-commits has only the exitcode output: bad must fail with exitcode 1, every other
# mode succeed with exitcode 0.
#
# Environment: ACTION, MODE, STEPS (the JSON of the steps context).

set -euo pipefail

: "${ACTION:?}" "${MODE:?}" "${STEPS:?}"

id="run-${ACTION}"
ran_steps="$(jq -r '[to_entries[] | select(.key | startswith("run-")) | select(.value.outcome != "skipped") | .key] | join(" ")' <<<"${STEPS}")"
if [[ "${ran_steps}" != "${id}" ]]; then
	echo "::error::expected only step ${id} to run, but these ran: '${ran_steps}'"
	exit 1
fi

get() {
	jq -r --arg id "${id}" --arg key "$1" '.[$id] | if $key == "outcome" then .outcome else (.outputs[$key] // "") end' <<<"${STEPS}"
}
outcome="$(get outcome)"
result="$(get result)"
ran="$(get ran)"
exitcode="$(get exitcode)"

problems=()
# An output the action never wrote is a failure in itself, whatever the mode.
if [[ "${ACTION}" != conventional-commits ]]; then
	[[ -n "${result}" ]] || problems+=("the result output is empty: the action did not write its verdict")
	[[ -n "${ran}" ]] || problems+=("the ran output is empty")
fi
[[ -n "${exitcode}" ]] || problems+=("the exitcode output is empty")
want() {
	local name="$1" got="$2" expected="$3"
	if [[ "${got}" != "${expected}" ]]; then
		problems+=("${name} is '${got}', expected '${expected}'")
	fi
}

if [[ "${ACTION}" == conventional-commits ]]; then
	case "${MODE}" in
	bad)
		want outcome "${outcome}" failure
		want exitcode "${exitcode}" 1
		;;
	clean | nested | none)
		want outcome "${outcome}" success
		want exitcode "${exitcode}" 0
		;;
	*) problems+=("unknown mode ${MODE}") ;;
	esac
else
	case "${MODE}" in
	bad)
		want outcome "${outcome}" failure
		want result "${result}" failed
		want ran "${ran}" true
		if [[ ! "${exitcode}" =~ ^[1-9][0-9]*$ ]]; then
			problems+=("exitcode is '${exitcode}', expected a nonzero status")
		fi
		;;
	clean | nested)
		want outcome "${outcome}" success
		want result "${result}" passed
		want ran "${ran}" true
		want exitcode "${exitcode}" 0
		;;
	none)
		want outcome "${outcome}" success
		want result "${result}" skipped
		want ran "${ran}" false
		want exitcode "${exitcode}" 0
		;;
	*) problems+=("unknown mode ${MODE}") ;;
	esac
fi

echo "${ACTION} (${MODE}): outcome=${outcome} result=${result:-n/a} ran=${ran:-n/a} exitcode=${exitcode:-n/a}"
if ((${#problems[@]} > 0)); then
	for problem in "${problems[@]}"; do
		echo "::error::${ACTION} (${MODE}): ${problem}"
	done
	exit 1
fi
echo "The verdict is the one mode ${MODE} requires."
