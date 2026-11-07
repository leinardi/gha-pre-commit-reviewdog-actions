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
# Tests sqlfluff.sh: run-fix picks the passes handed to run-passes.sh (a stub, and the real one in
# VALIDATE_ONLY mode with the PASSES of action.yaml). No network, no pre-commit.
#
# Needs: jq, and python3 with PyYAML (or yq) to read action.yaml.
#
# Run: bash sqlfluff/sqlfluff.test.sh

# Each check's condition is a single-quoted string that check evaluates after the run, so the
# variables it reads are set by then (SC2016), and some are read only there (SC2034).
# shellcheck disable=SC2016,SC2034

SCRIPT_NAME=sqlfluff.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="${HERE##*/}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
NL=$'\n'

# A copy of the action next to a stub lib/run-passes.sh that records its environment.
mkdir -p "${WORK}/action/lib" "${WORK}/action/${ACTION_DIR}"
cp "${HERE}/${SCRIPT_NAME}" "${WORK}/action/${ACTION_DIR}/"
cat >"${WORK}/action/lib/run-passes.sh" <<'STUB'
#!/usr/bin/env bash
env | LC_ALL=C sort >"${STUB_ENV}"
printf '%s' "${PASSES:-}" >"${STUB_PASSES}"
echo "stub run-passes"
exit "${STUB_RC:-0}"
STUB
chmod +x "${WORK}/action/lib/run-passes.sh"

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "ok - $1"
}
not_ok() {
	FAIL=$((FAIL + 1))
	echo "not ok - $1"
	if [[ -n "${2:-}" ]]; then
		while IFS= read -r line; do printf '       %s\n' "${line}"; done <<<"$2"
	fi
}
check() {
	local name="$1"
	shift
	if "$@"; then ok "${name}"; else not_ok "${name}" "status ${STATUS}${NL}${LOG}${NL}OUTPUT:${NL}${OUTPUT}"; fi
}

# run [ENV=VALUE...]: runs the copy with the stub. Sets STATUS, LOG, OUTPUT, ENV_SEEN, PASSES_SEEN.
N=0
run() {
	N=$((N + 1))
	local dir="${WORK}/run-${N}"
	mkdir -p "${dir}"
	: >"${dir}/output"
	STATUS=0
	LOG="$(env -i PATH="${PATH}" HOME="${dir}" GITHUB_OUTPUT="${dir}/output" STUB_ENV="${dir}/env" \
		STUB_PASSES="${dir}/passes" "$@" bash "${WORK}/action/${ACTION_DIR}/${SCRIPT_NAME}" 2>&1)" || STATUS=$?
	OUTPUT="$(cat "${dir}/output")"
	ENV_SEEN="$(cat "${dir}/env" 2>/dev/null || true)"
	PASSES_SEEN="$(cat "${dir}/passes" 2>/dev/null || true)"
}
# validate [ENV=VALUE...]: runs the real script of this checkout with the real run-passes.sh in
# VALIDATE_ONLY mode. Sets STATUS and LOG.
validate() {
	STATUS=0
	LOG="$(env -i PATH="${PATH}" HOME="${WORK}" ACTION_NAME="${ACTION_DIR}" VALIDATE_ONLY=true "$@" \
		bash "${HERE}/${SCRIPT_NAME}" 2>&1)" || STATUS=$?
	OUTPUT=""
}
out() { sed -n "s/^$1=//p" <<<"${OUTPUT}"; }

# The PASSES literal of action.yaml's run step.
if command -v python3 >/dev/null && python3 -I -c 'import yaml' 2>/dev/null; then
	ACTION_PASSES="$(python3 -I -c 'import sys, yaml; print([s for s in yaml.safe_load(open(sys.argv[1]))["runs"]["steps"] if s.get("id") == "run"][0]["env"]["PASSES"])' "${HERE}/action.yaml")"
else
	ACTION_PASSES="$(yq '.runs.steps[] | select(.id == "run") | .env.PASSES' "${HERE}/action.yaml")"
fi

run RUN_FIX=true PASSES="${ACTION_PASSES}" FROM_REF=abc
check "run-fix true keeps the lint and fix passes, PASSES unchanged" \
	eval '[[ ${STATUS} == 0 && "${PASSES_SEEN}" == "${ACTION_PASSES}" && "$(jq -c "[.[].id]" <<<"${PASSES_SEEN}")" == "[\"lint\",\"fix\"]" ]]'
check "every other variable reaches run-passes.sh unchanged" eval 'grep -qx "FROM_REF=abc" <<<"${ENV_SEEN}"'
run RUN_FIX=false PASSES="${ACTION_PASSES}"
check "run-fix false drops the fix pass, so sqlfluff-fix never runs" \
	eval '[[ ${STATUS} == 0 && "$(jq -c "[.[].id]" <<<"${PASSES_SEEN}")" == "[\"lint\"]" ]] && ! grep -q sqlfluff-fix <<<"${PASSES_SEEN}"'
for value in True yes "" " true"; do
	run RUN_FIX="${value}" PASSES="${ACTION_PASSES}"
	check "run-fix '${value}' is refused with result=error before anything runs" \
		eval '[[ ${STATUS} == 2 && -z "${PASSES_SEEN}" && $(out result) == error && $(out ran) == false ]] && grep -q "run-fix must be true or false" <<<"${LOG}"'
done
run RUN_FIX=$'true\n::error::injected %0A' PASSES="${ACTION_PASSES}"
check "a run-fix with a line break cannot inject a workflow command: %, CR and LF are escaped" \
	eval '[[ ${STATUS} == 2 ]] && ! grep -q "^::error::injected" <<<"${LOG}" && grep -qF "got '"'"'true%0A::error::injected %250A'"'"'" <<<"${LOG}"'
run RUN_FIX=false PASSES='not json'
check "PASSES that is not JSON is refused" eval '[[ ${STATUS} == 2 && $(out result) == error ]]'

validate RUN_FIX=true PASSES="${ACTION_PASSES}"
check "the real run-passes.sh accepts action.yaml's PASSES with run-fix true" eval '[[ ${STATUS} == 0 ]] && grep -q "(lint fix)" <<<"${LOG}"'
validate RUN_FIX=false PASSES="${ACTION_PASSES}"
check "the real run-passes.sh accepts action.yaml's PASSES with run-fix false" eval '[[ ${STATUS} == 0 ]] && grep -q "1 pass(es) (lint)" <<<"${LOG}"'

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
