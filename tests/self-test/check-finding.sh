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
# A secondary check of a CI self-test bad row: the hook itself, run directly in the caller on the
# same changed files, fails and its output or the fixes it made in place (git diff) contain the
# generator's expected-finding text.
#
# The primary check is check-reports.sh, on what the action actually handed reviewdog. This one
# tells the two ways that check can fail apart: the generator's bad change no longer trips the
# hook (this fails too), or the action lost the finding between the hook and reviewdog (this
# passes). It runs last: the hook may change the caller.
#
# Usage: tests/self-test/check-finding.sh CALLER_DIR
# Environment: FROM_REF, TO_REF, CHECK_HOOK, CHECK_STAGE, EXPECTED (the generator's outputs).

set -euo pipefail

[[ $# -eq 1 ]] || {
	echo "Usage: $0 CALLER_DIR" >&2
	exit 2
}
: "${FROM_REF:?}" "${TO_REF:?}" "${CHECK_HOOK:?}" "${CHECK_STAGE:?}" "${EXPECTED:?}"
cd "$1"

files=()
while IFS= read -r -d '' path; do
	[[ ! -e "${path}" && ! -L "${path}" ]] || files+=("${path}")
done < <(git diff --name-only --no-ext-diff -z "${FROM_REF}...${TO_REF}")
if ((${#files[@]} == 0)); then
	echo "::error::no changed file between ${FROM_REF} and ${TO_REF}: the bad row has nothing to check"
	exit 1
fi

log="$(mktemp)"
trap 'rm -f "${log}"' EXIT
rc=0
pre-commit run "${CHECK_HOOK}" --hook-stage "${CHECK_STAGE}" --color=never --files "${files[@]}" >"${log}" 2>&1 || rc=$?
git diff --no-ext-diff >>"${log}"

echo "::group::${CHECK_HOOK} (exit ${rc}) and its fixes"
cat "${log}"
echo "::endgroup::"

if ((rc == 0)); then
	echo "::error::${CHECK_HOOK} passed on the bad change"
	exit 1
fi
if ! grep -qF -- "${EXPECTED}" "${log}"; then
	echo "::error::${CHECK_HOOK} failed, but neither its output nor its fixes contain: ${EXPECTED}"
	exit 1
fi
echo "${CHECK_HOOK} failed with the planted finding: ${EXPECTED}"
